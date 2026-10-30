// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CampaignPool} from "../../src/launchpad/CampaignPool.sol";
import {LaunchpadHook} from "../../src/launchpad/LaunchpadHook.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {PositionLocker} from "../../src/launchpad/PositionLocker.sol";
import {MockCampaignToken} from "./MiningCampaign.t.sol";

contract MockRegistry {
    mapping(address => address) public poolToken;

    function set(address pool, address token) external {
        poolToken[pool] = token;
    }
}

contract MockMinerSink {
    uint256 public received;

    function depositMinerLiquidityEth() external payable {
        received += msg.value;
    }

    /// The hook pays plain ETH (`sweep`), like `MinerPool` takes it.
    receive() external payable {
        received += msg.value;
    }
}

/// @notice Swaps through the PoolManager directly (exact input).
contract Swapper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, bool ethForToken, uint256 amountIn) external payable {
        pm.unlock(abi.encode(key, ethForToken, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        if (zeroForOne) {
            pm.settle{value: uint128(-d.amount0())}();
            pm.take(key.currency1, address(this), uint128(d.amount1()));
        } else {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
            pm.settle();
            pm.take(key.currency0, address(this), uint128(d.amount0()));
        }
        return "";
    }

    receive() external payable {}
}

/// @notice Any swap through the PoolManager: exact input or output, with a
/// price limit; settles whatever the deltas say.
contract FlexSwapper is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        returns (BalanceDelta d)
    {
        d = abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountSpecified, limit)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit) =
            abi.decode(data, (PoolKey, bool, int256, uint160));
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            ""
        );
        if (d.amount0() < 0) pm.settle{value: uint128(-d.amount0())}();
        if (d.amount1() < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
            pm.settle();
        }
        if (d.amount0() > 0) pm.take(key.currency0, address(this), uint128(d.amount0()));
        if (d.amount1() > 0) pm.take(key.currency1, address(this), uint128(d.amount1()));
        return abi.encode(d);
    }

    receive() external payable {}
}

