// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import "forge-std/console.sol"; // REMOVE THIS WHEN DONE DEBUGGING

contract BattleswapsHook is BaseHook {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    struct BattleRequestKey {
        bytes32 pairKey;
        address requester;
    }

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
        address player0; // Is (always) the player that requested the battle
        address player1; // Is (always) the player that accepted the battle request
        uint256 startedAt; // The time the battle is accepted and hence started
        uint256 endsAt; // The specific time the battle is expected to end
        uint256 player0Token0Balance; // The current balance of Token 0 for player 0
        uint256 player0Token1Balance; // The current balance of Token 1 for player 0
        uint256 player1Token0Balance; // The current balance of Token 0 for player 1
        uint256 player1Token1Balance; // The current balance of Token 1 for player 1
        BattleRequest battleRequest; // A reference to the original battle request information
    }

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

    event BattleBalanceUpdatesSkipped(
        bool zeroForOne,
        address indexed player,
        bool isPlayer0,
        address token0,
        address token1,
        address requester,
        uint256 deltaAmount,
        uint256 timestamp
    );

    event PrizeRedeemed(
        address indexed winner,
        uint256 player0FinalBalance,
        uint player1FinalBalance,
        uint256 timestamp
    );

    address battleSwapRouter;

    mapping(bytes32 => mapping(address => BattleRequest)) public battleRequests; // pairKey => requester address => BattleRequest
    mapping(bytes32 => mapping(address => Battle)) public battles; // pairKey => requester address => Battle

    mapping(address => mapping(bytes32 => bool))
        public playersWithOpenBattleRequests; // requester address => pairKey => bool
    mapping(address => mapping(bytes32 => address))
        public playersWithOpenBattles; // player address => pairKey => requester address
    BattleRequestKey[] public battleRequestKeys;

    modifier onlyPlayerAvailableForBattle(address _token0, address _token1) {
        bytes32 pairKey = keccak256(abi.encodePacked(_token0, _token1));
        require(
            !isPlayerWithOpenBattleRequestForPairKey(pairKey, msg.sender),
            "Player already has an open battle request for this token pair."
        );
        require(
            isPlayerWithOpenBattleForPairKey(pairKey, msg.sender) == address(0),
            "Player already has an open battle for this token pair."
        );
        _;
    }

    constructor(
        IPoolManager _manager,
        address _battleSwapRouter
    ) BaseHook(_manager) {
        battleSwapRouter = _battleSwapRouter;
    }

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
        address swapCaller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        require(
            swapCaller == battleSwapRouter,
            "The swaps for this hook can only be called by the BattleswapsRouter contract."
        );

        // Check if trader has an open battle for pairKey
        address trader = abi.decode(hookData, (address));
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
        Battle storage battle = battles[pairKey][battleRequester];

        // If battle has expired, short-circuit the afterSwap hook logic
        if (battle.endsAt <= block.timestamp) {
            return (this.afterSwap.selector, 0);
        }

        // Calculate and then update the new balances for Token 0 and Token 1
        bool isPlayer0 = battle.player0 == trader;
        CalculateNewBalancesParams
            memory calcNewBalParams = CalculateNewBalancesParams({
                swapParams: swapParams,
                delta: delta,
                battle: battle,
                player: trader
            });
        (uint256 token0Balance, uint256 token1Balance) = _calculateNewBalances(
            calcNewBalParams
        );

        if (isPlayer0) {
            battle.player0Token0Balance = token0Balance;
            battle.player0Token1Balance = token1Balance;
        } else {
            battle.player1Token0Balance = token0Balance;
            battle.player1Token1Balance = token1Balance;
        }

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

        battleRequestKeys.push(BattleRequestKey(pairKey, msg.sender));

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

    function redeemPrize(bytes32 pairKey) external payable {
        // Retrieve the battle for which the prize is being redeemed for
        address requester = playersWithOpenBattles[msg.sender][pairKey];
        require(
            requester != address(0),
            "Player has no current battle for given pairKey."
        );

        // Check that battle has ended i.e. expired
        Battle memory battle = battles[pairKey][requester];
        require(
            battle.endsAt <= block.timestamp,
            "Given battle has not ended yet."
        );

        /*
        IMPORTANT NOTE: Currently, the hook ONLY supports pools 
        with dynamic fees and a tick spacing of 60 as that is what is deployed to 
        anvil node for local testing.

        In a production version, we would take into account the remaining other 
        factors such as static fees and varying tick spacings. This would of course mean
        that those need to be supplied as well when calling the redeemPrize function.
        */
        PoolKey memory poolKey = PoolKey(
            Currency.wrap(battle.battleRequest.token0),
            Currency.wrap(battle.battleRequest.token1),
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // see note above
            60, // see note above
            this
        );

        // Load the final balance for each player
        uint player0FinalBalance = calculatePlayerFinalBalance(
            battle.player0Token0Balance,
            battle.player0Token1Balance,
            poolKey
        );
        uint player1FinalBalance = calculatePlayerFinalBalance(
            battle.player1Token0Balance,
            battle.player1Token1Balance,
            poolKey
        );

        // Check if player won, if they did then transfer money to them
        bool isPlayer0 = msg.sender == battle.player0;
        if (
            (isPlayer0 && player0FinalBalance > player1FinalBalance) ||
            (!isPlayer0 && player1FinalBalance > player0FinalBalance)
        ) {
            ERC20(battle.battleRequest.token0).transferFrom(
                address(this),
                msg.sender,
                battle.battleRequest.prizePotShareToken0
            );
            ERC20(battle.battleRequest.token1).transferFrom(
                address(this),
                msg.sender,
                battle.battleRequest.prizePotShareToken1
            );

            // Update local storage and emit an event that the prize was redeemed
            delete battles[pairKey][battle.battleRequest.requester];
            delete playersWithOpenBattles[battle.player0][pairKey];
            delete playersWithOpenBattles[battle.player1][pairKey];

            emit PrizeRedeemed(
                msg.sender,
                player0FinalBalance,
                player1FinalBalance,
                block.timestamp
            );
        } else if (player0FinalBalance == player1FinalBalance) {
            // TODO: Decide how to handle the case when there is a draw.
            // Perhaps both players can be refunded their deposits back or
            // the game can be expiry can be extended etc.
        }

        // If this point is reached then the caller is not actually the winner so revert the transaction
        revert("Caller attempted to redeem prize but did not win this battle.");
    }

    function calculatePlayerFinalBalance(
        uint256 amountToken0,
        uint256 amountToken1,
        PoolKey memory poolKey
    ) internal view returns (uint256 valueInToken0) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());

        // Calculate price in terms of Token0
        uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96); // Square the sqrtPriceX96
        uint256 price = priceX96 / (1 << 192); // Divide by 2^192 to get the actual price

        // Convert amountToken1 to value in Token0
        uint256 token1ValueInToken0 = (amountToken1 * price) / 1e18; // Note: Divide by 1e18 to keep for correct scale
        return amountToken0 + token1ValueInToken0;
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

    function getBattleRequestKeys()
        public
        view
        returns (BattleRequestKey[] memory)
    {
        return battleRequestKeys;
    }

    struct CalculateNewBalancesParams {
        IPoolManager.SwapParams swapParams;
        BalanceDelta delta;
        Battle battle;
        address player;
    }

    function _calculateNewBalances(
        CalculateNewBalancesParams memory params
    ) private returns (uint256, uint256) {
        // Load initial Battle values
        bool isPlayer0 = params.player == params.battle.player0;
        uint256 token0Balance = isPlayer0
            ? params.battle.player0Token0Balance
            : params.battle.player1Token0Balance;
        uint256 token1Balance = isPlayer0
            ? params.battle.player0Token1Balance
            : params.battle.player1Token1Balance;
        uint256 beforeToken0Balance = token0Balance;
        uint256 beforeToken1Balance = token1Balance;

        // Check current balances and calculate new values where necessary
        if (
            params.swapParams.zeroForOne &&
            token0Balance >= uint256(int256(-params.delta.amount0()))
        ) {
            token0Balance -= uint256(int256(-params.delta.amount0()));
            token1Balance += uint256(int256(params.delta.amount1()));
        } else if (
            !params.swapParams.zeroForOne &&
            token1Balance >= uint256(int256(-params.delta.amount1()))
        ) {
            token1Balance -= uint256(int256(-params.delta.amount1()));
            token0Balance += uint256(int256(params.delta.amount0()));
        }

        // If there were changes to the balances, emit event to indicate this
        EmitBattleBalancesEventParams
            memory eventParams = EmitBattleBalancesEventParams({
                zeroForOne: params.swapParams.zeroForOne,
                battle: params.battle,
                player: params.player,
                beforeToken0Balance: beforeToken0Balance,
                beforeToken1Balance: beforeToken1Balance,
                token0Balance: token0Balance,
                token1Balance: token1Balance,
                deltaAmount: params.swapParams.zeroForOne
                    ? uint256(int256(-params.delta.amount0()))
                    : uint256(int256(-params.delta.amount1()))
            });
        _emitBattleBalancesEvent(eventParams);

        return (token0Balance, token1Balance);
    }

    struct EmitBattleBalancesEventParams {
        bool zeroForOne;
        Battle battle;
        address player;
        uint256 beforeToken0Balance;
        uint256 beforeToken1Balance;
        uint256 token0Balance;
        uint256 token1Balance;
        uint256 deltaAmount;
    }

    function _emitBattleBalancesEvent(
        EmitBattleBalancesEventParams memory params
    ) private {
        if (
            params.beforeToken0Balance != params.token0Balance ||
            params.beforeToken1Balance != params.token1Balance
        ) {
            emit BattleBalancesUpdated(
                params.player,
                params.player == params.battle.player0,
                params.battle.battleRequest.token0,
                params.battle.battleRequest.token1,
                params.battle.player0,
                params.beforeToken0Balance,
                params.beforeToken1Balance,
                params.token0Balance,
                params.token1Balance,
                block.timestamp
            );
        } else {
            emit BattleBalanceUpdatesSkipped(
                params.zeroForOne,
                params.player,
                params.player == params.battle.player0,
                params.battle.battleRequest.token0,
                params.battle.battleRequest.token1,
                params.battle.player0,
                params.deltaAmount,
                block.timestamp
            );
        }
    }
}
