// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "base-std-test/lib/BaseTest.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {B20WalletBinding} from "../src/B20WalletBinding.sol";
import {B20NFTRevenueVault} from "../src/B20NFTRevenueVault.sol";
import {B20EligibleNFT} from "../src/B20EligibleNFT.sol";
import {B20PublicNFT} from "../src/B20PublicNFT.sol";
import {B20Mining} from "../src/B20Mining.sol";
import {B20ClaimVault} from "../src/B20ClaimVault.sol";
import {B20CommunityVault} from "../src/B20CommunityVault.sol";
import {MinerBurner} from "../src/MinerBurner.sol";
import {B20LiquidityFinalizer} from "../src/B20LiquidityFinalizer.sol";
import {MinerPool} from "../src/MinerPool.sol";
import {B20TeamVesting} from "../src/B20TeamVesting.sol";
import {B20EcosystemVault} from "../src/B20EcosystemVault.sol";
import {B20SnapshotMerkle} from "../src/B20SnapshotMerkle.sol";
import {B20NativeAssetConfig} from "../src/libraries/B20NativeAssetConfig.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Full cross-contract integration test: deploys every real
/// B20MINER protocol contract together (no mock Mining, no mock
/// ClaimVault), wires them through nonce-predicted `CREATE` addresses
/// exactly as `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md` §7.2 describes,
/// and drives one real mining/finalization/claim/burn lifecycle end to
/// end. Only the Base `GasPriceOracle` predeploy is mocked; Uniswap's real
/// V4 `PoolManager` is deployed at its Base Mainnet address (MINER's pool,
/// owner decision 30 October 2026) — everything else is the real,
/// unmodified production contract.
///
/// Not a full suite, not fuzz/invariant. Four targeted scenarios only:
/// predicted-address/wiring, one full lifecycle through claim, one
/// atomic-revert proof, and one T+30 unclaimed-burn proof.
contract B20SystemIntegrationTest is BaseTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---- Uniswap's V4 PoolManager on Base Mainnet (`MinerPool` pins it) ----
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    uint256 internal constant MINING_START = 1_800_000_000;
    uint256 internal constant MINING_END = MINING_START + 15 days;
    uint256 internal constant POW_TARGET = type(uint256).max;

    uint256 internal constant OPEN_DEADLINE = MINING_START + 30 days;
    // $1 at 2,400.00 USD/ETH, as DeployB20Genesis.activationFeeFor(240000).
    uint256 internal constant ACTIVATION_FEE = 416_666_666_666_667;

    string internal fixturesJson;

    // ---- Real protocol contracts ----
    IB20Asset internal token;
    B20WalletBinding internal walletBinding;
    MinerPool internal minerPool;
    B20EcosystemVault internal ecosystemVault;
    B20TeamVesting internal teamVesting;
    B20NFTRevenueVault internal nftRevenueVault;
    B20EligibleNFT internal eligibleNFT;
    B20PublicNFT internal publicNFT;
    B20LiquidityFinalizer internal finalizer;
    B20Mining internal mining;
    B20ClaimVault internal claimVault;
    MinerBurner internal burner;
    B20CommunityVault internal communityVault;

    address internal predictedFinalizer;
    address internal predictedMining;
    address internal predictedClaimVault;

    address internal treasury;
    address internal operationsRecipient;
    address internal ecosystemManager;
    address internal teamBeneficiary;

    address internal opener;

    // ownerA: a genuine Snapshot V1 wallet from the production fixture —
    // its base quota is confirmed with a real fixture proof. It sends the
    // binding transaction itself; its mining wallet signs consent with a
    // real ECDSA EIP-712 signature.
    address internal ownerA;
    uint256 internal fixtureAllocationA;
    bytes32[] internal fixtureProofA;
    uint256 internal minerWalletAPk;
    address internal minerWalletA;

    // ownerB: a synthetic wallet outside the snapshot, earning quota by
    // minting a real B20PublicNFT.
    address internal ownerB;
    uint256 internal minerWalletBPk;
    address internal minerWalletB;

    function setUp() public override {
        super.setUp();
        vm.chainId(8_453);
        fixturesJson = vm.readFile("test/fixtures/snapshot-v1-proofs.json");

        vm.warp(MINING_START - 7 days);
        _deployPredeploys();
        _deployCoreProtocol();
        _bindOwnerA();
        _bindOwnerB();

        // The launch order (2 Nov 2026): the opener's `openMining()` opens
        // NFT minting and allocation confirmation together with mining.
        vm.warp(MINING_START);
        vm.prank(opener);
        mining.openMining();

        _confirmOwnerAAllocation();
        _mintAndConfirmOwnerBAllocation();

        _submitProofs();
    }

    // ---------------------------------------------------------------
    // setUp helpers
    // ---------------------------------------------------------------

    function _deployPredeploys() internal {
        // the real PoolManager, constructed at its Base address (its
        // no-delegate-call guard keeps that address in an immutable)
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(makeAddr("poolManagerOwner")), POOL_MANAGER);

        vm.fee(1 gwei);
        vm.txGasPrice(0.5 gwei);
    }

    function _loadFixture(uint256 index)
        internal
        view
        returns (address wallet, uint256 allocation, bytes32[] memory proof)
    {
        string memory base = string.concat(".[", vm.toString(index), "]");
        wallet = vm.parseJsonAddress(fixturesJson, string.concat(base, ".wallet"));
        allocation = vm.parseJsonUint(fixturesJson, string.concat(base, ".allocation_b20"));
        proof = vm.parseJsonBytes32Array(fixturesJson, string.concat(base, ".proof"));
    }

    /// @dev Deploys every real protocol contract, computing the
    /// Finalizer/Mining/ClaimVault addresses via nonce-based `CREATE`
    /// prediction *before* any of the three is actually deployed — see
    /// docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md §7.2. `address(this)` (the
    /// test contract) is the sole deployer throughout, so nonce
    /// prediction against `vm.getNonce(address(this))` is exact as long
    /// as nothing else deploys from this contract in between.
    function _deployCoreProtocol() internal {
        treasury = makeAddr("treasury");
        operationsRecipient = makeAddr("operationsRecipient");
        ecosystemManager = makeAddr("ecosystemManager");
        teamBeneficiary = makeAddr("teamBeneficiary");
        opener = makeAddr("opener");

        // The native B20 is created through the singleton Factory rather
        // than with CREATE. Predict every reserve recipient from this
        // contract's current CREATE nonce before the bootstrap batch mint.
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedEcosystemVault = vm.computeCreateAddress(address(this), baseNonce + 2);
        address predictedTeamVesting = vm.computeCreateAddress(address(this), baseNonce + 3);
        predictedFinalizer = vm.computeCreateAddress(address(this), baseNonce + 7);
        predictedMining = vm.computeCreateAddress(address(this), baseNonce + 8);
        predictedClaimVault = vm.computeCreateAddress(address(this), baseNonce + 9);
        address predictedBurner = vm.computeCreateAddress(address(this), baseNonce + 10);
        address predictedCommunityVault = vm.computeCreateAddress(address(this), baseNonce + 11);

        token = B20NativeAssetConfig.create(
            address(this),
            B20NativeAssetConfig.Reserves({
                claimVault: predictedClaimVault,
                liquidityFinalizer: predictedFinalizer,
                ecosystemVault: predictedEcosystemVault,
                teamVesting: predictedTeamVesting,
                communityVault: predictedCommunityVault,
                burner: predictedBurner
            })
        );
        walletBinding = new B20WalletBinding(treasury, B20SnapshotMerkle.MERKLE_ROOT, ACTIVATION_FEE);
        minerPool = new MinerPool(POOL_MANAGER, address(token), predictedBurner, predictedFinalizer);
        ecosystemVault = new B20EcosystemVault(address(token), ecosystemManager);
        teamVesting = new B20TeamVesting(address(token), teamBeneficiary, 1);

        nftRevenueVault = new B20NFTRevenueVault(predictedFinalizer, operationsRecipient);
        eligibleNFT = new B20EligibleNFT(
            "B20 Eligible NFT", "B20E", B20SnapshotMerkle.MERKLE_ROOT, address(nftRevenueVault), predictedMining
        );
        publicNFT = new B20PublicNFT("B20 Public NFT", "B20P", address(nftRevenueVault), predictedMining);

        finalizer = new B20LiquidityFinalizer(
            address(token),
            predictedMining,
            predictedClaimVault,
            address(nftRevenueVault),
            address(minerPool)
        );
        mining = new B20Mining(
            address(walletBinding),
            POW_TARGET,
            opener,
            OPEN_DEADLINE,
            address(eligibleNFT),
            address(publicNFT),
            address(finalizer)
        );
        claimVault = new B20ClaimVault(address(token), address(mining), address(finalizer));
        burner = new MinerBurner(address(token));
        communityVault = new B20CommunityVault(
            address(token), address(mining), address(claimVault), address(burner), ecosystemManager
        );

        assertEq(address(ecosystemVault), predictedEcosystemVault);
        assertEq(address(teamVesting), predictedTeamVesting);
        assertEq(address(burner), predictedBurner);
        assertEq(address(communityVault), predictedCommunityVault);
        B20NativeAssetConfig.verifyConfiguration(
            token,
            address(this),
            B20NativeAssetConfig.Reserves({
                claimVault: address(claimVault),
                liquidityFinalizer: address(finalizer),
                ecosystemVault: address(ecosystemVault),
                teamVesting: address(teamVesting),
                communityVault: address(communityVault),
                burner: address(burner)
            })
        );
    }

    /// @dev The owner wallet activates once, paying the fee. Any mining
    /// wallet may then mine for it; `minerPk` is kept for the call sites.
    function _bind(address ownerWallet, uint256 minerPk) internal {
        minerPk;
        vm.prank(ownerWallet);
        walletBinding.activate{value: ACTIVATION_FEE}();
    }

    function _bindOwnerA() internal {
        (ownerA, fixtureAllocationA, fixtureProofA) = _loadFixture(0);
        minerWalletAPk = 0xA11CE;
        minerWalletA = vm.addr(minerWalletAPk);
        vm.deal(ownerA, 1 ether);
        vm.deal(minerWalletA, 10 ether);
        _bind(ownerA, minerWalletAPk);
    }

    function _bindOwnerB() internal {
        ownerB = makeAddr("ownerB");
        minerWalletBPk = 0xB0B5;
        minerWalletB = vm.addr(minerWalletBPk);
        vm.deal(ownerB, 10 ether);
        vm.deal(minerWalletB, 10 ether);
        _bind(ownerB, minerWalletBPk);
    }

    function _confirmOwnerAAllocation() internal {
        vm.prank(ownerA);
        mining.confirmAllocation(fixtureAllocationA, fixtureProofA);
    }

    function _mintAndConfirmOwnerBAllocation() internal {
        uint256 mintPrice = publicNFT.MINT_PRICE();
        vm.prank(ownerB);
        publicNFT.mint{value: mintPrice}(1);

        vm.prank(ownerB);
        mining.confirmAllocation(0, new bytes32[](0));

        // The allocation is final: ownerB cannot mint again.
        vm.prank(ownerB);
        vm.expectRevert(B20PublicNFT.MintingClosed.selector);
        publicNFT.mint{value: mintPrice}(1);
    }

    function _submitProofs() internal {
        (, uint256 feeA) = mining.quoteProof(ownerA);
        bytes32 challengeA = mining.challengeOf(ownerA);
        vm.prank(minerWalletA);
        mining.submitProof{value: feeA}(ownerA, challengeA, 0);

        (, uint256 feeB) = mining.quoteProof(ownerB);
        bytes32 challengeB = mining.challengeOf(ownerB);
        vm.prank(minerWalletB);
        mining.submitProof{value: feeB}(ownerB, challengeB, 0);
    }

    // ---------------------------------------------------------------
    // 0. Open mining for activated owners (owner decision 25 Sep 2026, v5)
    // ---------------------------------------------------------------

    /// The same mining wallet mines for whichever activated owner the proof
    /// names, with no registration; the reward always lands on that owner.
    function test_anyMiningWallet_minesForAnActivatedOwner_rewardsGoToTheNamedOwner() public {
        uint256 lockedABefore = mining.minedLocked(ownerA);
        uint256 lockedBBefore = mining.minedLocked(ownerB);

        // minerWalletA was never registered for ownerB: it mines for ownerB anyway.
        (uint256 rewardB, uint256 feeB) = mining.quoteProof(ownerB);
        bytes32 challengeB = mining.challengeOf(ownerB);
        vm.prank(minerWalletA);
        mining.submitProof{value: feeB}(ownerB, challengeB, 0);
        assertEq(mining.minedLocked(ownerB), lockedBBefore + rewardB, "the proof's owner earns it");
        assertEq(mining.minedLocked(ownerA), lockedABefore, "the other owner is untouched");

        // A brand-new wallet (a CLI, say) mines for ownerA with no setup.
        address cliWallet = makeAddr("cliWallet");
        vm.deal(cliWallet, 1 ether);
        (uint256 rewardA, uint256 feeA) = mining.quoteProof(ownerA);
        bytes32 challengeA = mining.challengeOf(ownerA);
        vm.prank(cliWallet);
        mining.submitProof{value: feeA}(ownerA, challengeA, 0);
        assertEq(mining.minedLocked(ownerA), lockedABefore + rewardA);
        assertEq(cliWallet.balance, 1 ether - feeA, "the miner pays the fee; the reward is not its");
    }

    /// Nobody can mine for an owner wallet that never activated, even with
    /// a confirmed allocation.
    function test_notActivatedOwner_cannotBeMinedFor() public {
        // ownerC confirms a real allocation (a Public NFT) but never activates.
        address ownerC = makeAddr("ownerC");
        vm.deal(ownerC, 1 ether);
        uint256 mintPrice = publicNFT.MINT_PRICE();
        vm.prank(ownerC);
        publicNFT.mint{value: mintPrice}(1);
        vm.prank(ownerC);
        mining.confirmAllocation(0, new bytes32[](0));
        assertGt(mining.remainingQuota(ownerC), 0);

        (, uint256 feeC) = mining.quoteProof(ownerC);
        bytes32 challengeC = mining.challengeOf(ownerC);
        vm.prank(minerWalletA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.InactiveBinding.selector, ownerC, minerWalletA));
        mining.submitProof{value: feeC}(ownerC, challengeC, 0);
    }

    // ---------------------------------------------------------------
    // 1. Predicted-address / wiring
    // ---------------------------------------------------------------

    /// Nonce-predicted CREATE addresses match the real deployment, every
    /// circular immutable link resolves correctly, and the 100B supply
    /// reconciles with no leftover at the deployer.
    function test_predictedAddresses_matchDeploymentAndCircularWiring() public view {
        assertEq(address(finalizer), predictedFinalizer, "finalizer address mismatch");
        assertEq(address(mining), predictedMining, "mining address mismatch");
        assertEq(address(claimVault), predictedClaimVault, "claimVault address mismatch");

        assertEq(mining.liquidityVault(), address(finalizer), "Mining -> Finalizer");
        assertEq(address(finalizer.mining()), address(mining), "Finalizer -> Mining");
        assertEq(address(finalizer.claimVault()), address(claimVault), "Finalizer -> ClaimVault");
        assertEq(address(claimVault.mining()), address(mining), "ClaimVault -> Mining");
        assertEq(address(claimVault.finalizer()), address(finalizer), "ClaimVault -> Finalizer");
        assertEq(nftRevenueVault.liquidityRecipient(), address(finalizer), "NFTRevenueVault -> Finalizer");

        assertEq(token.balanceOf(address(claimVault)), claimVault.BASE_RESERVE() + claimVault.NFT_RESERVE());
        assertEq(token.balanceOf(address(finalizer)), finalizer.LIQUIDITY_RESERVE());
        assertEq(token.balanceOf(address(ecosystemVault)), 5_000_000_000 * 1e18);
        assertEq(token.balanceOf(address(teamVesting)), 1_000_000_000 * 1e18);
        assertEq(token.balanceOf(address(communityVault)), 8_000_000_000 * 1e18);
        assertEq(token.balanceOf(address(this)), 0, "deployer must hold no leftover MINER");
        assertEq(
            token.balanceOf(address(claimVault)) + token.balanceOf(address(finalizer))
                + token.balanceOf(address(ecosystemVault)) + token.balanceOf(address(teamVesting))
                + token.balanceOf(address(communityVault)),
            token.totalSupply()
        );
        assertEq(token.totalSupply(), 100_000_000_000 * 1e18);
    }

    // ---------------------------------------------------------------
    // 2. Atomic revert
    // ---------------------------------------------------------------

    /// A failure while opening the pool (here: `MinerPool.open` reverts)
    /// undoes the ENTIRE transaction — the MINER sent to the pool, the NFT
    /// revenue distribution and the real ClaimVault and liquidity-reserve
    /// burns that already happened.
    function test_finalize_atomicRevertWhenPoolOpenFails() public {
        vm.mockCallRevert(address(minerPool), abi.encodeWithSelector(MinerPool.open.selector), "open failed");

        vm.warp(MINING_END);

        uint256 totalSupplyBefore = token.totalSupply();
        uint256 baseMinedBefore = mining.totalBaseMinedLocked();
        uint256 nftMinedBefore = mining.totalNftMinedLocked();

        vm.expectRevert();
        finalizer.finalize();

        assertFalse(finalizer.finalized());
        assertFalse(claimVault.reservesFinalized());
        assertEq(token.totalSupply(), totalSupplyBefore, "no burn should have persisted");
        assertEq(mining.totalBaseMinedLocked(), baseMinedBefore);
        assertEq(mining.totalNftMinedLocked(), nftMinedBefore);
        assertEq(token.balanceOf(address(minerPool)), 0, "no MINER left at the pool");
        assertEq(token.balanceOf(POOL_MANAGER), 0, "nothing in the PoolManager");
        vm.clearMockedCalls();
    }

    /// The public V4 pool key initialized by a stranger at another price
    /// before `T+15` (the V4 form of the 26 September 2026 griefed-pair
    /// finding): finalize() still runs, the pool opens at its price, and
    /// claims open.
    function test_finalize_andClaim_surviveAStrangerInitializedPool() public {
        PoolKey memory key = minerPool.poolKey();
        IPoolManager(POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(-120_000));
        vm.warp(MINING_END);

        finalizer.finalize();

        assertTrue(finalizer.finalized());
        assertTrue(claimVault.reservesFinalized());
        (uint160 price,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        assertEq(price, minerPool.openingSqrtPriceX96());
    }

    // ---------------------------------------------------------------
    // 3. Full lifecycle through claim
    // ---------------------------------------------------------------

    /// Real mining fees reach the Finalizer and are accounted; T+15
    /// finalize() runs the real sequence and opens MINER's pool in the real
    /// V4 PoolManager (held by `MinerPool` for good, no LP token); claim
    /// opens and pays the owner's exact
    /// mined amount; a second claim is rejected; counters reconcile.
    function test_fullLifecycle_financeClaimAndSecondClaimRejected() public {
        uint256 accountedBefore = finalizer.accountedLiquidityEth();
        uint256 nftVaultBalanceBefore = address(nftRevenueVault).balance;
        assertGt(accountedBefore, 0, "mining fees should have reached the finalizer");
        assertGt(nftVaultBalanceBefore, 0, "NFT mint fee should have reached the revenue vault");

        uint256 totalSupplyBeforeFinalize = token.totalSupply();
        uint256 unminedBaseExpected = claimVault.BASE_RESERVE() - mining.totalBaseMinedLocked();
        uint256 unminedNftExpected = claimVault.NFT_RESERVE() - mining.totalNftMinedLocked();

        vm.warp(MINING_END);
        finalizer.finalize();

        assertTrue(finalizer.finalized());
        assertTrue(minerPool.opened());
        (uint160 price,,,) = IPoolManager(POOL_MANAGER).getSlot0(minerPool.poolKey().toId());
        assertEq(price, minerPool.openingSqrtPriceX96(), "opens at 1 ETH = 6,000,000 MINER");
        assertGt(finalizer.liquidityMinted(), 0);
        // both sides sit in the PoolManager; only rounding dust is left out
        assertApproxEqAbs(token.balanceOf(POOL_MANAGER), finalizer.minerAdded(), 1e12);
        assertApproxEqAbs(POOL_MANAGER.balance, finalizer.ethAdded(), 1e6);
        assertEq(token.balanceOf(address(finalizer)), 0);
        assertEq(token.balanceOf(address(minerPool)), 0);

        assertEq(
            finalizer.ethAdded(),
            accountedBefore + nftVaultBalanceBefore / 2,
            "NFT revenue's liquidity half must be folded into the pool ETH"
        );
        // The pool opens at 1 ETH = 6,000,000 MINER while every proof paid its
        // fee at 1 ETH = 12,000,000 MINER: the opening price per MINER is twice
        // the fee paid per MINER.
        assertEq(finalizer.minerAdded(), finalizer.ethAdded() * finalizer.POOL_MINER_PER_ETH());
        assertEq(mining.MINER_PER_ETH(), 2 * finalizer.POOL_MINER_PER_ETH());

        assertTrue(claimVault.reservesFinalized());
        assertEq(
            token.totalSupply(),
            totalSupplyBeforeFinalize - unminedBaseExpected - unminedNftExpected - finalizer.liquidityReserveBurned()
                - burner.totalBurned(), // the opening's rounding dust, burned by MinerPool
            "only the unmined reserves, the unused liquidity reserve and the opening's dust are burned"
        );
        assertLe(burner.totalBurned(), 1e12);
        assertEq(token.allowance(address(finalizer), address(minerPool)), 0);
        assertGt(claimVault.claimable(ownerA), 0);

        uint256 expectedA = mining.baseMinedLocked(ownerA) + mining.nftMinedLocked(ownerA);
        vm.prank(ownerA);
        claimVault.claim();
        assertEq(token.balanceOf(ownerA), expectedA);
        assertTrue(claimVault.claimed(ownerA));

        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.AlreadyClaimed.selector, ownerA));
        claimVault.claim();

        assertEq(claimVault.baseReserveRemaining() + claimVault.totalBaseClaimed(), mining.totalBaseMinedLocked());
        assertEq(claimVault.nftReserveRemaining() + claimVault.totalNftClaimed(), mining.totalNftMinedLocked());
    }

    // ---------------------------------------------------------------
    // 3b. Community rewards and the burner (B20_REVENUE_MODEL.md 1.36)
    // ---------------------------------------------------------------

    /// With the native MINER (reference B20 factory): after mining ends the
    /// community vault keeps the 1B floor (almost nothing of the snapshot was
    /// mined here), burns the other 7B through `MinerBurner` — whose
    /// genesis `BURN_ROLE` really lowers `totalSupply` — and starts staking
    /// rewards at the claim deadline. A holder can then burn MINER just by
    /// sending it to the burner.
    function test_communityVault_scalesAndBurnsThroughTheBurner_andUsersCanBurn() public {
        vm.warp(MINING_END);
        finalizer.finalize();
        uint256 supplyBefore = token.totalSupply();
        uint256 burnedBefore = burner.totalBurned(); // the pool opening's rounding dust

        communityVault.settle();
        assertEq(communityVault.keptTotal(), communityVault.FLOOR());
        assertEq(token.balanceOf(address(communityVault)), 1_000_000_000 * 1e18);
        assertEq(token.totalSupply(), supplyBefore - 7_000_000_000 * 1e18);
        assertEq(burner.totalBurned() - burnedBefore, 7_000_000_000 * 1e18);
        assertEq(communityVault.rewardsStart(), claimVault.claimDeadline());
        assertEq(communityVault.stakingPot() + communityVault.airdropPot(), communityVault.keptTotal());

        vm.prank(ownerA);
        claimVault.claim();
        uint256 aBalance = token.balanceOf(ownerA);
        vm.prank(ownerA);
        assertTrue(token.transfer(address(burner), aBalance / 2));
        uint256 supplyMid = token.totalSupply();
        vm.prank(makeAddr("anyone"));
        burner.burn();
        assertEq(token.totalSupply(), supplyMid - aBalance / 2);
        assertEq(token.balanceOf(address(burner)), 0);
    }

    // ---------------------------------------------------------------
    // 4. T+30 unclaimed burn
    // ---------------------------------------------------------------

    /// ownerA claims; ownerB deliberately never does. At the claim
    /// deadline, `burnUnclaimed()` burns exactly ownerB's outstanding
    /// locked reward, freezes both reserve counters at zero, and a
    /// second burn attempt is rejected.
    function test_burnUnclaimed_atT30BurnsOwnerBsUnclaimedLiability() public {
        vm.warp(MINING_END);
        finalizer.finalize();

        vm.prank(ownerA);
        claimVault.claim();

        vm.warp(claimVault.claimDeadline());

        uint256 expectedUnclaimedBase = mining.totalBaseMinedLocked() - claimVault.totalBaseClaimed();
        uint256 expectedUnclaimedNft = mining.totalNftMinedLocked() - claimVault.totalNftClaimed();
        assertGt(expectedUnclaimedNft, 0, "ownerB's unclaimed nft reward should still be outstanding");
        assertEq(mining.nftMinedLocked(ownerB), expectedUnclaimedNft);

        uint256 totalSupplyBefore = token.totalSupply();

        claimVault.burnUnclaimed();

        assertTrue(claimVault.unclaimedReserveBurned());
        assertEq(claimVault.baseReserveRemaining(), 0);
        assertEq(claimVault.nftReserveRemaining(), 0);
        assertEq(token.totalSupply(), totalSupplyBefore - expectedUnclaimedBase - expectedUnclaimedNft);

        assertEq(claimVault.totalBaseClaimed() + expectedUnclaimedBase, mining.totalBaseMinedLocked());
        assertEq(claimVault.totalNftClaimed() + expectedUnclaimedNft, mining.totalNftMinedLocked());

        vm.expectRevert(B20ClaimVault.AlreadyBurnedUnclaimed.selector);
        claimVault.burnUnclaimed();
    }
}
