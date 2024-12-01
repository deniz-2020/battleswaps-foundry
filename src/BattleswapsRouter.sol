// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

error CallerNotPoolManager();

contract BattleswapsRouter is Ownable {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    struct CallbackData {
        address swapCaller;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) Ownable(msg.sender) {
        manager = _manager;
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params
    ) external payable returns (BalanceDelta delta) {
        return
            delta = abi.decode(
                manager.unlock(
                    abi.encode(
                        CallbackData(
                            msg.sender,
                            key,
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
}