/// @notice The Launchpad V4 path against the real Uniswap V4 PoolManager
/// deployed on Base Sepolia (v4.0.0). Needs network access:
/// `forge test --match-path test/launchpad/LaunchpadV4.fork.t.sol`.
contract LaunchpadV4ForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant TREASURY = address(0x7EA5);
    address constant CREATOR = address(0xC0FFEE);
    address constant OWNER = address(0xA11CE);
    address constant MINER = address(0x3141);
    uint256 constant SUPPLY = 1_000_000_000;
    uint256 constant PRICE_DEN = 100_000;

    MockRegistry registry;
    MockMinerSink sink;
    PositionLocker locker;
    address hook;
    MiningCampaign campaignImpl;
    CampaignPool poolImpl;
    /// The creator's anti-snipe choice for the next `_create` (K49).

    receive() external payable {}

    /// @notice This test is the pools' factory (K68): 5,000 USD at 2,342.56 USD per ETH.
    uint256 constant OPENING_FDV = 2.1344 ether;

    function directLaunchFdvWei() external pure returns (uint256) {
        return OPENING_FDV;
    }

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
        registry = new MockRegistry();
        sink = new MockMinerSink();
        // A hook address whose low 14 bits carry exactly the hook's permissions.
        hook = address(uint160(uint256(keccak256("b20.launchpad.hook")) & ~uint256(0x3FFF)) | uint160(0x20CC)); // beforeInitialize, before/afterSwap (+ return deltas)
        locker = new PositionLocker(address(PM), address(registry), hook);
        deployCodeTo(
            "LaunchpadHook.sol:LaunchpadHook", abi.encode(address(PM), address(locker), TREASURY, address(sink)), hook
        );
        campaignImpl = new MiningCampaign();
        poolImpl = new CampaignPool();
        vm.deal(MINER, 100_000 ether);
    }

    struct Setup {
        MockCampaignToken token;
        MiningCampaign campaign;
        CampaignPool pool;
    }

    /// `multiple`: the pool opens at 2× or 1× the mining price (K51); the
    /// split follows the factory (2/3 mined at 2×, 1/2 at 1×).
    function _create(uint256 supply, uint256 proofFee, uint8 multiple) internal returns (Setup memory s) {
        s.token = new MockCampaignToken();
        s.campaign = MiningCampaign(payable(Clones.clone(address(campaignImpl))));
        s.pool = CampaignPool(payable(Clones.clone(address(poolImpl))));
        uint256 rm = multiple == 2 ? supply * 1e18 * 3 / 5 : supply * 1e18 * 2 / 5; // K55: 60% / 40%
        uint256 rp = supply * 1e18 - rm;
        // deposit cap = spare pool tokens after a full sell-out, at the pool price
        uint256 cap = (rp - rm * 9_541 / (10_000 * uint256(multiple))) * PRICE_DEN * multiple / (supply * 10_000) - 1.5 ether; // K53 buffer, K55 price, K56 share

        MiningCampaign.InitParams memory mp;
        mp.token = address(s.token);
        mp.pool = address(s.pool);
        mp.platformTreasury = TREASURY;
        mp.powTarget = type(uint256).max;
        mp.proofFee = proofFee;
        mp.supplyWhole = supply;
        mp.miningReserve = rm;
        mp.start = uint64(block.timestamp + 1 hours);
        mp.durationDays = 3;
        mp.walletCapWei = 1_000_000 ether;
        s.campaign.initialize(mp);

        s.pool
            .initialize(
                CampaignPool.InitParams({
                    token: address(s.token),
                    campaign: address(s.campaign),
                    locker: address(locker),
                    creator: CREATOR,
                    feeRecipient: CREATOR,
                    supplyWhole: supply,
                    depositCapWei: cap,
                    openingMultiple: multiple,
                    antiSnipe: false, // K52: a mining token's pool never takes the creator's choice
                    instant: false
                })
            );
        // K65 (v12): nothing minted up front; proofs and the opening mint up to the cap.
        s.token.setSupplyCap(rm + rp);
        registry.set(address(s.pool), address(s.token));
        // K63: these tests exercise the 2× opening itself, so a 2× campaign
        // qualifies; the threshold has its own tests (clearMockedCalls).
        if (multiple == 2) {
            vm.mockCall(
                address(s.campaign), abi.encodeCall(MiningCampaign.doubleOpeningQualified, ()), abi.encode(true)
            );
        }
    }

    /// K53: the pool opens at the target price rounded down to a usable
    /// tick (at most one spacing, ~2% in price, ~1% in sqrtPrice).
    function _assertOpening(uint160 price, uint160 target) internal pure {
        assertLe(price, target, "opening above the target");
        assertGe(uint256(price) * 1_011, uint256(target) * 1_000, "opening more than ~1% (sqrt) off");
        assertEq(TickMath.getTickAtSqrtPrice(price) % 200, 0, "opening not on a usable tick");
    }

    function _mine(MiningCampaign c, uint256 proofs) internal {
        if (!c.opened()) {
            vm.warp(c.start());
            c.open();
        }
        for (uint256 i = 0; i < proofs; i++) {
            (, uint256 fee) = c.quoteProof(OWNER);
            if (fee == 0) return;
            vm.prank(MINER);
            c.submitProof{value: fee}(OWNER, c.challengeOf(OWNER), i);
        }
    }

    // ------------------------------------------------------------ the hook

    function test_nobodyElseCanCreateTheOfficialPool() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        PoolKey memory key = locker.poolKey(address(s.token));
        uint160 anyPrice = TickMath.getSqrtPriceAtTick(0);
        vm.expectRevert(); // wrapped LaunchpadHook.InitializerNotAllowed
        PM.initialize(key, anyPrice);

        // a hookless pool with the same tokens is someone else's pool and changes nothing
        PoolKey memory other = locker.poolKey(address(s.token)); // a fresh copy
        other.hooks = IHooks(address(0));
        PM.initialize(other, anyPrice);

        _mine(s.campaign, 5);
        vm.warp(s.campaign.end());
        s.pool.finalize();
        (uint160 price,,,) = PM.getSlot0(key.toId());
        _assertOpening(price, s.pool.sqrtPriceX96());
    }

    function test_lockOnlyByTheRegisteredPoolAndOnce() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        vm.expectRevert(
            abi.encodeWithSelector(PositionLocker.NotCampaignPool.selector, address(this), address(s.token))
        );
        locker.lock{value: 1 ether}(address(s.token), CREATOR, 1e18, 0, TickMath.getSqrtPriceAtTick(0), true);
        vm.expectRevert(
            abi.encodeWithSelector(PositionLocker.NotCampaignPool.selector, address(this), address(s.token))
        );
        locker.lock(address(s.token), CREATOR, 1e18, 0, TickMath.getSqrtPriceAtTick(0), false);
    }

    // ------------------------------------------------------------ anti-snipe (K40)

    /// A finalized pool with 2 ETH of deposits and 40 proofs of fees.
    /// A protected pool (K52: only pools that start from zero are): nobody
    /// mined, so it launches directly at 1.5 ETH FDV, the creator's 2 ETH
    /// deposit as buy support for sells.
    function _opened() internal returns (Setup memory s, PoolKey memory key, uint256 t0) {
        return _opened(false);
    }

    /// `mined`: somebody mined, so the full-range pool opens — never protected.
    function _opened(bool mined) internal returns (Setup memory s, PoolKey memory key, uint256 t0) {
        s = _create(SUPPLY, 1e15, 2);
        vm.deal(CREATOR, 10 ether);
        vm.prank(CREATOR);
        s.pool.deposit{value: 0.5 ether}(CREATOR);
        if (mined) _mine(s.campaign, 40);
        vm.warp(s.campaign.end());
        s.pool.finalize();
        key = locker.poolKey(address(s.token));
        t0 = block.timestamp;
        assertEq(LaunchpadHook(hook).openedAt(key.toId()), t0);
    }

    /// Everything the hook has credited so far: the 1% fees (split at once,
    /// K69) plus any surcharge (in the platform's share).
    function _credited(LaunchpadHook h) internal view returns (uint256) {
        return h.creatorFeesOwed(CREATOR) + h.platformFeesOwed() + h.minerLiquidityOwed();
    }

    function test_openingFeeFallsFrom99To1PercentIn20Seconds() public {
        (, PoolKey memory key, uint256 t0) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        PoolId id = key.toId();
        assertEq(h.combinedFeeBps(id, t0), 9_900);
        assertEq(h.combinedFeeBps(id, t0 + 10), 5_000);
        assertEq(h.combinedFeeBps(id, t0 + 19), 590);
        assertEq(h.combinedFeeBps(id, t0 + 20), 100);
        assertEq(h.combinedFeeBps(id, t0 + 365 days), 100);
        // a pool the hook never opened
        assertEq(h.combinedFeeBps(PoolId.wrap(bytes32(uint256(1))), t0), 0);
    }

    /// Buying in the opening second (e.g. bundled with finalize) costs 99%
    /// of the ETH paid (K40): 1% is the trading fee (K69), 98% the surcharge;
    /// the last 1% reaches the pool.
    function test_buyInTheOpeningSecondPays99Percent() public {
        (Setup memory s, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        FlexSwapper sw = new FlexSwapper(PM);
        vm.deal(address(sw), 10 ether);

        assertEq(h.surchargeFor(key.toId(), 1 ether), 0.98 ether);
        uint256 snap = vm.snapshotState();
        BalanceDelta atOpen = sw.swap(key, true, -1 ether, 0);
        assertEq(-atOpen.amount0(), 1 ether); // the buyer paid 1 ETH in all
        // the 0.01 ETH fee split at once 50/30/20; the 0.98 ETH surcharge to the platform
        assertEq(h.creatorFeesOwed(CREATOR), 0.005 ether);
        assertEq(h.platformFeesOwed(), 0.003 ether + 0.98 ether);
        assertEq(h.minerLiquidityOwed(), 0.002 ether);
        assertEq(h.feeRecipientOf(address(s.token)), CREATOR);

        // the same tokens as 0.01 ETH reaching the pool once the window is over
        vm.revertToState(snap);
        vm.warp(block.timestamp + 20);
        BalanceDelta later = sw.swap(key, true, -int256(uint256(0.01 ether) * 100 / 99), 0);
        assertApproxEqRel(later.amount1(), atOpen.amount1(), 1e12);
        uint256 fee = uint256(0.01 ether) * 100 / 99 / 100;
        assertEq(_credited(h), fee); // no surcharge after the window
        assertEq(h.platformFeesOwed(), fee * 3_000 / 10_000);
    }

    function test_sellInTheWindowPaysFromTheEthOut() public {
        (Setup memory s, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        FlexSwapper sw = new FlexSwapper(PM);
        uint256 amount = 100_000_000e18; // ~0.15 ETH into the buy support
        s.token.seed(address(sw), amount); // tokens bought elsewhere (outside the cap)

        // after the window: 1% of the ETH the pool pays out, in ETH (K69)
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 20);
        BalanceDelta plain = sw.swap(key, false, -int256(amount), 0);
        uint256 gross = uint256(uint128(plain.amount0())) + _credited(h);
        uint256 fee = gross / 100;
        assertEq(_credited(h), fee);
        assertEq(h.platformFeesOwed(), fee * 3_000 / 10_000);
        assertEq(h.minerLiquidityOwed(), fee * 2_000 / 10_000);
        vm.revertToState(snap);

        vm.warp(block.timestamp + 10); // halfway: 50% combined
        BalanceDelta mid = sw.swap(key, false, -int256(amount), 0);
        assertEq(uint256(uint128(mid.amount0())), gross - gross * 5_000 / 10_000);
        assertEq(h.creatorFeesOwed(CREATOR) + h.minerLiquidityOwed(), fee - fee * 3_000 / 10_000);
        assertEq(h.platformFeesOwed(), fee * 3_000 / 10_000 + gross * 5_000 / 10_000 - fee);
        assertEq(mid.amount1(), -int128(int256(amount)));
    }

    function test_exactOutputWaitsForTheWindowAndPartialFillsNeverPay() public {
        (Setup memory s, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        FlexSwapper sw = new FlexSwapper(PM);
        vm.deal(address(sw), 10 ether);
        (uint160 price,,,) = PM.getSlot0(key.toId());

        vm.expectRevert(); // wrapped ExactOutputDuringOpening
        sw.swap(key, true, 1_000e18, 0);
        // a buy whose price limit would stop it early: the fee would be
        // charged on ETH that never reached the pool
        vm.expectRevert(); // wrapped PartialFill
        sw.swap(key, true, -1 ether, price - price / 1_000_000);

        vm.warp(block.timestamp + 20);
        // exact tokens out: 1% of the ETH paid, on top of what the swap needed
        BalanceDelta out = sw.swap(key, true, 1_000e18, 0);
        assertEq(out.amount1(), 1_000e18);
        uint256 paid = uint256(uint128(-out.amount0()));
        assertEq(_credited(h), (paid - _credited(h)) * 100 / 9_900);
        // exact ETH out: the pool pays the fee on top
        uint256 accrued = _credited(h);
        BalanceDelta sold = sw.swap(key, false, 0.000001 ether, 0);
        assertEq(sold.amount0(), int128(int256(0.000001 ether)));
        assertEq(_credited(h) - accrued, uint256(0.000001 ether) * 100 / 9_900);
        accrued = _credited(h);
        // still refused after the window: a partial fill
        (price,,,) = PM.getSlot0(key.toId());
        vm.expectRevert(); // wrapped PartialFill
        sw.swap(key, true, -1 ether, price - price / 1_000_000);
        assertEq(_credited(h), accrued); // nothing charged
    }

    /// K69: the split happens in the swap; anyone pays the platform's and
    /// MINER liquidity's shares out, only the creator claims its own.
    function test_sharesArePaidOutByAnyoneAndClaimedByTheCreator() public {
        (Setup memory s, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        vm.expectRevert(LaunchpadHook.NothingToSweep.selector);
        h.sweep();

        FlexSwapper sw = new FlexSwapper(PM);
        vm.deal(address(sw), 10 ether);
        sw.swap(key, true, -1 ether, 0); // opening second: 0.01 fee + 0.98 surcharge

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(address(0xBEEF));
        (uint256 toPlatform, uint256 toMiner) = h.sweep();
        assertEq(toPlatform, 0.983 ether);
        assertEq(toMiner, 0.002 ether);
        assertEq(TREASURY.balance - treasuryBefore, 0.983 ether);
        assertEq(sink.received(), 0.002 ether);
        assertEq(h.platformFeesOwed(), 0);
        assertEq(h.minerLiquidityOwed(), 0);
        vm.expectRevert(LaunchpadHook.NothingToSweep.selector);
        h.sweep();

        // the creator's share is untouched by the sweep and only its own to pull
        assertEq(h.creatorFeesOwed(CREATOR), 0.005 ether);
        vm.expectRevert(LaunchpadHook.NothingOwed.selector);
        h.claimCreatorFees();
        uint256 creatorBefore = CREATOR.balance;
        vm.prank(CREATOR);
        assertEq(h.claimCreatorFees(), 0.005 ether);
        assertEq(CREATOR.balance - creatorBefore, 0.005 ether);
        assertEq(h.creatorFeesOwed(CREATOR), 0);
        // the hook holds no claims beyond what it owes
        assertEq(PM.balanceOf(hook, 0), 0);

        vm.expectRevert(abi.encodeWithSelector(LaunchpadHook.NotLocker.selector, address(this)));
        h.setFeeRecipient(address(s.token), address(this));
    }

    /// Each swap's creator share goes to the fee recipient of that moment:
    /// a change never moves shares already earned (K69).
    function test_aRecipientChangeKeepsTheSharesAlreadyEarned() public {
        (Setup memory s, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        address next = address(0xFEE2);
        FlexSwapper sw = new FlexSwapper(PM);
        vm.deal(address(sw), 10 ether);
        vm.warp(block.timestamp + 20);
        sw.swap(key, true, -1 ether, 0); // 0.01 ETH fee: 0.005 to the creator

        vm.prank(CREATOR);
        locker.proposeFeeRecipient(address(s.token), next);
        sw.swap(key, true, -1 ether, 0); // proposed only: still the creator's
        assertEq(h.creatorFeesOwed(CREATOR), 0.01 ether);
        vm.prank(next);
        locker.acceptFeeRecipient(address(s.token));
        assertEq(h.feeRecipientOf(address(s.token)), next);

        sw.swap(key, true, -1 ether, 0);
        assertEq(h.creatorFeesOwed(CREATOR), 0.01 ether);
        assertEq(h.creatorFeesOwed(next), 0.005 ether);
    }

    function test_onlyThePoolManagerCallsTheHook() public {
        (, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        vm.expectRevert(LaunchpadHook.NotPoolManager.selector);
        h.beforeSwap(address(this), key, IPoolManager.SwapParams(true, -1, 0), "");
        vm.expectRevert(LaunchpadHook.NotPoolManager.selector);
        h.unlockCallback(abi.encode(uint256(1)));
    }

    // ------------------------------------------------------------ finalize

    function test_finalizeOpensAtTwiceTheMiningPriceAndBurnsTheRest() public {
        Setup memory s = _create(SUPPLY, 1e15, 2); // reward 100,000 tokens per 0.001 ETH proof (K55)
        vm.deal(CREATOR, 10 ether);
        vm.prank(CREATOR);
        s.pool.deposit{value: 0.5 ether}(CREATOR);
        _mine(s.campaign, 40);
        uint256 mined = s.campaign.minedTotal();
        uint256 poolShare = s.campaign.poolAccrued();
        vm.warp(s.campaign.end());
        s.pool.finalize();

        PoolKey memory key = locker.poolKey(address(s.token));
        (uint160 price,,,) = PM.getSlot0(key.toId());
        _assertOpening(price, s.pool.sqrtPriceX96());
        assertEq(uint8(s.pool.status()), uint8(CampaignPool.Status.Finalized));
        assertGt(PM.getLiquidity(key.toId()), 0);

        // every ETH went in (the full-range position uses all but a few wei)
        uint256 eth = poolShare + 0.5 ether;
        assertApproxEqAbs(s.pool.ethAdded(), eth, 1e6);
        // tokens in the pool: the ETH at the pool price (50,000,000 per ETH at 1B,
        // up to ~2% fewer at the tick-rounded opening) plus the 1.5 ETH buffer (K53)
        _assertPoolTokens(s, eth * 50_000_000, 1.5 ether * 50_000_000);
        // supply left: mined (claimable) + pool tokens; every other token burned
        assertEq(s.token.totalSupply(), mined + s.pool.tokenAdded());
        assertEq(s.token.balanceOf(address(s.pool)), 0);

        // K63: finalize delivered the miners' tokens; a buyer trades, and the
        // 1% ETH fees split 50/30/20 (K69); no token fee
        assertEq(s.token.balanceOf(OWNER), mined);

        Swapper sw = new Swapper(PM);
        vm.deal(address(sw), 10 ether);
        vm.warp(block.timestamp + 20); // after the opening anti-snipe window (K40)
        sw.swap{value: 1 ether}(key, true, 1 ether); // buy with 1 ETH: 1% fee = 0.01 ETH
        vm.prank(OWNER);
        s.token.transfer(address(sw), 1_000e18);
        LaunchpadHook h = LaunchpadHook(hook);
        uint256 buyFee = _credited(h);
        assertEq(buyFee, 0.01 ether);
        sw.swap(key, false, 1_000e18); // sell 1,000 tokens: 1% of the ETH out
        uint256 sellFee = _credited(h) - buyFee;
        assertGt(sellFee, 0);

        // each swap split at once, 50/30/20
        uint256 platform = buyFee * 3 / 10 + sellFee * 3 / 10;
        uint256 miner = buyFee * 2 / 10 + sellFee * 2 / 10;
        assertEq(h.platformFeesOwed(), platform);
        assertEq(h.minerLiquidityOwed(), miner);
        assertEq(h.creatorFeesOwed(CREATOR), buyFee + sellFee - platform - miner);
        uint256 treasuryBefore = TREASURY.balance;
        h.sweep();
        assertEq(TREASURY.balance - treasuryBefore, platform);
        assertEq(sink.received(), miner);
        // no token fee anywhere
        assertEq(s.token.balanceOf(CREATOR), 0);
        assertEq(s.token.balanceOf(TREASURY), 0);
        assertEq(s.token.balanceOf(address(locker)), 0);
        // the locker holds only the wei the lock left unused
        assertEq(locker.creatorEthOwed(CREATOR), eth - s.pool.ethAdded());

        uint256 creatorBefore = CREATOR.balance;
        vm.prank(CREATOR);
        h.claimCreatorFees();
        assertEq(CREATOR.balance - creatorBefore, buyFee + sellFee - platform - miner);
    }

    function test_fullSellOutPlusMaxDepositFitsThePoolReserve() public {
        // 100 ETH per proof → 12,000,000 tokens per proof at 1B: ~56 proofs sell out
        Setup memory s = _create(SUPPLY, 100 ether, 2);
        vm.deal(CREATOR, 1_000 ether);
        uint256 cap = s.pool.depositCapWei();
        assertEq(cap, 0.7754 ether); // 113.77M spare tokens at 50M per ETH, minus the 1.5 ETH buffer (K53, K56)
        vm.prank(CREATOR);
        s.pool.deposit{value: cap}(CREATOR);
        vm.deal(MINER, 10_000 ether);
        _mine(s.campaign, 100);
        assertEq(s.campaign.minedTotal(), s.campaign.miningReserve());
        assertTrue(s.campaign.miningOver()); // sold out: finalize before the end
        s.pool.finalize();
        assertLe(s.pool.tokenAdded(), SUPPLY * 1e18 * 2 / 5 + 1);
        assertEq(s.token.totalSupply(), s.campaign.minedTotal() + s.pool.tokenAdded());
        _assertBuffer(s); // K53: still room for the full buffer
    }

    function test_depositCapAndCreatorBadge() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        uint256 cap = s.pool.depositCapWei();
        vm.deal(address(0xD0), cap + 1);
        vm.startPrank(address(0xD0));
        s.pool.deposit{value: cap}(address(0xD0));
        vm.expectRevert(abi.encodeWithSelector(CampaignPool.DepositAboveCap.selector, cap));
        s.pool.deposit{value: 1}(address(0xD0));
        vm.stopPrank();
        assertEq(s.pool.creatorDeposited(), 0);
    }

    // ------------------------------------------- direct launch (K49, v5)

    /// Tokens per ETH (both in wei) at a pool price.
    function _tokensPerEth(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
    }

    /// Nobody mined: no refund, no burn. Every token goes into one
    /// single-sided position opening at ~1.5 ETH FDV (o1's model), and the
    /// first buyers move the price up from there.
    function test_nobodyMinedLaunchesTheWholeSupplyDirectly() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        vm.warp(s.campaign.end());
        assertTrue(s.pool.wouldLaunchDirectly());
        s.pool.finalize();

        assertEq(uint8(s.pool.status()), uint8(CampaignPool.Status.Finalized));
        assertEq(uint8(s.campaign.status()), uint8(MiningCampaign.Status.Finalized));
        assertTrue(s.pool.directLaunch());
        PoolKey memory key = locker.poolKey(address(s.token));
        (uint160 price, int24 tick,,) = PM.getSlot0(key.toId());
        (uint128 liq,,, int24 split, int24 upper, uint128 bid) = locker.positions(address(s.token));
        assertEq(upper, TickMath.maxUsableTick(200)); // no floor in a direct launch
        assertEq(tick, split);
        assertEq(price, TickMath.getSqrtPriceAtTick(split));
        assertEq(bid, 0);
        assertGt(liq, 0);
        // the whole supply is in the pool, minus wei-level rounding (burned)
        assertApproxEqAbs(s.token.balanceOf(address(PM)), SUPPLY * 1e18, 1e9);
        assertApproxEqAbs(s.token.totalSupply(), SUPPLY * 1e18, 1e9);
        // FDV = supply / tokens per ETH: the factory's 5,000 USD (K68), the
        // opening tick rounded down (≤ ~2% more)
        uint256 fdv = SUPPLY * 1e18 / _tokensPerEth(price);
        assertGe(fdv, OPENING_FDV - 1e12);
        assertApproxEqRel(fdv, OPENING_FDV, 0.021e18);
        assertEq(s.pool.directFdvWei(), OPENING_FDV);

        // trading works at once: a buy takes tokens out, a sell brings ETH back
        vm.warp(block.timestamp + 20); // after the anti-snipe window
        Swapper sw = new Swapper(PM);
        vm.deal(address(sw), 1 ether);
        sw.swap(key, true, 0.1 ether);
        uint256 bought = s.token.balanceOf(address(sw));
        assertGt(bought, 0);
        (uint160 after_,,,) = PM.getSlot0(key.toId());
        assertLt(after_, price); // fewer tokens per ETH: the token got dearer
        sw.swap(key, false, bought / 2);
        assertGt(address(sw).balance, 0.9 ether);

        // the creator earned its share of both swaps' fees at once
        assertGt(LaunchpadHook(hook).creatorFeesOwed(CREATOR), 0);
    }

    /// Nobody mined but the creator deposited: the deposit becomes locked
    /// buy support just below the direct launch's opening price.
    function test_nobodyMinedWithADepositGetsBuySupport() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        s.pool.deposit{value: 0.1 ether}(CREATOR);
        vm.warp(s.campaign.end());
        assertTrue(s.pool.wouldLaunchDirectly());
        s.pool.finalize();

        assertTrue(s.pool.directLaunch());
        (,,,, int24 upper, uint128 bid) = locker.positions(address(s.token));
        assertEq(upper, TickMath.maxUsableTick(200)); // the deposit's support reaches the lowest price
        assertGt(bid, 0);
        assertApproxEqAbs(s.pool.ethAdded(), 0.1 ether, 1e6);
        assertApproxEqAbs(s.token.balanceOf(address(PM)), SUPPLY * 1e18, 1e9);
    }

    /// K51 (v6): there is no minimum pool. One proof is enough for the
    /// full-range pool at the chosen opening; a small raise is never sent
    /// into the 1.5 ETH direct launch, far below the price its miners paid.
    function test_aTinyRaiseOpensTheFullRangePool() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        _mine(s.campaign, 1);
        vm.warp(s.campaign.end());
        assertFalse(s.pool.wouldLaunchDirectly());
        s.pool.finalize();
        assertFalse(s.pool.directLaunch());
        (uint160 price,,,) = PM.getSlot0(locker.poolKey(address(s.token)).toId());
        _assertOpening(price, s.pool.sqrtPriceX96());
        assertEq(s.pool.poolPriceNum() * 2, s.campaign.priceNum()); // twice the mining price
    }

    // ------------------------------------------------ K63 opening (v11)

    function _mineFor(MiningCampaign c, address owner, uint256 proofs) internal {
        if (!c.opened()) {
            vm.warp(c.start());
            c.open();
        }
        for (uint256 i = 0; i < proofs; i++) {
            (, uint256 fee) = c.quoteProof(owner);
            vm.prank(MINER);
            c.submitProof{value: fee}(owner, c.challengeOf(owner), i);
        }
    }

    /// K63: a 2× campaign below the threshold opens at 1× (the mining price).
    function test_twoXBelowTheThresholdOpensAtOneX() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        vm.clearMockedCalls();
        _mine(s.campaign, 20); // one miner, 0.02 ETH
        vm.warp(s.campaign.end());
        assertFalse(s.campaign.doubleOpeningQualified());
        vm.expectEmit(address(s.pool));
        emit CampaignPool.OpeningSet(2, 1);
        s.pool.finalize();
        assertEq(s.pool.chosenMultiple(), 2);
        assertEq(s.pool.openingMultiple(), 1);
        assertEq(s.pool.poolPriceNum(), s.campaign.priceNum());
        (uint160 price,,,) = PM.getSlot0(locker.poolKey(address(s.token)).toId());
        _assertOpening(price, s.pool.sqrtPriceX96());
        assertEq(s.token.balanceOf(OWNER), s.campaign.minedTotal());
        assertEq(s.token.totalSupply(), s.campaign.minedTotal() + s.pool.tokenAdded());
    }

    /// K63: at least 0.5 ETH from at least 10 miners of 0.005 ETH keeps 2×.
    function test_tenMinersAndHalfAnEthKeepTwoX() public {
        Setup memory s = _create(SUPPLY, 0.01 ether, 2);
        vm.clearMockedCalls();
        for (uint256 i = 1; i <= 10; i++) {
            _mineFor(s.campaign, address(uint160(0x5000 + i)), 5); // 0.05 ETH each
        }
        assertEq(s.campaign.qualifiedMiners(), 10);
        assertEq(s.campaign.minedEth(), 0.5 ether);
        assertTrue(s.campaign.doubleOpeningQualified());
        vm.warp(s.campaign.end());
        s.pool.finalize();
        assertEq(s.pool.openingMultiple(), 2);
        assertEq(s.pool.poolPriceNum() * 2, s.campaign.priceNum());
        for (uint256 i = 1; i <= 10; i++) {
            assertEq(s.token.balanceOf(address(uint160(0x5000 + i))), s.campaign.minedOf(address(uint160(0x5000 + i))));
        }
    }

    /// K63: with more owners than `finalize` serves, the pool stays closed —
    /// nobody can trade — until `distribute` has reached everyone; then
    /// anyone opens it.
    function test_poolOpensOnlyAfterEveryOwnerHasTheirTokens() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        uint256 n = s.pool.FINALIZE_BATCH() + 10;
        for (uint256 i = 1; i <= n; i++) {
            _mineFor(s.campaign, address(uint160(0x9000 + i)), 1);
        }
        vm.warp(s.campaign.end());
        uint256 eth = s.campaign.poolAccrued();
        s.pool.finalize();
        assertEq(uint8(s.pool.status()), uint8(CampaignPool.Status.Distributing));
        assertEq(s.campaign.distributedCount(), s.pool.FINALIZE_BATCH());
        assertEq(s.pool.poolEth(), eth);
        assertEq(s.pool.ethAdded(), 0, "no liquidity before everyone is served");
        assertEq(s.token.balanceOf(address(uint160(0x9000 + n))), 0);
        vm.expectRevert(CampaignPool.DistributionPending.selector);
        s.pool.open();
        vm.expectRevert(CampaignPool.NotActive.selector);
        s.pool.finalize();

        vm.prank(address(0xF00)); // anyone
        s.campaign.distribute(100);
        assertTrue(s.campaign.distributionDone());
        assertEq(s.token.balanceOf(address(uint160(0x9000 + n))), s.campaign.rewardPerProof());
        vm.prank(address(0xF00));
        s.pool.open();
        assertEq(uint8(s.pool.status()), uint8(CampaignPool.Status.Finalized));
        assertApproxEqAbs(s.pool.ethAdded(), eth, 1e6);
        (uint160 price,,,) = PM.getSlot0(locker.poolKey(address(s.token)).toId());
        _assertOpening(price, s.pool.sqrtPriceX96());
        vm.expectRevert(CampaignPool.NotDistributing.selector);
        s.pool.open();
    }

    /// K51: a 1× opening opens the pool at the mining price itself.
    function test_oneXOpensAtTheMiningPrice() public {
        Setup memory s = _create(SUPPLY, 1e15, 1);
        assertEq(s.pool.openingMultiple(), 1);
        assertEq(s.pool.poolPriceNum(), s.campaign.priceNum());
        assertEq(s.campaign.miningReserve(), SUPPLY * 1e18 * 2 / 5);
        _mine(s.campaign, 20);
        uint256 mined = s.campaign.minedTotal();
        vm.warp(s.campaign.end());
        s.pool.finalize();
        assertFalse(s.pool.directLaunch());
        (uint160 price,,,) = PM.getSlot0(locker.poolKey(address(s.token)).toId());
        _assertOpening(price, s.pool.sqrtPriceX96());
        // the pool pairs each ETH with as many tokens as mining gave for it
        // (up to ~2% fewer at the rounded opening), plus the 1.5 ETH buffer;
        // K56: the pool got 95–99% of the fees, the platform the rest
        uint256 poolEth = s.pool.ethAdded();
        _assertPoolTokens(s, mined * poolEth / (poolEth + s.campaign.platformAccrued()), 1.5 ether * 100_000_000);
    }

    /// K51: at 1× the pool half still covers a full sell-out plus the
    /// largest deposit (~0.68 ETH, K56).
    function test_oneXFullSellOutPlusMaxDepositFitsThePoolReserve() public {
        Setup memory s = _create(SUPPLY, 100 ether, 1);
        vm.deal(CREATOR, 1_000 ether);
        uint256 cap = s.pool.depositCapWei();
        assertEq(cap, 0.6836 ether); // 218.36M spare tokens at 100M per ETH, minus the buffer (K56)
        vm.prank(CREATOR);
        s.pool.deposit{value: cap}(CREATOR);
        vm.deal(MINER, 10_000 ether);
        _mine(s.campaign, 100);
        assertEq(s.campaign.minedTotal(), s.campaign.miningReserve());
        s.pool.finalize();
        assertLe(s.pool.tokenAdded(), SUPPLY * 1e18 * 3 / 5 + 1);
        _assertBuffer(s);
        assertEq(s.token.totalSupply(), s.campaign.minedTotal() + s.pool.tokenAdded());
    }

    // ------------------------------------------ opening buffer (K53, v6)

    /// The buffer is in place: its position exists and holds about 1.5 ETH
    /// worth of tokens at the opening price.
    function _assertBuffer(Setup memory s) internal view {
        (uint128 ask,,, int24 split, int24 upper, uint128 bid) = locker.positions(address(s.token));
        assertGt(ask, 0, "no ask");
        assertGt(bid, 0, "no bid");
        assertGt(upper, split, "bid above the opening");
        assertLt(upper, TickMath.maxUsableTick(200), "a mined pool has a floor (K54)");
        uint256 bufferTokens = s.pool.tokensFor(1.5 ether);
        assertGe(s.pool.tokenAdded(), bufferTokens, "buffer tokens missing");
    }

    /// `tokenAdded` = the full range's tokens (`fullRange`, or up to ~2% fewer
    /// at the tick-rounded opening) + the buffer.
    function _assertPoolTokens(Setup memory s, uint256 fullRange, uint256 buffer) internal view {
        assertLe(s.pool.tokenAdded(), fullRange + buffer + 1e6, "more tokens than the opening and buffer");
        assertGe(s.pool.tokenAdded(), fullRange * 979 / 1_000 + buffer - 1e6, "fewer tokens than the opening and buffer");
    }

    /// ETH per token, scaled by 1e18, from the pool's sqrtPriceX96 (token per ETH).
    function _ethPerToken(PoolKey memory key) internal view returns (uint256) {
        (uint160 p,,,) = PM.getSlot0(key.toId());
        return Math.mulDiv(1e18, 1 << 192, uint256(p) * uint256(p));
    }

    /// K53: one proof raised next to nothing, yet buyers meet o1's depth:
    /// a $1 buy (0.00037 ETH) barely moves the price, and doubling it takes
    /// about 0.62 ETH — 0.414 × (pool ETH + the 1.5 ETH buffer).
    function test_bufferGivesATinyPoolO1Depth() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        _mine(s.campaign, 1); // 0.001 ETH raised: 0.0009 ETH into the pool
        vm.warp(s.campaign.end());
        s.pool.finalize();
        _assertBuffer(s);
        PoolKey memory key = locker.poolKey(address(s.token));
        uint256 before = _ethPerToken(key);

        Swapper sw = new Swapper(PM);
        vm.deal(address(sw), 2 ether);
        sw.swap(key, true, 0.00037 ether);
        uint256 afterSmall = _ethPerToken(key);
        assertLt(afterSmall * 1e6, before * 1_001_000, "a $1 buy moved the price more than 0.1%");

        sw.swap(key, true, 0.62 ether - 0.00037 ether);
        uint256 doubled = _ethPerToken(key);
        assertGt(doubled * 100, before * 190, "0.62 ETH should nearly double the price");
        assertLt(doubled * 100, before * 205, "0.62 ETH should not much more than double it");

        // without the buffer the same pool would have had 0.0009 ETH of depth:
        // the $1 buy alone would have moved it by ~85%
    }

    // ---------------------------------------------- the floor (K54, v6)

    /// Every miner sells everything with no outside buyer: they get all the
    /// ETH back (but the 1% swap fee), and the price stops at the floor.
    function _sellAllIntoTheFloor(uint8 multiple)
        internal
        returns (uint256 raised, uint256 back, int24 upper, uint256 paid)
    {
        Setup memory s = _create(SUPPLY, 1e15, multiple);
        _mine(s.campaign, 50);
        vm.warp(s.campaign.end());
        s.pool.finalize();
        raised = s.pool.ethAdded();
        paid = raised + s.campaign.platformAccrued();
        int24 split;
        (,,, split, upper,) = locker.positions(address(s.token));
        assertGt(upper, split);

        uint256 mined = s.token.balanceOf(OWNER); // K63: delivered at finalize
        assertEq(mined, s.campaign.minedTotal());
        Swapper sw = new Swapper(PM);
        vm.prank(OWNER);
        s.token.transfer(address(sw), mined);
        sw.swap(locker.poolKey(address(s.token)), false, mined);
        back = address(sw).balance;
        (, int24 tick,,) = PM.getSlot0(locker.poolKey(address(s.token)).toId());
        assertLe(tick, upper, "the price fell through the floor");
    }

    /// The floor is `f² / m` of the mining price, `f` the pool's share of
    /// the mining fees (K54; K56: 95.4–99%); the rounding (opening tick
    /// down, floor tick up) only lowers it, by at most ~4%.
    function _assertFloor(int24 upper, uint256 raised, uint256 paid, uint256 m) internal pure {
        uint256 floorEthPerToken = Math.mulDiv(1e18, 1 << 192, uint256(TickMath.getSqrtPriceAtTick(upper)) ** 2);
        uint256 expected = Math.mulDiv(uint256(1e18) / 100_000_000, raised * raised, paid * paid) / m;
        assertLe(floorEthPerToken, expected, "floor above f^2/m");
        assertGe(floorEthPerToken, expected * 95 / 100, "floor far below f^2/m");
    }

    function test_floorReturnsTheEthToMinersAtTwoX() public {
        (uint256 raised, uint256 back, int24 upper, uint256 paid) = _sellAllIntoTheFloor(2);
        assertLe(back, raised);
        assertGe(back * 1_000, raised * 975, "miners got less than ~97.5% of the pool's ETH back");
        assertGe(raised * 1_000, paid * 954, "the pool got less than 95.4% of the fees");
        // 2×: about half the mining price (~47–49%), a quarter of the opening
        _assertFloor(upper, raised, paid, 2);
    }

    function test_floorReturnsTheEthToMinersAtOneX() public {
        (uint256 raised, uint256 back, int24 upper, uint256 paid) = _sellAllIntoTheFloor(1);
        assertLe(back, raised);
        assertGe(back * 1_000, raised * 975, "miners got less than ~97.5% of the pool's ETH back");
        assertGe(raised * 1_000, paid * 954, "the pool got less than 95.4% of the fees");
        // 1×: ~91–98% of the mining price (= of the opening)
        _assertFloor(upper, raised, paid, 1);
    }

    /// A buyer who bought from the ask and sells back first takes their own
    /// ETH back above the opening; the miners' floor is untouched.
    function test_buyersSellBackAboveTheFloor() public {
        Setup memory s = _create(SUPPLY, 1e15, 1);
        _mine(s.campaign, 50);
        vm.warp(s.campaign.end());
        s.pool.finalize();
        PoolKey memory key = locker.poolKey(address(s.token));
        (,,, int24 split,,) = locker.positions(address(s.token));
        Swapper buyer = new Swapper(PM);
        vm.deal(address(buyer), 1 ether);
        buyer.swap(key, true, 0.01 ether);
        uint256 got = s.token.balanceOf(address(buyer));
        buyer.swap(key, false, got);
        (, int24 tick,,) = PM.getSlot0(key.toId());
        assertLe(tick, split + 1, "the price went below the opening");
        assertGe(address(buyer).balance, 1 ether - 0.01 ether * 3 / 100); // two 1% fees and rounding
    }

    // ------------------------------------- anti-snipe only from zero (K52)

    /// A mined token's full-range pool is never protected: its miners hold
    /// their tokens already, so early buyers only buy from them.
    function test_aMinedTokensPoolOpensAtThePlainFee() public {
        (, PoolKey memory key, uint256 t0) = _opened(true);
        LaunchpadHook h = LaunchpadHook(hook);
        assertFalse(h.protectedPool(key.toId()));
        assertEq(h.combinedFeeBps(key.toId(), t0), 100);
        assertEq(h.surchargeFor(key.toId(), 1 ether), 0);
        FlexSwapper sw = new FlexSwapper(PM);
        vm.deal(address(sw), 2 ether);
        sw.swap(key, true, -1 ether, 0); // opening second, no surcharge
        assertEq(h.platformFeesOwed(), 0.003 ether);
        // exact output is fine without the window
        uint256 before = _credited(h);
        sw.swap(key, true, 1_000e18, 0);
        assertEq(h.platformFeesOwed() - 0.003 ether, (_credited(h) - before) * 3_000 / 10_000);
    }

    function test_onlyTheLockerArmsAPoolAndOnlyBeforeItOpens() public {
        (, PoolKey memory key,) = _opened();
        LaunchpadHook h = LaunchpadHook(hook);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadHook.NotLocker.selector, address(this)));
        h.protect(PoolId.wrap(bytes32(uint256(7))));
        vm.prank(address(locker));
        vm.expectRevert(LaunchpadHook.AlreadyOpened.selector);
        h.protect(key.toId());
    }

    /// Security review (1.8): a pool raised with only a few wei must still
    /// finalize into a real pool, never leave the campaign stuck — at the
    /// smallest and the largest supply.
    function test_tinyRaisesStillFinalize() public {
        uint256[2] memory supplies = [uint256(1_000_000), 1_000_000_000_000];
        uint256[4] memory deposits = [uint256(1), 7, 1_000, 1e9];
        for (uint256 i; i < 2; i++) {
            for (uint256 j; j < 4; j++) {
                uint256 snap = vm.snapshotState();
                Setup memory s = _create(supplies[i], 1e15, 2);
                _mine(s.campaign, 1); // somebody mined: the full-range path
                vm.deal(CREATOR, 1 ether);
                vm.prank(CREATOR);
                s.pool.deposit{value: deposits[j]}(CREATOR);
                vm.warp(s.campaign.end());
                s.pool.finalize();
                assertEq(uint8(s.pool.status()), uint8(CampaignPool.Status.Finalized));
                assertGt(s.pool.liquidity(), 0);
                (uint160 price,,,) = PM.getSlot0(locker.poolKey(address(s.token)).toId());
                _assertOpening(price, s.pool.sqrtPriceX96());
                vm.revertToState(snap);
            }
        }
    }

    function test_finalizeWaitsForMiningToEnd() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        _mine(s.campaign, 1);
        vm.expectRevert(CampaignPool.MiningNotOver.selector);
        s.pool.finalize();
    }

    // ---------------------------------------------------- fee recipient

    function test_feeRecipientChangesInTwoSteps() public {
        Setup memory s = _create(SUPPLY, 1e15, 2);
        _mine(s.campaign, 3);
        vm.warp(s.campaign.end());
        s.pool.finalize();
        address next = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.NotFeeRecipient.selector, address(this)));
        locker.proposeFeeRecipient(address(s.token), next);
        vm.prank(CREATOR);
        locker.proposeFeeRecipient(address(s.token), next);
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.NotPendingRecipient.selector, address(this)));
        locker.acceptFeeRecipient(address(s.token));
        vm.prank(next);
        locker.acceptFeeRecipient(address(s.token));
        (, address recipient,,,,) = locker.positions(address(s.token));
        assertEq(recipient, next);
    }
}
