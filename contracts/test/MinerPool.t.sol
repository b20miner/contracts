// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MinerBurner} from "../src/MinerBurner.sol";
import {MinerPool} from "../src/MinerPool.sol";

contract MockMinerP is ERC20, ERC20Burnable {
    constructor() ERC20("Mock MINER", "MMINER") {
        _mint(msg.sender, 1_000_000_000_000e18);
    }
}

/// @notice `MinerPool` against a real Uniswap V4 PoolManager deployed here
/// (`B20_REVENUE_MODEL.md` §6, owner decisions of 30 October 2026): the
/// opening, buy fees back in as buy support, sale fees burned, and a
/// stranger who initialized or seeded the public pool key first.
contract MinerPoolTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolManager pm;
    PoolSwapTest swapper;
    PoolModifyLiquidityTest lp;
    MockMinerP miner;
    MinerBurner burner;
    MinerPool pool;
    address finalizer = makeAddr("finalizer");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");

    uint160 constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    function setUp() public {
        pm = new PoolManager(address(this));
        swapper = new PoolSwapTest(pm);
        lp = new PoolModifyLiquidityTest(pm);
        miner = new MockMinerP();
        burner = new MinerBurner(address(miner));
        pool = new MinerPool(address(pm), address(miner), address(burner), finalizer);
        miner.transfer(trader, 10_000_000_000e18);
        miner.transfer(stranger, 10_000_000_000e18);
        vm.deal(trader, 1_000 ether);
        vm.deal(stranger, 10_000 ether);
        vm.deal(finalizer, 10_000 ether);
        vm.prank(trader);
        miner.approve(address(swapper), type(uint256).max);
        vm.prank(stranger);
        miner.approve(address(lp), type(uint256).max);
        vm.prank(stranger);
        miner.approve(address(swapper), type(uint256).max);
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    function _open(uint256 eth) internal returns (uint128 liq) {
        uint256 m = eth * 6_000_000;
        miner.transfer(address(pool), m);
        vm.prank(finalizer);
        liq = pool.open{value: eth}(m);
    }

    function _price() internal view returns (uint160 p, int24 tick) {
        (p, tick,,) = IPoolManager(address(pm)).getSlot0(pool.poolKey().toId());
    }

    function _buy(address who, uint256 eth) internal {
        PoolKey memory key = pool.poolKey();
        vm.prank(who);
        swapper.swap{value: eth}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(address who, uint256 amount) internal {
        PoolKey memory key = pool.poolKey();
        vm.prank(who);
        swapper.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ---------------------------------------------------------------
    // construction and opening
    // ---------------------------------------------------------------

    function test_constructor_pinsBasePoolManagers() public {
        vm.chainId(8_453);
        vm.expectRevert(
            abi.encodeWithSelector(MinerPool.WrongPoolManager.selector, address(pm), pool.BASE_MAINNET_POOL_MANAGER())
        );
        new MinerPool(address(pm), address(miner), address(burner), finalizer);
        vm.chainId(84_532);
        vm.expectRevert(
            abi.encodeWithSelector(MinerPool.WrongPoolManager.selector, address(pm), pool.BASE_SEPOLIA_POOL_MANAGER())
        );
        new MinerPool(address(pm), address(miner), address(burner), finalizer);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(MinerPool.ZeroAddress.selector);
        new MinerPool(address(pm), address(miner), address(burner), address(0));
    }

    function test_open_onlyFinalizerOnce() public {
        miner.transfer(address(pool), 6_000_000e18);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MinerPool.NotFinalizer.selector, stranger));
        pool.open{value: 1 ether}(6_000_000e18);

        _open(1 ether);
        vm.prank(finalizer);
        vm.expectRevert(MinerPool.AlreadyOpened.selector);
        pool.open{value: 1 ether}(6_000_000e18);
    }

    function test_open_requiresTheMinerFirst() public {
        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(MinerPool.MissingMiner.selector, 0, 6_000_000e18));
        pool.open{value: 1 ether}(6_000_000e18);
    }

    function test_open_rejectsBurnerOfAnotherToken() public {
        MinerBurner other = new MinerBurner(address(new MockMinerP()));
        MinerPool p = new MinerPool(address(pm), address(miner), address(other), finalizer);
        miner.transfer(address(p), 6_000_000e18);
        address otherMiner = address(other.MINER());
        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(MinerPool.BurnerTokenMismatch.selector, otherMiner, address(miner)));
        p.open{value: 1 ether}(6_000_000e18);
    }

    function test_open_fullRangeAtTheOpeningPrice() public {
        uint256 supplyBefore = miner.totalSupply();
        uint128 liq = _open(100 ether);
        (uint160 p,) = _price();
        assertEq(p, pool.openingSqrtPriceX96(), "opens at 1 ETH = 6,000,000 MINER");
        assertGt(liq, 0);
        assertTrue(pool.opened());
        assertLe(pool.totalEthAdded(), 1e6, "at most rounding dust left for buy support");
        (int24 lo, int24 hi) = pool.ranges(0);
        assertEq(lo, TickMath.minUsableTick(60));
        assertEq(hi, TickMath.maxUsableTick(60));
        // both sides in the pool, at most rounding dust outside it
        assertApproxEqAbs(address(pm).balance, 100 ether, 1e6);
        assertApproxEqAbs(miner.balanceOf(address(pm)), 600_000_000e18, 1e12);
        assertEq(miner.balanceOf(address(pool)), 0, "no MINER held: dust burned");
        assertLe(supplyBefore - miner.totalSupply(), 1e12, "only rounding dust burned at the opening");
        assertEq(pool.totalFeesBurned(), 0, "dust is not counted as fees");
    }

    function test_open_ethWaitingBeforeOpenBecomesBuySupport() public {
        vm.deal(address(this), 3 ether);
        pool.depositMinerLiquidityEth{value: 2 ether}();
        (bool ok,) = address(pool).call{value: 1 ether}(""); // the hook's sweep
        assertTrue(ok);
        pool.flush(); // a no-op before the opening
        assertEq(address(pool).balance, 3 ether);
        _open(10 ether);
        assertGe(pool.rangeCount(), 2, "full range + buy support");
        assertLe(address(pool).balance, 1e6, "the waiting ETH went in");
        assertApproxEqAbs(pool.totalEthAdded(), 3 ether, 1e6);
        (, int24 tick) = _price();
        (int24 lower,) = pool.ranges(pool.rangeCount() - 1);
        assertGt(lower, tick, "buy support sits wholly on the ETH side of the price");
    }

    // ---------------------------------------------------------------
    // fees: ETH back in, MINER burned
    // ---------------------------------------------------------------

    function test_flush_burnsSaleFeesAndKeepsBuyFees() public {
        _open(100 ether);
        _sell(trader, 60_000_000e18); // 0.3% fee in MINER
        _buy(trader, 10 ether); // 0.3% fee in ETH
        uint256 supplyBefore = miner.totalSupply();
        uint256 burnerBefore = burner.totalBurned(); // the opening's rounding dust

        vm.recordLogs();
        pool.flush();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 burned = supplyBefore - miner.totalSupply();
        assertApproxEqRel(burned, 60_000_000e18 * 3 / 1000, 1e15, "the whole MINER fee of the sale is burned");
        assertEq(pool.totalFeesBurned(), burned, "every burned MINER came from fees");
        assertEq(burner.totalBurned() - burnerBefore, burned, "the burner burned exactly the fees");
        assertApproxEqRel(pool.totalEthAdded(), 10 ether * 3 / 1000, 1e15, "the ETH fee of the buy goes back in");
        assertEq(miner.balanceOf(address(pool)), 0);
        assertEq(miner.balanceOf(address(burner)), 0);

        bool sawFeesBurned;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == MinerPool.FeesBurned.selector) {
                (uint256 amount, uint256 total) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amount, burned);
                assertEq(total, burned);
                sawFeesBurned = true;
            }
        }
        assertTrue(sawFeesBurned, "FeesBurned emitted");
    }

    function test_flush_repeatsWithoutDoubleCounting() public {
        _open(100 ether);
        _sell(trader, 6_000_000e18);
        pool.flush();
        uint256 first = pool.totalFeesBurned();
        pool.flush(); // nothing new
        assertEq(pool.totalFeesBurned(), first);
        _sell(trader, 6_000_000e18);
        pool.flush();
        assertApproxEqRel(pool.totalFeesBurned(), 2 * first, 2e16);
    }

    function test_flush_feesOnBuySupportRangesAlsoCollected() public {
        _open(10 ether);
        vm.deal(address(this), 5 ether);
        pool.depositMinerLiquidityEth{value: 5 ether}();
        pool.flush(); // 5 ETH buy support just above the tick
        _sell(trader, 120_000_000e18); // crosses into the buy support
        uint256 before = miner.totalSupply();
        pool.flush();
        assertApproxEqRel(before - miner.totalSupply(), 120_000_000e18 * 3 / 1000, 1e15);
    }

    function test_userSentMiner_burnedAtNextFlush_notCountedAsFees() public {
        _open(10 ether);
        miner.transfer(address(pool), 1_000e18);
        uint256 before = miner.totalSupply();
        pool.flush();
        assertEq(before - miner.totalSupply(), 1_000e18);
        assertEq(pool.totalFeesBurned(), 0);
    }

    function test_noFunctionTakesLiquidityOut() public {
        _open(10 ether);
        // the pool's own position: only this contract could remove it, and it has no such path
        (uint128 liquidity,,) = IPoolManager(address(pm)).getPositionInfo(
            pool.poolKey().toId(), address(pool), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 0
        );
        assertGt(liquidity, 0);
        _sell(trader, 6_000_000e18);
        pool.flush();
        (uint128 after_,,) = IPoolManager(address(pm)).getPositionInfo(
            pool.poolKey().toId(), address(pool), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 0
        );
        assertEq(after_, liquidity, "flush never removes liquidity");
    }

    // ---------------------------------------------------------------
    // a stranger got to the public pool key first
    // ---------------------------------------------------------------

    function test_open_resetsPriceAStrangerSetLower() public {
        // MINER 100x dearer than the opening (60,000 per ETH), no liquidity
        pm.initialize(pool.poolKey(), uint160(_sqrtX96(60_000)));
        _open(10 ether);
        (uint160 p,) = _price();
        assertEq(p, pool.openingSqrtPriceX96(), "price moved back for free");
    }

    function test_open_resetsPriceAStrangerSetHigher() public {
        pm.initialize(pool.poolKey(), uint160(_sqrtX96(600_000_000)));
        _open(10 ether);
        (uint160 p,) = _price();
        assertEq(p, pool.openingSqrtPriceX96());
    }

    function test_open_strangerEthLiquidityIsCrossedAtTheirLoss() public {
        // stranger initializes MINER far dearer and parks ETH just above that price
        PoolKey memory key = pool.poolKey();
        int24 strangerTick = -60_000; // ~400 MINER per ETH
        pm.initialize(key, TickMath.getSqrtPriceAtTick(strangerTick));
        vm.prank(stranger);
        lp.modifyLiquidity{value: 5 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: strangerTick + 60, tickUpper: strangerTick + 6_000, liquidityDelta: 1e16, salt: 0
            }),
            ""
        );
        uint256 eth = 10 ether;
        miner.transfer(address(pool), eth * 6_000_000);
        vm.prank(finalizer);
        pool.open{value: eth}(eth * 6_000_000);
        (uint160 p,) = _price();
        assertEq(p, pool.openingSqrtPriceX96(), "price back at the opening");
        // the stranger's ETH was bought with MINER far below its value; it now
        // sits in the pool as buy support (more ETH than the finalizer sent)
        assertGt(pool.totalEthAdded(), 0);
    }

    /// A stranger holding MINER (none exists outside the vaults before `T+15`;
    /// tested anyway) sets MINER far cheaper and parks more MINER below the
    /// price than the opening's ETH can buy: the move stalls, the opening
    /// still happens with both sides.
    function test_open_cannotBeBlockedByStrangerLiquidity() public {
        PoolKey memory key = pool.poolKey();
        int24 strangerTick = 200_040; // ~485 million MINER per ETH
        pm.initialize(key, TickMath.getSqrtPriceAtTick(strangerTick));
        vm.prank(stranger);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: strangerTick - 6_000, tickUpper: strangerTick - 60, liquidityDelta: 1e24, salt: 0
            }),
            ""
        );
        uint256 eth = 1 ether;
        miner.transfer(address(pool), eth * 6_000_000);
        vm.prank(finalizer);
        uint128 liq = pool.open{value: eth}(eth * 6_000_000);
        assertTrue(pool.opened());
        assertGt(liq, 0, "the opening keeps both sides");
        (uint160 p,) = _price();
        assertGt(p, pool.openingSqrtPriceX96(), "the move stalled above the target");
    }

    function _sqrtX96(uint256 minerPerEth) internal pure returns (uint256) {
        return _sqrt(minerPerEth << 192);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    receive() external payable {}
}
