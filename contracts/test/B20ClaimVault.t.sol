// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {B20ClaimVault} from "../src/B20ClaimVault.sol";
import {IB20MiningClaims} from "../src/interfaces/IB20MiningClaims.sol";
import {IB20FinalizationStatus} from "../src/interfaces/IB20FinalizationStatus.sol";

/// @notice Test-only ERC20Burnable standing in for the production native B20
/// Asset's ERC-20-compatible transfer and role-authorized burn surface —
/// only what these tests need: an unrestricted mint at construction and
/// standard transfer/burn from OpenZeppelin.
contract MockMinerToken is ERC20, ERC20Burnable {
    constructor() ERC20("Mock MINER", "MMINER") {
        _mint(msg.sender, 1_000_000_000_000 * 1e18);
    }
}

/// @notice Minimal, directly settable mock of the subset of B20Mining
/// that B20ClaimVault reads. Lets tests set per-owner locked amounts and
/// the global totals independently, and set mismatched caps for the
/// constructor-validation tests.
contract MockMining is IB20MiningClaims {
    uint256 public miningEndValue;
    uint256 public baseCap = 60_000_000_000 * 1e18;
    uint256 public nftCap = 1_000_000_000 * 1e18;

    mapping(address ownerWallet => uint256 amount) public baseLocked;
    mapping(address ownerWallet => uint256 amount) public nftLocked;
    uint256 public totalBaseLocked;
    uint256 public totalNftLocked;

    constructor(uint256 miningEndValue_) {
        miningEndValue = miningEndValue_;
    }

    function setCaps(uint256 base_, uint256 nft_) external {
        baseCap = base_;
        nftCap = nft_;
    }

    /// @dev Sets `ownerWallet`'s locked amounts and keeps the global
    /// totals consistent (replaces, not adds).
    function setLocked(address ownerWallet, uint256 base_, uint256 nft_) external {
        totalBaseLocked = totalBaseLocked - baseLocked[ownerWallet] + base_;
        totalNftLocked = totalNftLocked - nftLocked[ownerWallet] + nft_;
        baseLocked[ownerWallet] = base_;
        nftLocked[ownerWallet] = nft_;
    }

    function MINING_END() external view returns (uint256) {
        return miningEndValue;
    }

    function BASE_QUOTA_CAP() external view returns (uint256) {
        return baseCap;
    }

    function NFT_QUOTA_CAP() external view returns (uint256) {
        return nftCap;
    }

    function baseMinedLocked(address ownerWallet) external view returns (uint256) {
        return baseLocked[ownerWallet];
    }

    function nftMinedLocked(address ownerWallet) external view returns (uint256) {
        return nftLocked[ownerWallet];
    }

    function totalBaseMinedLocked() external view returns (uint256) {
        return totalBaseLocked;
    }

    function totalNftMinedLocked() external view returns (uint256) {
        return totalNftLocked;
    }
}

/// @notice Minimal, directly settable mock of B20LiquidityFinalizer's
/// `finalized()` flag.
contract MockFinalizer is IB20FinalizationStatus {
    bool public finalizedValue;

    function setFinalized(bool value) external {
        finalizedValue = value;
    }

    function finalized() external view returns (bool) {
        return finalizedValue;
    }
}

