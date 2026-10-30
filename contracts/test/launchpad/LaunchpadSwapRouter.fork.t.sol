// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CampaignPool} from "../../src/launchpad/CampaignPool.sol";
import {LaunchpadHook} from "../../src/launchpad/LaunchpadHook.sol";
import {LaunchpadSwapRouter} from "../../src/launchpad/LaunchpadSwapRouter.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {PositionLocker} from "../../src/launchpad/PositionLocker.sol";
import {MockCampaignToken} from "./MiningCampaign.t.sol";
import {FlexSwapper, MockMinerSink, MockRegistry} from "./LaunchpadV4.fork.t.sol";

/// @notice Tries to use the router's callback from outside its own swap.
contract CallbackThief is IUnlockCallback {
    IPoolManager immutable pm;
    LaunchpadSwapRouter immutable router;

    constructor(IPoolManager pm_, LaunchpadSwapRouter router_) {
        pm = pm_;
        router = router_;
    }

    /// The PoolManager calls back whoever unlocked it: this contract, never the router.
    function steal(bytes calldata data) external {
        pm.unlock(data);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        return router.unlockCallback(data);
    }
}

/// @notice Adds liquidity to a plain pool in one range (token side only, below the price).
contract RangeAdder is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external {
        pm.unlock(abi.encode(key, lower, upper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lower, int24 upper, int256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta d,) = pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        if (d.amount0() < 0) pm.settle{value: uint128(-d.amount0())}();
        if (d.amount1() < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint128(-d.amount1()));
            pm.settle();
        }
        return "";
    }
}

/// @notice A smart wallet that refuses ETH: a buy's refund cannot reach it.
contract NoEthWallet {
    function buy(LaunchpadSwapRouter r, PoolKey calldata key, uint256 amountIn) external payable {
        r.swap{value: msg.value}(key, true, amountIn, 0, block.timestamp);
    }
}

