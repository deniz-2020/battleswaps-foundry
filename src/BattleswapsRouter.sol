// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

error CallerNotPoolManager();

contract BattleswapsRouter is Ownable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    struct TokenData {
        address token0Address;
        string token0Name;
        string token0Currency;
        address token1Address;
        string token1Name;
        string token1Currency;
    }

    struct CallbackData {
        address swapCaller;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    IPoolManager public immutable manager;
    mapping(PoolId => PoolKey) public registeredPoolKeys;
    PoolId[] public poolIds;

    constructor(IPoolManager _manager) Ownable(msg.sender) {
        manager = _manager;
    }

    function swap(
        PoolId poolId,
        IPoolManager.SwapParams memory params
    ) external payable returns (BalanceDelta delta) {
        PoolKey memory poolKey = registeredPoolKeys[poolId];
        require(
            Currency.unwrap(poolKey.currency0) != address(0),
            "The specified Pool is not registered for swaps"
        );

        return
            delta = abi.decode(
                manager.unlock(
                    abi.encode(
                        CallbackData(
                            msg.sender,
                            poolKey,
                            params,
                            abi.encode(msg.sender)
                        )
                    )
                ),
                (BalanceDelta)
            );
    }

    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert CallerNotPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        int256 deltaAfter0 = manager.currencyDelta(
            address(this),
            data.key.currency0
        );
        int256 deltaAfter1 = manager.currencyDelta(
            address(this),
            data.key.currency1
        );

        if (deltaAfter0 < 0) {
            data.key.currency0.settle(
                manager,
                data.swapCaller,
                uint256(-deltaAfter0),
                false
            );
        }
        if (deltaAfter1 < 0) {
            data.key.currency1.settle(
                manager,
                data.swapCaller,
                uint256(-deltaAfter1),
                false
            );
        }
        if (deltaAfter0 > 0) {
            data.key.currency0.take(
                manager,
                data.swapCaller,
                uint256(deltaAfter0),
                false
            );
        }
        if (deltaAfter1 > 0) {
            data.key.currency1.take(
                manager,
                data.swapCaller,
                uint256(deltaAfter1),
                false
            );
        }

        return abi.encode(delta);
    }

    function getAllPoolIds() public view returns (PoolId[] memory) {
        return poolIds;
    }

    function getTokenDataByPoolId(
        PoolId poolId
    ) public view returns (TokenData memory) {
        PoolKey memory poolKey = registeredPoolKeys[poolId];
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        return
            TokenData({
                token0Address: token0,
                token0Name: ERC20(token0).name(),
                token0Currency: ERC20(token0).symbol(),
                token1Address: token1,
                token1Name: ERC20(token1).name(),
                token1Currency: ERC20(token1).symbol()
            });
    }

    // TODO: Limit this function so that not just anyone can call it! For now for testing, anyone can it...
    function registerPool(PoolKey memory poolKey) external {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(poolKey)));
        registeredPoolKeys[poolId] = poolKey;
        poolIds.push(poolId);
    }
}
