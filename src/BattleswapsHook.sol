// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import "forge-std/console.sol"; // REMOVE THIS WHEN DONE DEBUGGING

contract BattleswapsHook is BaseHook {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    struct BattleRequest {
        address requester; // Player who is requesting the battle
        address opponent; // Opponent address (optionally provided)
        uint256 prizePotShareToken0; // Prize pot share to be taken from each player for Token 0
        uint256 prizePotShareToken1; // Prize pot share to be taken from each player for Token 1
        uint256 duration; // Duration of the battle in UNIX
        uint256 startBalanceToken0; // Starting balance of Token 0
        uint256 startBalanceToken1; // Starting balance of Token 1
        address token0; // Reference to token0
        address token1; // Reference to token1
        uint256 timestamp; // Timestamp of when the battle request was made
    }

    struct Battle {
        address player0; // Is the player that requested the battle
        address player1; // Is the player that accepted the battle request
        uint256 startedAt; // The time the battle is accepted and hence started
        uint256 endsAt; // The specific time the battle is expected to end
        uint256 player0Token0Balance; // The current balance of Token 0 for player 0
        uint256 player0Token1Balance; // The current balance of Token 1 for player 0
        uint256 player1Token0Balance; // The current balance of Token 0 for player 1
        uint256 player1Token1Balance; // The current balance of Token 1 for player 1
        BattleRequest battleRequest; // A reference to the original battle request information
    }

    mapping(bytes32 => mapping(address => BattleRequest)) public battleRequests; // Mapping(pairKey => Mapping(requester address => BattleRequest))
    mapping(bytes32 => mapping(address => Battle)) public battles; // Mapping(pairKey => Mapping(requester address => Battle))

    mapping(address => mapping(bytes32 => bool))
        public playersWithOpenBattleRequests; // requester address => pairKey => bool
    mapping(address => mapping(bytes32 => address))
        public playersWithOpenBattles; // requester/accepter address => pairKey => requester address

    event BattleRequestCreated(
        address indexed requester,
        address token0,
        address token1,
        uint256 prizePotShareToken0,
        uint256 prizePotShareToken1,
        uint256 duration,
        uint256 startBalanceToken0,
        uint256 startBalanceToken1,
        address indexed opponent,
        uint256 timestamp
    );

    event BattleRequestAccepted(
        address indexed requester,
        address indexed accepter,
        address token0,
        address token1,
        uint256 prizePotShareToken0,
        uint256 prizePotShareToken1,
        uint256 duration,
        uint256 startBalanceToken0,
        uint256 startBalanceToken1,
        uint256 timestamp
    );

    event BattleBalancesUpdated(
        address indexed player,
        bool isPlayer0,
        address token0,
        address token1,
        address requester,
        uint256 beforeBalanceToken0,
        uint256 beforeBalanceToken1,
        uint256 afterBalanceToken0,
        uint256 afterBalanceToken1,
        uint256 timestamp
    );

    modifier onlyPlayerAvailableForBattle(address _token0, address _token1) {
        bytes32 pairKey = keccak256(abi.encodePacked(_token0, _token1));
        require(
            !isPlayerWithOpenBattleRequestForPairKey(pairKey, msg.sender),
            "Player already has an open battle request for this token pair."
        );
        require(
            isPlayerWithOpenBattleForPairKey(pairKey, msg.sender) != address(0),
            "Player already has an open battle for this token pair."
        );
        _;
    }

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

    function afterSwap(
        address trader,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Check if trader has an open battle for pairKey
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));

        // If there is no open battle, short-circuit the afterSwap hook logic and continue as normal
        address battleRequester = isPlayerWithOpenBattleForPairKey(
            pairKey,
            trader
        );
        if (battleRequester == address(0)) {
            return (this.afterSwap.selector, 0);
        }

        // If there is an open battle, load it
        Battle memory battle = getBattle(pairKey, battleRequester);
        bool isPlayer0 = battle.player0 == trader;
        uint256 token0Balance = isPlayer0
            ? battle.player0Token0Balance
            : battle.player1Token0Balance;
        uint256 token1Balance = isPlayer0
            ? battle.player0Token1Balance
            : battle.player1Token1Balance;
        uint256 beforeToken0Balance = token0Balance;
        uint256 beforeToken1Balance = token1Balance;

        if (swapParams.zeroForOne) {
            // If player is giving Token 0, check its balance limit
            if (token0Balance >= uint256(int256(-delta.amount0()))) {
                token0Balance -= uint256(int256(-delta.amount0()));
                token1Balance += uint256(int256(delta.amount1()));
            }
        } else {
            // If player is giving Token 1, check its balance limit
            if (token1Balance >= uint256(int256(-delta.amount1()))) {
                token1Balance -= uint256(int256(-delta.amount1()));
                token0Balance += uint256(int256(delta.amount0()));
            }
        }

        // Update Battle with newly calculated Token 0 and Token 1 balances
        if (isPlayer0) {
            battle.player0Token0Balance = token0Balance;
            battle.player0Token1Balance = token1Balance;
        } else {
            battle.player1Token0Balance = token0Balance;
            battle.player1Token1Balance = token1Balance;
        }

        emit BattleBalancesUpdated(
            msg.sender,
            isPlayer0,
            token0,
            token1,
            battle.player0,
            beforeToken0Balance,
            beforeToken1Balance,
            token0Balance,
            token1Balance,
            block.timestamp
        );

        return (this.afterSwap.selector, 0);
    }

    struct RequestBattleParams {
        uint256 prizePotShareToken0;
        uint256 prizePotShareToken1;
        uint256 duration;
        address token0;
        address token1;
        uint256 startBalanceToken0;
        uint256 startBalanceToken1;
        address opponent;
    }

    function requestBattle(
        RequestBattleParams calldata params
    )
        external
        payable
        onlyPlayerAvailableForBattle(params.token0, params.token1)
    {
        require(
            params.prizePotShareToken0 > 0 || params.prizePotShareToken1 > 0,
            "At least one of prizePotShareToken0 or prizePotShareToken1 must be greater than 0."
        );
        require(
            params.duration >= 1 days && params.duration <= 1000 days,
            "Duration must be at least 1 day long and no more than 1000 days long."
        );
        require(
            params.token0 != params.token1,
            "The tokens token0 and token1 must be different."
        );
        require(
            params.startBalanceToken0 > 0 || params.startBalanceToken1 > 0,
            "At least one of _startBalanceToken0 or _startBalanceToken1 must be greater than 0."
        );
        if (params.opponent != address(0)) {
            require(
                params.opponent != msg.sender,
                "Opponent cannot be the same as the player requesting battle."
            );
        }

        // Take the prize pot money from the requester
        if (params.prizePotShareToken0 > 0) {
            ERC20(params.token0).transferFrom(
                msg.sender,
                address(this),
                params.prizePotShareToken0
            );
        }
        if (params.prizePotShareToken1 > 0) {
            ERC20(params.token1).transferFrom(
                msg.sender,
                address(this),
                params.prizePotShareToken1
            );
        }

        // Track the player that made the battle request
        bytes32 pairKey = keccak256(
            abi.encodePacked(params.token0, params.token1)
        );
        playersWithOpenBattleRequests[msg.sender][pairKey] = true;

        // Record battle request in mapping
        battleRequests[pairKey][msg.sender] = BattleRequest({
            requester: msg.sender,
            opponent: params.opponent,
            prizePotShareToken0: params.prizePotShareToken0,
            prizePotShareToken1: params.prizePotShareToken1,
            duration: params.duration,
            startBalanceToken0: params.startBalanceToken0,
            startBalanceToken1: params.startBalanceToken1,
            token0: params.token0,
            token1: params.token1,
            timestamp: block.timestamp
        });

        emit BattleRequestCreated(
            msg.sender,
            params.token0,
            params.token1,
            params.prizePotShareToken0,
            params.prizePotShareToken1,
            params.duration,
            params.startBalanceToken0,
            params.startBalanceToken1,
            params.opponent,
            block.timestamp
        );
    }

    struct AcceptBattleParams {
        address token0;
        address token1;
        address requester;
    }

    function acceptBattle(
        AcceptBattleParams calldata params
    )
        external
        payable
        onlyPlayerAvailableForBattle(params.token0, params.token1)
    {
        bytes32 pairKey = keccak256(
            abi.encodePacked(params.token0, params.token1)
        );

        // Find the battle request
        BattleRequest memory br = getBattleRequest(pairKey, params.requester);
        require(
            br.requester != address(0),
            "Given battle request could not be found."
        );

        // Initialise and record battle in mapping
        battles[pairKey][br.requester] = Battle({
            player0: br.requester,
            player1: msg.sender,
            startedAt: block.timestamp,
            endsAt: block.timestamp + br.duration,
            player0Token0Balance: br.startBalanceToken0,
            player0Token1Balance: br.startBalanceToken1,
            player1Token0Balance: br.startBalanceToken0,
            player1Token1Balance: br.startBalanceToken1,
            battleRequest: br
        });

        emit BattleRequestAccepted(
            br.requester,
            msg.sender,
            br.token0,
            br.token1,
            br.prizePotShareToken0,
            br.prizePotShareToken1,
            br.duration,
            br.startBalanceToken0,
            br.startBalanceToken1,
            block.timestamp
        );

        // Take the prize pot money from the accepter
        if (br.prizePotShareToken0 > 0) {
            ERC20(br.token0).transferFrom(
                msg.sender,
                address(this),
                br.prizePotShareToken0
            );
        }
        if (br.prizePotShareToken1 > 0) {
            ERC20(br.token1).transferFrom(
                msg.sender,
                address(this),
                br.prizePotShareToken1
            );
        }

        // Update trackings
        playersWithOpenBattleRequests[br.requester][pairKey] = false;
        playersWithOpenBattles[msg.sender][pairKey] = br.requester;
        playersWithOpenBattles[br.requester][pairKey] = br.requester;

        // Remove the battle request from the battle requests mapping
        deleteBattleRequest(pairKey, br.requester);
    }

    function getBattleRequest(
        bytes32 pairKey,
        address requester
    ) public view returns (BattleRequest memory) {
        return battleRequests[pairKey][requester];
    }

    function deleteBattleRequest(bytes32 pairKey, address requester) internal {
        delete battleRequests[pairKey][requester];
    }

    function getBattle(
        bytes32 pairKey,
        address requester
    ) public view returns (Battle memory) {
        return battles[pairKey][requester];
    }

    function isPlayerWithOpenBattleRequestForPairKey(
        bytes32 pairKey,
        address player
    ) public view returns (bool) {
        return playersWithOpenBattleRequests[player][pairKey];
    }

    function isPlayerWithOpenBattleForPairKey(
        bytes32 pairKey,
        address player
    ) public view returns (address) {
        return playersWithOpenBattles[player][pairKey];
    }
}
