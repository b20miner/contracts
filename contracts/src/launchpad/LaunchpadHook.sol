// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice The Launchpad's Uniswap V4 hook
/// (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §3.8, §9, K40, §37, §38).
///
/// Pool gate (`beforeInitialize`): a pool that names this hook can only be
/// initialized by `LOCKER` (`PositionLocker`), which only does it for a
/// campaign's own `CampaignPool` at finalize, in the same transaction that
/// adds the liquidity. Nobody can create the official pool early, set its
/// price or put liquidity in it before finalize, so the pre-creation attacks
/// of §9.1 — including the tick-crossing gas bomb — cannot happen.
///
/// Trading fee (K69, Launchpad v14, owner decision of 26 October 2026):
/// the pools have no LP fee; this hook takes `FEE_BPS` (1%) of the ETH side
/// of every swap, buys and sells alike, so the fee is always ETH — never the
/// token (v1–v13: a 1% LP fee on the input, so sells paid it in tokens).
/// Every swap splits its fee at once, as o1 does: `CREATOR_BPS` 50% is
/// credited to the token's fee recipient of that moment
/// (`creatorFeesOwed`, pulled with `claimCreatorFees`), `PLATFORM_BPS` 30%
/// and `MINER_LIQUIDITY_BPS` 20% accrue for everyone (`platformFeesOwed`,
/// `minerLiquidityOwed`) and anyone pays them out (`sweep`). `LOCKER` tells
/// this hook each token's recipient (`setFeeRecipient`: before the pool
/// opens and on every change). The fee is a share of the ETH the swapper
/// pays (buy) or the pool pays out (sell):
/// - buy, exact input: taken from the ETH paid in, before the swap;
/// - sell, exact input: taken from the ETH paid out, after the swap;
/// - buy, exact output: added to the ETH the swap needed, after it;
/// - sell, exact output: the pool pays out the fee on top, before the swap;
/// - a swap the price limit would fill only in part is refused, so the fee
///   is never charged on ETH that was not swapped.
///
/// Opening anti-snipe (K40), optional per pool since Launchpad v5 (K49: the
/// creator opts in at creation; `LOCKER` arms it with `protect` just before
/// it initializes the pool): finalize is permissionless, so a bot could
/// open the pool and buy in the same transaction. For `ANTI_SNIPE_WINDOW`
/// seconds after a protected pool opens, the fee is higher, 99% at the
/// opening second and falling linearly to the plain 1% at the end:
///   combined(t) = 1% + 98% × (window − t) / window
/// Exact output is refused during the window (the fee could not be bounded
/// by the caller's input). Everything above the 1% is the surcharge: it
/// goes to the platform (`platformFeesOwed`), as on o1; the 1% part is
/// split as any other fee. `LOCKER`'s own swap — an instant launch's creator buy, in
/// the create transaction, before anyone else can trade
/// (`PositionLocker.buyAtOpening`, K56) — pays the 1% but never the
/// surcharge.
///
/// Fees are held as the PoolManager's ERC-6909 ETH claims (no ETH moves
/// during a swap); a payout burns them and takes the ETH. Pulled, not
/// pushed: a recipient that refuses ETH blocks only its own claim, never a
/// swap. No admin, no upgrade, no parameter can change.
contract LaunchpadHook is IUnlockCallback {
    uint256 public constant BPS = 10_000;
    /// @notice K69: the trading fee, a share of the ETH side of every swap.
    uint256 public constant FEE_BPS = 100;
    /// @notice Combined fee (fee + surcharge) at the second the pool opens.
    uint256 public constant OPENING_TOTAL_FEE_BPS = 9_900;
    uint256 public constant ANTI_SNIPE_WINDOW = 20 seconds;
    uint256 internal constant EXTRA_BPS = OPENING_TOTAL_FEE_BPS - FEE_BPS;
    /// @notice K69: the 1% fee's split (o1: creator / platform / referrer).
    uint256 public constant CREATOR_BPS = 5_000;
    uint256 public constant PLATFORM_BPS = 3_000;
    uint256 public constant MINER_LIQUIDITY_BPS = 2_000;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable LOCKER;
    address public immutable PLATFORM_TREASURY;
    /// @notice Where the MINER liquidity shares go (mainnet `MinerPool`, Base Sepolia `TestMinerPool`).
    address public immutable MINER_LIQUIDITY;

    /// @notice When each official pool was initialized (its finalize).
    mapping(PoolId poolId => uint256) public openedAt;
    /// @notice Pools whose creator chose the opening anti-snipe (K49).
    mapping(PoolId poolId => bool) public protectedPool;
    /// @notice Who earns each token's creator share now (set by `LOCKER`).
    mapping(address token => address) public feeRecipientOf;
    /// @notice K69: creator shares credited and not yet claimed.
    mapping(address recipient => uint256) public creatorFeesOwed;
    /// @notice Platform shares plus every surcharge, not yet swept.
    uint128 public platformFeesOwed;
    /// @notice MINER liquidity shares, not yet swept (one slot with the above).
    uint128 public minerLiquidityOwed;

    error NotPoolManager();
    error NotLocker(address caller);
    error AlreadyOpened();
    error InitializerNotAllowed(address sender);
    error ExactOutputDuringOpening();
    error PartialFill();
    error NothingToSweep();
    error NothingOwed();
    error ZeroRecipient();

    event PoolOpened(PoolId indexed poolId, uint256 openedAt, bool protectedPool);
    /// @notice K69: every charged swap, split at once. The 1% fee is
    /// `creatorFee + platformFee + minerFee`; `surcharge` (anti-snipe) goes
    /// to the platform too. `recipient` earned `creatorFee`.
    event SwapFee(
        PoolId indexed poolId,
        address indexed swapper,
        address indexed recipient,
        bool buy,
        uint256 creatorFee,
        uint256 platformFee,
        uint256 minerFee,
        uint256 surcharge
    );
    event FeeRecipientSet(address indexed token, address indexed recipient);
    event CreatorFeesClaimed(address indexed recipient, uint256 amount);
    event FeesSwept(uint256 toPlatform, uint256 toMinerLiquidity);

    constructor(address poolManager, address locker, address platformTreasury, address minerLiquidity) {
        POOL_MANAGER = IPoolManager(poolManager);
        LOCKER = locker;
        PLATFORM_TREASURY = platformTreasury;
        MINER_LIQUIDITY = minerLiquidity;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Combined fee in bps (fee + surcharge) a swap in `poolId`
    /// pays at `timestamp`; 0 for a pool this hook never opened.
    function combinedFeeBps(PoolId poolId, uint256 timestamp) external view returns (uint256) {
        uint256 opened = openedAt[poolId];
        if (opened == 0 || timestamp < opened) return 0;
        return _feeBps(_remaining(poolId, timestamp));
    }

    /// @notice Surcharge (wei) on `ethAmount` in `poolId` right now: the
    /// part of the combined fee above the 1%.
    function surchargeFor(PoolId poolId, uint256 ethAmount) external view returns (uint256) {
        uint256 remaining = _remaining(poolId, block.timestamp);
        return ethAmount * _feeBps(remaining) / BPS - ethAmount * FEE_BPS / BPS;
    }

    // ------------------------------------------------------------------
    // Arming (K49)
    // ------------------------------------------------------------------

    /// @notice `LOCKER` only, before the pool is initialized: the pool's
    /// creator chose the opening anti-snipe. A pool not armed opens with the
    /// plain 1% fee from its first swap.
    function protect(PoolId poolId) external {
        if (msg.sender != LOCKER) revert NotLocker(msg.sender);
        if (openedAt[poolId] != 0) revert AlreadyOpened();
        protectedPool[poolId] = true;
    }

    /// @notice `LOCKER` only: `recipient` earns `token`'s creator share
    /// from the next swap on — before the pool opens (so the opening creator
    /// buy pays it too) and on every accepted change. Shares already
    /// credited stay with whoever earned them.
    function setFeeRecipient(address token, address recipient) external {
        if (msg.sender != LOCKER) revert NotLocker(msg.sender);
        if (recipient == address(0)) revert ZeroRecipient();
        feeRecipientOf[token] = recipient;
        emit FeeRecipientSet(token, recipient);
    }

    // ------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != LOCKER) revert InitializerNotAllowed(sender);
        PoolId poolId = key.toId();
        openedAt[poolId] = block.timestamp;
        emit PoolOpened(poolId, block.timestamp, protectedPool[poolId]);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev The cases whose ETH amount is the specified one: a buy paying
    /// exact ETH in (the fee comes off it) and a sell asking exact ETH out
    /// (the pool pays the fee on top). The other two pay in `afterSwap`.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 remaining = sender == LOCKER ? 0 : _remaining(key.toId(), block.timestamp);
        bool exactInput = params.amountSpecified < 0;
        if (remaining != 0 && !exactInput) revert ExactOutputDuringOpening();
        // ETH is specified for an exact-input buy or an exact-output sell.
        if (exactInput != params.zeroForOne) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 bps = _feeBps(remaining);
        uint256 total;
        uint256 fee;
        if (exactInput) {
            uint256 ethIn = uint256(-params.amountSpecified);
            total = ethIn * bps / BPS;
            fee = ethIn * FEE_BPS / BPS;
        } else {
            // The pool pays out `out + total`, `total` being `bps` of that.
            uint256 out = uint256(params.amountSpecified);
            total = Math.mulDiv(out, bps, BPS - bps);
            fee = Math.mulDiv(out, FEE_BPS, BPS - FEE_BPS);
        }
        if (total == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _take(key, sender, params.zeroForOne, fee, total - fee);
        // forge-lint: disable-next-line(unsafe-typecast) total < |amountSpecified| <= int128 max (PoolManager)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(total)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        uint256 remaining = sender == LOCKER ? 0 : _remaining(key.toId(), block.timestamp);
        uint256 bps = _feeBps(remaining);
        bool exactInput = params.amountSpecified < 0;
        int128 eth = delta.amount0();

        if (exactInput == params.zeroForOne) {
            // Charged in beforeSwap on the specified ETH: the swap must have
            // used all of the rest (in) or paid all of it out (out).
            uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 total = exactInput ? specified * bps / BPS : Math.mulDiv(specified, bps, BPS - bps);
            if (total == 0) return (IHooks.afterSwap.selector, 0);
            int256 expected = exactInput ? params.amountSpecified + int256(total) : int256(specified + total);
            if (int256(eth) != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 charged;
        uint256 fee;
        if (exactInput) {
            // Sell, exact tokens in: a share of the ETH paid out.
            if (eth <= 0) return (IHooks.afterSwap.selector, 0);
            uint256 ethOut = uint256(uint128(eth));
            charged = ethOut * bps / BPS;
            fee = ethOut * FEE_BPS / BPS;
        } else {
            // Buy, exact tokens out (after the window only): on top of the ETH in.
            if (eth >= 0) return (IHooks.afterSwap.selector, 0);
            if (int256(delta.amount1()) != params.amountSpecified) revert PartialFill();
            uint256 ethIn = uint256(uint128(-eth));
            charged = Math.mulDiv(ethIn, bps, BPS - bps);
            fee = Math.mulDiv(ethIn, FEE_BPS, BPS - FEE_BPS);
        }
        if (charged == 0) return (IHooks.afterSwap.selector, 0);
        _take(key, sender, params.zeroForOne, fee, charged - fee);
        // forge-lint: disable-next-line(unsafe-typecast) charged <= the swap's ETH <= int128 max
        return (IHooks.afterSwap.selector, int128(int256(charged)));
    }

    // ------------------------------------------------------------------
    // Payouts
    // ------------------------------------------------------------------

    /// @notice The caller pulls every creator share credited to it.
    function claimCreatorFees() external returns (uint256 amount) {
        amount = creatorFeesOwed[msg.sender];
        if (amount == 0) revert NothingOwed();
        creatorFeesOwed[msg.sender] = 0;
        POOL_MANAGER.unlock(abi.encode(msg.sender, amount));
        emit CreatorFeesClaimed(msg.sender, amount);
    }

    /// @notice Anyone: pays the platform's shares and surcharges to
    /// `PLATFORM_TREASURY` and the MINER liquidity shares to `MINER_LIQUIDITY`.
    function sweep() external returns (uint256 toPlatform, uint256 toMinerLiquidity) {
        toPlatform = platformFeesOwed;
        toMinerLiquidity = minerLiquidityOwed;
        if (toPlatform == 0 && toMinerLiquidity == 0) revert NothingToSweep();
        platformFeesOwed = 0;
        minerLiquidityOwed = 0;
        if (toPlatform != 0) POOL_MANAGER.unlock(abi.encode(PLATFORM_TREASURY, toPlatform));
        // The MINER pool takes plain ETH and adds whatever it holds on its next `flush`.
        if (toMinerLiquidity != 0) POOL_MANAGER.unlock(abi.encode(MINER_LIQUIDITY, toMinerLiquidity));
        emit FeesSwept(toPlatform, toMinerLiquidity);
    }

    /// @dev Only as the callback of this contract's own `unlock` (`claimCreatorFees`, `sweep`).
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        POOL_MANAGER.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        POOL_MANAGER.take(CurrencyLibrary.ADDRESS_ZERO, to, amount);
        return "";
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Seconds of the window left; 0 once it is over, for a pool this
    /// hook never opened, or for one opened without the anti-snipe.
    function _remaining(PoolId poolId, uint256 timestamp) internal view returns (uint256) {
        uint256 opened = openedAt[poolId];
        if (opened == 0 || !protectedPool[poolId] || timestamp < opened) return 0;
        uint256 elapsed = timestamp - opened;
        return elapsed >= ANTI_SNIPE_WINDOW ? 0 : ANTI_SNIPE_WINDOW - elapsed;
    }

    /// @dev The combined fee: 1%, plus 98% × the share of the window left.
    function _feeBps(uint256 remaining) internal pure returns (uint256) {
        return FEE_BPS + EXTRA_BPS * remaining / ANTI_SNIPE_WINDOW;
    }

    /// @dev Mints the fee and surcharge to this hook as ERC-6909 claims; that
    /// debt is balanced by the delta the callback returns, so no ETH moves
    /// mid-swap. Splits the fee at once (K69); the creator share's rounding
    /// remainder stays with the creator.
    function _take(PoolKey calldata key, address swapper, bool buy, uint256 fee, uint256 surcharge) internal {
        POOL_MANAGER.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee + surcharge);
        uint256 platformFee = fee * PLATFORM_BPS / BPS;
        uint256 minerFee = fee * MINER_LIQUIDITY_BPS / BPS;
        uint256 creatorFee = fee - platformFee - minerFee;
        address recipient = feeRecipientOf[Currency.unwrap(key.currency1)];
        if (creatorFee != 0) creatorFeesOwed[recipient] += creatorFee;
        // forge-lint: disable-next-line(unsafe-typecast) one swap's ETH is far below 2^128 wei
        platformFeesOwed += uint128(platformFee + surcharge);
        // forge-lint: disable-next-line(unsafe-typecast) as above
        minerLiquidityOwed += uint128(minerFee);
        emit SwapFee(key.toId(), swapper, recipient, buy, creatorFee, platformFee, minerFee, surcharge);
    }
}
