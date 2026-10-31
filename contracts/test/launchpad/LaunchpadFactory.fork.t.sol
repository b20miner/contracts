// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActivationRegistryFeatureList} from "base-std-test/lib/mocks/ActivationRegistryFeatureList.sol";
import {MockActivationRegistry} from "base-std-test/lib/mocks/MockActivationRegistry.sol";
import {MockB20Factory} from "base-std-test/lib/mocks/MockB20Factory.sol";
import {MockPolicyRegistry} from "base-std-test/lib/mocks/MockPolicyRegistry.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {MinerBurner} from "../../src/MinerBurner.sol";
import {MinerPool} from "../../src/MinerPool.sol";
import {CampaignPool} from "../../src/launchpad/CampaignPool.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {LaunchpadHook} from "../../src/launchpad/LaunchpadHook.sol";
import {PositionLocker} from "../../src/launchpad/PositionLocker.sol";
import {MockCampaignToken} from "./MiningCampaign.t.sol";
import {Swapper} from "./LaunchpadV4.fork.t.sol";

/// @notice Chainlink AggregatorV3 stand-in (K66): answer 0 until set, so the
/// factory charges its fallback fee unless a test sets a price.
contract MockEthUsdFeed {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    bool public broken;

    function set(int256 a, uint256 at) external {
        answer = a;
        updatedAt = at;
    }

    function breakIt() external {
        broken = true;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice The whole Launchpad on a Base Sepolia fork: the real Uniswap V4
/// PoolManager, the MINER `MinerPool` on it, and base-std's reference B20 factory
/// (etched by BaseTest; the live one is a precompile). Needs network access.
contract LaunchpadFactoryForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant TREASURY = address(0x7EA5);
    address constant GUARDIAN = address(0x6A2D);
    address constant CREATOR = address(0xC0FFEE);
    address constant OWNER = address(0xA11CE);
    address constant MINER_WALLET = address(0x3141);
    uint256 constant CREATION_FEE = 1_116_582_000_000_000; // ~3 USD
    uint256 constant PROOF_FEE = 100_000_000_000_000; // 0.0001 ETH (K57)
    uint256 constant INITIAL_FDV = 1_861_000_000_000_000_000; // ~5,000 USD at the same price, fixed in ETH (K68)

    MockCampaignToken miner; // stands in for MINER
    MinerBurner burner;
    MinerPool minerPool;
    PositionLocker locker;
    LaunchpadFactory factory;
    MockEthUsdFeed feed;

    receive() external payable {}

    /// The keeper's rhythm (audit H-1): `MinerPool` adds buy support only
    /// with a sample in the previous `WINDOW`, so flush twice a window apart.
    function _keeperFlush() internal {
        minerPool.flush();
        vm.warp(block.timestamp + minerPool.WINDOW());
        vm.roll(block.number + 1);
        minerPool.flush();
    }

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
        _etchReferenceB20();

        miner = new MockCampaignToken();
        vm.deal(address(this), 1_000 ether);
        burner = new MinerBurner(address(miner));
        // the MINER pool at 6,000,000 MINER per ETH, opened as the finalizer
        // does at genesis (this test stands in for the finalizer)
        minerPool = new MinerPool(address(PM), address(miner), address(burner), address(this));
        miner.mint(address(minerPool), 60_000_000e18);
        minerPool.open{value: 10 ether}(60_000_000e18);

        address hook = address(uint160(uint256(keccak256("b20.launchpad.hook")) & ~uint256(0x3FFF)) | uint160(0x20CC)); // beforeInitialize, before/afterSwap (+ return deltas)
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        locker = new PositionLocker(address(PM), predictedFactory, hook);
        deployCodeTo(
            "LaunchpadHook.sol:LaunchpadHook", abi.encode(address(PM), address(locker), TREASURY, address(minerPool)), hook
        );
        feed = new MockEthUsdFeed();
        MiningCampaign miningImpl = new MiningCampaign();
        CampaignPool poolImpl = new CampaignPool();
        factory = new LaunchpadFactory(
            LaunchpadFactory.Config({
                miningImpl: address(miningImpl),
                poolImpl: address(poolImpl),
                locker: address(locker),
                feeRouter: address(minerPool),
                platformTreasury: TREASURY,
                guardian: GUARDIAN,
                creationFeeWei: CREATION_FEE,
                ethUsdFeed: address(feed),
                directLaunchFdvWei: INITIAL_FDV,
                proofFeeWei: PROOF_FEE,
                powTarget: type(uint256).max
            })
        );
        assertEq(address(factory), predictedFactory);
        vm.deal(CREATOR, 100 ether);
        vm.deal(MINER_WALLET, 100 ether);
    }

    /// @dev base-std's reference B20 precompiles (as `BaseTest` does). On the
    /// fork the activation registry's storage already reads as active, so a
    /// feature that is already on is skipped instead of re-activated.
    function _etchReferenceB20() internal {
        vm.etch(StdPrecompiles.B20_FACTORY_ADDRESS, type(MockB20Factory).runtimeCode);
        vm.etch(StdPrecompiles.POLICY_REGISTRY_ADDRESS, type(MockPolicyRegistry).runtimeCode);
        vm.etch(StdPrecompiles.ACTIVATION_REGISTRY_ADDRESS, type(MockActivationRegistry).runtimeCode);
        // on a fork, code etched at existing addresses needs explicit cheatcode access
        vm.allowCheatcodes(StdPrecompiles.B20_FACTORY_ADDRESS);
        vm.allowCheatcodes(StdPrecompiles.POLICY_REGISTRY_ADDRESS);
        vm.allowCheatcodes(StdPrecompiles.ACTIVATION_REGISTRY_ADDRESS);
        address activationAdmin = StdPrecompiles.ACTIVATION_REGISTRY.admin();
        vm.startPrank(activationAdmin);
        try StdPrecompiles.ACTIVATION_REGISTRY.activate(ActivationRegistryFeatureList.B20_ASSET) {} catch {}
        try StdPrecompiles.ACTIVATION_REGISTRY.activate(ActivationRegistryFeatureList.POLICY_REGISTRY) {} catch {}
        vm.stopPrank();
    }

    function _params() internal view returns (LaunchpadFactory.CreateParams memory p) {
        p.name = "Kedi";
        p.symbol = "KEDI";
        p.totalSupply = 1_000_000_000;
        p.startTime = 0; // K44: mining starts in the create transaction
        p.durationDays = 3;
        p.walletCapWei = 0.05 ether; // the app default (K55)
        p.openingMultiple = 2; // K51 default
        p.metadataHash = keccak256("kedi.json");
        p.deadline = uint64(block.timestamp + 10 minutes);
        (p.expectedToken,,) = factory.predict(CREATOR);
    }

    function _create(LaunchpadFactory.CreateParams memory p, uint256 value) internal returns (address token) {
        vm.prank(CREATOR);
        token = factory.create{value: value}(p, CREATION_FEE);
    }

    function _parts(address token) internal view returns (MiningCampaign c, CampaignPool pool) {
        (address campaign, address poolAddr,,) = factory.campaignOf(token);
        c = MiningCampaign(payable(campaign));
        pool = CampaignPool(payable(poolAddr));
    }

    // -------------------------------------------------------------- create

    function test_createBuildsTheCampaignInOneTransaction() public {
        (address pToken, address pCampaign, address pPool) = factory.predict(CREATOR);
        uint256 treasuryBefore = TREASURY.balance;
        uint256 minerPoolBefore = address(minerPool).balance;

        address token = _create(_params(), CREATION_FEE + 0.5 ether);
        (MiningCampaign c, CampaignPool pool) = _parts(token);

        assertEq(token, pToken);
        assertEq(address(c), pCampaign);
        assertEq(address(pool), pPool);
        assertEq(factory.poolToken(pPool), token);
        assertEq(factory.creatorNonce(CREATOR), 1);

        IERC20 t = IERC20(token);
        uint256 rm = uint256(1_000_000_000e18) * 3 / 5; // 2×: at most 60% mined (K55)
        // K65 (v12): nothing exists yet; the cap is the full supply and only
        // the campaign and the pool may mint (and burn)
        assertEq(t.totalSupply(), 0);
        assertEq(IB20(token).supplyCap(), 1_000_000_000e18);
        assertEq(c.miningReserve(), rm);
        assertTrue(IAccessControl(token).hasRole(B20Constants.MINT_ROLE, address(c)));
        assertTrue(IAccessControl(token).hasRole(B20Constants.MINT_ROLE, address(pool)));
        assertFalse(IAccessControl(token).hasRole(B20Constants.MINT_ROLE, address(factory)));
        assertTrue(IAccessControl(token).hasRole(B20Constants.BURN_ROLE, address(c)));
        assertTrue(IAccessControl(token).hasRole(B20Constants.BURN_ROLE, address(pool)));
        assertFalse(IAccessControl(token).hasRole(B20Constants.BURN_ROLE, address(factory)));

        assertEq(c.capTokens(), 5_000_000e18); // 0.05 ETH × 100,000,000 tokens per ETH (K55)
        assertEq(c.start(), block.timestamp); // K44: opened with the token
        assertTrue(c.opened());
        assertTrue(c.seed() != bytes32(0));
        assertEq(pool.creatorDeposited(), 0.5 ether);
        // K56: 400M − 95.41% × 600M / 2 = 113.77M spare tokens at 50M per ETH, minus the 1.5 ETH buffer
        assertEq(pool.depositCapWei(), 0.7754 ether);

        // fee: half to the platform, half waits in the MINER pool as buy support
        assertEq(TREASURY.balance - treasuryBefore, CREATION_FEE / 2);
        assertEq(address(minerPool).balance - minerPoolBefore, CREATION_FEE - CREATION_FEE / 2);
        uint256 addedBefore = minerPool.totalEthAdded();
        _keeperFlush();
        assertLe(address(minerPool).balance, 1e6); // rounding dust waits for the next flush
        assertApproxEqAbs(
            minerPool.totalEthAdded() - addedBefore, minerPoolBefore + CREATION_FEE - CREATION_FEE / 2, 1e6
        );
    }

    /// K65: a proof's gas through the reference B20 (the live precompile
    /// charges its own price): the first proof mints into an empty escrow
    /// and starts the chain; later ones update both.
    function test_gasOfProof() public {
        address token = _create(_params(), CREATION_FEE);
        (MiningCampaign c,) = _parts(token);
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 fee) = c.quoteProof(OWNER);
            bytes32 challenge = c.challengeOf(OWNER);
            vm.prank(MINER_WALLET);
            uint256 g = gasleft();
            c.submitProof{value: fee}(OWNER, challenge, i);
            emit log_named_uint("submitProof gas", g - gasleft());
        }
    }

    function test_gasOfCreate() public {
        LaunchpadFactory.CreateParams memory p = _params();
        vm.prank(CREATOR);
        uint256 g = gasleft();
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        emit log_named_uint("create gas", g - gasleft());
    }

    function test_validation() public {
        LaunchpadFactory.CreateParams memory p = _params();
        vm.startPrank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.WrongFee.selector, CREATION_FEE, CREATION_FEE - 1));
        factory.create{value: CREATION_FEE - 1}(p, CREATION_FEE);

        // K43: exactly 1 billion, nothing else.
        uint256[4] memory wrong = [uint256(999_999), 1_000_000, 999_999_999, 100_000_000_000];
        for (uint256 i; i < wrong.length; ++i) {
            p.totalSupply = wrong[i];
            vm.expectRevert(LaunchpadFactory.InvalidSupply.selector);
            factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        }
        assertEq(factory.SUPPLY(), 1_000_000_000);
        p = _params();
        p.startTime = uint64(block.timestamp + 2 hours); // K44: no scheduled start any more
        vm.expectRevert(LaunchpadFactory.InvalidStartTime.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.durationDays = 5;
        vm.expectRevert(LaunchpadFactory.InvalidDuration.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.durationDays = 2;
        vm.expectRevert(LaunchpadFactory.InvalidDuration.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.walletCapWei = 0.6 ether; // K55: at most 0.5 ETH
        vm.expectRevert(LaunchpadFactory.InvalidWalletCap.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.walletCapWei = 0.009 ether; // K55: at least 0.01 ETH
        vm.expectRevert(LaunchpadFactory.InvalidWalletCap.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.claimVestingDays = 5;
        vm.expectRevert(LaunchpadFactory.InvalidVesting.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        // K51: the pool opens at 2× or 1× the mining price, nothing else
        p = _params();
        p.openingMultiple = 3;
        vm.expectRevert(LaunchpadFactory.InvalidOpening.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.openingMultiple = 0;
        vm.expectRevert(LaunchpadFactory.InvalidOpening.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        // K50: anyone mines, so a cap is always required
        p = _params();
        p.walletCapWei = 0;
        vm.expectRevert(LaunchpadFactory.InvalidWalletCap.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.name = "";
        vm.expectRevert(LaunchpadFactory.InvalidName.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        vm.stopPrank();
    }

    function test_fixedSupplyCapAndDepositAboveCap() public {
        LaunchpadFactory.CreateParams memory p = _params();
        p.totalSupply = 69_420_000; // a free supply was accepted before K43
        vm.prank(CREATOR);
        vm.expectRevert(LaunchpadFactory.InvalidSupply.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        address token = _create(_params(), CREATION_FEE);
        (MiningCampaign c,) = _parts(token);
        assertEq(c.capTokens(), 5_000_000e18); // 0.05 ETH cap × 100,000,000 tokens per ETH (K55)

        vm.deal(CREATOR, 1_000 ether);
        LaunchpadFactory.CreateParams memory next = _params();
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(CampaignPool.DepositAboveCap.selector, 0.7754 ether));
        factory.create{value: CREATION_FEE + 2 ether}(next, CREATION_FEE);
    }

    // ----------------------------------------------------------- lifecycle

    function test_fullLifecycle() public {
        address token = _create(_params(), CREATION_FEE);
        (MiningCampaign c, CampaignPool pool) = _parts(token);
        for (uint256 i = 0; i < 30; i++) {
            (, uint256 fee) = c.quoteProof(OWNER);
            bytes32 challenge = c.challengeOf(OWNER); // before the prank, which the next call uses up
            vm.prank(MINER_WALLET);
            c.submitProof{value: fee}(OWNER, challenge, i);
        }
        // K65: every proof minted its reward and added a token block
        assertEq(IERC20(token).totalSupply(), c.minedTotal());
        assertEq(c.tokenBlocks(), 30);
        c.withdrawPlatformFees();
        vm.warp(c.end());
        pool.finalize();
        // K65: both minters gave the role up; the supply is final
        assertFalse(IAccessControl(token).hasRole(B20Constants.MINT_ROLE, address(c)));
        assertFalse(IAccessControl(token).hasRole(B20Constants.MINT_ROLE, address(pool)));

        PoolKey memory key = locker.poolKey(token);
        (uint160 price,,,) = PM.getSlot0(key.toId());
        _assertOpening(price, pool.sqrtPriceX96());
        assertEq(IERC20(token).totalSupply(), c.minedTotal() + pool.tokenAdded());
        // K63: one miner of 0.003 ETH does not qualify for 2×: the pool opened
        // at 1×, and finalize delivered the tokens (no claim)
        assertEq(pool.chosenMultiple(), 2);
        assertEq(pool.openingMultiple(), 1);
        assertEq(IERC20(token).balanceOf(OWNER), c.minedTotal());
        Swapper sw = new Swapper(PM);
        vm.deal(address(sw), 1 ether);
        vm.warp(block.timestamp + 20); // after the opening anti-snipe window (K40)
        sw.swap{value: 0.1 ether}(key, true, 0.1 ether);

        _keeperFlush(); // the creation fee's half, so only the sweep is left
        // the MINER-liquidity 20% of the 1% ETH fee (K69), split in the swap,
        // waits in the MINER pool until someone flushes it into buy support
        uint256 dust = address(minerPool).balance; // what the last flush could not place
        LaunchpadHook(locker.HOOK()).sweep();
        assertEq(address(minerPool).balance - dust, 0.0002 ether);
        uint256 addedBefore = minerPool.totalEthAdded();
        vm.roll(block.number + 1); // one buy-support addition per block
        minerPool.flush();
        assertApproxEqAbs(minerPool.totalEthAdded() - addedBefore, 0.0002 ether + dust, 1e6);
    }

    /// K51/K55: a 1× opening mines 40% of the supply, keeps 60% for the pool
    /// and opens it at the mining price; the deposit cap is 0.9 ETH.
    function test_oneXOpeningSplitsTheSupplyInHalf() public {
        LaunchpadFactory.CreateParams memory p = _params();
        p.openingMultiple = 1;
        address token = _create(p, CREATION_FEE);
        (MiningCampaign c, CampaignPool pool) = _parts(token);
        assertEq(c.miningReserve(), 400_000_000e18);
        assertEq(IB20(token).supplyCap(), 1_000_000_000e18); // K65: the pool's 60% is minted at the opening
        assertEq(IERC20(token).totalSupply(), 0);
        assertEq(pool.openingMultiple(), 1);
        assertEq(pool.poolPriceNum(), c.priceNum());
        // K56: 600M − 95.41% × 400M = 218.36M spare tokens at 100M per ETH, minus the 1.5 ETH buffer
        assertEq(pool.depositCapWei(), 0.6836 ether);
    }

    /// K53: the pool opens at the target price rounded down to a usable
    /// tick (at most one spacing, ~2% in price, ~1% in sqrtPrice).
    function _assertOpening(uint160 price, uint160 target) internal pure {
        assertLe(price, target, "opening above the target");
        assertGe(uint256(price) * 1_011, uint256(target) * 1_000, "opening more than ~1% (sqrt) off");
        assertEq(TickMath.getTickAtSqrtPrice(price) % 200, 0, "opening not on a usable tick");
    }

    // ------------------------------------------------- v13: no staking

    /// v13 (owner decision, 19 Oct 2026): no stake bonus and no stakers'
    /// window — every owner has the same quota and mines from the start.
    function test_everyOwnerHasTheSameQuotaFromTheStart() public {
        address token = _create(_params(), CREATION_FEE);
        (MiningCampaign c,) = _parts(token);
        address other = address(0x07E4);
        assertEq(c.quotaOf(OWNER), c.capTokens());
        assertEq(c.quotaOf(other), c.capTokens());
        (uint256 reward, uint256 fee) = c.quoteProof(other);
        assertGt(reward, 0);
        vm.prank(MINER_WALLET);
        c.submitProof{value: fee}(other, c.challengeOf(other), 1);
        assertEq(c.minedOf(other), reward);
    }

    /// v13 (owner decision, 20 Oct 2026): the name fits in 32 bytes and the
    /// symbol in 10, counted in UTF-8 bytes (a Turkish letter is 2).
    function test_nameAndSymbolLengthCaps() public {
        LaunchpadFactory.CreateParams memory p = _params();
        p.name = "abcdefghijklmnopqrstuvwxyz012345"; // 32
        p.symbol = "ABCDEFGHIJ"; // 10
        _create(p, CREATION_FEE);

        vm.startPrank(CREATOR);
        p = _params();
        p.name = "abcdefghijklmnopqrstuvwxyz0123456"; // 33
        vm.expectRevert(LaunchpadFactory.InvalidName.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.symbol = "ABCDEFGHIJK"; // 11
        vm.expectRevert(LaunchpadFactory.InvalidName.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.symbol = unicode"ŞŞŞŞŞŞ"; // 6 letters, 12 bytes
        vm.expectRevert(LaunchpadFactory.InvalidName.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _params();
        p.symbol = "";
        vm.expectRevert(LaunchpadFactory.InvalidName.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        vm.stopPrank();

        p = _params();
        p.symbol = unicode"ŞŞŞŞŞ"; // 5 letters, 10 bytes
        _create(p, CREATION_FEE);
    }

    // --------------------------------------------- signing safety (K41)

    /// The creator signs for one exact result: a transaction that lands after
    /// its deadline, or would create a different token than the one the app
    /// showed, reverts and charges nothing.
    function test_createRevertsAfterItsDeadlineOrForAnotherToken() public {
        LaunchpadFactory.CreateParams memory p = _params();
        vm.warp(p.deadline + 1);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.Expired.selector, p.deadline));
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);

        // two creates signed from the same wallet with the same prediction:
        // the first lands, the second no longer matches and reverts
        LaunchpadFactory.CreateParams memory a = _params();
        LaunchpadFactory.CreateParams memory b = _params();
        address first = _create(a, CREATION_FEE);
        assertEq(first, a.expectedToken);
        (address next,,) = factory.predict(CREATOR);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.UnexpectedToken.selector, b.expectedToken, next));
        factory.create{value: CREATION_FEE}(b, CREATION_FEE);

        // a zero expected token is not a wildcard
        b.expectedToken = address(0);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.UnexpectedToken.selector, address(0), next));
        factory.create{value: CREATION_FEE}(b, CREATION_FEE);
        assertEq(factory.campaignCount(), 1);
    }

    function test_onlyTheCreatorAnnounces() public {
        address token = _create(_params(), CREATION_FEE);
        vm.expectRevert(LaunchpadFactory.NotCreator.selector);
        factory.announce(token, "hello");

        vm.startPrank(CREATOR);
        vm.expectEmit(true, true, true, true, address(factory));
        emit LaunchpadFactory.Announcement(token, 1, CREATOR, "Mining opens at 18:00 UTC");
        assertEq(factory.announce(token, "Mining opens at 18:00 UTC"), 1);
        assertEq(factory.announce(token, "Pool is live"), 2);
        assertEq(factory.announcementCount(token), 2);

        vm.expectRevert(LaunchpadFactory.InvalidAnnouncement.selector);
        factory.announce(token, "");
        bytes memory long = new bytes(501);
        vm.expectRevert(LaunchpadFactory.InvalidAnnouncement.selector);
        factory.announce(token, string(long));
        assertEq(factory.announce(token, string(new bytes(500))), 3);
        // not a Launchpad token
        vm.expectRevert(LaunchpadFactory.NotCreator.selector);
        factory.announce(address(0xDEAD), "x");
        vm.stopPrank();
    }

    // --------------------------------------------- guardian and metadata

    function test_guardianOnlyClosesNewCreation() public {
        address token = _create(_params(), CREATION_FEE);
        vm.expectRevert(LaunchpadFactory.NotGuardian.selector);
        factory.deprecate();
        vm.prank(GUARDIAN);
        factory.deprecate();
        LaunchpadFactory.CreateParams memory next = _params();
        vm.prank(CREATOR);
        vm.expectRevert(LaunchpadFactory.IsDeprecated.selector);
        factory.create{value: CREATION_FEE}(next, CREATION_FEE);

        // the existing campaign keeps working
        (MiningCampaign c,) = _parts(token);
        (, uint256 fee) = c.quoteProof(OWNER);
        vm.prank(MINER_WALLET);
        c.submitProof{value: fee}(OWNER, c.challengeOf(OWNER), 1);
    }

    /// K49 (v5): mining can run for a single day. K52 (v6): a mining
    /// token takes no anti-snipe choice — its pool is never protected.
    function test_oneDayMiningAndNoAntiSnipeChoiceForMining() public {
        LaunchpadFactory.CreateParams memory p = _params();
        p.durationDays = 1;
        address token = _create(p, CREATION_FEE);
        (MiningCampaign c, CampaignPool pool) = _parts(token);
        assertEq(c.end(), c.start() + 1 days);
        assertFalse(pool.antiSnipe());
        assertFalse(pool.instant());

        p = _params();
        p.antiSnipe = true;
        vm.prank(CREATOR);
        vm.expectRevert(LaunchpadFactory.InvalidLaunchOptions.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
    }

    // ------------------------------------------------- instant launch (K52)

    function _instantParams() internal view returns (LaunchpadFactory.CreateParams memory p) {
        p = _params();
        p.instant = true;
        p.durationDays = 0;
        p.walletCapWei = 0;
        p.openingMultiple = 0;
    }

    /// No mining: the create transaction opens the pool with the whole
    /// supply at the opening FDV (K68), protected if the creator asked, and anyone
    /// can buy at once (after the 20-second window).
    function test_instantLaunchTradesAtOnce() public {
        LaunchpadFactory.CreateParams memory p = _instantParams();
        p.antiSnipe = true;
        address token = _create(p, CREATION_FEE);
        (address campaign, address poolAddr, address creator,) = factory.campaignOf(token);
        assertEq(campaign, address(0));
        assertEq(creator, CREATOR);
        CampaignPool pool = CampaignPool(payable(poolAddr));
        assertTrue(pool.instant());
        assertTrue(pool.directLaunch());
        assertEq(uint8(pool.status()), uint8(CampaignPool.Status.Finalized));
        assertTrue(pool.wouldLaunchDirectly());
        assertEq(pool.poolEth(), 0);
        // every token is in the pool, minus wei-level rounding (burned)
        assertApproxEqAbs(IERC20(token).balanceOf(address(PM)), 1_000_000_000e18, 1e9);
        assertEq(IERC20(token).balanceOf(poolAddr), 0);
        assertFalse(IAccessControl(token).hasRole(B20Constants.BURN_ROLE, address(factory)));

        PoolKey memory key = locker.poolKey(token);
        LaunchpadHook h = LaunchpadHook(locker.HOOK());
        assertTrue(h.protectedPool(key.toId()));
        assertEq(h.combinedFeeBps(key.toId(), block.timestamp), 9_900);

        vm.warp(block.timestamp + 20);
        Swapper sw = new Swapper(PM);
        vm.deal(address(sw), 1 ether);
        sw.swap(key, true, 0.1 ether);
        assertGt(IERC20(token).balanceOf(address(sw)), 0);

        // nothing to deposit into: it is already trading
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(CampaignPool.NotActive.selector);
        pool.deposit{value: 1}(CREATOR);
    }

    function test_instantLaunchRules() public {
        // without protection: the plain 1% from the first trade
        address token = _create(_instantParams(), CREATION_FEE);
        LaunchpadHook h = LaunchpadHook(locker.HOOK());
        assertFalse(h.protectedPool(locker.poolKey(token).toId()));

        // less than the fee
        LaunchpadFactory.CreateParams memory p = _instantParams();
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.WrongFee.selector, CREATION_FEE, CREATION_FEE - 1));
        factory.create{value: CREATION_FEE - 1}(p, CREATION_FEE);

        // no mining option may be set
        p = _instantParams();
        p.durationDays = 3;
        vm.prank(CREATOR);
        vm.expectRevert(LaunchpadFactory.InvalidLaunchOptions.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _instantParams();
        p.walletCapWei = 0.05 ether; // the app default (K55)
        vm.prank(CREATOR);
        vm.expectRevert(LaunchpadFactory.InvalidLaunchOptions.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
        p = _instantParams();
        p.openingMultiple = 2;
        vm.prank(CREATOR);
        vm.expectRevert(LaunchpadFactory.InvalidLaunchOptions.selector);
        factory.create{value: CREATION_FEE}(p, CREATION_FEE);
    }

    /// K56: the extra ETH of an instant launch is the creator's first buy —
    /// in the create transaction, before anyone else, free of the anti-snipe
    /// surcharge — and the window still protects everyone after it.
    function test_instantLaunchCreatorBuysFirstWithoutSurcharge() public {
        LaunchpadFactory.CreateParams memory p = _instantParams();
        p.antiSnipe = true;
        uint256 platformBefore = LaunchpadHook(locker.HOOK()).platformFeesOwed();
        address token = _create(p, CREATION_FEE + 0.1 ether);
        (,address poolAddr,,) = factory.campaignOf(token);
        CampaignPool pool = CampaignPool(payable(poolAddr));
        uint256 bought = IERC20(token).balanceOf(CREATOR);

        // 0.1 ETH into a ~1.861 ETH FDV pool (the fixed opening FDV, ~5,000
        // USD on the deploy day, K68), 1% fee: 0.099 / (1.861 + 0.099) = ~5.05% of the supply
        assertEq(pool.directFdvWei(), INITIAL_FDV);
        assertEq(pool.creatorBuyEth(), 0.1 ether);
        assertEq(pool.creatorBuyTokens(), bought);
        assertApproxEqRel(bought, 50_500_000e18, 0.03e18); // the opening rounds to a tick (≤ 2%)
        assertTrue(locker.openingBuyDone(token));
        LaunchpadHook h = LaunchpadHook(locker.HOOK());
        assertEq(h.platformFeesOwed() - platformBefore, 0.0003 ether, "the creator paid no surcharge");
        assertEq(h.creatorFeesOwed(CREATOR), 0.0005 ether, "but the 1% fee, like o1's dev buy, half back to itself (K69)");

        // the next buyer, in the same second, pays the opening 99%
        PoolKey memory key = locker.poolKey(token);
        assertEq(h.combinedFeeBps(key.toId(), block.timestamp), 9_900);
        Swapper sw = new Swapper(PM);
        vm.deal(address(sw), 1 ether);
        sw.swap(key, true, 0.1 ether);
        assertGt(h.platformFeesOwed() - platformBefore, 0.0003 ether + 0.09 ether); // ~98% of 0.1 ETH
        assertLt(IERC20(token).balanceOf(address(sw)), bought / 50);

        // nobody can call the opening buy again
        vm.deal(poolAddr, 1 ether);
        vm.prank(poolAddr);
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.OpeningBuyDone.selector, token));
        locker.buyAtOpening{value: 1}(token, poolAddr);
        vm.expectRevert(abi.encodeWithSelector(PositionLocker.NotCampaignPool.selector, address(this), token));
        locker.buyAtOpening{value: 1}(token, address(this));
    }

    /// K56: without protection the creator still buys first; paying in MINER works too.
    function test_instantLaunchCreatorBuyUnprotectedAndInMiner() public {
        address token = _create(_instantParams(), CREATION_FEE + 1.5 ether);
        (,address poolAddr,,) = factory.campaignOf(token);
        // 1.5 ETH into a ~1.861 ETH FDV pool: 1.485 / (1.861 + 1.485) = ~44.4%
        uint256 bought = IERC20(token).balanceOf(CREATOR);
        assertEq(CampaignPool(payable(poolAddr)).creatorBuyTokens(), bought);
        assertApproxEqRel(bought, 443_800_000e18, 0.03e18);

        // no extra ETH: no buy
        address plain = _create(_instantParams(), CREATION_FEE);
        (,address plainPool,,) = factory.campaignOf(plain);
        assertEq(CampaignPool(payable(plainPool)).creatorBuyEth(), 0);
        assertFalse(locker.openingBuyDone(plain));
    }

    /// K45 (v5): the profile is fixed at launch; the factory has no update.
    function test_profileHasNoUpdateFunction() public view {
        (bool ok,) = address(factory).staticcall(abi.encodeWithSignature("updateMetadata(address,bytes32)", address(1), bytes32(0)));
        assertFalse(ok);
    }

    // ------------------------------------------------- K66: 3 USD fee via Chainlink

    /// The fee is 3 USD at the feed's answer, rounded up to the wei.
    function test_feeFollowsChainlink() public {
        feed.set(2_500e8, block.timestamp);
        (bool live, uint256 price) = factory.ethUsdPrice();
        assertTrue(live);
        assertEq(price, 2_500e8);
        assertEq(factory.creationFeeWei(), 0.0012 ether); // 3 / 2,500
        feed.set(3_333_33000000, block.timestamp); // 3,333.33 USD
        assertEq(factory.creationFeeWei(), (uint256(300e26) + 333_333_000_000 * 100 - 1) / (333_333_000_000 * 100));

        feed.set(2_000e8, block.timestamp);
        uint256 fee = factory.creationFeeWei();
        assertEq(fee, 0.0015 ether);
        uint256 treasuryBefore = TREASURY.balance;
        LaunchpadFactory.CreateParams memory p = _params();
        vm.prank(CREATOR);
        address token = factory.create{value: fee}(p, fee);
        assertEq(TREASURY.balance - treasuryBefore, fee / 2);
        assertTrue(token != address(0));
    }

    /// K68: an instant launch opens at a fixed ETH amount, as on o1 — the
    /// feed never moves it; only the guardian refreshes it, within
    /// 0.25..10 ETH, and a pool keeps the value it opened with.
    function test_guardianSetsTheOpeningFdv() public {
        assertEq(factory.directLaunchFdvWei(), INITIAL_FDV);
        feed.set(2_500e8, block.timestamp);
        assertEq(factory.directLaunchFdvWei(), INITIAL_FDV, "the feed does not move it");

        vm.expectRevert(LaunchpadFactory.NotGuardian.selector);
        factory.setDirectLaunchFdvWei(2 ether);
        vm.startPrank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.InvalidOpeningFdv.selector, 0.25 ether - 1));
        factory.setDirectLaunchFdvWei(0.25 ether - 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.InvalidOpeningFdv.selector, 10 ether + 1));
        factory.setDirectLaunchFdvWei(10 ether + 1);
        factory.setDirectLaunchFdvWei(0.25 ether);
        factory.setDirectLaunchFdvWei(10 ether);
        vm.expectEmit(address(factory));
        emit LaunchpadFactory.DirectLaunchFdvSet(10 ether, 2 ether);
        factory.setDirectLaunchFdvWei(2 ether);
        vm.stopPrank();

        uint256 fee = factory.creationFeeWei();
        LaunchpadFactory.CreateParams memory p = _instantParams();
        vm.prank(CREATOR);
        address token = factory.create{value: fee}(p, fee);
        (, address poolAddr,,) = factory.campaignOf(token);
        CampaignPool pool = CampaignPool(payable(poolAddr));
        assertEq(pool.directFdvWei(), 2 ether);
        (uint160 price,,,) = PM.getSlot0(locker.poolKey(token).toId());
        // FDV = supply / tokens per ETH, the opening tick rounded down (≤ ~2% more)
        uint256 tokensPerEth = FullMath.mulDiv(uint256(price), uint256(price), 1 << 192);
        uint256 fdv = 1_000_000_000e18 / tokensPerEth;
        assertApproxEqRel(fdv, 2 ether, 0.021e18);

        // a refresh changes the next launches only
        vm.prank(GUARDIAN);
        factory.setDirectLaunchFdvWei(1 ether);
        assertEq(pool.directFdvWei(), 2 ether);
        p = _instantParams();
        vm.prank(CREATOR);
        token = factory.create{value: fee}(p, fee);
        (, poolAddr,,) = factory.campaignOf(token);
        assertEq(CampaignPool(payable(poolAddr)).directFdvWei(), 1 ether);
    }

    /// What `maxFeeWei` holds above the fee goes back; the deposit is exact.
    function test_refundsWhatTheMaxHoldsAboveTheFee() public {
        feed.set(2_500e8, block.timestamp);
        uint256 fee = factory.creationFeeWei();
        uint256 maxFee = fee * 102 / 100;
        uint256 before = CREATOR.balance;
        LaunchpadFactory.CreateParams memory p = _params();
        vm.prank(CREATOR);
        address token = factory.create{value: maxFee + 0.5 ether}(p, maxFee);
        (, CampaignPool pool) = _parts(token);
        assertEq(pool.creatorDeposited(), 0.5 ether);
        assertEq(before - CREATOR.balance, fee + 0.5 ether);
        assertEq(address(factory).balance, 0);
    }

    /// A price drop above the creator's margin reverts; too little ETH too.
    function test_feeAboveTheMaxReverts() public {
        feed.set(2_500e8, block.timestamp);
        uint256 quoted = factory.creationFeeWei();
        feed.set(2_400e8, block.timestamp);
        uint256 fee = factory.creationFeeWei();
        LaunchpadFactory.CreateParams memory p = _params();
        vm.startPrank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.FeeAboveMax.selector, fee, quoted));
        factory.create{value: quoted}(p, quoted);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.WrongFee.selector, fee, fee - 1));
        factory.create{value: fee - 1}(p, fee);
        vm.stopPrank();
    }

    /// Older than 6 hours, outside 500..20,000 USD, zero, negative, from the
    /// future or a reverting feed: the deploy day's fee, and creation goes on.
    function test_unusableFeedFallsBack() public {
        vm.warp(block.timestamp + 1 days);
        feed.set(2_500e8, block.timestamp - 6 hours);
        assertEq(factory.creationFeeWei(), 0.0012 ether); // exactly 6 h: still used
        feed.set(2_500e8, block.timestamp - 6 hours - 1);
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        feed.set(2_500e8, block.timestamp + 1);
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        feed.set(499e8, block.timestamp);
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        feed.set(500e8, block.timestamp);
        assertEq(factory.creationFeeWei(), 0.006 ether);
        feed.set(20_000e8, block.timestamp);
        assertEq(factory.creationFeeWei(), 0.00015 ether);
        feed.set(20_000e8 + 1, block.timestamp);
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        feed.set(0, block.timestamp);
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        feed.set(-1, block.timestamp);
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        (bool live,) = factory.ethUsdPrice();
        assertFalse(live);

        feed.set(2_500e8, block.timestamp);
        feed.breakIt();
        assertEq(factory.creationFeeWei(), CREATION_FEE);
        address token = _create(_params(), CREATION_FEE);
        assertTrue(token != address(0));
    }

    /// A factory without a feed always charges its fixed fee.
    function test_noFeedMeansTheFixedFee() public {
        LaunchpadFactory.Config memory c;
        c.creationFeeWei = 1 ether;
        // K68: the opening FDV must be in the guardian's range from the start
        vm.expectRevert(abi.encodeWithSelector(LaunchpadFactory.InvalidOpeningFdv.selector, 0));
        new LaunchpadFactory(c);
        c.directLaunchFdvWei = INITIAL_FDV;
        LaunchpadFactory f = new LaunchpadFactory(c);
        (bool live,) = f.ethUsdPrice();
        assertFalse(live);
        assertEq(f.creationFeeWei(), 1 ether);
    }
}