/// @notice Critical targeted tests for B20ClaimVault only. Not a full
/// suite, not fuzz/invariant. `B20LiquidityFinalizer` does not exist yet
/// — `MockFinalizer` stands in for it, and `finalizeReserves()` is
/// exercised via `vm.prank(address(finalizer))`, exactly as a real
/// finalizer contract calling it from inside its own `finalize()` would
/// appear on-chain (same `msg.sender`).
contract B20ClaimVaultTest is Test {
    uint256 internal constant MINING_END = 1_800_000_000;
    uint256 internal constant CLAIM_PERIOD = 15 days;
    uint256 internal constant BASE_RESERVE = 60_000_000_000 * 1e18;
    uint256 internal constant NFT_RESERVE = 1_000_000_000 * 1e18;
    uint256 internal constant TOTAL_RESERVE = BASE_RESERVE + NFT_RESERVE;

    MockMinerToken internal token;
    MockMining internal mining;
    MockFinalizer internal finalizer;
    B20ClaimVault internal vault;

    address internal owner1 = makeAddr("owner1");
    address internal owner2 = makeAddr("owner2");
    address internal minerWallet = makeAddr("minerWallet");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        token = new MockMinerToken();
        mining = new MockMining(MINING_END);
        finalizer = new MockFinalizer();
        vault = new B20ClaimVault(address(token), address(mining), address(finalizer));
    }

    function _fundVault(uint256 amount) internal {
        token.transfer(address(vault), amount);
    }

    function _finalizeReserves() internal {
        vm.warp(MINING_END);
        vm.prank(address(finalizer));
        vault.finalizeReserves();
    }

    // ---------------------------------------------------------------
    // 1. Constructor rejects zero / no-code addresses
    // ---------------------------------------------------------------

    /// 15 days everywhere but Base Sepolia, where it is 1 day like the mining window.
    function test_claimPeriod_isFifteenDaysExceptOnBaseSepolia() public {
        assertEq(vault.CLAIM_PERIOD(), 15 days);
        vm.chainId(8_453);
        assertEq(new B20ClaimVault(address(token), address(mining), address(finalizer)).CLAIM_PERIOD(), 15 days);
        vm.chainId(84_532);
        B20ClaimVault short = new B20ClaimVault(address(token), address(mining), address(finalizer));
        assertEq(short.CLAIM_PERIOD(), 1 days);
        assertEq(short.claimDeadline(), mining.MINING_END() + 1 days);
    }

    function test_constructor_rejectsZeroMinerToken() public {
        vm.expectRevert(B20ClaimVault.ZeroMinerToken.selector);
        new B20ClaimVault(address(0), address(mining), address(finalizer));
    }

    function test_constructor_rejectsMinerTokenWithNoCode() public {
        address eoa = makeAddr("eoaMinerToken");
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.MinerTokenHasNoCode.selector, eoa));
        new B20ClaimVault(eoa, address(mining), address(finalizer));
    }

    function test_constructor_rejectsZeroMining() public {
        vm.expectRevert(B20ClaimVault.ZeroMining.selector);
        new B20ClaimVault(address(token), address(0), address(finalizer));
    }

    function test_constructor_rejectsMiningWithNoCode() public {
        address eoa = makeAddr("eoaMining");
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.MiningHasNoCode.selector, eoa));
        new B20ClaimVault(address(token), eoa, address(finalizer));
    }

    function test_constructor_rejectsZeroFinalizer() public {
        vm.expectRevert(B20ClaimVault.ZeroFinalizer.selector);
        new B20ClaimVault(address(token), address(mining), address(0));
    }

    function test_constructor_rejectsFinalizerWithNoCode() public {
        address eoa = makeAddr("eoaFinalizer");
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.FinalizerHasNoCode.selector, eoa));
        new B20ClaimVault(address(token), address(mining), eoa);
    }

    // ---------------------------------------------------------------
    // 2. Mining cap mismatch is rejected
    // ---------------------------------------------------------------

    function test_constructor_rejectsBaseQuotaCapMismatch() public {
        MockMining badMining = new MockMining(MINING_END);
        badMining.setCaps(BASE_RESERVE - 1, NFT_RESERVE);

        vm.expectRevert(
            abi.encodeWithSelector(B20ClaimVault.BaseQuotaCapMismatch.selector, BASE_RESERVE - 1, BASE_RESERVE)
        );
        new B20ClaimVault(address(token), address(badMining), address(finalizer));
    }

    function test_constructor_rejectsNftQuotaCapMismatch() public {
        MockMining badMining = new MockMining(MINING_END);
        badMining.setCaps(BASE_RESERVE, NFT_RESERVE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(B20ClaimVault.NftQuotaCapMismatch.selector, NFT_RESERVE + 1, NFT_RESERVE)
        );
        new B20ClaimVault(address(token), address(badMining), address(finalizer));
    }

    // ---------------------------------------------------------------
    // 3. Only the finalizer may call finalizeReserves()
    // ---------------------------------------------------------------

    function test_finalizeReserves_rejectsNonFinalizerCaller() public {
        _fundVault(TOTAL_RESERVE);
        vm.warp(MINING_END);

        vm.prank(stranger);
        vm.expectRevert(B20ClaimVault.NotFinalizer.selector);
        vault.finalizeReserves();

        assertFalse(vault.reservesFinalized());
    }

    // ---------------------------------------------------------------
    // 4. finalizeReserves() rejects before MINING_END
    // ---------------------------------------------------------------

    function test_finalizeReserves_rejectsBeforeMiningEnd() public {
        _fundVault(TOTAL_RESERVE);

        vm.prank(address(finalizer));
        vm.expectRevert(B20ClaimVault.TooEarly.selector);
        vault.finalizeReserves();

        assertFalse(vault.reservesFinalized());
    }

    // ---------------------------------------------------------------
    // 5. Insufficient funding is rejected, state unchanged
    // ---------------------------------------------------------------

    function test_finalizeReserves_rejectsInsufficientFunding() public {
        _fundVault(TOTAL_RESERVE - 1);
        vm.warp(MINING_END);

        vm.prank(address(finalizer));
        vm.expectRevert(
            abi.encodeWithSelector(B20ClaimVault.InsufficientFunding.selector, TOTAL_RESERVE - 1, TOTAL_RESERVE)
        );
        vault.finalizeReserves();

        assertFalse(vault.reservesFinalized());
        assertEq(vault.baseReserveRemaining(), 0);
        assertEq(vault.nftReserveRemaining(), 0);
        assertEq(token.balanceOf(address(vault)), TOTAL_RESERVE - 1);
    }

    // ---------------------------------------------------------------
    // 6. Successful finalization burns the correct unmined amounts
    //    separately and leaves the correct liability
    // ---------------------------------------------------------------

    function test_finalizeReserves_burnsUnminedAmountsSeparatelyAndSetsLiability() public {
        uint256 minedBase = 10_000 * 1e18;
        uint256 minedNft = 2_000 * 1e18;
        mining.setLocked(owner1, minedBase, minedNft);
        _fundVault(TOTAL_RESERVE);

        uint256 expectedUnminedBase = BASE_RESERVE - minedBase;
        uint256 expectedUnminedNft = NFT_RESERVE - minedNft;
        uint256 supplyBefore = token.totalSupply();

        vm.warp(MINING_END);
        vm.expectEmit(true, true, true, true, address(vault));
        emit B20ClaimVault.ReservesFinalized(expectedUnminedBase, expectedUnminedNft, minedBase, minedNft);
        vm.prank(address(finalizer));
        vault.finalizeReserves();

        assertTrue(vault.reservesFinalized());
        assertEq(vault.baseReserveRemaining(), minedBase);
        assertEq(vault.nftReserveRemaining(), minedNft);
        assertEq(token.totalSupply(), supplyBefore - expectedUnminedBase - expectedUnminedNft);
        assertEq(token.balanceOf(address(vault)), minedBase + minedNft);
    }

    // ---------------------------------------------------------------
    // 7. Excess/donated MINER is not folded into the official burn
    // ---------------------------------------------------------------

    function test_finalizeReserves_excessDonationNotBurned() public {
        uint256 minedBase = 500 * 1e18;
        uint256 minedNft = 100 * 1e18;
        mining.setLocked(owner1, minedBase, minedNft);

        uint256 donation = 777 * 1e18;
        _fundVault(TOTAL_RESERVE + donation);

        _finalizeReserves();

        assertEq(vault.baseReserveRemaining(), minedBase);
        assertEq(vault.nftReserveRemaining(), minedNft);
        // Official liability plus the untouched donation, nothing more,
        // nothing less.
        assertEq(token.balanceOf(address(vault)), minedBase + minedNft + donation);
    }

    // ---------------------------------------------------------------
    // 8. A second finalizeReserves() call is rejected
    // ---------------------------------------------------------------

    function test_finalizeReserves_rejectsSecondCall() public {
        mining.setLocked(owner1, 100 * 1e18, 10 * 1e18);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();

        vm.prank(address(finalizer));
        vm.expectRevert(B20ClaimVault.AlreadyFinalizedReserves.selector);
        vault.finalizeReserves();
    }

    // ---------------------------------------------------------------
    // 9. claim() rejects before the finalizer reports finalized
    // ---------------------------------------------------------------

    function test_claim_rejectsBeforeFinalizerFinalized() public {
        uint256 minedBase = 1_000 * 1e18;
        mining.setLocked(owner1, minedBase, 0);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        // finalizer.finalized() deliberately left false.

        vm.prank(owner1);
        vm.expectRevert(B20ClaimVault.FinalizationNotComplete.selector);
        vault.claim();
    }

    function test_claim_rejectsIfReservesNeverFinalized() public {
        vm.prank(owner1);
        vm.expectRevert(B20ClaimVault.ReservesNotFinalized.selector);
        vault.claim();
    }

    // ---------------------------------------------------------------
    // 10. An owner claims exactly base + NFT, only to their own address
    // ---------------------------------------------------------------

    function test_claim_paysExactBasePlusNftToOwner() public {
        uint256 minedBase = 12_345 * 1e18;
        uint256 minedNft = 678 * 1e18;
        mining.setLocked(owner1, minedBase, minedNft);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.expectEmit(true, true, true, true, address(vault));
        emit B20ClaimVault.Claimed(owner1, minedBase, minedNft);
        vm.prank(owner1);
        vault.claim();

        assertEq(token.balanceOf(owner1), minedBase + minedNft);
        assertTrue(vault.claimed(owner1));
        assertEq(vault.totalBaseClaimed(), minedBase);
        assertEq(vault.totalNftClaimed(), minedNft);
        assertEq(vault.baseReserveRemaining(), 0);
        assertEq(vault.nftReserveRemaining(), 0);
    }

    // ---------------------------------------------------------------
    // 11. No other owner or mining wallet can claim someone else's reward
    // ---------------------------------------------------------------

    function test_claim_miningWalletCannotClaimOwnersReward() public {
        mining.setLocked(owner1, 5_000 * 1e18, 500 * 1e18);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        // minerWallet is bound to owner1 in the real B20WalletBinding
        // model, but B20ClaimVault has no concept of that binding at
        // all — msg.sender is looked up directly in B20Mining, and
        // minerWallet itself has never mined anything.
        vm.prank(minerWallet);
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.NothingToClaim.selector, minerWallet));
        vault.claim();

        assertEq(token.balanceOf(minerWallet), 0);
        assertFalse(vault.claimed(owner1));
    }

    function test_claim_ownerCannotClaimAnotherOwnersReward() public {
        mining.setLocked(owner1, 5_000 * 1e18, 500 * 1e18);
        // owner2 has nothing locked.
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.NothingToClaim.selector, owner2));
        vault.claim();

        assertEq(token.balanceOf(owner2), 0);
    }

    // ---------------------------------------------------------------
    // 12. Zero claim and double claim are rejected
    // ---------------------------------------------------------------

    function test_claim_rejectsWhenNothingToClaim() public {
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.NothingToClaim.selector, stranger));
        vault.claim();
    }

    function test_claim_rejectsDoubleClaim() public {
        mining.setLocked(owner1, 1_000 * 1e18, 0);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.prank(owner1);
        vault.claim();

        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(B20ClaimVault.AlreadyClaimed.selector, owner1));
        vault.claim();
    }

    // ---------------------------------------------------------------
    // 13. Claim deadline boundary: one second before accepted, at
    //     the deadline rejected
    // ---------------------------------------------------------------

    function test_claim_acceptsOneSecondBeforeDeadline() public {
        mining.setLocked(owner1, 1_000 * 1e18, 0);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.warp(vault.claimDeadline() - 1);
        vm.prank(owner1);
        vault.claim();

        assertTrue(vault.claimed(owner1));
    }

    function test_claim_rejectsAtDeadline() public {
        mining.setLocked(owner1, 1_000 * 1e18, 0);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.warp(vault.claimDeadline());
        vm.prank(owner1);
        vm.expectRevert(B20ClaimVault.ClaimWindowClosed.selector);
        vault.claim();
    }

    // ---------------------------------------------------------------
    // 14. burnUnclaimed() rejects before the deadline
    // ---------------------------------------------------------------

    function test_burnUnclaimed_rejectsBeforeDeadline() public {
        mining.setLocked(owner1, 1_000 * 1e18, 0);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.warp(vault.claimDeadline() - 1);
        vm.expectRevert(B20ClaimVault.ClaimWindowStillOpen.selector);
        vault.burnUnclaimed();
    }

    // ---------------------------------------------------------------
    // 15. T+30 burn burns exactly the remaining base/NFT liability
    // ---------------------------------------------------------------

    function test_burnUnclaimed_burnsExactRemainingLiability() public {
        mining.setLocked(owner1, 4_000 * 1e18, 400 * 1e18);
        mining.setLocked(owner2, 1_000 * 1e18, 100 * 1e18);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        // Only owner1 claims; owner2's reward goes unclaimed.
        vm.prank(owner1);
        vault.claim();

        uint256 supplyBefore = token.totalSupply();
        vm.warp(vault.claimDeadline());

        vm.expectEmit(true, true, true, true, address(vault));
        emit B20ClaimVault.UnclaimedReserveBurned(1_000 * 1e18, 100 * 1e18);
        vault.burnUnclaimed();

        assertTrue(vault.unclaimedReserveBurned());
        assertEq(vault.baseReserveRemaining(), 0);
        assertEq(vault.nftReserveRemaining(), 0);
        assertEq(token.totalSupply(), supplyBefore - 1_000 * 1e18 - 100 * 1e18);
    }

    // ---------------------------------------------------------------
    // 16. Excess donation survives the T+30 burn, locked in the vault
    // ---------------------------------------------------------------

    function test_burnUnclaimed_excessDonationRemainsLocked() public {
        mining.setLocked(owner1, 4_000 * 1e18, 400 * 1e18);
        uint256 donation = 55 * 1e18;
        _fundVault(TOTAL_RESERVE + donation);
        _finalizeReserves();
        finalizer.setFinalized(true);
        // owner1 never claims — everything mined is "unclaimed" at T+30.

        vm.warp(vault.claimDeadline());
        vault.burnUnclaimed();

        assertEq(token.balanceOf(address(vault)), donation);
    }

    // ---------------------------------------------------------------
    // 17. A second burnUnclaimed() call is rejected
    // ---------------------------------------------------------------

    function test_burnUnclaimed_rejectsSecondCall() public {
        mining.setLocked(owner1, 1_000 * 1e18, 0);
        _fundVault(TOTAL_RESERVE);
        _finalizeReserves();
        finalizer.setFinalized(true);

        vm.warp(vault.claimDeadline());
        vault.burnUnclaimed();

        vm.expectRevert(B20ClaimVault.AlreadyBurnedUnclaimed.selector);
        vault.burnUnclaimed();
    }

    // ---------------------------------------------------------------
    // 18. Global claimed/remaining counters reconcile after every
    //     successful action
    // ---------------------------------------------------------------

    function test_invariant_countersReconcileAfterEachSuccessfulAction() public {
        mining.setLocked(owner1, 4_000 * 1e18, 400 * 1e18);
        mining.setLocked(owner2, 1_000 * 1e18, 100 * 1e18);
        _fundVault(TOTAL_RESERVE);

        _finalizeReserves();
        assertEq(vault.baseReserveRemaining() + vault.totalBaseClaimed(), mining.totalBaseMinedLocked());
        assertEq(vault.nftReserveRemaining() + vault.totalNftClaimed(), mining.totalNftMinedLocked());

        finalizer.setFinalized(true);

        vm.prank(owner1);
        vault.claim();
        assertEq(vault.baseReserveRemaining() + vault.totalBaseClaimed(), mining.totalBaseMinedLocked());
        assertEq(vault.nftReserveRemaining() + vault.totalNftClaimed(), mining.totalNftMinedLocked());

        vm.prank(owner2);
        vault.claim();
        assertEq(vault.baseReserveRemaining() + vault.totalBaseClaimed(), mining.totalBaseMinedLocked());
        assertEq(vault.nftReserveRemaining() + vault.totalNftClaimed(), mining.totalNftMinedLocked());
        assertEq(vault.baseReserveRemaining(), 0);
        assertEq(vault.nftReserveRemaining(), 0);

        vm.warp(vault.claimDeadline());
        vault.burnUnclaimed();
        assertEq(vault.baseReserveRemaining() + vault.totalBaseClaimed(), mining.totalBaseMinedLocked());
        assertEq(vault.nftReserveRemaining() + vault.totalNftClaimed(), mining.totalNftMinedLocked());
    }
}
