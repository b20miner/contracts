// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ActivationRegistryFeatureList} from "base-std-test/lib/mocks/ActivationRegistryFeatureList.sol";
import {MockActivationRegistry} from "base-std-test/lib/mocks/MockActivationRegistry.sol";
import {MockB20Factory} from "base-std-test/lib/mocks/MockB20Factory.sol";
import {MockPolicyRegistry} from "base-std-test/lib/mocks/MockPolicyRegistry.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {MinerBurner} from "../../src/MinerBurner.sol";
import {MinerPool} from "../../src/MinerPool.sol";
import {LaunchpadSwapRouter} from "../../src/launchpad/LaunchpadSwapRouter.sol";
import {TestMinerLauncher} from "../../src/launchpad/TestMinerLauncher.sol";

interface IB20Roles {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function mint(address to, uint256 amount) external;
}

/// @notice `TestMinerLauncher` (3 Nov 2026): tMINER on mainnet MINER's
/// `MinerPool` code, against the real Uniswap V4 PoolManager on a Base
/// Sepolia fork, trading through `LaunchpadSwapRouter` as the app does.
/// Needs network access.
contract TestMinerLauncherForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    uint256 constant OPENING_ETH = 0.02 ether;

    TestMinerLauncher launcher;
    MinerPool pool;
    MinerBurner burner;
    IERC20Metadata token;
    LaunchpadSwapRouter router;
    address trader = makeAddr("trader");

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
        // A fork where the B20 precompiles run natively (Base Sepolia, seen 3 Nov 2026)
        // refuses vm.etch on them and uses them as they are; otherwise the reference mocks.
        try this.etchReferenceB20() {} catch {}
        launcher = new TestMinerLauncher{value: OPENING_ETH}(address(PM));
        pool = launcher.POOL();
        burner = launcher.BURNER();
        token = IERC20Metadata(launcher.TOKEN());
        router = new LaunchpadSwapRouter(PM);
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    function test_createsTMinerOpensTheMainnetPoolCodeAtSixMillionPerEth() public view {
        assertEq(token.name(), "B20MINER Test");
        assertEq(token.symbol(), "tMINER");
        assertEq(token.decimals(), 18);
        // the supply is what the opening ETH matches, less the opening's rounding dust (burned)
        assertLe(token.totalSupply(), OPENING_ETH * 6_000_000);
        assertGt(token.totalSupply(), OPENING_ETH * 6_000_000 * 999 / 1000);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(burner)), 0);
        assertEq(token.balanceOf(address(launcher)), 0);

        assertTrue(pool.opened());
        assertEq(pool.FINALIZER(), address(launcher));
        assertEq(address(pool.MINER()), address(token));
        assertEq(address(pool.BURNER()), address(burner));
        assertEq(address(burner.MINER()), address(token));
        assertEq(pool.openingLiquidity(), launcher.OPENING_LIQUIDITY());
        assertApproxEqAbs(pool.openingEth(), OPENING_ETH, 1e6);

        (uint160 sqrtP,,,) = PM.getSlot0(pool.poolKey().toId());
        assertEq(sqrtP, pool.openingSqrtPriceX96());
        // [0] the opening full range; the opening's ETH rounding dust may add one bid band below it (as on mainnet)
        assertLe(pool.rangeCount(), 2);
        (int24 lower, int24 upper) = pool.ranges(0);
        assertEq(lower, TickMath.minUsableTick(60));
        assertEq(upper, TickMath.maxUsableTick(60));
    }

    function test_onlyTheBurnerMayBurnAndNobodyCanMint() public {
        IB20Roles roles = IB20Roles(address(token));
        assertTrue(roles.hasRole(B20Constants.BURN_ROLE, address(burner)));
        assertFalse(roles.hasRole(B20Constants.BURN_ROLE, address(pool)));
        assertFalse(roles.hasRole(B20Constants.MINT_ROLE, address(launcher)));
        assertFalse(roles.hasRole(B20Constants.MINT_ROLE, address(this)));
        assertFalse(roles.hasRole(B20Constants.DEFAULT_ADMIN_ROLE, address(launcher)));
        vm.expectRevert();
        roles.mint(address(this), 1);
    }

    function test_openCannotRunAgain() public {
        vm.deal(address(launcher), 1 ether);
        vm.prank(address(launcher));
        vm.expectRevert(MinerPool.AlreadyOpened.selector);
        pool.open{value: 1 ether}(1);
    }

    function test_buysAndSalesTrade_saleFeesBurned_buyFeesBackIn() public {
        _firstWindow();
        PoolKey memory key = pool.poolKey();
        vm.prank(trader);
        uint256 got = router.swap{value: 0.001 ether}(key, true, 0.001 ether, 0, block.timestamp);
        assertGt(got, 0);
        vm.prank(trader);
        uint256 ethOut = router.swap(key, false, got / 2, 0, block.timestamp);
        assertGt(ethOut, 0);

        uint256 supplyBefore = token.totalSupply();
        uint256 addedBefore = pool.totalEthAdded();
        pool.flush();
        assertApproxEqAbs(pool.totalFeesBurned(), (got / 2) * 3 / 1000, 1e6);
        assertEq(supplyBefore - token.totalSupply(), pool.totalFeesBurned());
        assertApproxEqAbs(pool.totalEthAdded() - addedBefore, 0.001 ether * 3 / 1000, 1e6);
    }

    function test_launchpadEthBecomesBuySupportFromTheFirstWindow() public {
        _firstWindow();
        vm.deal(address(0xFEE), 1 ether);
        vm.prank(address(0xFEE));
        pool.depositMinerLiquidityEth{value: 0.01 ether}();
        uint256 addedBefore = pool.totalEthAdded();
        pool.flush();
        uint256 cap = pool.bidCap(pool.windowMax());
        assertGt(cap, 0);
        assertApproxEqAbs(pool.totalEthAdded() - addedBefore, cap, 1e6);
    }

    function test_onlyOnBaseSepoliaAndWithEth() public {
        vm.expectRevert(TestMinerLauncher.ZeroAmount.selector);
        new TestMinerLauncher(address(PM));
        vm.chainId(8_453);
        vm.expectRevert(abi.encodeWithSelector(TestMinerLauncher.WrongChain.selector, 8_453));
        new TestMinerLauncher{value: 1 ether}(address(PM));
    }

    /// One `WINDOW` after the opening a flush closes its window; then flushes add buy support.
    function _firstWindow() internal {
        vm.warp(block.timestamp + pool.WINDOW());
        vm.roll(block.number + 1);
        pool.flush();
        vm.roll(block.number + 1);
    }

    function etchReferenceB20() external {
        vm.etch(StdPrecompiles.B20_FACTORY_ADDRESS, type(MockB20Factory).runtimeCode);
        vm.etch(StdPrecompiles.POLICY_REGISTRY_ADDRESS, type(MockPolicyRegistry).runtimeCode);
        vm.etch(StdPrecompiles.ACTIVATION_REGISTRY_ADDRESS, type(MockActivationRegistry).runtimeCode);
        vm.allowCheatcodes(StdPrecompiles.B20_FACTORY_ADDRESS);
        vm.allowCheatcodes(StdPrecompiles.POLICY_REGISTRY_ADDRESS);
        vm.allowCheatcodes(StdPrecompiles.ACTIVATION_REGISTRY_ADDRESS);
        address activationAdmin = StdPrecompiles.ACTIVATION_REGISTRY.admin();
        vm.startPrank(activationAdmin);
        try StdPrecompiles.ACTIVATION_REGISTRY.activate(ActivationRegistryFeatureList.B20_ASSET) {} catch {}
        try StdPrecompiles.ACTIVATION_REGISTRY.activate(ActivationRegistryFeatureList.POLICY_REGISTRY) {} catch {}
        vm.stopPrank();
    }
}
