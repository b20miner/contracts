// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActivationRegistryFeatureList} from "base-std-test/lib/mocks/ActivationRegistryFeatureList.sol";
import {MockActivationRegistry} from "base-std-test/lib/mocks/MockActivationRegistry.sol";
import {MockB20Factory} from "base-std-test/lib/mocks/MockB20Factory.sol";
import {MockPolicyRegistry} from "base-std-test/lib/mocks/MockPolicyRegistry.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {DeployB20Genesis} from "../script/DeployB20Genesis.s.sol";
import {DeployLaunchpad} from "../script/DeployLaunchpad.s.sol";
import {LaunchpadFactory} from "../src/launchpad/LaunchpadFactory.sol";
import {LaunchpadSwapRouter} from "../src/launchpad/LaunchpadSwapRouter.sol";
import {MinerWalletFactory} from "../src/wallet/MinerWalletFactory.sol";

/// @dev The genesis script's own deploy and checks, with this contract as
/// the deployer (see `B20DeploymentScript.t.sol`).
contract RehearsalGenesisHarness is DeployB20Genesis {
    function deployForTest(Config calldata config) external returns (Deployment memory d) {
        _validateEnvironment(config, address(this));
        d = _deploy(config, address(this), vm.getNonce(address(this)));
        _verifyDeployment(d, address(this), config);
    }

    function _afterNativeFactoryCreate(address deployer, uint256 nextNonce) internal override {
        vm.setNonce(deployer, uint64(nextNonce));
    }
}

/// @dev The Launchpad script's own deploy and checks, with this contract as
/// the deployer and CREATE2 creator.
contract RehearsalLaunchpadHarness is DeployLaunchpad {
    function _create2Deployer() internal view override returns (address) {
        return address(this);
    }

    function deployForTest(Config memory c) external returns (Deployment memory d, uint256 checks) {
        _validateEnvironment(c);
        d = _deploy(c, address(this), vm.getNonce(address(this)));
        checks = _verifyDeployment(d, c);
    }

    function feedForTest() external view returns (address) {
        return _defaultEthUsdFeed();
    }
}

