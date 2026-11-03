// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {B20PoW} from "../src/B20PoW.sol";
import {B20Mining} from "../src/B20Mining.sol";
import {IB20WalletBinding} from "../src/interfaces/IB20WalletBinding.sol";
import {IB20EligibleNFT} from "../src/interfaces/IB20EligibleNFT.sol";
import {IB20PublicNFT} from "../src/interfaces/IB20PublicNFT.sol";

/// @notice Minimal test-only mock of B20WalletBinding: a directly settable
/// owner -> active-mining-wallet mapping, so tests can simulate bind /
/// rotation without the real contract's EIP-712 signature flow.
contract MockWalletBinding is IB20WalletBinding {
    mapping(address ownerWallet => address miningWallet) public activeMiningWallet;

    function setActive(address ownerWallet, address miningWallet) external {
        activeMiningWallet[ownerWallet] = miningWallet;
    }

    function isActiveBinding(address ownerWallet, address miningWallet) external view returns (bool) {
        return miningWallet != address(0) && activeMiningWallet[ownerWallet] == miningWallet;
    }
}

/// @notice Minimal test-only mock of B20EligibleNFT: a directly settable
/// owner -> bonus mapping. `mining()` reports whichever contract asks
/// (so any B20Mining constructed against it passes its wiring check)
/// unless a fixed answer is forced.
contract MockEligibleNFT is IB20EligibleNFT {
    mapping(address wallet => uint256 amount) public bonus;
    address public forcedMining;

    function setBonus(address wallet, uint256 amount) external {
        bonus[wallet] = amount;
    }

    function forceMining(address value) external {
        forcedMining = value;
    }

    function eligibleBonus(address wallet) external view returns (uint256) {
        return bonus[wallet];
    }

    function mining() external view returns (address) {
        return forcedMining == address(0) ? msg.sender : forcedMining;
    }
}

/// @notice Minimal test-only mock of B20PublicNFT, same shape as
/// `MockEligibleNFT`.
contract MockPublicNFT is IB20PublicNFT {
    mapping(address wallet => uint256 amount) public quota;
    address public forcedMining;

    function setQuota(address wallet, uint256 amount) external {
        quota[wallet] = amount;
    }

    function forceMining(address value) external {
        forcedMining = value;
    }

    function publicMiningQuota(address wallet) external view returns (uint256) {
        return quota[wallet];
    }

    function mining() external view returns (address) {
        return forcedMining == address(0) ? msg.sender : forcedMining;
    }
}

/// @notice Test-only mining-fee recipient whose ETH acceptance can be
/// toggled off, to exercise the "liquidity transfer fails" revert path.
contract MockLiquidityVault {
    bool public accepts = true;

    function setAccepts(bool value) external {
        accepts = value;
    }

    receive() external payable {
        require(accepts, "MockLiquidityVault: rejecting");
    }
}

/// @notice Test-only mining wallet whose ETH acceptance can be toggled
/// off, to exercise the "refund fails" revert path. Used as `msg.sender`
/// for `submitProof` via `vm.prank` — no wrapper call function needed.
contract MockRejectingMiner {
    bool public accepts = true;

    function setAccepts(bool value) external {
        accepts = value;
    }

    receive() external payable {
        require(accepts, "MockRejectingMiner: rejecting");
    }
}

/// @notice Test-only mining wallet that attempts a reentrant
/// `submitProof` call from inside the `receive()` triggered by its own
/// refund, to prove `nonReentrant` blocks it. Used as `msg.sender` for
/// the outer `submitProof` via `vm.prank`.
contract ReentrantMiner {
    B20Mining public target;
    address public ownerWallet;
    uint256 public reentryAttempts;
    bool public reentryReverted;

    function configure(B20Mining target_, address ownerWallet_) external {
        target = target_;
        ownerWallet = ownerWallet_;
    }

    receive() external payable {
        reentryAttempts += 1;
        if (reentryAttempts == 1) {
            try target.submitProof(ownerWallet, bytes32(0), 0) {
                reentryReverted = false;
            } catch {
                reentryReverted = true;
            }
        }
    }
}

