// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IMinerLiquiditySink} from "./launchpad/interfaces/ILaunchpadInterfaces.sol";

/// @dev `MinerBurner`: burns every MINER it holds.
interface IMinerBurnerSink {
    function MINER() external view returns (address);
    function burn() external returns (uint256);
}

/// @notice MINER's one official pool and everything it earns
/// (`B20_REVENUE_MODEL.md` §6, owner decisions of 30 October 2026): a
/// hookless Uniswap V4 pool `(ETH, MINER, 0.3% LP fee, tick spacing 60)`
/// whose liquidity this contract holds for good. No admin, no upgrade, no
/// function that removes liquidity.
///
/// - `open` (once, only `B20LiquidityFinalizer` at `T+15`): the mining fees'
///   ETH and the matching MINER (1 ETH = 6,000,000 MINER) go in as one
///   full-range position at that price.
/// - The Launchpad's MINER-liquidity share (ETH: the hook's `sweep` and
///   half of each creation fee) arrives as plain ETH or through
///   `depositMinerLiquidityEth`; before `open` it waits here.
/// - `flush` (anyone; the relay keeper does it regularly) collects the
///   pool's 0.3% fees. The ETH side — fees of buys plus every waiting ETH —
///   goes back in as buy support just below the price. The MINER side —
///   fees of sales — is never added back: it goes to `MinerBurner` and is
///   burned (`FeesBurned`). This is MINER's only ongoing burn.
///
/// The V4 pool key is public, so before `open` anyone may initialize it at
/// another price or add liquidity there. `open` first moves the price back
/// to the opening price with at most half of this contract's own ETH or
/// MINER, so it can never be blocked; crossing a stranger's liquidity on
/// the way trades at prices worse for the stranger than the opening price.
/// Only liquidity larger than that half can leave the opening off the
/// target price — and before `T+15` there is no MINER outside this
/// system's own vaults to place such liquidity on the MINER side.
contract MinerPool is IMinerLiquiditySink, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice The opening price, as `B20LiquidityFinalizer.POOL_MINER_PER_ETH`.
    uint256 public constant POOL_MINER_PER_ETH = 6_000_000;
    uint24 public constant FEE = 3_000;
    int24 public constant TICK_SPACING = 60;
    /// @notice Buy-support ranges sit on a 600-tick grid (~6%) and reach `BAND`
    /// ticks (a price halving), so additions at the same price merge.
    int24 public constant GRID = 600;
    int24 public constant BAND = 6_960;

    /// @notice Uniswap's V4 PoolManager on Base Mainnet and Base Sepolia.
    address public constant BASE_MAINNET_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8_453;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable MINER;
    IMinerBurnerSink public immutable BURNER;
    /// @notice The only caller of `open`. Deployed after this contract
    /// (predicted address), so it is checked when `open` runs.
    address public immutable FINALIZER;

    struct Range {
        int24 lower;
        int24 upper;
    }

    /// @notice Every range this contract holds liquidity in; `[0]` is the opening full range.
    Range[] public ranges;
    mapping(bytes32 key => bool) public hasRange;
    bool public opened;
    /// @notice Tick the pool opened at.
    int24 public openingTick;
    /// @notice MINER burned from the pool's fees (sales); excludes anything
    /// else `MinerBurner` burns.
    uint256 public totalFeesBurned;
    /// @notice ETH (buy fees and the Launchpad's share) added back as buy support.
    uint256 public totalEthAdded;

    enum Action {
        Open,
        Flush
    }

    error ZeroAddress();
    error WrongPoolManager(address provided, address expected);
    error NotFinalizer(address caller);
    error AlreadyOpened();
    error NotPoolManager();
    error ZeroAmount();
    error MissingMiner(uint256 balance, uint256 required);
    error BurnerTokenMismatch(address burnerMiner, address miner);

    event Opened(
        int24 tick, uint128 liquidity, uint256 ethAdded, uint256 minerAdded, uint256 minerBurned, bool priceReset
    );
    event MinerLiquidityDeposited(address indexed from, uint256 amount);
    event Flushed(uint256 ethFees, uint256 minerFees, uint256 ethAdded, int24 bidLower);
    /// @notice MINER from the pool's fees burned through `MinerBurner`.
    event FeesBurned(uint256 amount, uint256 totalFeesBurned);

    constructor(address poolManager, address miner, address burner, address finalizer) {
        if (poolManager == address(0) || miner == address(0) || burner == address(0) || finalizer == address(0)) {
            revert ZeroAddress();
        }
        if (block.chainid == BASE_MAINNET_CHAIN_ID && poolManager != BASE_MAINNET_POOL_MANAGER) {
            revert WrongPoolManager(poolManager, BASE_MAINNET_POOL_MANAGER);
        }
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID && poolManager != BASE_SEPOLIA_POOL_MANAGER) {
            revert WrongPoolManager(poolManager, BASE_SEPOLIA_POOL_MANAGER);
        }
        POOL_MANAGER = IPoolManager(poolManager);
        MINER = IERC20(miner);
        BURNER = IMinerBurnerSink(burner);
        FINALIZER = finalizer;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(MINER)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function rangeCount() external view returns (uint256) {
        return ranges.length;
    }

    /// @notice The opening price as sqrtPriceX96 (MINER wei per ETH wei, ETH = currency0).
    function openingSqrtPriceX96() public pure returns (uint160) {
        return uint160(Math.sqrt(POOL_MINER_PER_ETH << 192));
    }

    // ------------------------------------------------------------------
    // Open (once, the finalizer)
    // ------------------------------------------------------------------

    /// @notice The finalizer sends `minerAmount` MINER here first, then calls
    /// this with the ETH. Returns the opening position's liquidity.
    function open(uint256 minerAmount) external payable nonReentrant returns (uint128 liquidity) {
        if (msg.sender != FINALIZER) revert NotFinalizer(msg.sender);
        if (opened) revert AlreadyOpened();
        if (msg.value == 0 || minerAmount == 0) revert ZeroAmount();
        uint256 held = MINER.balanceOf(address(this));
        if (held < minerAmount) revert MissingMiner(held, minerAmount);
        address burnerMiner = BURNER.MINER();
        if (burnerMiner != address(MINER)) revert BurnerTokenMismatch(burnerMiner, address(MINER));
        opened = true;
        liquidity = abi.decode(
            POOL_MANAGER.unlock(abi.encode(Action.Open, msg.value, minerAmount)), (uint128)
        );
        _burnHeldMiner();
    }

    // ------------------------------------------------------------------
    // Payments (the Launchpad)
    // ------------------------------------------------------------------

    /// @inheritdoc IMinerLiquiditySink
    function depositMinerLiquidityEth() external payable {
        emit MinerLiquidityDeposited(msg.sender, msg.value);
    }

    /// @notice Collects the pool's fees: ETH back in as buy support, MINER burned.
    /// A no-op until `open`.
    function flush() external nonReentrant {
        if (!opened) return;
        POOL_MANAGER.unlock(abi.encode(Action.Flush, uint256(0), uint256(0)));
        _burnHeldMiner();
    }

    // ------------------------------------------------------------------
    // PoolManager callback
    // ------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (Action action, uint256 eth, uint256 miner) = abi.decode(data, (Action, uint256, uint256));
        if (action == Action.Open) return abi.encode(_open(eth, miner));
        _flush();
        return "";
    }

    function _open(uint256 eth, uint256 miner) internal returns (uint128 liq) {
        PoolKey memory key = poolKey();
        bool reset;
        (eth, miner, reset) = _openingPrice(key, eth, miner);
        uint256 ethIn;
        uint256 minerIn;
        (liq, ethIn, minerIn) = _fullRange(key, eth, miner);
        // Rounding dust: ETH stays for the `flush` below (buy support), MINER
        // left over is part of the unused liquidity reserve and is burned.
        emit Opened(openingTick, liq, ethIn, minerIn, miner - minerIn, reset);
        _flush();
    }

    /// @dev Initializes the pool at the opening price, or moves it back there
    /// if a stranger initialized it first; returns the funds left.
    function _openingPrice(PoolKey memory key, uint256 eth, uint256 miner)
        internal
        returns (uint256, uint256, bool reset)
    {
        uint160 target = openingSqrtPriceX96();
        (uint160 current,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (current == 0) {
            POOL_MANAGER.initialize(key, target);
        } else if (current != target) {
            (eth, miner) = _moveTo(key, current, target, eth, miner);
            reset = true;
        }
        return (eth, miner, reset);
    }

    /// @dev The opening position: full range at the price the pool is at now.
    function _fullRange(PoolKey memory key, uint256 eth, uint256 miner)
        internal
        returns (uint128 liq, uint256 ethIn, uint256 minerIn)
    {
        (uint160 price, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        openingTick = tick;
        int24 lo = TickMath.minUsableTick(TICK_SPACING);
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        liq = LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), eth, miner
        );
        if (liq == 0) return (0, 0, 0);
        _record(lo, hi);
        (ethIn, minerIn) = _modify(key, lo, hi, int256(uint256(liq)));
        _pay(key, ethIn, minerIn);
    }

    /// @dev Moves the price to `target` with at most `eth` / `miner` of this
    /// contract's own funds and returns what is left of each.
    function _moveTo(PoolKey memory key, uint160 current, uint160 target, uint256 eth, uint256 miner)
        internal
        returns (uint256, uint256)
    {
        bool zeroForOne = target < current; // the price falls when ETH goes in
        // At most half of either side: the opening position always keeps
        // both, so a stranger's liquidity can stall the move but never empty
        // the opening (and with it `finalize`).
        uint256 budget = (zeroForOne ? eth : miner) / 2;
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        BalanceDelta d = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(budget), sqrtPriceLimitX96: target}),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 < 0) {
            uint256 owed = uint256(uint128(-a0));
            POOL_MANAGER.settle{value: owed}();
            eth -= owed;
        } else if (a0 > 0) {
            POOL_MANAGER.take(key.currency0, address(this), uint256(uint128(a0)));
            eth += uint256(uint128(a0));
        }
        if (a1 < 0) {
            uint256 owed = uint256(uint128(-a1));
            POOL_MANAGER.sync(key.currency1);
            MINER.safeTransfer(address(POOL_MANAGER), owed);
            POOL_MANAGER.settle();
            miner -= owed;
        } else if (a1 > 0) {
            POOL_MANAGER.take(key.currency1, address(this), uint256(uint128(a1)));
            miner += uint256(uint128(a1));
        }
        return (eth, miner);
    }

    function _flush() internal {
        PoolKey memory key = poolKey();
        // 1. collect: a zero change on every range pays its fees to this contract
        uint256 ethFees;
        uint256 minerFees;
        for (uint256 i; i < ranges.length; ++i) {
            (uint256 e, uint256 m) = _collect(key, ranges[i]);
            ethFees += e;
            minerFees += m;
        }
        if (ethFees > 0) POOL_MANAGER.take(key.currency0, address(this), ethFees);
        // 2. MINER fees are never added back: straight to the burner
        if (minerFees > 0) {
            POOL_MANAGER.take(key.currency1, address(BURNER), minerFees);
            totalFeesBurned += minerFees;
            emit FeesBurned(minerFees, totalFeesBurned);
        }
        // 3. every ETH held goes in just below the price as buy support
        (, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        int24 bidLower = _floor(tick, GRID) + GRID;
        uint256 ethIn = _addBid(key, bidLower, address(this).balance);
        _pay(key, ethIn, 0);
        totalEthAdded += ethIn;
        emit Flushed(ethFees, minerFees, ethIn, bidLower);
    }

    /// @dev Everything MINER this contract holds outside the pool (opening
    /// dust, anything sent here) goes to the burner, then the burner burns.
    function _burnHeldMiner() internal {
        uint256 held = MINER.balanceOf(address(this));
        if (held > 0) MINER.safeTransfer(address(BURNER), held);
        if (MINER.balanceOf(address(BURNER)) > 0) BURNER.burn();
    }

    function _collect(PoolKey memory key, Range memory r) internal returns (uint256 eth, uint256 miner) {
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: r.lower, tickUpper: r.upper, liquidityDelta: 0, salt: 0}),
            ""
        );
        eth = uint256(int256(delta.amount0()));
        miner = uint256(int256(delta.amount1()));
    }

    /// @dev ETH single-sided in `[lower, lower + BAND]`, wholly above the current tick.
    function _addBid(PoolKey memory key, int24 lower, uint256 eth) internal returns (uint256 used) {
        int24 hi = TickMath.maxUsableTick(TICK_SPACING);
        if (eth == 0 || lower >= hi) return 0;
        int24 upper = lower + BAND > hi ? hi : lower + BAND;
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), eth
        );
        if (liq == 0) return 0;
        _record(lower, upper);
        (used,) = _modify(key, lower, upper, int256(uint256(liq)));
    }

    /// @dev Adds liquidity; returns what is owed to the PoolManager.
    function _modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        internal
        returns (uint256 eth, uint256 miner)
    {
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidity, salt: 0}),
            ""
        );
        // a fresh range has no fees, and every range was collected first: the delta is the deposit only
        eth = uint256(-int256(delta.amount0()));
        miner = uint256(-int256(delta.amount1()));
    }

    function _pay(PoolKey memory key, uint256 eth, uint256 miner) internal {
        if (eth > 0) POOL_MANAGER.settle{value: eth}();
        if (miner > 0) {
            POOL_MANAGER.sync(key.currency1);
            MINER.safeTransfer(address(POOL_MANAGER), miner);
            POOL_MANAGER.settle();
        }
    }

    function _record(int24 lower, int24 upper) internal {
        bytes32 k = keccak256(abi.encode(lower, upper));
        if (hasRange[k]) return;
        hasRange[k] = true;
        ranges.push(Range(lower, upper));
    }

    /// @dev Rounds `tick` down to a multiple of `step` (towards negative infinity).
    function _floor(int24 tick, int24 step) internal pure returns (int24 r) {
        r = (tick / step) * step;
        if (tick < 0 && tick % step != 0) r -= step;
    }

    /// @dev The hook's `sweep`, the PoolManager's `take` and plain deposits; kept for the next `flush`.
    receive() external payable {}
}
