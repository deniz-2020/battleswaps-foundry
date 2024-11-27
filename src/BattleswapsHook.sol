// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract BattleswapsHook is BaseHook {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    struct BattleRequest {
        address requester; // Player who is requesting the battle
        uint256 prizePotShareToken0; // Prize pot share to be taken from each participant for Token 0
        uint256 prizePotShareToken1; // Prize pot share to be taken from each participant for Token 1
        uint256 duration; // Duration of the battle in UNIX
        uint256 startBalanceToken0; // Starting balance of Token 0
        uint256 startBalanceToken1; // Starting balance of Token 1
        address opponent; // Opponent address (optional)
        uint256 creationTimestamp; // Timestamp of when the request was made
    }

    mapping(bytes32 => mapping(address => BattleRequest)) public battleRequests; // Mapping(Token pair hash => Mapping(requester => BattleRequest))

    event BattleRequestCreated(
        address indexed requester,
        uint256 prizePotShareToken0,
        uint256 prizePotShareToken1,
        uint256 duration,
        uint256 startBalanceToken0,
        uint256 startBalanceToken1,
        address opponent,
        uint256 creationTimestamp
    );

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Stub implementation of `afterSwap`
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        return (this.afterSwap.selector, 0);
    }

    function requestBattle(
        uint256 _prizePotShareToken0,
        uint256 _prizePotShareToken1,
        uint256 _duration,
        address _token0,
        address _token1,
        uint256 _startBalanceToken0,
        uint256 _startBalanceToken1,
        address _opponent
    ) external payable {
        require(
            _prizePotShareToken0 > 0 || _prizePotShareToken1 > 0,
            "At least one of prizePotShareToken0 or prizePotShareToken1 must be greater than 0"
        );
        require(
            _duration >= 1 days && _duration <= 1000 days,
            "Duration must be at least 1 day long and no more than 1000 days long"
        );
        require(
            _token0 != _token1,
            "The tokens token0 and token1 must be different"
        );
        require(
            _startBalanceToken0 > 0 || _startBalanceToken1 > 0,
            "At least one of _startBalanceToken0 or _startBalanceToken1 must be greater than 0"
        );
        if (_opponent != address(0)) {
            require(
                _opponent != msg.sender,
                "Opponent cannot be the same as the player requesting battle"
            );
        }

        // Take the prize pot money from the requester
        if (_prizePotShareToken0 > 0) {
            ERC20(_token0).transferFrom(
                msg.sender,
                address(this),
                _prizePotShareToken0
            );
        }
        if (_prizePotShareToken1 > 0) {
            ERC20(_token1).transferFrom(
                msg.sender,
                address(this),
                _prizePotShareToken1
            );
        }

        // Record battle request in mapping
        bytes32 pairKey = keccak256(abi.encodePacked(_token0, _token1));
        battleRequests[pairKey][msg.sender] = BattleRequest({
            requester: msg.sender,
            prizePotShareToken0: _prizePotShareToken0,
            prizePotShareToken1: _prizePotShareToken1,
            duration: _duration,
            startBalanceToken0: _startBalanceToken0,
            startBalanceToken1: _startBalanceToken1,
            opponent: _opponent,
            creationTimestamp: block.timestamp
        });

        emit BattleRequestCreated(
            msg.sender,
            _prizePotShareToken0,
            _prizePotShareToken1,
            _duration,
            _startBalanceToken0,
            _startBalanceToken1,
            _opponent,
            block.timestamp
        );
    }

    function getBattleRequest(
        bytes32 pairKey,
        address requester
    ) public view returns (BattleRequest memory) {
        return battleRequests[pairKey][requester];
    }
}
