// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {MinerBurner} from "../src/MinerBurner.sol";
import {MinerPool} from "../src/MinerPool.sol";
import {LaunchpadSwapRouter} from "../src/launchpad/LaunchpadSwapRouter.sol";
import {MockMinerP} from "./MinerPool.t.sol";

/// @notice Mainnet rehearsal of `MinerPool` (owner decisions of 30 October
/// 2026) on a Base mainnet fork: the real Uniswap V4 PoolManager the
/// contract pins, trades through our `LaunchpadSwapRouter`, sale fees
/// burned, buy fees and Launchpad ETH in as buy support, and a stranger who
/// initialized the public pool key first. MINER is an ERC-20 stand-in (the
/// live one is a B20 precompile asset). Needs network access.
contract MinerPoolForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    uint256 constant OPENING_ETH = 10 ether;

    MockMinerP miner;
    MinerBurner burner;
    MinerPool pool;
    LaunchpadSwapRouter router;
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        assertEq(block.chainid, 8_453);
        miner = new MockMinerP();
        burner = new MinerBurner(address(miner));
        // this test stands in for the B20 liquidity finalizer
        pool = new MinerPool(address(PM), address(miner), address(burner), address(this));
        router = new LaunchpadSwapRouter(PM);
        miner.transfer(trader, 1_000_000_000e18);
        vm.deal(trader, 100 ether);
        vm.deal(stranger, 1 ether);
        vm.deal(address(this), 100 ether);
        vm.prank(trader);
        miner.approve(address(router), type(uint256).max);
    }

    function _open() internal returns (uint128 liq) {
        uint256 m = OPENING_ETH * 6_000_000;
        miner.transfer(address(pool), m);
        liq = pool.open{value: OPENING_ETH}(m);
    }

    /// One `WINDOW` after the opening a flush closes its window; then flushes add buy support.
    function _firstWindow() internal {
        vm.warp(block.timestamp + pool.WINDOW());
        vm.roll(block.number + 1);
        pool.flush();
        vm.roll(block.number + 1);
    }

    function _tick() internal view returns (uint160 p, int24 tick) {
        (p, tick,,) = PM.getSlot0(pool.poolKey().toId());
    }

    function test_opensAtSixMillionPerEthOnTheMainnetPoolManager() public {
        uint128 liq = _open();
        assertGt(liq, 0);
        assertTrue(pool.opened());
        (uint160 p,) = _tick();
        assertEq(p, pool.openingSqrtPriceX96());
        assertEq(PM.getLiquidity(pool.poolKey().toId()), liq);
        assertLe(address(pool).balance, 1e6); // only rounding dust
        assertEq(miner.balanceOf(address(pool)), 0); // MINER dust went to the burner
    }

    function test_buysAndSalesThroughOurRouter_saleFeesBurned_buyFeesBackIn() public {
        _open();
        _firstWindow();
        PoolKey memory key = pool.poolKey();

        vm.prank(trader);
        uint256 got = router.swap{value: 0.01 ether}(key, true, 0.01 ether, 0, block.timestamp);
        assertApproxEqRel(got, 0.01 ether * 6_000_000 * 997 / 1000, 0.002e18);

        uint256 sold = 600_000e18;
        vm.prank(trader);
        uint256 ethOut = router.swap(key, false, sold, 0, block.timestamp);
        assertGt(ethOut, 0);

        uint256 ranges = pool.rangeCount();
        uint256 addedBefore = pool.totalEthAdded();
        uint256 supplyBefore = miner.totalSupply();
        uint256 burnedBefore = burner.totalBurned(); // the opening's rounding dust
        pool.flush();
        // the 0.30% of the sale, in MINER, is burned (the pool's rounding takes a few wei)
        assertApproxEqAbs(pool.totalFeesBurned(), sold * 3 / 1000, 1e6);
        assertEq(burner.totalBurned() - burnedBefore, pool.totalFeesBurned());
        assertEq(supplyBefore - miner.totalSupply(), pool.totalFeesBurned());
        // the 0.30% of the buy, in ETH, went back in as buy support
        assertApproxEqAbs(pool.totalEthAdded() - addedBefore, 0.01 ether * 3 / 1000, 1e6);
        assertGe(pool.rangeCount(), ranges); // a band used before is topped up, not repeated
        assertEq(miner.balanceOf(address(pool)), 0);
        assertEq(miner.balanceOf(address(burner)), 0);
    }

    function test_launchpadEthBecomesBuySupportBelowThePrice() public {
        _open();
        _firstWindow();
        uint256 dust = address(pool).balance;
        vm.deal(address(0xFEE), 1 ether);
        vm.prank(address(0xFEE));
        pool.depositMinerLiquidityEth{value: 0.5 ether}();
        assertEq(address(pool).balance - dust, 0.5 ether);
        uint256 addedBefore = pool.totalEthAdded();
        pool.flush();
        // at most `bidCap` per flush (0.25% of the opening ETH); the rest waits
        uint256 cap = pool.bidCap(pool.windowMax());
        assertApproxEqAbs(pool.totalEthAdded() - addedBefore, cap, 1e6);
        assertApproxEqAbs(address(pool).balance, 0.5 ether + dust - cap, 1e6);

        // a large sale walks into the support: the ETH buys MINER back
        PoolKey memory key = pool.poolKey();
        (, int24 tickBefore) = _tick();
        vm.prank(trader);
        router.swap(key, false, 100_000_000e18, 0, block.timestamp);
        (, int24 tickAfter) = _tick();
        assertGt(tickAfter, tickBefore); // more MINER per ETH: MINER got cheaper
        pool.flush();
        assertApproxEqAbs(pool.totalFeesBurned(), 100_000_000e18 * 3 / 1000, 1e6);
    }

    /// The pool key is public: a stranger who initialized it at another
    /// price on the real PoolManager does not stop the opening.
    function test_strangerInitializedTheKeyFirst() public {
        PoolKey memory key = pool.poolKey();
        uint160 target = pool.openingSqrtPriceX96();
        vm.prank(stranger);
        PM.initialize(key, target / 2); // a quarter of the price
        _open();
        (uint160 p,) = _tick();
        assertEq(p, target);
        assertGt(PM.getLiquidity(key.toId()), 0);
    }
}