/// @notice The Launchpad swap router (web app doc §4.6zp) against the real
/// Uniswap V4 PoolManager on Base Sepolia and a real Launchpad pool:
/// `forge test --match-path test/launchpad/LaunchpadSwapRouter.fork.t.sol`.
contract LaunchpadSwapRouterForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant TREASURY = address(0x7EA5);
    address constant CREATOR = address(0xC0FFEE);
    address constant OWNER = address(0xA11CE);
    address constant MINER = address(0x3141);
    address constant TRADER = address(0x7AADE7);
    address constant OTHER = address(0x0BAD);
    uint256 constant SUPPLY = 1_000_000_000;
    uint256 constant PRICE_DEN = 100_000;

    MockRegistry registry;
    MockMinerSink sink;
    PositionLocker locker;
    address hook;
    MiningCampaign campaignImpl;
    CampaignPool poolImpl;
    LaunchpadSwapRouter router;

    /// @notice This test is the pools' factory: direct launches open at 1.5 ETH FDV.
    function directLaunchFdvWei() external pure returns (uint256) {
        return 1.5 ether;
    }

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
        registry = new MockRegistry();
        sink = new MockMinerSink();
        hook = address(uint160(uint256(keccak256("b20.launchpad.hook")) & ~uint256(0x3FFF)) | uint160(0x20CC));
        locker = new PositionLocker(address(PM), address(registry), hook);
        deployCodeTo(
            "LaunchpadHook.sol:LaunchpadHook", abi.encode(address(PM), address(locker), TREASURY, address(sink)), hook
        );
        campaignImpl = new MiningCampaign();
        poolImpl = new CampaignPool();
        router = new LaunchpadSwapRouter(PM);
        vm.deal(MINER, 100_000 ether);
        vm.deal(TRADER, 1_000 ether);
    }

    /// A 2× campaign opened by finalize (LaunchpadV4.fork.t.sol `_create` / `_opened`).
    function _opened(bool mined) internal returns (MockCampaignToken token, PoolKey memory key) {
        token = new MockCampaignToken();
        MiningCampaign campaign = MiningCampaign(payable(Clones.clone(address(campaignImpl))));
        CampaignPool pool = CampaignPool(payable(Clones.clone(address(poolImpl))));
        uint256 rm = SUPPLY * 1e18 * 3 / 5;
        uint256 rp = SUPPLY * 1e18 - rm;
        uint256 cap = (rp - rm * 9_541 / (10_000 * 2)) * PRICE_DEN * 2 / (SUPPLY * 10_000) - 1.5 ether;

        MiningCampaign.InitParams memory mp;
        mp.token = address(token);
        mp.pool = address(pool);
        mp.platformTreasury = TREASURY;
        mp.powTarget = type(uint256).max;
        mp.proofFee = 1e15;
        mp.supplyWhole = SUPPLY;
        mp.miningReserve = rm;
        mp.start = uint64(block.timestamp + 1 hours);
        mp.durationDays = 3;
        mp.walletCapWei = 1_000_000 ether;
        campaign.initialize(mp);
        pool.initialize(
            CampaignPool.InitParams({
                token: address(token),
                campaign: address(campaign),
                locker: address(locker),
                creator: CREATOR,
                feeRecipient: CREATOR,
                supplyWhole: SUPPLY,
                depositCapWei: cap,
                openingMultiple: 2,
                antiSnipe: false,
                instant: false
            })
        );
        token.setSupplyCap(rm + rp);
        registry.set(address(pool), address(token));
        vm.mockCall(address(campaign), abi.encodeCall(MiningCampaign.doubleOpeningQualified, ()), abi.encode(true));

        vm.deal(CREATOR, 10 ether);
        vm.prank(CREATOR);
        pool.deposit{value: 0.5 ether}(CREATOR);
        if (mined) {
            vm.warp(campaign.start());
            campaign.open();
            for (uint256 i = 0; i < 40; i++) {
                (, uint256 fee) = campaign.quoteProof(OWNER);
                if (fee == 0) break;
                vm.prank(MINER);
                campaign.submitProof{value: fee}(OWNER, campaign.challengeOf(OWNER), i);
            }
        }
        vm.warp(campaign.end());
        pool.finalize();
        key = locker.poolKey(address(token));
    }

    function _buy(PoolKey memory key, uint256 eth) internal returns (uint256 out) {
        vm.prank(TRADER);
        out = router.swap{value: eth}(key, true, eth, 0, block.timestamp);
    }

    // ------------------------------------------------------------ swaps

    /// A buy through the router gets exactly what the same swap straight on
    /// the PoolManager gets; the trader pays the ETH and nothing stays behind.
    function test_buyMatchesADirectSwapAndKeepsNothing() public {
        (MockCampaignToken token, PoolKey memory key) = _opened(true);
        vm.warp(block.timestamp + 20);
        FlexSwapper direct = new FlexSwapper(PM);
        vm.deal(address(direct), 1 ether);
        uint256 snap = vm.snapshotState();
        BalanceDelta d = direct.swap(key, true, -0.1 ether, 0);
        vm.revertToState(snap);

        uint256 ethBefore = TRADER.balance;
        vm.expectEmit(true, true, false, true, address(router));
        emit LaunchpadSwapRouter.Swap(TRADER, key.toId(), true, 0.1 ether, uint256(uint128(d.amount1())));
        uint256 out = _buy(key, 0.1 ether);
        assertEq(out, uint256(uint128(d.amount1())), "same as a direct swap");
        assertEq(token.balanceOf(TRADER), out);
        assertEq(ethBefore - TRADER.balance, 0.1 ether);
        assertEq(address(router).balance, 0, "no ETH left in the router");
        assertEq(token.balanceOf(address(router)), 0, "no tokens left in the router");
    }

    /// A sale: one approve, then the swap. Exactly the amount is pulled, the
    /// ETH matches a direct swap, and a second sale needs no new approval.
    function test_sellIsApproveThenSwapAndTheNextSaleIsOneTransaction() public {
        (MockCampaignToken token, PoolKey memory key) = _opened(true);
        vm.warp(block.timestamp + 20);
        uint256 bought = _buy(key, 0.2 ether);
        uint256 half = bought / 2;

        FlexSwapper direct = new FlexSwapper(PM);
        token.seed(address(direct), half);
        uint256 snap = vm.snapshotState();
        BalanceDelta d = direct.swap(key, false, -int256(half), 0);
        vm.revertToState(snap);

        vm.prank(TRADER);
        token.approve(address(router), type(uint256).max);
        uint256 ethBefore = TRADER.balance;
        vm.prank(TRADER);
        uint256 out = router.swap(key, false, half, uint256(uint128(d.amount0())), block.timestamp);
        assertEq(out, uint256(uint128(d.amount0())), "same ETH as a direct swap");
        assertEq(TRADER.balance - ethBefore, out);
        assertEq(token.balanceOf(TRADER), bought - half, "exactly the amount sold was pulled");

        // The second sale: the swap alone.
        uint256 rest = token.balanceOf(TRADER);
        vm.prank(TRADER);
        router.swap(key, false, rest, 1, block.timestamp);
        assertEq(token.balanceOf(TRADER), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------- the opening

    /// The hook's opening surcharge works through the router: a buy in the
    /// opening second pays 99% in all, a sale halfway pays from the ETH out.
    function test_theOpeningSurchargeAppliesThroughTheRouter() public {
        (MockCampaignToken token, PoolKey memory key) = _opened(false);
        LaunchpadHook h = LaunchpadHook(hook);
        uint256 surcharge = h.surchargeFor(key.toId(), 1 ether);

        vm.recordLogs();
        uint256 ethBefore = TRADER.balance;
        _buy(key, 1 ether);
        assertEq(ethBefore - TRADER.balance, 1 ether, "the buyer paid 1 ETH in all");
        assertEq(h.platformFeesOwed(), surcharge + 0.003 ether); // the surcharge and 30% of the 0.01 ETH fee
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == hook && logs[i].topics[0] == LaunchpadHook.SwapFee.selector) seen = true;
        }
        assertTrue(seen, "SwapFee emitted");

        vm.warp(block.timestamp + 10);
        uint256 got = token.balanceOf(TRADER);
        vm.startPrank(TRADER);
        token.approve(address(router), got);
        router.swap(key, false, got, 0, block.timestamp);
        vm.stopPrank();
        assertGt(h.platformFeesOwed(), surcharge + 0.003 ether, "the sale paid its surcharge too");
    }

    // ------------------------------------------------------------ limits

    function test_minOutDeadlineAmountAndValueAreChecked() public {
        (MockCampaignToken token, PoolKey memory key) = _opened(true);
        vm.warp(block.timestamp + 20);
        vm.startPrank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadSwapRouter.Expired.selector, block.timestamp - 1));
        router.swap{value: 1 ether}(key, true, 1 ether, 0, block.timestamp - 1);
        vm.expectRevert(LaunchpadSwapRouter.ZeroAmount.selector);
        router.swap(key, true, 0, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadSwapRouter.WrongValue.selector, 0.5 ether, 1 ether));
        router.swap{value: 0.5 ether}(key, true, 1 ether, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadSwapRouter.WrongValue.selector, 1, 0));
        router.swap{value: 1}(key, false, 1e18, 0, block.timestamp);
        uint256 tooLarge = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(abi.encodeWithSelector(LaunchpadSwapRouter.AmountTooLarge.selector, tooLarge));
        router.swap(key, false, tooLarge, 0, block.timestamp);
        vm.expectRevert(); // TooLittleReceived(out, minOut)
        router.swap{value: 0.01 ether}(key, true, 0.01 ether, type(uint256).max, block.timestamp);
        vm.stopPrank();
        assertEq(token.balanceOf(TRADER), 0);
    }

    // ---------------------------------------------------------- the payer

    /// Only the caller pays: someone else's approval of the router cannot be
    /// spent, and the callback works only inside the router's own swap.
    function test_nobodyCanSpendAnotherHoldersApproval() public {
        (MockCampaignToken token, PoolKey memory key) = _opened(true);
        vm.warp(block.timestamp + 20);
        uint256 bought = _buy(key, 0.1 ether);
        vm.prank(TRADER);
        token.approve(address(router), type(uint256).max);

        // OTHER holds nothing: a sale pulls from OTHER, not from TRADER.
        vm.prank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, bought)
        );
        router.swap(key, false, bought, 0, block.timestamp);

        // Calling the callback directly, or through another unlock, fails.
        bytes memory steal = abi.encode(TRADER, key, false, bought);
        vm.prank(OTHER);
        vm.expectRevert(LaunchpadSwapRouter.NotPoolManager.selector);
        router.unlockCallback(steal);
        CallbackThief thief = new CallbackThief(PM, router);
        vm.expectRevert(); // the PoolManager calls the thief; the router refuses the thief
        thief.steal(steal);

        assertEq(token.balanceOf(TRADER), bought, "the holder kept every token");
    }

    // ------------------------------------------------------- partial fills

    /// A buy larger than the pool can fill (a plain pool with one narrow
    /// range): only what was used is paid, the rest of the ETH goes back; a
    /// wallet that refuses ETH gets a revert instead of losing it.
    function test_aPartialFillRefundsTheRestOfTheEth() public {
        MockCampaignToken token = new MockCampaignToken();
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3_000, 60, IHooks(address(0)));
        PM.initialize(key, TickMath.getSqrtPriceAtTick(0));
        RangeAdder adder = new RangeAdder(PM);
        token.seed(address(adder), 1_000_000e18);
        adder.add(key, -600, 0, 1e21);

        uint256 eth = 1_000 ether;
        vm.recordLogs();
        vm.prank(TRADER);
        uint256 out = router.swap{value: eth}(key, true, eth, 0, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(router)) (, paid,) = abi.decode(logs[i].data, (bool, uint256, uint256));
        }
        assertGt(out, 0);
        assertGt(paid, 0);
        assertLt(paid, eth, "the pool ran out before the ETH did");
        assertEq(TRADER.balance, 1_000 ether - paid, "the unused ETH came back");
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(TRADER), out);

        // The same in a fresh pool, from a wallet that refuses ETH: the refund cannot be delivered.
        PoolKey memory key2 = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 500, 10, IHooks(address(0)));
        PM.initialize(key2, TickMath.getSqrtPriceAtTick(0));
        token.seed(address(adder), 1_000_000e18);
        adder.add(key2, -600, 0, 1e21);
        // What a wallet that takes ETH would get back from the same buy.
        uint256 snap = vm.snapshotState();
        vm.deal(TRADER, eth);
        vm.prank(TRADER);
        router.swap{value: eth}(key2, true, eth, 0, block.timestamp);
        uint256 refund = TRADER.balance;
        vm.revertToState(snap);
        assertGt(refund, 0);
        NoEthWallet w = new NoEthWallet();
        vm.deal(address(w), eth);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadSwapRouter.EthTransferFailed.selector, address(w), refund));
        w.buy{value: eth}(router, key2, eth);
    }
}
