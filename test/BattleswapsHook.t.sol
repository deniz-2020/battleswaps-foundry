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

import "forge-std/console.sol";
import {BattleswapsHook} from "../src/BattleswapsHook.sol";

contract BattleswapsHooksTest is Test, Deployers {
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

        // Approve the contract for deposits
        token0.approve(address(battleswapsHook), type(uint256).max);
        token1.approve(address(battleswapsHook), type(uint256).max);
    }

    function test_should_revert_if_prizePotShareToken0_and_prizePotShareToken1_are_both_zero()
        public
    {
        vm.expectRevert(
            "At least one of prizePotShareToken0 or prizePotShareToken1 must be greater than 0"
        );

        uint256 _prizePotShareToken0 = 0;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }

    function test_should_revert_if_duration_less_than_one_day() public {
        vm.expectRevert(
            "Duration must be at least 1 day long and no more than 1000 days long"
        );

        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 0.5 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }

    function test_should_revert_if_duration_more_than_one_thousand_days()
        public
    {
        vm.expectRevert(
            "Duration must be at least 1 day long and no more than 1000 days long"
        );

        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 1001 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }

    function test_should_revert_if_token0_and_token1_are_the_same() public {
        vm.expectRevert("The tokens token0 and token1 must be different");

        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token0);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }

    function test_should_revert_if_startBalanceToken0_and_startBalanceToken1_are_both_zero()
        public
    {
        vm.expectRevert(
            "At least one of _startBalanceToken0 or _startBalanceToken1 must be greater than 0"
        );

        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 0;
        uint256 _startBalanceToken1 = 0;
        address _opponent = opponent;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }

    function test_should_revert_if_an_opponent_is_provided_and_is_the_same_as_the_requester()
        public
    {
        vm.expectRevert(
            "Opponent cannot be the same as the player requesting battle"
        );

        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = requester;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }

    // ======

    function test_should_take_prizePotShareToken0_from_requester_into_hook_if_amount_is_greater_than_zero()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        uint256 initialHookBalance = token0.balanceOf(address(battleswapsHook));
        uint256 finalHookBalance = initialHookBalance + _prizePotShareToken0;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );

        assertEq(token0.balanceOf(address(battleswapsHook)), finalHookBalance);
    }

    function test_should_take_prizePotShareToken1_from_requester_into_hook_if_amount_is_greater_than_zero()
        public
    {
        uint256 _prizePotShareToken0 = 0;
        uint256 _prizePotShareToken1 = 100;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        uint256 initialHookBalance = token1.balanceOf(address(battleswapsHook));
        uint256 finalHookBalance = initialHookBalance + _prizePotShareToken1;

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );

        assertEq(token1.balanceOf(address(battleswapsHook)), finalHookBalance);
    }

    function test_should_take_prizePotShareToken0_and_prizePotShareToken1_from_requester_into_hook_if_amount_is_greater_than_zero_for_both()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 100;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

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

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );

        assertEq(
            token0.balanceOf(address(battleswapsHook)),
            finalHookBalance_token0
        );
        assertEq(
            token1.balanceOf(address(battleswapsHook)),
            finalHookBalance_token1
        );
    }

    function test_should_add_battle_request_to_battle_requests_mapping()
        public
    {
        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;
        bytes32 pairKey = keccak256(abi.encodePacked(_token0, _token1));

        BattleswapsHook.BattleRequest
            memory battleRequestBefore = battleswapsHook.getBattleRequest(
                pairKey,
                requester
            );
        assertEq(battleRequestBefore.requester, address(0));

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );

        BattleswapsHook.BattleRequest
            memory battleRequestAfter = battleswapsHook.getBattleRequest(
                pairKey,
                requester
            );
        assertEq(battleRequestAfter.requester, requester);
    }

    function test_should_emit_event_BattleRequestCreated_when_battle_request_added_to_battle_requests_mapping()
        public
    {
        vm.expectEmit(true, false, false, true);

        uint256 _prizePotShareToken0 = 100;
        uint256 _prizePotShareToken1 = 0;
        uint256 _duration = 10 days;
        address _token0 = address(token0);
        address _token1 = address(token1);
        uint256 _startBalanceToken0 = 100 * 1e18;
        uint256 _startBalanceToken1 = 100 * 1e18;
        address _opponent = opponent;

        emit BattleswapsHook.BattleRequestCreated( // Note: This does not emit the event but sets up the expectation for Foundry to match against.
            requester,
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _startBalanceToken0,
            _startBalanceToken1,
            opponent,
            block.timestamp
        );

        battleswapsHook.requestBattle(
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _token0,
            _token1,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent
        );
    }
}
