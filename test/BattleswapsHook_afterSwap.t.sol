// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";

import "forge-std/console.sol";
import {BattleswapsRouter} from "../src/BattleswapsRouter.sol";
import {BattleswapsHook} from "../src/BattleswapsHook.sol";

contract BattleswapsHook_afterSwap is Test, Deployers {
    BattleswapsRouter battleswapsRouter;
    BattleswapsHook battleswapsHook;
    MockERC20 token0;
    MockERC20 token1;

    Currency token0Currency;
    Currency token1Currency;

    address requester;
    address opponent;

    function setUp() public {
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy the BattleswapsRouter contract
        battleswapsRouter = new BattleswapsRouter(manager);

        // Deploy the Token 0 and Token 1 contracts
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0Currency = Currency.wrap(address(token0));
        token1Currency = Currency.wrap(address(token1));

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo(
            "BattleswapsHook.sol",
            abi.encode(manager, battleswapsRouter), // This is the encoded list of parameters that will be passed to the constructor of the hook
            address(flags)
        );

        // Set reference the hook contract
        battleswapsHook = BattleswapsHook(address(flags));

        // Approve Token 0 and Token 1 for spending on the swap router and modify liquidity router
        token0.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(battleswapsRouter), type(uint256).max);

        token1.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(battleswapsRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            token0Currency, // Currency for token0
            token1Currency, // Currency for token1
            battleswapsHook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // ========================================================================================
        opponent = address(0x789);
        requester = address(this);

        // Mint tokens for requester and opponent
        token0.mint(requester, 1000 * 1e18);
        token1.mint(requester, 1000 * 1e18);
        token0.mint(opponent, 1000 * 1e18);
        token1.mint(opponent, 1000 * 1e18);

        // Approve the hook contract to spend token0 and token1
        token0.approve(address(battleswapsHook), type(uint256).max);
        token1.approve(address(battleswapsHook), type(uint256).max);

        // Add some liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // A requester (the test contract) requests a battle
        BattleswapsHook.RequestBattleParams memory params = BattleswapsHook
            .RequestBattleParams({
                prizePotShareToken0: 100,
                prizePotShareToken1: 0,
                duration: 10 days,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: 100 * 1e18,
                startBalanceToken1: 100 * 1e18,
                opponent: opponent
            });
        battleswapsHook.requestBattle(params);

        // An accepter accepts the battle
        vm.startPrank(opponent);
        token0.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token0 for prank

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });

        battleswapsHook.acceptBattle(acceptBattleParams);
        vm.stopPrank();
    }

    // function test_should_revert_if_swap_not_triggered_by_BattleSwapsRouter()
    //     public
    // {
    //     vm.expectRevert(
    //         "The swaps for this hook can only be called by the BattleswapsRouter contract."
    //     );

    //     // An address that is not the BattleswapsRouter triggers the poolManager to
    //     vm.startPrank(address(manager));
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -1 * 1e18,
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });
    //     address nonBattleswapsRouter = address(0x888);
    //     battleswapsHook.afterSwap(
    //         nonBattleswapsRouter,
    //         key,
    //         params,
    //         BalanceDelta.wrap(int256(100)),
    //         ZERO_BYTES
    //     );
    //     vm.stopPrank();
    // }

    // function test_should_skip_battle_logic_if_trader_has_no_open_battle()
    //     public
    // {
    //     // Start recording logs for any events emitted
    //     vm.recordLogs();

    //     // A trader not involved in any battles makes a swap in the pool and triggers afterSwap
    //     address trader = address(0x900);
    //     vm.startPrank(trader);
    //     token0.mint(trader, 1000 * 1e18);
    //     token1.mint(trader, 1000 * 1e18);

    //     // Trader makes a swap in the pool and triggers afterSwap
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -1 * 1e18,
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });
    //     token0.approve(address(battleswapsRouter), type(uint256).max);
    //     token1.approve(address(battleswapsRouter), type(uint256).max);
    //     battleswapsRouter.swap(key, params);
    //     vm.stopPrank();

    //     Vm.Log[] memory entries = vm.getRecordedLogs();
    //     bytes32 eventHash = keccak256(
    //         "BattleBalancesUpdated(address,bool,address,address,address,uint256,uint256,uint256,uint256,uint256)"
    //     );
    //     for (uint256 i = 0; i < entries.length; i++) {
    //         assertTrue(entries[i].topics[0] != eventHash);
    //     }
    // }

    // function test_should_skip_battle_logic_if_trader_has_open_battle_but_it_has_expired()
    //     public
    // {
    //     // Mock the block time and fast forward by 11 days (the Battle should have expired
    //     // by 10 days so this will cause the Battle to be expired at this point)
    //     vm.warp(block.timestamp + 11 days);

    //     // Start recording logs for any events emitted
    //     vm.recordLogs();

    //     // Requester makes a swap in the pool and triggers afterSwap (Battle has already been
    //     // requested and accepted by another trader (opponent) in setup() function)
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -1 * 1e18,
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });
    //     battleswapsRouter.swap(key, params);

    //     Vm.Log[] memory entries = vm.getRecordedLogs();
    //     bytes32 eventHash = keccak256(
    //         "BattleBalancesUpdated(address,bool,address,address,address,uint256,uint256,uint256,uint256,uint256)"
    //     );
    //     for (uint256 i = 0; i < entries.length; i++) {
    //         assertTrue(entries[i].topics[0] != eventHash);
    //     }
    // }

    // function test_should_update_balances_only_for_player0_when_player0_makes_a_swap()
    //     public
    // {
    //     // Requester (the test smart contract) is player 0
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -10000, // This amount is within the balance limit
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     battleswapsRouter.swap(key, params);

    //     BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     // Check balances for player0 are updated
    //     assertTrue(
    //         battleBefore.player0Token0Balance > battleAfter.player0Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player0Token1Balance < battleAfter.player0Token1Balance
    //     );

    //     // Check balances for player1 are not updated
    //     assertTrue(
    //         battleBefore.player1Token0Balance ==
    //             battleAfter.player1Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player1Token1Balance ==
    //             battleAfter.player1Token1Balance
    //     );
    // }

    // function test_should_update_balances_only_for_player1_when_player1_makes_a_swap()
    //     public
    // {
    //     // Opponent is player 1
    //     vm.startPrank(opponent);
    //     token0.approve(address(battleswapsRouter), type(uint256).max); // must re-approve the router to spend tokens due to prank
    //     token1.approve(address(battleswapsRouter), type(uint256).max);

    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -100000, // This amount is within the balance limit
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     battleswapsRouter.swap(key, params);
    //     vm.stopPrank();

    //     BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     // Check balances for player1 are updated
    //     assertTrue(
    //         battleBefore.player1Token0Balance > battleAfter.player1Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player1Token1Balance < battleAfter.player1Token1Balance
    //     );

    //     // Check balances for player0 are not updated
    //     assertTrue(
    //         battleBefore.player0Token0Balance ==
    //             battleAfter.player0Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player0Token1Balance ==
    //             battleAfter.player0Token1Balance
    //     );
    // }

    // function test_should_update_balances_when_player_swaps_zeroForOne_and_is_within_balance_limits()
    //     public
    // {
    //     // Requester (the test smart contract) is player 0
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -100000, // This amount is within the balance limit
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     battleswapsRouter.swap(key, params);

    //     BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     // Check balances for player0 not updated
    //     assertTrue(
    //         battleBefore.player0Token0Balance > battleAfter.player0Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player0Token1Balance < battleAfter.player0Token1Balance
    //     );
    // }

    // function test_should_not_update_balances_when_player_swaps_zeroForOne_and_is_out_of_balance_limits()
    //     public
    // {
    //     // Requester (the test smart contract) is player 0
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: true,
    //         amountSpecified: -111 * 1e18, // This amount is out of the balance limit as player0 only has 100*1e18 at this point
    //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //     });

    //     bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     battleswapsRouter.swap(key, params);

    //     BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     // Check balances for player0 not updated
    //     assertTrue(
    //         battleBefore.player0Token0Balance ==
    //             battleAfter.player0Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player0Token1Balance ==
    //             battleAfter.player0Token1Balance
    //     );
    // }

    // function test_should_update_balances_when_player_swaps_non_zeroForOne_and_is_within_balance_limits()
    //     public
    // {
    //     // Requester (the test smart contract) is player 0
    // IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //     zeroForOne: false,
    //     amountSpecified: -100000, // This amount is within the balance limit
    //     sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    // });

    //     bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     battleswapsRouter.swap(key, params);

    //     BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     // Check balances for player0 not updated
    //     assertTrue(
    //         battleBefore.player0Token0Balance < battleAfter.player0Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player0Token1Balance > battleAfter.player0Token1Balance
    //     );
    // }

    // function test_should_not_update_balances_when_player_swaps_non_zeroForOne_and_is_out_of_balance_limits()
    //     public
    // {
    //     // Requester (the test smart contract) is player 0
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: false,
    //         amountSpecified: -111 * 1e18, // This amount is out of the balance limit as player0 only has 100*1e18 at this point
    //         sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //     });

    //     bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     battleswapsRouter.swap(key, params);

    //     BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //         pairKey,
    //         requester
    //     );

    //     // Check balances for player0 not updated
    //     assertTrue(
    //         battleBefore.player0Token0Balance ==
    //             battleAfter.player0Token0Balance
    //     );
    //     assertTrue(
    //         battleBefore.player0Token1Balance ==
    //             battleAfter.player0Token1Balance
    //     );
    // }

    // function test_should_emit_event_BattleBalancesUpdated_when_player_makes_a_swap()
    //     public
    // {
    //     //vm.recordLogs();

    //     //bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
    //     // BattleswapsHook.Battle memory battleBefore = battleswapsHook.getBattle(
    //     //     pairKey,
    //     //     requester
    //     // );

    // Requester (the test smart contract) is player 0
    // IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //     zeroForOne: false,
    //     amountSpecified: -100000, // This amount is within the balance limit
    //     sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    // });
    //     // battleswapsRouter.swap(key, params);

    //     // BattleswapsHook.Battle memory battleAfter = battleswapsHook.getBattle(
    //     //     pairKey,
    //     //     requester
    //     // );

    //     //Vm.Log[] memory logs = vm.getRecordedLogs();

    //     // for (uint256 i = 0; i < logs.length; i++) {
    //     //     Vm.Log memory log = logs[i];

    //     //     // Check if the topic matches the BattleBalancesUpdated signature
    //     //     bytes32 expectedTopic = keccak256(
    //     //         "BattleBalancesUpdated(address,bool,address,address,address,uint256,uint256,uint256,uint256,uint256)"
    //     //     );
    //     //     if (log.topics[0] == expectedTopic) {
    //     //         // Decode indexed parameters
    //     //         address decodedRequester = abi.decode(
    //     //             abi.encodePacked(log.topics[1]),
    //     //             (address)
    //     //         );
    //     //         // address decodedPlayer = abi.decode(
    //     //         //     abi.encodePacked(log.topics[2]),
    //     //         //     (address)
    //     //         // );

    //     //         // Decode unindexed parameters
    //     //         //bool decodedIsPlayer0,
    //     //         // address decodedToken0 = abi.decode( // uint256 decodedTimestamp // address decodedToken1, // uint256 decodedBeforeToken0Balance, // uint256 decodedBeforeToken1Balance, // uint256 decodedAfterToken0Balance, // uint256 decodedAfterToken1Balance,
    //     //         //         log.data,
    //     //         //         (
    //     //         //             bool,
    //     //         //             address,
    //     //         //             address,
    //     //         //             uint256,
    //     //         //             uint256,
    //     //         //             uint256,
    //     //         //             uint256,
    //     //         //             uint256
    //     //         //         )
    //     //         //     );

    //     //         // emit BattleswapsHook.BattleBalancesUpdated(
    //     //         //     requester,
    //     //         //     true,
    //     //         //     address(token0),
    //     //         //     address(token1),
    //     //         //     requester,
    //     //         //     battleBefore.player0Token0Balance,
    //     //         //     battleBefore.player0Token1Balance,
    //     //         //     battleAfter.player0Token0Balance,
    //     //         //     battleAfter.player0Token1Balance,
    //     //         //     block.timestamp
    //     //         // );

    //     //         // Perform assertions
    //     //         assertEq(decodedRequester, requester);
    //     //         // assertEq(decodedIsPlayer0, true);
    //     //         //assertEq(decodedToken0, address(token0));
    //     //         // assertEq(decodedToken1, address(token1));
    //     //         // assertEq(
    //     //         //     decodedBeforeToken0Balance,
    //     //         //     battleBefore.player0Token0Balance
    //     //         // );
    //     //         // assertEq(
    //     //         //     decodedBeforeToken1Balance,
    //     //         //     battleBefore.player0Token1Balance
    //     //         // );
    //     //         // assertEq(
    //     //         //     decodedAfterToken0Balance,
    //     //         //     battleAfter.player0Token0Balance
    //     //         // );
    //     //         // assertEq(
    //     //         //     decodedAfterToken1Balance,
    //     //         //     battleAfter.player0Token1Balance
    //     //         // );
    //     //         //assertApproxEqAbs(decodedTimestamp, block.timestamp);

    //     //         return; // Exit after validating the correct event
    //     //     }
    //     // }
    // }
}