/// @notice The whole mainnet path, rehearsed on a fork (owner, 30 October
/// 2026: the testnet runs what mainnet runs): the B20MINER genesis with its
/// V4 `MinerPool`, Launchpad v16 sending its MINER share to that pool, a
/// mining wallet factory trusting both, NFT revenue as the pool's ETH,
/// Launchpad fees waiting in the closed pool, B20MINER's finalize opening
/// it, then MINER bought and sold through our router with the sale fee
/// burned. Both scripts run unchanged on Base Sepolia (1-day windows) and
/// on Base (15 days). base-std's reference B20 precompiles stand in for
/// Base's native ones. Needs network access.
abstract contract GenesisLaunchpadRehearsal is Test {
    address constant TREASURY = address(0x7EA5);
    address constant ECOSYSTEM = address(0xEC0);
    address constant OPENER = address(0x0BE7);
    address constant CREATOR = address(0xC0FFEE);
    address constant TRADER = address(0x7AD3);
    uint256 constant PRICE_CENTS = 240_000;

    RehearsalGenesisHarness genesis;
    RehearsalLaunchpadHarness launchpad;
    DeployB20Genesis.Deployment g;
    DeployLaunchpad.Deployment l;
    LaunchpadSwapRouter router;

    function _rpc() internal pure virtual returns (string memory);
    function _poolManager() internal pure virtual returns (IPoolManager);
    function _window() internal pure virtual returns (uint256);

    function setUp() public {
        vm.createSelectFork(_rpc());
        // A fork where the B20 precompiles run natively (Base Sepolia, seen 3 Nov 2026)
        // refuses vm.etch on them and uses them as they are; otherwise the reference mocks.
        try this.etchReferenceB20() {} catch {}

        genesis = new RehearsalGenesisHarness();
        g = genesis.deployForTest(
            DeployB20Genesis.Config({
                expectedDeployer: address(genesis),
                operationsTreasury: TREASURY,
                ecosystemManager: ECOSYSTEM,
                teamBeneficiary: makeAddr("team"),
                nftOperationsRecipient: makeAddr("nftOperations"),
                tgeTimestamp: block.timestamp + 1 days,
                miningOpener: OPENER,
                openDeadline: block.timestamp + 30 days,
                ethUsdPriceCents: PRICE_CENTS,
                activationFee: genesis.activationFeeFor(PRICE_CENTS)
            })
        );

        launchpad = new RehearsalLaunchpadHarness();
        (l,) = launchpad.deployForTest(
            DeployLaunchpad.Config({
                deployer: address(launchpad),
                miner: address(g.token),
                minerPool: address(g.minerPool),
                platformTreasury: TREASURY,
                guardian: ECOSYSTEM,
                ethUsdPriceCents: PRICE_CENTS,
                creationFeeWei: launchpad.creationFeeFor(PRICE_CENTS),
                ethUsdFeed: launchpad.feedForTest(),
                directLaunchFdvWei: launchpad.directLaunchFdvFor(PRICE_CENTS),
                fresh: true
            })
        );
        router = new LaunchpadSwapRouter(_poolManager());
        vm.deal(CREATOR, 10 ether);
        vm.deal(TRADER, 10 ether);
    }

    function test_theWholeMainnetPath() public {
        // windows: 15 days on Base, 1 day on Base Sepolia, from the same code
        assertEq(g.mining.MINING_DURATION(), _window());
        assertEq(g.claimVault.CLAIM_PERIOD(), _window());

        // the mining wallets trust this genesis and this Launchpad
        MinerWalletFactory wallets = new MinerWalletFactory(address(g.mining), address(l.factory));
        assertEq(wallets.IMPLEMENTATION().B20_MINING(), address(g.mining));
        assertEq(wallets.IMPLEMENTATION().LAUNCHPAD_FACTORY(), address(l.factory));

        // nothing is open before the opener's call (2 Nov 2026)
        uint256 nftPrice = g.publicNFT.MINT_PRICE(); // before the prank, which the next call uses up
        vm.deal(address(0xB0001), 1 ether);
        vm.prank(address(0xB0001));
        vm.expectRevert();
        g.publicNFT.mint{value: 5 * nftPrice}(5);

        vm.prank(OPENER);
        g.mining.openMining();
        uint256 end = g.mining.MINING_END();
        assertEq(end, block.timestamp + _window());

        // then Public NFTs, half of whose price is the pool's ETH
        for (uint160 i = 1; i <= 3; i++) {
            address buyer = address(0xB0000 + i);
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            g.publicNFT.mint{value: 5 * nftPrice}(5);
        }

        // a Launchpad token while MINER's pool is still closed: its trading-fee share waits there
        uint256 fee = l.factory.creationFeeWei();
        LaunchpadFactory.CreateParams memory p;
        p.name = "Kedi";
        p.symbol = "KEDI";
        p.totalSupply = 1_000_000_000;
        p.instant = true;
        p.deadline = uint64(block.timestamp + 10 minutes);
        (p.expectedToken,,) = l.factory.predict(CREATOR);
        vm.prank(CREATOR);
        address token = l.factory.create{value: fee}(p, fee);
        assertEq(address(g.minerPool).balance, 0); // v21: the creation fee is all platform revenue
        vm.warp(block.timestamp + 30); // past the opening anti-snipe window
        PoolKey memory key = l.locker.poolKey(token);
        vm.prank(TRADER);
        router.swap{value: 0.5 ether}(key, true, 0.5 ether, 0, block.timestamp);
        l.hook.sweep();
        uint256 waiting = address(g.minerPool).balance;
        assertGt(waiting, 0);
        g.minerPool.flush(); // nothing to do before the opening
        assertEq(address(g.minerPool).balance, waiting);
        assertFalse(g.minerPool.opened());

        // B20MINER's finalize opens the pool; the waiting ETH becomes buy support
        vm.warp(end);
        g.finalizer.finalize();
        assertTrue(g.minerPool.opened());
        assertGt(g.finalizer.ethAdded(), 0);
        assertEq(g.finalizer.minerAdded(), g.finalizer.ethAdded() * 6_000_000);
        assertApproxEqAbs(g.minerPool.totalEthAdded(), waiting, 1e6);
        assertLe(address(g.minerPool).balance, 1e6);
        assertEq(g.claimVault.claimDeadline(), end + _window());

        // MINER bought and sold through the same router as every Launchpad token
        PoolKey memory mk = g.minerPool.poolKey();
        vm.prank(TRADER);
        uint256 bought = router.swap{value: 0.001 ether}(mk, true, 0.001 ether, 0, block.timestamp);
        assertGt(bought, 0);
        vm.startPrank(TRADER);
        IERC20(address(g.token)).approve(address(router), bought);
        router.swap(mk, false, bought, 0, block.timestamp);
        vm.stopPrank();

        uint256 supplyBefore = g.token.totalSupply();
        uint256 burnedBefore = g.burner.totalBurned();
        g.minerPool.flush();
        // the sale's 0.30% in MINER is burned; the buy's 0.30% in ETH stays as support
        assertApproxEqAbs(g.minerPool.totalFeesBurned(), bought * 3 / 1000, 1e6);
        assertEq(g.burner.totalBurned() - burnedBefore, g.minerPool.totalFeesBurned());
        assertEq(supplyBefore - g.token.totalSupply(), g.minerPool.totalFeesBurned());
        assertEq(g.token.balanceOf(address(g.burner)), 0);
    }

    /// @dev base-std's reference B20 precompiles (as `BaseTest` does). On a
    /// fork, a feature that is already on is skipped instead of re-activated.
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

contract GenesisLaunchpadRehearsalSepoliaForkTest is GenesisLaunchpadRehearsal {
    function _rpc() internal pure override returns (string memory) {
        return "https://sepolia.base.org";
    }

    function _poolManager() internal pure override returns (IPoolManager) {
        return IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    }

    function _window() internal pure override returns (uint256) {
        return 1 days;
    }
}

contract GenesisLaunchpadRehearsalMainnetForkTest is GenesisLaunchpadRehearsal {
    function _rpc() internal pure override returns (string memory) {
        return "https://mainnet.base.org";
    }

    function _poolManager() internal pure override returns (IPoolManager) {
        return IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    }

    function _window() internal pure override returns (uint256) {
        return 15 days;
    }
}