/// @notice Targeted tests for B20Mining: the one-time mining opening,
/// the one-time allocation confirmation, the mining window, quota
/// consumption, mining-fee collection, fixed per-proof reward accounting
/// and NFT-first `Mined — Locked` bookkeeping.
contract B20MiningTest is Test {
    /// Tests open mining exactly at this timestamp, so the window is
    /// always `[MINING_START, MINING_END)`.
    uint256 internal constant MINING_START = 1_800_000_000;
    uint256 internal constant MINING_END = MINING_START + 15 days;
    uint256 internal constant DEPLOY_TIME = MINING_START - 7 days;
    uint256 internal constant OPEN_DEADLINE = MINING_START + 30 days;

    // Production economics (B20_REVENUE_MODEL.md §2): a full proof earns
    // 312.5 MINER and pays ceil(312.5e18 / 12,000,000) wei.
    uint256 internal constant DEFAULT_REWARD = 312.5e18;
    uint256 internal constant DEFAULT_MINING_FEE = 26_041_666_666_667;

    MockWalletBinding internal binding;
    MockEligibleNFT internal eligibleMock;
    MockPublicNFT internal publicMock;
    MockLiquidityVault internal liquidityVault;

    // Accepts every hash (uint256(hash) <= type(uint256).max is always
    // true), so tests don't need a nonce search to submit a "valid" proof
    // — this is explicitly a test-only target, never a production one.
    B20Mining internal mining;

    // A near-impossible target (accepts essentially no hash), used only to
    // deterministically produce an InvalidProof rejection without a search.
    B20Mining internal strictMining;

    address internal opener = makeAddr("opener");
    address internal owner = makeAddr("owner");
    address internal otherOwner = makeAddr("otherOwner");
    address internal minerA = makeAddr("minerA");
    address internal minerB = makeAddr("minerB");
    address internal stranger = makeAddr("stranger");

    string internal fixturesJson;

    function setUp() public {
        vm.warp(DEPLOY_TIME);
        binding = new MockWalletBinding();
        eligibleMock = new MockEligibleNFT();
        publicMock = new MockPublicNFT();
        liquidityVault = new MockLiquidityVault();

        mining = _deployMining(type(uint256).max);
        strictMining = _deployMining(1);

        // Default nonzero Public NFT quota for the two standard test
        // owners, so most tests can confirm an allocation with a trivial
        // baseAllocation=0 / empty-proof call.
        publicMock.setQuota(owner, 10_000 * 1e18);
        publicMock.setQuota(otherOwner, 10_000 * 1e18);

        vm.deal(minerA, 1000 ether);
        vm.deal(minerB, 1000 ether);

        fixturesJson = vm.readFile("test/fixtures/snapshot-v1-proofs.json");
    }

    function _deployMining(uint256 target) internal returns (B20Mining) {
        return new B20Mining(
            address(binding),
            target,
            opener,
            OPEN_DEADLINE,
            address(eligibleMock),
            address(publicMock),
            address(liquidityVault)
        );
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

    /// @dev Opens `target` at MINING_START (warping forward if needed)
    /// unless it is already open.
    function _ensureOpened(B20Mining target) internal {
        if (target.miningOpened()) return;
        if (block.timestamp < MINING_START) vm.warp(MINING_START);
        vm.prank(opener);
        target.openMining();
    }

    /// @dev Confirms `ownerWallet`'s allocation from the pre-configured
    /// mock NFT quota (baseAllocation=0, empty proof), unless already
    /// confirmed.
    function _confirm(B20Mining target, address ownerWallet) internal {
        if (target.allocationConfirmed(ownerWallet)) return;
        vm.prank(ownerWallet);
        target.confirmAllocation(0, new bytes32[](0));
    }

    /// @dev Binds `ownerWallet` to `activeMiner`, opens mining and
    /// confirms the owner's mock NFT allocation, so `submitProof` tests
    /// that are really about binding/challenge/replay behavior don't need
    /// to deal with snapshot proofs at all.
    function _prepareForMining(B20Mining target, address ownerWallet, address activeMiner) internal {
        binding.setActive(ownerWallet, activeMiner);
        _ensureOpened(target);
        _confirm(target, ownerWallet);
    }

    /// @dev Submits a proof as `minerWallet` with `value` wei attached.
    function _submitProof(
        B20Mining target,
        address minerWallet,
        address ownerWallet,
        bytes32 expectedChallenge,
        uint256 nonce,
        uint256 value
    ) internal {
        vm.prank(minerWallet);
        target.submitProof{value: value}(ownerWallet, expectedChallenge, nonce);
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    function test_constructor_rejectsZeroWalletBinding() public {
        vm.expectRevert(B20Mining.ZeroWalletBinding.selector);
        new B20Mining(
            address(0),
            type(uint256).max,
            opener,
            OPEN_DEADLINE,
            address(eligibleMock),
            address(publicMock),
            address(liquidityVault)
        );
    }

    /// Base keeps the 15-day window; Base Sepolia gets 1 day (owner, 30
    /// October 2026) with the same code, so the testnet runs the whole
    /// cycle quickly.
    function test_miningDuration_isFifteenDaysExceptOnBaseSepolia() public {
        vm.chainId(8_453);
        assertEq(_deployMining(type(uint256).max).MINING_DURATION(), 15 days);
        vm.chainId(84_532);
        B20Mining short = _deployMining(type(uint256).max);
        assertEq(short.MINING_DURATION(), 1 days);
        vm.warp(MINING_START);
        vm.prank(opener);
        short.openMining();
        assertEq(short.MINING_END(), MINING_START + 1 days);
        vm.warp(MINING_START + 1 days - 1);
        assertFalse(short.miningEnded());
        vm.warp(MINING_START + 1 days);
        assertTrue(short.miningEnded());
    }

    function test_constructor_rejectsZeroTarget() public {
        vm.expectRevert(B20Mining.ZeroPowTarget.selector);
        _deployMining(0);
    }

    function test_constructor_rejectsZeroOpener() public {
        vm.expectRevert(B20Mining.ZeroMiningOpener.selector);
        new B20Mining(
            address(binding),
            type(uint256).max,
            address(0),
            OPEN_DEADLINE,
            address(eligibleMock),
            address(publicMock),
            address(liquidityVault)
        );
    }

    function test_constructor_rejectsOpenDeadlineNotInFuture() public {
        vm.expectRevert(B20Mining.OpenDeadlineNotInFuture.selector);
        new B20Mining(
            address(binding),
            type(uint256).max,
            opener,
            block.timestamp,
            address(eligibleMock),
            address(publicMock),
            address(liquidityVault)
        );
    }

    /// Immutables read back exactly; no setter selector exists; mining is
    /// not open after deployment.
    function test_immutables_areUnchangeable() public {
        assertEq(mining.POW_TARGET(), type(uint256).max);
        assertEq(address(mining.walletBinding()), address(binding));
        assertEq(mining.MINING_OPENER(), opener);
        assertEq(mining.OPEN_DEADLINE(), OPEN_DEADLINE);
        assertEq(mining.MINING_DURATION(), 15 days);
        assertEq(address(mining.eligibleNFT()), address(eligibleMock));
        assertEq(address(mining.publicNFT()), address(publicMock));
        assertEq(mining.liquidityVault(), address(liquidityVault));
        assertFalse(mining.miningOpened());

        (bool success,) = address(mining).call(abi.encodeWithSignature("setPowTarget(uint256)", 1));
        assertFalse(success);
        (bool success2,) = address(mining).call(abi.encodeWithSignature("setWalletBinding(address)", address(0)));
        assertFalse(success2);
        (bool success3,) = address(mining).call(abi.encodeWithSignature("setMiningEnd(uint256)", 0));
        assertFalse(success3);
    }

    /// Constructor rejects an NFT collection that does not report this
    /// mining contract from `mining()`.
    function test_constructor_rejectsNftMiningMismatch() public {
        address wrong = makeAddr("wrongMining");
        MockEligibleNFT wrongEligible = new MockEligibleNFT();
        wrongEligible.forceMining(wrong);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NftMiningMismatch.selector, address(wrongEligible), wrong));
        new B20Mining(
            address(binding),
            type(uint256).max,
            opener,
            OPEN_DEADLINE,
            address(wrongEligible),
            address(publicMock),
            address(liquidityVault)
        );

        MockPublicNFT wrongPublic = new MockPublicNFT();
        wrongPublic.forceMining(wrong);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NftMiningMismatch.selector, address(wrongPublic), wrong));
        new B20Mining(
            address(binding),
            type(uint256).max,
            opener,
            OPEN_DEADLINE,
            address(eligibleMock),
            address(wrongPublic),
            address(liquidityVault)
        );
    }

    function test_constructor_rejectsZeroLiquidityVault() public {
        vm.expectRevert(B20Mining.ZeroLiquidityVault.selector);
        new B20Mining(
            address(binding),
            type(uint256).max,
            opener,
            OPEN_DEADLINE,
            address(eligibleMock),
            address(publicMock),
            address(0)
        );
    }

    function test_constructor_rejectsLiquidityVaultWithNoCode() public {
        address eoa = makeAddr("eoaLiquidityVault");
        vm.expectRevert(abi.encodeWithSelector(B20Mining.LiquidityVaultHasNoCode.selector, eoa));
        new B20Mining(
            address(binding), type(uint256).max, opener, OPEN_DEADLINE, address(eligibleMock), address(publicMock), eoa
        );
    }

    /// Constructor rejects a liquidityVault equal to the contract's own
    /// (about-to-be-deployed) address — a fund-locking self-reference.
    function test_constructor_rejectsLiquidityVaultIsSelf() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(B20Mining.LiquidityVaultIsSelf.selector);
        new B20Mining(
            address(binding),
            type(uint256).max,
            opener,
            OPEN_DEADLINE,
            address(eligibleMock),
            address(publicMock),
            predicted
        );
    }

    // ---------------------------------------------------------------
    // Opening mining
    // ---------------------------------------------------------------

    /// Before opening, every window read fails closed and the summary
    /// view reports "not opened".
    function test_beforeOpening_windowReadsFailClosed() public {
        vm.expectRevert(B20Mining.MiningNotOpened.selector);
        mining.MINING_START();
        vm.expectRevert(B20Mining.MiningNotOpened.selector);
        mining.MINING_END();
        vm.expectRevert(B20Mining.MiningNotOpened.selector);
        mining.challengeOf(owner);

        (bool opened, uint256 start, uint256 end, uint256 deadline) = mining.miningWindow();
        assertFalse(opened);
        assertEq(start, 0);
        assertEq(end, 0);
        assertEq(deadline, OPEN_DEADLINE);
        assertFalse(mining.miningEnded());
        // Nothing opens before `openMining()` (2 Nov 2026): no NFT mint, no confirm.
        assertFalse(mining.mintingOpenFor(owner));
        vm.prank(owner);
        vm.expectRevert(B20Mining.MiningNotOpened.selector);
        mining.confirmAllocation(0, new bytes32[](0));
    }

    /// `openMining()` opens NFT minting and allocation confirmation together
    /// with mining.
    function test_openMining_opensMintingAndConfirmation() public {
        assertFalse(mining.mintingOpenFor(owner));
        _ensureOpened(mining);
        assertTrue(mining.mintingOpenFor(owner));
        _confirm(mining, owner);
        assertTrue(mining.allocationConfirmed(owner));
        assertFalse(mining.mintingOpenFor(owner));
    }

    /// The opener opens mining: the window is exactly [now, now + 15 days)
    /// and the seed is set, in one transaction.
    function test_openMining_byOpenerFixesWindowAndSeed() public {
        vm.warp(MINING_START);
        vm.expectEmit(false, false, false, false, address(mining));
        emit B20Mining.MiningOpened(MINING_START, MINING_END, bytes32(0), opener);
        vm.prank(opener);
        mining.openMining();

        assertTrue(mining.miningOpened());
        assertEq(mining.MINING_START(), MINING_START);
        assertEq(mining.MINING_END(), MINING_END);
        assertTrue(mining.miningSeed() != bytes32(0));
        (bool opened, uint256 start, uint256 end,) = mining.miningWindow();
        assertTrue(opened);
        assertEq(start, MINING_START);
        assertEq(end, MINING_END);
    }

    /// Before OPEN_DEADLINE nobody but the opener can open mining.
    function test_openMining_rejectsStrangerBeforeDeadline() public {
        vm.warp(OPEN_DEADLINE - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NotMiningOpener.selector, stranger));
        mining.openMining();
    }

    /// From OPEN_DEADLINE on anyone can open mining, so an absent opener
    /// cannot freeze the protocol.
    function test_openMining_anyoneAtDeadline() public {
        vm.warp(OPEN_DEADLINE);
        vm.prank(stranger);
        mining.openMining();
        assertEq(mining.MINING_START(), OPEN_DEADLINE);
        assertEq(mining.MINING_END(), OPEN_DEADLINE + 15 days);
    }

    /// Mining opens exactly once.
    function test_openMining_onlyOnce() public {
        _ensureOpened(mining);
        vm.prank(opener);
        vm.expectRevert(B20Mining.MiningAlreadyOpened.selector);
        mining.openMining();
    }

    /// A proof is rejected before mining is open, even with an active
    /// binding (confirmation itself needs mining open since 2 Nov 2026).
    function test_submitProof_rejectsBeforeOpening() public {
        binding.setActive(owner, minerA);

        vm.prank(minerA);
        vm.expectRevert(B20Mining.MiningNotOpened.selector);
        mining.submitProof(owner, bytes32(0), 0);
    }

    // ---------------------------------------------------------------
    // Mining window on submitProof
    // ---------------------------------------------------------------

    /// A proof is accepted exactly at MINING_START.
    function test_submitProof_acceptsAtMiningStart() public {
        _prepareForMining(mining, owner, minerA);
        assertEq(block.timestamp, MINING_START);
        bytes32 challenge = mining.challengeOf(owner);

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.acceptedProofs(owner), 1);
    }

    /// A proof is accepted one second before MINING_END.
    function test_submitProof_acceptsOneSecondBeforeMiningEnd() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        vm.warp(MINING_END - 1);

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.acceptedProofs(owner), 1);
    }

    /// A proof is rejected exactly at MINING_END.
    function test_submitProof_rejectsAtMiningEnd() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        vm.warp(MINING_END);

        vm.prank(minerA);
        vm.expectRevert(B20Mining.OutsideMiningWindow.selector);
        mining.submitProof(owner, challenge, 0);
        assertTrue(mining.miningEnded());
    }

    // ---------------------------------------------------------------
    // Allocation confirmation
    // ---------------------------------------------------------------

    /// A real production Merkle fixture confirms the base quota, before
    /// mining is open and without any mining wallet.
    function test_confirmAllocation_registersBaseQuotaWithRealFixture() public {
        _ensureOpened(mining);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);

        vm.expectEmit(true, false, false, true, address(mining));
        emit B20Mining.AllocationConfirmed(wallet, allocation * 1e18, 0, allocation * 1e18, 0);
        vm.prank(wallet);
        mining.confirmAllocation(allocation, proof);

        assertTrue(mining.allocationConfirmed(wallet));
        assertEq(mining.baseQuota(wallet), allocation * 1e18);
        assertEq(mining.totalBaseQuotaAuthorized(), allocation * 1e18);
        assertFalse(mining.mintingOpenFor(wallet));
    }

    /// A wrong wallet, wrong allocation, or wrong proof is rejected.
    function test_confirmAllocation_rejectsWrongWalletAllocationOrProof() public {
        _ensureOpened(mining);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);

        vm.prank(otherOwner);
        vm.expectRevert(B20Mining.InvalidSnapshotProof.selector);
        mining.confirmAllocation(allocation, proof);

        vm.prank(wallet);
        vm.expectRevert(B20Mining.InvalidSnapshotProof.selector);
        mining.confirmAllocation(allocation + 1, proof);

        bytes32[] memory tamperedProof = proof;
        tamperedProof[0] = tamperedProof[0] ^ bytes32(uint256(1));
        vm.prank(wallet);
        vm.expectRevert(B20Mining.InvalidSnapshotProof.selector);
        mining.confirmAllocation(allocation, tamperedProof);

        assertFalse(mining.allocationConfirmed(wallet));
        assertEq(mining.totalBaseQuotaAuthorized(), 0);
    }

    /// An allocation is confirmed exactly once.
    function test_confirmAllocation_onlyOnce() public {
        _ensureOpened(mining);
        _confirm(mining, owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.AllocationAlreadyConfirmed.selector, owner));
        mining.confirmAllocation(0, new bytes32[](0));
    }

    /// NFT quota gained after confirmation never reaches the mining
    /// contract (the real collections refuse such mints anyway).
    function test_confirmAllocation_quotaIsFrozen() public {
        _ensureOpened(mining);
        _confirm(mining, owner);
        publicMock.setQuota(owner, 50_000 * 1e18);
        eligibleMock.setBonus(owner, 1_000 * 1e18);
        assertEq(mining.nftQuota(owner), 10_000 * 1e18);
        assertEq(mining.totalNftQuotaAuthorized(), 10_000 * 1e18);
    }

    /// A Public-NFT-only owner confirms without any snapshot proof.
    function test_confirmAllocation_publicNftOnlyOwner() public {
        _ensureOpened(mining);
        _confirm(mining, owner);

        assertEq(mining.baseQuota(owner), 0);
        assertEq(mining.nftQuota(owner), 10_000 * 1e18);
    }

    /// Eligible bonus + Public quota + base quota sum correctly.
    function test_confirmAllocation_combinesBasePlusEligiblePlusPublic() public {
        _ensureOpened(mining);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        eligibleMock.setBonus(wallet, 500 * 1e18);
        publicMock.setQuota(wallet, 10_000 * 1e18);

        vm.prank(wallet);
        mining.confirmAllocation(allocation, proof);

        uint256 expectedBase = allocation * 1e18;
        uint256 expectedNft = 500 * 1e18 + 10_000 * 1e18;
        assertEq(mining.baseQuota(wallet), expectedBase);
        assertEq(mining.nftQuota(wallet), expectedNft);
        assertEq(mining.totalAuthorizedQuota(wallet), expectedBase + expectedNft);
    }

    /// A wallet holding an Eligible bonus cannot confirm without its base
    /// allocation — that would silently forfeit it.
    function test_confirmAllocation_eligibleHolderMustSupplyBase() public {
        _ensureOpened(mining);
        (address wallet,,) = _loadFixture(0);
        eligibleMock.setBonus(wallet, 500 * 1e18);

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.MissingBaseAllocation.selector, wallet));
        mining.confirmAllocation(0, new bytes32[](0));
    }

    /// Confirmation also works while mining runs, and closes at MINING_END.
    function test_confirmAllocation_openUntilMiningEnd() public {
        _ensureOpened(mining);
        vm.warp(MINING_END - 1);
        _confirm(mining, owner);
        assertTrue(mining.allocationConfirmed(owner));

        vm.warp(MINING_END);
        vm.prank(otherOwner);
        vm.expectRevert(B20Mining.AllocationClosed.selector);
        mining.confirmAllocation(0, new bytes32[](0));
        assertFalse(mining.mintingOpenFor(otherOwner));
    }

    /// NFT global reserve cap cannot be exceeded.
    ///
    /// The base quota cap (60,000,000,000 * 1e18) cannot be exercised the
    /// same way: baseQuota only ever comes from a real, Merkle-verified
    /// snapshot allocation, and the real snapshot's largest wallet
    /// allocation is ~190,736 whole tokens, many orders of magnitude below
    /// the cap. The shared over-cap-reverts code path is confirmed via the
    /// NFT cap below and via `test_baseQuotaCap_hasExpectedValue`.
    function test_confirmAllocation_rejectsNftQuotaCapExceeded() public {
        _ensureOpened(mining);
        uint256 cap = mining.NFT_QUOTA_CAP();
        uint256 tooMuch = cap + 1;
        publicMock.setQuota(owner, tooMuch);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NftQuotaCapExceeded.selector, tooMuch, cap));
        mining.confirmAllocation(0, new bytes32[](0));
    }

    function test_baseQuotaCap_hasExpectedValue() public view {
        assertEq(mining.BASE_QUOTA_CAP(), 60_000_000_000 * 1e18);
        assertEq(mining.NFT_QUOTA_CAP(), 1_000_000_000 * 1e18);
    }

    /// An owner with no snapshot and no NFT quota is rejected.
    function test_confirmAllocation_rejectsOwnerWithNoAuthorizedQuota() public {
        _ensureOpened(mining);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NoAuthorizedQuota.selector, stranger));
        mining.confirmAllocation(0, new bytes32[](0));
        assertFalse(mining.allocationConfirmed(stranger));
    }

    // ---------------------------------------------------------------
    // Rotation preserves quota and challenge state together
    // ---------------------------------------------------------------

    function test_rotation_doesNotResetQuotaOrChallenge() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        uint256 quotaBefore = mining.totalAuthorizedQuota(owner);
        bytes32 challengeBefore = mining.challengeOf(owner);
        uint256 countBefore = mining.acceptedProofs(owner);

        binding.setActive(owner, minerB); // rotation

        assertEq(mining.totalAuthorizedQuota(owner), quotaBefore);
        assertEq(mining.challengeOf(owner), challengeBefore);
        assertEq(mining.acceptedProofs(owner), countBefore);

        _submitProof(mining, minerB, owner, challengeBefore, 0, DEFAULT_MINING_FEE);
        assertEq(mining.acceptedProofs(owner), countBefore + 1);
    }

    /// An owner without a confirmed allocation cannot submit a proof.
    function test_submitProof_rejectsOwnerWithoutConfirmedAllocation() public {
        binding.setActive(stranger, minerA);
        _ensureOpened(mining);

        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NoAuthorizedQuota.selector, stranger));
        mining.submitProof(stranger, bytes32(0), 0);
    }

    // ---------------------------------------------------------------

    /// Initial challenge for an owner is deterministic and non-zero (once
    /// the global seed exists).
    function test_challengeOf_initialIsDeterministicAndNonZero() public {
        _ensureOpened(mining);

        bytes32 first = mining.challengeOf(owner);
        bytes32 second = mining.challengeOf(owner);
        assertEq(first, second);
        assertTrue(first != bytes32(0));
    }

    /// Different owners get different initial challenges.
    function test_challengeOf_differsAcrossOwners() public {
        _ensureOpened(mining);
        assertTrue(mining.challengeOf(owner) != mining.challengeOf(otherOwner));
    }

    /// A mining wallet with no active binding cannot submit a proof.
    function test_submitProof_rejectsInactiveBinding() public {
        _ensureOpened(mining);
        // owner has quota synced but minerA is not bound to it.
        binding.setActive(owner, minerB);
        vm.prank(owner);
        mining.confirmAllocation(0, new bytes32[](0));
        bytes32 challenge = mining.challengeOf(owner);

        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.InactiveBinding.selector, owner, minerA));
        mining.submitProof(owner, challenge, 0);
    }

    /// An actively bound mining wallet with synced quota can submit a
    /// valid proof.
    function test_submitProof_activeWalletSucceeds() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.acceptedProofs(owner), 1);
    }

    /// A successful proof increments the counter and changes the
    /// challenge.
    function test_submitProof_incrementsCounterAndChangesChallenge() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 before = mining.challengeOf(owner);
        assertEq(mining.acceptedProofs(owner), 0);

        _submitProof(mining, minerA, owner, before, 0, DEFAULT_MINING_FEE);

        assertEq(mining.acceptedProofs(owner), 1);
        assertTrue(mining.challengeOf(owner) != before);
    }

    /// Submitting the same expectedChallenge a second time is rejected
    /// with StaleChallenge, even though it was valid the first time.
    function test_submitProof_rejectsStaleChallengeOnReplay() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        bytes32 newChallenge = mining.challengeOf(owner);
        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.StaleChallenge.selector, challenge, newChallenge));
        mining.submitProof{value: DEFAULT_MINING_FEE}(owner, challenge, 1);
    }

    /// An invalid proof (fails B20PoW.isValid) does not change state.
    function test_submitProof_invalidProofDoesNotChangeState() public {
        _prepareForMining(strictMining, owner, minerA);
        bytes32 challenge = strictMining.challengeOf(owner);
        uint256 countBefore = strictMining.acceptedProofs(owner);

        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.InvalidProof.selector, owner, minerA, challenge, uint256(0)));
        strictMining.submitProof(owner, challenge, 0);

        assertEq(strictMining.acceptedProofs(owner), countBefore);
        assertEq(strictMining.challengeOf(owner), challenge);
    }

    /// After binding rotation, the old mining wallet is rejected.
    function test_rotation_oldMiningWalletRejectedAfterRotation() public {
        _prepareForMining(mining, owner, minerA);
        binding.setActive(owner, minerB); // rotation: minerB is now active
        bytes32 challenge = mining.challengeOf(owner);

        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.InactiveBinding.selector, owner, minerA));
        mining.submitProof(owner, challenge, 0);
    }

    /// Rotation does not reset the owner's challenge or accepted-proof
    /// count.
    function test_rotation_doesNotResetChallengeOrCount() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        bytes32 challengeAfterProof = mining.challengeOf(owner);
        uint256 countAfterProof = mining.acceptedProofs(owner);

        binding.setActive(owner, minerB); // rotation

        assertEq(mining.challengeOf(owner), challengeAfterProof);
        assertEq(mining.acceptedProofs(owner), countAfterProof);
    }

    /// The new active mining wallet sees the same owner challenge and can
    /// submit its own proof for it (using its own address).
    function test_rotation_newWalletCanSubmitAgainstSameChallenge() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        binding.setActive(owner, minerB);
        bytes32 challengeForMinerB = mining.challengeOf(owner);

        _submitProof(mining, minerB, owner, challengeForMinerB, 0, DEFAULT_MINING_FEE);

        assertEq(mining.acceptedProofs(owner), 2);
    }

    /// One owner's proof does not change another owner's state.
    function test_submitProof_doesNotAffectOtherOwnerState() public {
        _prepareForMining(mining, owner, minerA);
        _ensureOpened(mining);
        bytes32 otherChallengeBefore = mining.challengeOf(otherOwner);
        uint256 otherCountBefore = mining.acceptedProofs(otherOwner);
        bytes32 challenge = mining.challengeOf(owner);

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.challengeOf(otherOwner), otherChallengeBefore);
        assertEq(mining.acceptedProofs(otherOwner), otherCountBefore);
    }

    /// The contract does not accept ETH directly.
    function test_receive_directETHTransferIsRejected() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(mining).call{value: 1 ether}("");
        assertFalse(success);
    }

    /// The existing ProofAccepted event fields are still emitted
    /// correctly (as the first event of the two now emitted per proof).
    function test_submitProof_emitsCorrectEventFields() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        uint256 nonce = 42;

        bytes32 expectedProofHash = B20PoW.computeHash(block.chainid, address(mining), owner, minerA, challenge, nonce);
        bytes32 expectedNewChallenge = keccak256(
            abi.encodePacked(
                "B20_NEXT_CHALLENGE_V1",
                challenge,
                expectedProofHash,
                owner,
                minerA,
                uint256(1),
                block.chainid,
                address(mining),
                block.prevrandao,
                block.number
            )
        );

        vm.expectEmit(true, true, false, true, address(mining));
        emit B20Mining.ProofAccepted(owner, minerA, challenge, nonce, expectedProofHash, expectedNewChallenge, 1);

        _submitProof(mining, minerA, owner, challenge, nonce, DEFAULT_MINING_FEE);
    }

    // ---------------------------------------------------------------
    // Mining-fee collection and refund (new)
    // ---------------------------------------------------------------

    /// 2. A successful proof forwards exactly the mining fee to
    /// liquidityVault and leaves no ETH in the mining contract.
    function test_submitProof_forwardsFeeToVaultAndLeavesNoBalance() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);

        uint256 vaultBalanceBefore = address(liquidityVault).balance;

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(address(liquidityVault).balance, vaultBalanceBefore + DEFAULT_MINING_FEE);
        assertEq(address(mining).balance, 0);
        assertEq(mining.totalMiningFeesForwarded(), DEFAULT_MINING_FEE);
    }

    /// 3. Excess msg.value is refunded exactly, leaving the miner's net
    /// cost equal to the mining fee.
    function test_submitProof_refundsExcessValue() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);

        uint256 overpay = 1 ether;
        uint256 minerBalanceBefore = minerA.balance;

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE + overpay);

        assertEq(minerA.balance, minerBalanceBefore - DEFAULT_MINING_FEE);
        assertEq(address(liquidityVault).balance, DEFAULT_MINING_FEE);
        assertEq(address(mining).balance, 0);
    }

    /// 4. Insufficient msg.value reverts without changing any state.
    function test_submitProof_insufficientValueRevertsWithoutStateChange() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);

        bytes32 challengeBefore = mining.challengeOf(owner);
        uint256 countBefore = mining.acceptedProofs(owner);
        uint256 vaultBalanceBefore = address(liquidityVault).balance;
        uint256 minedLockedBefore = mining.minedLocked(owner);

        vm.prank(minerA);
        vm.expectRevert(
            abi.encodeWithSelector(B20Mining.InsufficientMiningFee.selector, DEFAULT_MINING_FEE - 1, DEFAULT_MINING_FEE)
        );
        mining.submitProof{value: DEFAULT_MINING_FEE - 1}(owner, challenge, 0);

        assertEq(mining.challengeOf(owner), challengeBefore);
        assertEq(mining.acceptedProofs(owner), countBefore);
        assertEq(address(liquidityVault).balance, vaultBalanceBefore);
        assertEq(mining.minedLocked(owner), minedLockedBefore);
    }

    /// The fixed economics constants: 312.5 MINER per proof, priced at
    /// 12,000,000 MINER per ETH, fee rounded up to the wei.
    function test_economicsConstants() public view {
        assertEq(mining.MINER_PER_ETH(), 12_000_000);
        assertEq(mining.REWARD_PER_PROOF(), DEFAULT_REWARD);
        assertEq(mining.MINING_FEE_PER_PROOF(), DEFAULT_MINING_FEE);
        // 312.5e18 / 12e6 = 26,041,666,666,666.67 → rounded up.
        assertEq(mining.miningFeeFor(DEFAULT_REWARD), DEFAULT_MINING_FEE);
        assertEq(mining.miningFeeFor(12_000_000), 1);
        assertEq(mining.miningFeeFor(12_000_001), 2);
        assertEq(mining.miningFeeFor(0), 0);
    }

    /// `quoteProof` reports the full fixed reward and fee while quota
    /// remains, the capped amount on the last proof, and zero afterwards.
    function test_quoteProof_fullCappedAndExhausted() public {
        _prepareForMining(mining, owner, minerA); // 10,000 MINER NFT quota
        (uint256 reward, uint256 fee) = mining.quoteProof(owner);
        assertEq(reward, DEFAULT_REWARD);
        assertEq(fee, DEFAULT_MINING_FEE);

        (reward, fee) = mining.quoteProof(stranger); // no quota
        assertEq(reward, 0);
        assertEq(fee, 0);

        publicMock.setQuota(otherOwner, 100e18); // below one full proof
        _prepareForMining(mining, otherOwner, minerB);
        (reward, fee) = mining.quoteProof(otherOwner);
        assertEq(reward, 100e18);
        assertEq(fee, mining.miningFeeFor(100e18));
    }

    /// A 50,000 MINER quota is mined in exactly 160 proofs, and the fees
    /// forwarded to the liquidity vault total 160 × the per-proof fee —
    /// the 50,000 MINER ≈ 0.0041667 ETH target of B20_REVENUE_MODEL.md §2.1.
    function test_fiftyThousandMinerQuotaIsExactly160Proofs() public {
        publicMock.setQuota(owner, 50_000e18);
        _prepareForMining(mining, owner, minerA);

        for (uint256 i = 0; i < 160; i++) {
            bytes32 challenge = mining.challengeOf(owner);
            _submitProof(mining, minerA, owner, challenge, i, DEFAULT_MINING_FEE);
        }

        assertEq(mining.minedLocked(owner), 50_000e18);
        assertEq(mining.remainingQuota(owner), 0);
        assertEq(mining.acceptedProofs(owner), 160);
        assertEq(address(liquidityVault).balance, 160 * DEFAULT_MINING_FEE);
        assertEq(mining.totalMiningFeesForwarded(), 160 * DEFAULT_MINING_FEE);
        // Within 160 wei of the exact 50,000 / 12,000,000 ETH.
        assertApproxEqAbs(160 * DEFAULT_MINING_FEE, uint256(50_000e18) / 12_000_000, 160);
    }

    /// 5. If the liquidity vault rejects the transfer, the whole
    /// transaction reverts — no partial state change.
    function test_submitProof_revertsFullyIfLiquidityTransferFails() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        liquidityVault.setAccepts(false);

        bytes32 challengeBefore = mining.challengeOf(owner);
        uint256 countBefore = mining.acceptedProofs(owner);
        uint256 minerBalanceBefore = minerA.balance;

        vm.prank(minerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20Mining.LiquidityTransferFailed.selector, address(liquidityVault), DEFAULT_MINING_FEE
            )
        );
        mining.submitProof{value: DEFAULT_MINING_FEE}(owner, challenge, 0);

        assertEq(mining.challengeOf(owner), challengeBefore);
        assertEq(mining.acceptedProofs(owner), countBefore);
        assertEq(address(liquidityVault).balance, 0);
        assertEq(minerA.balance, minerBalanceBefore);
    }

    /// 6. If the refund transfer fails, the whole transaction reverts —
    /// including the fee transfer that would otherwise have succeeded.
    function test_submitProof_revertsFullyIfRefundFails() public {
        MockRejectingMiner rejectingMiner = new MockRejectingMiner();
        vm.deal(address(rejectingMiner), 10 ether);
        _prepareForMining(mining, owner, address(rejectingMiner));
        bytes32 challenge = mining.challengeOf(owner);
        rejectingMiner.setAccepts(false);

        uint256 overpay = 1 ether;
        uint256 countBefore = mining.acceptedProofs(owner);

        vm.prank(address(rejectingMiner));
        vm.expectRevert(abi.encodeWithSelector(B20Mining.RefundFailed.selector, address(rejectingMiner), overpay));
        mining.submitProof{value: DEFAULT_MINING_FEE + overpay}(owner, challenge, 0);

        assertEq(mining.acceptedProofs(owner), countBefore);
        assertEq(address(liquidityVault).balance, 0);
        assertEq(mining.minedLocked(owner), 0);
    }

    // ---------------------------------------------------------------
    // Reward formula and NFT-first quota consumption (new)
    // ---------------------------------------------------------------

    /// 7. Every accepted proof credits the fixed `REWARD_PER_PROOF`
    /// (312.5 MINER token units, no extra 1e18 scaling) and it is emitted
    /// correctly in `ProofRewarded`.
    function test_submitProof_fixedRewardPerProof() public {
        _prepareForMining(mining, owner, minerA); // owner has 10_000e18 NFT quota
        bytes32 challenge = mining.challengeOf(owner);

        uint256 expectedReward = mining.REWARD_PER_PROOF();
        assertEq(expectedReward, DEFAULT_REWARD);

        bytes32 expectedProofHash = B20PoW.computeHash(block.chainid, address(mining), owner, minerA, challenge, 0);
        bytes32 expectedNewChallenge = keccak256(
            abi.encodePacked(
                "B20_NEXT_CHALLENGE_V1",
                challenge,
                expectedProofHash,
                owner,
                minerA,
                uint256(1),
                block.chainid,
                address(mining),
                block.prevrandao,
                block.number
            )
        );

        vm.expectEmit(true, true, false, true, address(mining));
        emit B20Mining.ProofRewarded(
            owner,
            minerA,
            expectedReward,
            expectedReward, // fully from NFT quota (ample headroom)
            0,
            DEFAULT_MINING_FEE,
            0,
            expectedReward,
            10_000 * 1e18 - expectedReward,
            expectedNewChallenge
        );

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.nftMinedLocked(owner), expectedReward);
        assertEq(mining.baseMinedLocked(owner), 0);
    }

    /// 8. NFT-only quota consumption: with ample NFT quota and no base
    /// quota synced, the entire reward is drawn from NFT quota.
    function test_submitProof_nftOnlyQuotaConsumption() public {
        _prepareForMining(mining, otherOwner, minerA); // otherOwner: 10_000e18 NFT, 0 base
        bytes32 challenge = mining.challengeOf(otherOwner);

        _submitProof(mining, minerA, otherOwner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.nftMinedLocked(otherOwner), DEFAULT_REWARD);
        assertEq(mining.baseMinedLocked(otherOwner), 0);
        assertEq(mining.remainingNftQuota(otherOwner), 10_000 * 1e18 - DEFAULT_REWARD);
        assertEq(mining.remainingBaseQuota(otherOwner), 0);
    }

    /// 9. Base-only quota consumption: an owner with only a snapshot
    /// allocation (no NFT quota) has the entire reward drawn from base
    /// quota.
    function test_submitProof_baseOnlyQuotaConsumption() public {
        _ensureOpened(mining);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        binding.setActive(wallet, minerA);
        vm.prank(wallet);
        mining.confirmAllocation(allocation, proof);
        assertEq(mining.nftQuota(wallet), 0);

        _ensureOpened(mining);
        bytes32 challenge = mining.challengeOf(wallet);

        _submitProof(mining, minerA, wallet, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.baseMinedLocked(wallet), DEFAULT_REWARD);
        assertEq(mining.nftMinedLocked(wallet), 0);
    }

    /// 10. Mixed quota: NFT is consumed first, leaving base quota
    /// completely untouched while NFT has enough headroom on its own.
    function test_submitProof_nftFirstConsumptionOrder() public {
        _ensureOpened(mining);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        publicMock.setQuota(wallet, 10_000 * 1e18); // ample NFT headroom
        binding.setActive(wallet, minerA);
        vm.prank(wallet);
        mining.confirmAllocation(allocation, proof);

        _ensureOpened(mining);
        bytes32 challenge = mining.challengeOf(wallet);

        uint256 baseQuotaBefore = mining.baseQuota(wallet);

        _submitProof(mining, minerA, wallet, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.nftMinedLocked(wallet), DEFAULT_REWARD);
        assertEq(mining.baseMinedLocked(wallet), 0);
        assertEq(mining.baseQuota(wallet), baseQuotaBefore); // base quota itself untouched
    }

    /// 11. When NFT quota is smaller than the reward, it is fully
    /// exhausted and the remainder of the *same* proof's reward is drawn
    /// from base quota.
    function test_submitProof_nftExhaustionSpillsIntoBase() public {
        _ensureOpened(mining);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        uint256 smallNft = 10 * 1e18; // less than DEFAULT_REWARD (312.5e18)
        publicMock.setQuota(wallet, smallNft);
        binding.setActive(wallet, minerA);
        vm.prank(wallet);
        mining.confirmAllocation(allocation, proof);

        _ensureOpened(mining);
        bytes32 challenge = mining.challengeOf(wallet);

        _submitProof(mining, minerA, wallet, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.nftMinedLocked(wallet), smallNft);
        assertEq(mining.baseMinedLocked(wallet), DEFAULT_REWARD - smallNft);
        assertEq(mining.remainingNftQuota(wallet), 0);
    }

    /// 12. When total remaining quota is smaller than the fixed reward,
    /// the reward is capped to the remaining quota and the mining fee
    /// follows the capped reward (every MINER is priced the same); the
    /// rest of `msg.value` is refunded.
    function test_submitProof_lastProofCapsRewardAndFee() public {
        uint256 tinyNft = 5 * 1e18; // less than DEFAULT_REWARD (312.5e18)
        publicMock.setQuota(owner, tinyNft);
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);

        uint256 cappedFee = mining.miningFeeFor(tinyNft);
        assertLt(cappedFee, DEFAULT_MINING_FEE);
        uint256 vaultBalanceBefore = address(liquidityVault).balance;
        uint256 minerBalanceBefore = minerA.balance;

        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.nftMinedLocked(owner), tinyNft);
        assertEq(mining.baseMinedLocked(owner), 0);
        assertEq(mining.remainingQuota(owner), 0);
        assertEq(address(liquidityVault).balance, vaultBalanceBefore + cappedFee);
        assertEq(minerA.balance, minerBalanceBefore - cappedFee);
        assertEq(address(mining).balance, 0);
    }

    /// 13. Once quota is fully exhausted, a further proof is rejected
    /// and no fee/state change occurs.
    function test_submitProof_rejectsWhenQuotaExhausted() public {
        uint256 tinyNft = 5 * 1e18;
        publicMock.setQuota(owner, tinyNft);
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);
        assertEq(mining.remainingQuota(owner), 0);

        uint256 vaultBalanceBefore = address(liquidityVault).balance;
        uint256 countBefore = mining.acceptedProofs(owner);

        bytes32 challengeAfterExhaustion = mining.challengeOf(owner);
        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.NoAuthorizedQuota.selector, owner));
        mining.submitProof{value: DEFAULT_MINING_FEE}(owner, challengeAfterExhaustion, 0);

        assertEq(address(liquidityVault).balance, vaultBalanceBefore);
        assertEq(mining.acceptedProofs(owner), countBefore);
    }

    /// 14. Global base/NFT mined counters correctly sum across owners.
    function test_submitProof_globalMinedCountersStayCorrect() public {
        _prepareForMining(mining, owner, minerA); // NFT-only path

        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        binding.setActive(wallet, minerB);
        vm.prank(wallet);
        mining.confirmAllocation(allocation, proof); // base-only path

        bytes32 ownerChallenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, ownerChallenge, 0, DEFAULT_MINING_FEE);

        bytes32 walletChallenge = mining.challengeOf(wallet);
        _submitProof(mining, minerB, wallet, walletChallenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.totalNftMinedLocked(), mining.nftMinedLocked(owner));
        assertEq(mining.totalBaseMinedLocked(), mining.baseMinedLocked(wallet));
        assertEq(mining.totalNftMinedLocked(), DEFAULT_REWARD);
        assertEq(mining.totalBaseMinedLocked(), DEFAULT_REWARD);
    }

    /// 15. `minedLocked + remainingQuota == totalAuthorizedQuota` holds
    /// after a proof.
    function test_invariant_minedLockedPlusRemainingEqualsTotalAuthorized() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        assertEq(mining.minedLocked(owner) + mining.remainingQuota(owner), mining.totalAuthorizedQuota(owner));
    }

    /// 16. NFT quota gained after mining has started changes nothing:
    /// the allocation was frozen at confirmation.
    function test_confirmedAllocation_ignoresLaterNftQuota() public {
        _prepareForMining(mining, owner, minerA); // 10_000e18 NFT quota
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        uint256 remainingBefore = mining.remainingNftQuota(owner);
        publicMock.setQuota(owner, 20_000 * 1e18);

        assertEq(mining.remainingNftQuota(owner), remainingBefore);
        assertEq(mining.nftQuota(owner), 10_000 * 1e18);
    }

    /// 17. Rotation does not reset or duplicate an owner's reward/quota
    /// accounting; mining continues accumulating under the new wallet.
    function test_rotation_doesNotResetRewardAccounting() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        uint256 minedLockedBefore = mining.minedLocked(owner);
        uint256 remainingBefore = mining.remainingQuota(owner);

        binding.setActive(owner, minerB); // rotation

        assertEq(mining.minedLocked(owner), minedLockedBefore);
        assertEq(mining.remainingQuota(owner), remainingBefore);

        bytes32 challengeAfterRotation = mining.challengeOf(owner);
        _submitProof(mining, minerB, owner, challengeAfterRotation, 0, DEFAULT_MINING_FEE);

        assertEq(mining.minedLocked(owner), minedLockedBefore + DEFAULT_REWARD);
    }

    /// 18. An invalid/stale proof produces no protocol fee and no
    /// reward — full revert, nothing forwarded or locked.
    function test_submitProof_invalidProofProducesNoFeeOrReward() public {
        _prepareForMining(mining, owner, minerA);
        bytes32 challenge = mining.challengeOf(owner);
        _submitProof(mining, minerA, owner, challenge, 0, DEFAULT_MINING_FEE);

        uint256 vaultBalanceBefore = address(liquidityVault).balance;
        uint256 minedLockedBefore = mining.minedLocked(owner);
        uint256 countBefore = mining.acceptedProofs(owner);

        // Replaying the now-stale challenge.
        bytes32 currentChallenge = mining.challengeOf(owner);
        vm.prank(minerA);
        vm.expectRevert(abi.encodeWithSelector(B20Mining.StaleChallenge.selector, challenge, currentChallenge));
        mining.submitProof{value: DEFAULT_MINING_FEE}(owner, challenge, 1);

        assertEq(address(liquidityVault).balance, vaultBalanceBefore);
        assertEq(mining.minedLocked(owner), minedLockedBefore);
        assertEq(mining.acceptedProofs(owner), countBefore);
        assertEq(mining.totalMiningFeesForwarded(), DEFAULT_MINING_FEE); // only the first, valid proof's fee
    }

    /// 19. A reentrant call into `submitProof`, attempted from the
    /// refund callback, is blocked by `nonReentrant` and does not process
    /// a second proof.
    function test_submitProof_reentrancyIsBlocked() public {
        ReentrantMiner attacker = new ReentrantMiner();
        vm.deal(address(attacker), 10 ether);
        attacker.configure(mining, owner);

        _prepareForMining(mining, owner, address(attacker));
        bytes32 challenge = mining.challengeOf(owner);

        uint256 overpay = 1 ether;
        vm.prank(address(attacker));
        mining.submitProof{value: DEFAULT_MINING_FEE + overpay}(owner, challenge, 0);

        assertEq(attacker.reentryAttempts(), 1);
        assertTrue(attacker.reentryReverted());
        assertEq(mining.acceptedProofs(owner), 1);
        assertEq(mining.nftMinedLocked(owner), DEFAULT_REWARD);
    }
}
