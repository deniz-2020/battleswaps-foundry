// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import "forge-std/console.sol";
import {BattleswapsHook} from "../src/BattleswapsHook.sol";

contract BattleswapsHook_acceptBattle is Test, Deployers {
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

        // Deploy the Token 0 and Token 1 contracts
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        token0Currency = Currency.wrap(address(token0));
        token1Currency = Currency.wrap(address(token1));

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo(
            "BattleswapsHook.sol",
            abi.encode(manager), // This is the encoded list of parameters that will be passed to the constructor of the hook
            address(flags)
        );

        // Set reference the hook contract
        battleswapsHook = BattleswapsHook(address(flags));

        // Approve Token 0 and Token 1 for spending on the swap router and modify liquidity router
        token0.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);

        token1.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

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
    }

    function test_should_revert_if_player_already_has_open_battle_request()
        public
    {
        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: 100,
                prizePotShareToken1: 0,
                duration: 10 days,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: 100 * 1e18,
                startBalanceToken1: 100 * 1e18,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        vm.expectRevert(
            "Player already has an open battle request for this token pair."
        );

        // Next, the requester (test contract) attempts to accept the battle but this should fail
        // since they already opened a battle request
        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });
        battleswapsHook.acceptBattle(acceptBattleParams);
    }

    function test_should_revert_if_player_already_has_open_battle() public {
        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: 100,
                prizePotShareToken1: 0,
                duration: 10 days,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: 100 * 1e18,
                startBalanceToken1: 100 * 1e18,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // An opponent should accept the battle (start prank to temporarily change the caller to that of the opponent)
        vm.startPrank(opponent);
        token0.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token0 for prank

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams1 = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });
        battleswapsHook.acceptBattle(acceptBattleParams1);
        vm.stopPrank();

        // Now requester (test contract) attempts to accept battle
        vm.expectRevert(
            "Player already has an open battle for this token pair."
        );

        BattleswapsHook.AcceptBattleParams memory acceptBattleParams2 = BattleswapsHook
            .AcceptBattleParams({
                token0: address(token0), // the param values don't really matter here as revert being tested is irrelevant to them
                token1: address(token1),
                requester: requester
            });
        battleswapsHook.acceptBattle(acceptBattleParams2);
    }

    function test_should_revert_if_specified_battle_request_not_found() public {
        vm.expectRevert("Given battle request could not be found.");

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams1 = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });
        battleswapsHook.acceptBattle(acceptBattleParams1);
    }

    function test_should_add_battle_to_battles_mapping() public {
        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: 100,
                prizePotShareToken1: 0,
                duration: 10 days,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: 100 * 1e18,
                startBalanceToken1: 100 * 1e18,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Next, the battle request should be successfully accepted by another trader (opponent)
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

        bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
        BattleswapsHook.Battle memory battle = battleswapsHook.getBattle(
            pairKey,
            requester
        );
        assertEq(battle.player0, requester);
    }

    function test_should_emit_event_BattleRequestAccepted_when_battle_added_to_battles_mapping()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;

        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: _prizePotShareToken0,
                prizePotShareToken1: _prizePotShareToken1,
                duration: _duration,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: _startBalanceToken0,
                startBalanceToken1: _startBalanceToken1,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Next, the battle request should be successfully accepted by another trader (opponent)
        vm.startPrank(opponent);
        token0.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token0 for prank

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });

        vm.expectEmit(true, false, false, true);

        emit BattleswapsHook.BattleRequestAccepted( // Note: This does not emit the event but sets up the expectation for Foundry to match against.
            requester,
            opponent,
            address(token0),
            address(token1),
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _startBalanceToken0,
            _startBalanceToken1,
            block.timestamp
        );

        battleswapsHook.acceptBattle(acceptBattleParams);
        vm.stopPrank();
    }

    function test_should_take_prizePotShareToken0_from_accepter_into_hook_if_amount_is_greater_than_zero()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;

        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: _prizePotShareToken0,
                prizePotShareToken1: _prizePotShareToken1,
                duration: _duration,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: _startBalanceToken0,
                startBalanceToken1: _startBalanceToken1,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Next, the battle request should be successfully accepted by another trader (opponent)
        vm.startPrank(opponent);
        token0.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token0 for prank

        uint256 initialHookBalance = token0.balanceOf(address(battleswapsHook));
        uint256 finalHookBalance = initialHookBalance + _prizePotShareToken0;

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });

        battleswapsHook.acceptBattle(acceptBattleParams);
        vm.stopPrank();

        assertEq(token0.balanceOf(address(battleswapsHook)), finalHookBalance);
    }

    function test_should_take_prizePotShareToken1_from_accepter_into_hook_if_amount_is_greater_than_zero()
        public
    {
        uint256 _prizePotShareToken0 = 0;
        uint256 _prizePotShareToken1 = 100;
        uint256 _duration = 10 days;
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;

        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: _prizePotShareToken0,
                prizePotShareToken1: _prizePotShareToken1,
                duration: _duration,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: _startBalanceToken0,
                startBalanceToken1: _startBalanceToken1,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Next, the battle request should be successfully accepted by another trader (opponent)
        vm.startPrank(opponent);
        token1.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token1 for prank

        uint256 initialHookBalance = token1.balanceOf(address(battleswapsHook));
        uint256 finalHookBalance = initialHookBalance + _prizePotShareToken1;

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });

        battleswapsHook.acceptBattle(acceptBattleParams);
        vm.stopPrank();

        assertEq(token1.balanceOf(address(battleswapsHook)), finalHookBalance);
    }

    function test_should_take_prizePotShareToken0_and_prizePotShareToken1_from_accepter_into_hook_if_amount_is_greater_than_zero_for_both()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 100;
        uint256 _duration = 10 days;
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;

        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: _prizePotShareToken0,
                prizePotShareToken1: _prizePotShareToken1,
                duration: _duration,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: _startBalanceToken0,
                startBalanceToken1: _startBalanceToken1,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Next, the battle request should be successfully accepted by another trader (opponent)
        vm.startPrank(opponent);
        token0.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token0 for prank
        token1.approve(address(battleswapsHook), type(uint256).max); // must re-approve the hook to spend token1 for prank

        uint256 initialHookBalance_token0 = token0.balanceOf(
            address(battleswapsHook)
        );
        uint256 finalHookBalance_token0 = initialHookBalance_token0 +
            _prizePotShareToken0;

        uint256 initialHookBalance_token1 = token1.balanceOf(
            address(battleswapsHook)
        );
        uint256 finalHookBalance_token1 = initialHookBalance_token1 +
            _prizePotShareToken1;

        BattleswapsHook.AcceptBattleParams
            memory acceptBattleParams = BattleswapsHook.AcceptBattleParams({
                token0: address(token0),
                token1: address(token1),
                requester: requester
            });

        battleswapsHook.acceptBattle(acceptBattleParams);
        vm.stopPrank();

        assertEq(
            token0.balanceOf(address(battleswapsHook)),
            finalHookBalance_token0
        );
        assertEq(
            token1.balanceOf(address(battleswapsHook)),
            finalHookBalance_token1
        );
    }

    function test_should_update_playersWithOpenBattleRequests_and_playersWithOpenBattles()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;

        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: _prizePotShareToken0,
                prizePotShareToken1: _prizePotShareToken1,
                duration: _duration,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: _startBalanceToken0,
                startBalanceToken1: _startBalanceToken1,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Next, the battle request should be successfully accepted by another trader (opponent)
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

        bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
        bool battleRequestIsOpen = battleswapsHook
            .isPlayerWithOpenBattleRequestForPairKey(pairKey, requester);
        address hasOpenBattle_requester = battleswapsHook
            .isPlayerWithOpenBattleForPairKey(pairKey, requester);
        address hasOpenBattle_accepter = battleswapsHook
            .isPlayerWithOpenBattleForPairKey(pairKey, opponent);

        assertFalse(battleRequestIsOpen);
        assertTrue(hasOpenBattle_requester != address(0));
        assertTrue(hasOpenBattle_accepter != address(0));
    }

    function test_should_delete_battle_request_from_battle_requests_mapping()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;

        // First, the requester (test contract) makes a battle request
        BattleswapsHook.RequestBattleParams
            memory requestBattleParams = BattleswapsHook.RequestBattleParams({
                prizePotShareToken0: _prizePotShareToken0,
                prizePotShareToken1: _prizePotShareToken1,
                duration: _duration,
                token0: address(token0),
                token1: address(token1),
                startBalanceToken0: _startBalanceToken0,
                startBalanceToken1: _startBalanceToken1,
                opponent: opponent
            });
        battleswapsHook.requestBattle(requestBattleParams);

        // Check that battle request was indeed added
        bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));
        BattleswapsHook.BattleRequest
            memory battleRequest_before = battleswapsHook.getBattleRequest(
                pairKey,
                requester
            );
        assertEq(battleRequest_before.requester, requester);

        // Next, the battle request should be successfully accepted by another trader (opponent)
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

        // Check that battle request was indeed removed
        BattleswapsHook.BattleRequest
            memory battleRequest_after = battleswapsHook.getBattleRequest(
                pairKey,
                requester
            );

        assertEq(battleRequest_after.requester, address(0));
    }
}
