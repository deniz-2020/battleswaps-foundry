// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapRouterNoChecks} from "@uniswap/v4-core/src/test/SwapRouterNoChecks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolTakeTest} from "@uniswap/v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {PoolNestedActionsTest} from "@uniswap/v4-core/src/test/PoolNestedActionsTest.sol";
import {ActionsRouter} from "@uniswap/v4-core/src/test/ActionsRouter.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import "forge-std/console.sol";
import "forge-std/Script.sol";
import "../src/BattleswapsRouter.sol";
import "../src/BattleswapsHook.sol";

contract Deploy is Script, Deployers {
    BattleswapsRouter battleswapsRouter;
    BattleswapsHook battleswapsHook;
    MockERC20 token0;
    MockERC20 token1;

    Currency token0Currency;
    Currency token1Currency;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY"); // The private key of the EOA that will making the deployment i.e. paying the gas fees

        // Start broadcasting transactions (necessary for deployment)
        vm.startBroadcast(deployerPrivateKey);

        // Deploy PoolManager and Router contracts
        deployFreshManager();
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy the BattleswapsRouter contract
        battleswapsRouter = new BattleswapsRouter(manager);

        // Deploy the Token 0 and Token 1 contracts and ensure Token 0 is lexicographically smaller than Token 1
        token0 = new MockERC20("TokenJ", "TKJ", 18);
        token1 = new MockERC20("TokenZ", "TKZ", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

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
        token0.approve(address(manager), type(uint256).max);
        token0.approve(address(vm.addr(deployerPrivateKey)), type(uint256).max);

        token1.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(battleswapsRouter), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token0.approve(address(vm.addr(deployerPrivateKey)), type(uint256).max);

        token0.mint(vm.addr(deployerPrivateKey), 1000 * 1e18);
        token1.mint(vm.addr(deployerPrivateKey), 1000 * 1e18);

        // Initialize a pool
        (key, ) = initPool(
            token0Currency, // Currency for token0
            token1Currency, // Currency for token1
            battleswapsHook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1
        );

        // Register the new pool with the BattleswapsRouter (an alternative would be to run this on initialisation of a pool)
        battleswapsRouter.registerPool(key);
        bytes32 poolId = keccak256(abi.encode(key));
        console.log("Pool ID:");
        console.logBytes32(poolId);

        // ========================================================================================

        // Approve the hook contract to spend token0 and token1
        token0.approve(address(battleswapsHook), type(uint256).max);
        token1.approve(address(battleswapsHook), type(uint256).max);

        // Log the deployed contract addresses
        console.log("Foundry deployer EOA at:", vm.addr(deployerPrivateKey));
        console.log("BattleswapsRouter at:", address(battleswapsRouter));
        console.log("BattleswapsHook at:", address(battleswapsHook));
        console.log("token0 at:", address(token0));
        console.log("token1 at:", address(token1));

        // Add some liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 5 ether,
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

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
