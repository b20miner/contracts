// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {ILaunchpadRegistry, IPositionLocker} from "./interfaces/ILaunchpadInterfaces.sol";

interface ILaunchpadHookArming {
    function protect(PoolId poolId) external;
    function setFeeRecipient(address token, address recipient) external;
}

/// @notice Holds every Launchpad campaign's pool liquidity for good and
/// names who earns its creator fees (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md`
/// §3.4, K15, K16, §38). One contract for all campaigns.
///
/// The liquidity lives directly in the Uniswap V4 `PoolManager`, owned by
/// this contract: there is no position NFT, and this contract has no
/// function that removes liquidity, so the lock is permanent by
/// construction. Nothing is ever taken out: the pools have no LP fee.
///
/// Pools are `(ETH, token, no LP fee, tick spacing 200, LaunchpadHook)`;
/// the hook takes the 1% trading fee in ETH (K69, v14; v1–v13: a 1% LP fee). Only a
/// campaign's own `CampaignPool` (as registered in the factory) can create
/// its pool, once; the hook refuses every other initializer.
///
/// Since Launchpad v6 every pool has one shape (`lock`, K54), opening at a
/// usable tick `split`:
/// - the ask: tokens single-sided from the opening price up (`[min, split]`,
///   as on o1), which buyers buy from;
/// - the bid: all the ETH single-sided just below the opening price
///   (`[split, bidUpper]`), which sellers sell into.
/// A direct or instant launch puts the whole supply in the ask and any ETH
/// in a bid reaching the lowest price. A mined pool (K54) puts the tokens
/// matching the ETH raised plus the 1.5 ETH opening buffer (K53) in the ask,
/// and sizes the bid so that exactly the miners' tokens fit in it: selling
/// every mined token returns all the ETH, and the price can never fall
/// below the bid's far edge — the floor. Both positions are locked for good.
/// The anti-snipe arms the hook first when asked (K52).
///
/// Creator buy (K56, v8): right after an instant launch's `lock`, in the
/// same transaction, its pool may make one buy for the creator
/// (`buyAtOpening`). This contract is the swapper, and the hook charges no
/// anti-snipe surcharge on this contract's swaps; it makes no other swap.
///
/// Fee split (K69, Launchpad v14, owner decision of 26 October 2026): the
/// hook splits its 1% ETH fee on every swap, 50% creator / 30% platform /
/// 20% MINER liquidity, and pays it out itself (v1–v13, K16: this contract
/// collected an LP fee, ETH 80/10/10 and the sells' token fee 80% creator /
/// 20% platform). This contract keeps the fee recipient (two-step change)
/// and tells the hook (`setFeeRecipient`) before the pool opens and on
/// every change. `creatorEthOwed` holds only the few wei a `lock` leaves
/// unused (`withdrawCreatorEth`).
contract PositionLocker is IPositionLocker, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    /// @notice No LP fee: the hook takes the trading fee (K69).
    uint24 public constant FEE = 0;
    int24 public constant TICK_SPACING = 200;

    IPoolManager public immutable POOL_MANAGER;
    ILaunchpadRegistry public immutable REGISTRY;
    address public immutable HOOK;

    /// @dev `liquidity`: the ask `[min, split]`; `bidLiquidity`: the bid
    /// `[split, bidUpper]` (0 when no ETH). `split` is the opening tick;
    /// `bidUpper` the floor (the maximum usable tick without a floor).
    struct Position {
        uint128 liquidity;
        address feeRecipient;
        address pendingRecipient;
        int24 split;
        int24 bidUpper;
        uint128 bidLiquidity;
    }

    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    mapping(address token => Position) public positions;
    mapping(address recipient => uint256) public creatorEthOwed;

    /// @notice Tokens whose opening creator buy is done (K56): at most one.
    mapping(address token => bool) public openingBuyDone;

    enum Action {
        Add,
        Buy
    }

    error NotPoolManager();
    error NotCampaignPool(address caller, address token);
    error AlreadyLocked(address token);
    error NotLocked(address token);
    error ZeroRecipient();
    error NotFeeRecipient(address caller);
    error NotPendingRecipient(address caller);
    error NothingOwed();
    error EthTransferFailed(address to, uint256 amount);
    error OpeningBuyDone(address token);
    error PartialOpeningBuy(uint256 ethIn, uint256 ethUsed);

    event Locked(
        address indexed token,
        uint128 tokenLiquidity,
        uint128 bidLiquidity,
        uint256 ethUsed,
        uint256 tokenUsed,
        int24 split,
        int24 bidUpper
    );
    event CreatorEthWithdrawn(address indexed recipient, uint256 amount);
    event OpeningBuy(address indexed token, address indexed recipient, uint256 ethIn, uint256 tokensOut);
    event FeeRecipientProposed(address indexed token, address indexed current, address indexed pending);
    event FeeRecipientChanged(address indexed token, address indexed previous, address indexed current);

    constructor(address poolManager, address registry, address hook) {
        POOL_MANAGER = IPoolManager(poolManager);
        REGISTRY = ILaunchpadRegistry(registry);
        HOOK = hook;
    }

    function poolKey(address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    // ------------------------------------------------------------------
    // Lock (once per campaign, by its CampaignPool)
    // ------------------------------------------------------------------

    /// @inheritdoc IPositionLocker
    /// @dev The pool opens at `sqrtPriceX96` rounded down to a usable tick
    /// (`split`, at most one spacing = ~2% off), so the ask `[min, split]`
    /// lies wholly on the token side (buys move into it) and the bid
    /// `[split, bidUpper]` wholly on the ETH side (sells move into it).
    /// Unused tokens go back to the pool (which burns them); unused ETH —
    /// a few wei — is credited to the fee recipient.
    function lock(
        address token,
        address feeRecipient,
        uint256 tokenAmount,
        uint256 floorTokens,
        uint160 sqrtPriceX96,
        bool antiSnipe
    ) external payable nonReentrant returns (uint128 liquidity, uint256 ethUsed, uint256 tokenUsed) {
        int24 split = _split(sqrtPriceX96);
        _open(token, feeRecipient, tokenAmount, TickMath.getSqrtPriceAtTick(split), antiSnipe);
        (ethUsed, tokenUsed) = _addRanges(token, feeRecipient, split, tokenAmount, floorTokens);
        liquidity = positions[token].liquidity;
        _refundUnused(token, feeRecipient, tokenAmount, tokenUsed, ethUsed);
    }

    /// @dev Builds and adds the ask and the bid, records the position and
    /// emits `Locked`.
    function _addRanges(address token, address feeRecipient, int24 split, uint256 tokenAmount, uint256 floorTokens)
        internal
        returns (uint256 ethUsed, uint256 tokenUsed)
    {
        Range[] memory ranges = _ranges(split, tokenAmount, floorTokens);
        (ethUsed, tokenUsed) = _add(token, ranges);
        Position storage pos = positions[token];
        pos.liquidity = ranges[0].liquidity;
        pos.feeRecipient = feeRecipient;
        pos.split = split;
        pos.bidUpper = ranges.length > 1 ? ranges[1].upper : TickMath.maxUsableTick(TICK_SPACING);
        pos.bidLiquidity = ranges.length > 1 ? ranges[1].liquidity : 0;
        emit Locked(token, pos.liquidity, pos.bidLiquidity, ethUsed, tokenUsed, split, pos.bidUpper);
    }

    /// @dev The ask `[min, split]` with `tokenAmount`, and — when ETH was
    /// sent — the bid `[split, upper]` with all of it.
    function _ranges(int24 split, uint256 tokenAmount, uint256 floorTokens)
        internal
        view
        returns (Range[] memory ranges)
    {
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        uint160 opening = TickMath.getSqrtPriceAtTick(split);
        ranges = new Range[](msg.value > 0 ? 2 : 1);
        ranges[0] = Range(lo, split, LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(lo), opening, tokenAmount));
        if (msg.value == 0) return ranges;
        int24 upper = _bidUpper(split, opening, floorTokens);
        ranges[1] = Range(
            split, upper, LiquidityAmounts.getLiquidityForAmount0(opening, TickMath.getSqrtPriceAtTick(upper), msg.value)
        );
    }

    /// @dev The floor (K54). Selling `floorTokens` from `opening` down to
    /// price `b` takes `L(√b − √a)` tokens for `L(1/√a − 1/√b)` ETH, so with
    /// all the ETH `x` in `[a, b]`, exactly `floorTokens` fit when
    /// `√b = floorTokens / (x · √a)` (prices in tokens per ETH). Rounded up
    /// to the spacing, so at least that many fit; at least one spacing wide.
    /// `floorTokens == 0` (a direct or instant launch): the lowest price.
    function _bidUpper(int24 split, uint160 opening, uint256 floorTokens) internal view returns (int24 upper) {
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        if (floorTokens == 0) return hi;
        uint256 sqrtB = Math.mulDiv(floorTokens, 1 << 192, msg.value * uint256(opening));
        if (sqrtB >= TickMath.getSqrtPriceAtTick(hi)) return hi;
        if (sqrtB <= opening) return split + TICK_SPACING;
        int24 tick = TickMath.getTickAtSqrtPrice(uint160(sqrtB));
        upper = (tick / TICK_SPACING) * TICK_SPACING;
        if (upper < tick) upper += TICK_SPACING;
        if (upper <= split) upper = split + TICK_SPACING;
        if (upper > hi) upper = hi;
    }

    /// @dev `sqrtPriceX96`'s tick rounded down to the spacing, kept strictly
    /// inside the usable range.
    function _split(uint160 sqrtPriceX96) internal pure returns (int24 split) {
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        split = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) split -= TICK_SPACING;
        if (split <= lo) split = lo + TICK_SPACING;
        if (split >= hi) split = hi - TICK_SPACING;
    }

    /// @dev Checks the caller, pulls the tokens, arms the anti-snipe if
    /// chosen and creates the pool.
    function _open(address token, address feeRecipient, uint256 tokenAmount, uint160 sqrtPriceX96, bool antiSnipe)
        internal
    {
        if (REGISTRY.poolToken(msg.sender) != token || token == address(0)) {
            revert NotCampaignPool(msg.sender, token);
        }
        if (positions[token].liquidity != 0) revert AlreadyLocked(token);
        if (feeRecipient == address(0)) revert ZeroRecipient();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        PoolKey memory key = poolKey(token);
        ILaunchpadHookArming(HOOK).setFeeRecipient(token, feeRecipient);
        if (antiSnipe) ILaunchpadHookArming(HOOK).protect(key.toId());
        POOL_MANAGER.initialize(key, sqrtPriceX96);
    }

    function _add(address token, Range[] memory ranges) internal returns (uint256 eth, uint256 tok) {
        (eth, tok) =
            abi.decode(POOL_MANAGER.unlock(abi.encode(Action.Add, token, abi.encode(ranges))), (uint256, uint256));
    }

    /// @inheritdoc IPositionLocker
    /// @dev Only the token's own pool, once, after its `lock`. The whole
    /// `msg.value` must fill (the ask reaches the lowest price, so it always
    /// does); the tokens go straight to `recipient`.
    function buyAtOpening(address token, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (REGISTRY.poolToken(msg.sender) != token || token == address(0)) {
            revert NotCampaignPool(msg.sender, token);
        }
        if (positions[token].liquidity == 0) revert NotLocked(token);
        if (openingBuyDone[token]) revert OpeningBuyDone(token);
        if (recipient == address(0)) revert ZeroRecipient();
        openingBuyDone[token] = true;
        tokensOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(Action.Buy, token, abi.encode(msg.value, recipient))), (uint256)
        );
        emit OpeningBuy(token, recipient, msg.value, tokensOut);
    }

    /// @dev Unused tokens go back to the pool (which burns them); unused ETH
    /// — a few wei of rounding — is credited to the fee recipient.
    function _refundUnused(address token, address feeRecipient, uint256 tokenAmount, uint256 tokenUsed, uint256 ethUsed)
        internal
    {
        if (tokenAmount > tokenUsed) IERC20(token).safeTransfer(msg.sender, tokenAmount - tokenUsed);
        if (msg.value > ethUsed) creatorEthOwed[feeRecipient] += msg.value - ethUsed;
    }

    // ------------------------------------------------------------------
    // Fee recipient
    // ------------------------------------------------------------------

    /// @notice The fee recipient pulls the ETH a `lock` left unused (its
    /// trading fees are claimed from the hook, `claimCreatorFees`).
    function withdrawCreatorEth() external nonReentrant {
        uint256 amount = creatorEthOwed[msg.sender];
        if (amount == 0) revert NothingOwed();
        creatorEthOwed[msg.sender] = 0;
        emit CreatorEthWithdrawn(msg.sender, amount);
        _sendEth(msg.sender, amount);
    }

    /// @notice Two-step change of the fee recipient (§12, decision 4).
    function proposeFeeRecipient(address token, address pending) external {
        Position storage pos = positions[token];
        if (msg.sender != pos.feeRecipient || pos.liquidity == 0) revert NotFeeRecipient(msg.sender);
        if (pending == address(0)) revert ZeroRecipient();
        pos.pendingRecipient = pending;
        emit FeeRecipientProposed(token, msg.sender, pending);
    }

    function acceptFeeRecipient(address token) external {
        Position storage pos = positions[token];
        if (msg.sender != pos.pendingRecipient || msg.sender == address(0)) revert NotPendingRecipient(msg.sender);
        address previous = pos.feeRecipient;
        pos.feeRecipient = msg.sender;
        pos.pendingRecipient = address(0);
        ILaunchpadHookArming(HOOK).setFeeRecipient(token, msg.sender);
        emit FeeRecipientChanged(token, previous, msg.sender);
    }

    // ------------------------------------------------------------------
    // PoolManager callback
    // ------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (Action action, address token, bytes memory args) = abi.decode(data, (Action, address, bytes));
        PoolKey memory key = poolKey(token);
        if (action == Action.Buy) return _buy(key, args);
        Range[] memory ranges = abi.decode(args, (Range[]));
        int256 amount0;
        int256 amount1;
        for (uint256 i; i < ranges.length; ++i) {
            (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: ranges[i].lower,
                    tickUpper: ranges[i].upper,
                    liquidityDelta: int256(uint256(ranges[i].liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            amount0 += delta.amount0();
            amount1 += delta.amount1();
        }

        // Adding: what is owed to the PoolManager is negative.
        uint256 eth = uint256(-amount0);
        uint256 tok = uint256(-amount1);
        if (eth > 0) POOL_MANAGER.settle{value: eth}();
        if (tok > 0) {
            POOL_MANAGER.sync(key.currency1);
            IERC20(token).safeTransfer(address(POOL_MANAGER), tok);
            POOL_MANAGER.settle();
        }
        return abi.encode(eth, tok);
    }

    /// @dev The opening creator buy: exact-input ETH → token, filled in full;
    /// the hook takes its 1% (no surcharge) from the ETH in.
    function _buy(PoolKey memory key, bytes memory args) internal returns (bytes memory) {
        (uint256 ethIn, address recipient) = abi.decode(args, (uint256, address));
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 ethUsed = uint256(-int256(delta.amount0()));
        if (ethUsed != ethIn) revert PartialOpeningBuy(ethIn, ethUsed);
        uint256 out = uint256(int256(delta.amount1()));
        POOL_MANAGER.settle{value: ethUsed}();
        POOL_MANAGER.take(key.currency1, recipient, out);
        return abi.encode(out);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }
}
