// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {B20PoW} from "./B20PoW.sol";
import {B20SnapshotMerkle} from "./B20SnapshotMerkle.sol";
import {IB20WalletBinding} from "./interfaces/IB20WalletBinding.sol";
import {IB20EligibleNFT} from "./interfaces/IB20EligibleNFT.sol";
import {IB20PublicNFT} from "./interfaces/IB20PublicNFT.sol";

/// @notice B20MINER PoW + allocation + mining-fee/reward accounting:
/// a one-time mining opening, a one-time per-owner allocation
/// confirmation, active-binding checks, per-owner challenge state,
/// stale/replay protection, a fixed 15-day mining window (1 day on Base
/// Sepolia), per-proof
/// mining-fee collection, NFT-first quota consumption, and
/// `Mined — Locked` accounting.
///
/// Launch flow (`docs/MINING_WEB_APP_V1.md` §2, owner decision of
/// 24 September 2026):
/// 1. Deploy. NFT minting and allocation confirmation are open; mining
///    is not.
/// 2. `openMining()` — called once by `MINING_OPENER`, or by anyone at or
///    after `OPEN_DEADLINE` so an absent opener cannot freeze the
///    protocol. It fixes `[MINING_START, MINING_END)` = `[now, now +
///    MINING_DURATION)` and derives the global mining seed in the same
///    transaction. The opener gains nothing else: no quota, no setter, no
///    second call.
/// 3. `confirmAllocation()` — each owner wallet, once, freezes its quota:
///    the snapshot base allocation (Merkle-proven) plus whatever NFT
///    quota it holds at that moment. From then on both NFT collections
///    refuse new mints from that wallet (`mintingOpenFor`), so the
///    confirmed allocation is final.
/// 4. `submitProof()` — the owner's bound mining wallet mines the
///    confirmed quota until `MINING_END`.
///
/// Mining economics (`B20_REVENUE_MODEL.md` §2): every accepted proof
/// earns a fixed `REWARD_PER_PROOF` (312.5 MINER), capped by the owner's
/// remaining quota on the last proof, and pays a mining fee of exactly
/// that reward priced at `MINER_PER_ETH` (1 ETH = 12,000,000 MINER),
/// rounded up to the wei. The fee is forwarded in full to
/// `liquidityVault`. Neither amount depends on gas prices, so no oracle
/// is involved.
///
/// Out of scope, deliberately absent: any MINER token transfer, claim,
/// burn, finalization, DEX/LP creation, and any admin/pause/upgrade
/// path. `MINING_OPENER`'s single `openMining()` call is the only
/// privileged action and it cannot be repeated. The production
/// `POW_TARGET` is `2^232 − 1` (24 leading zero bits,
/// `DEPLOYMENT_PARAMETERS.md` §1.9); it stays a constructor argument so
/// tests can use an easy target, and the deploy script enforces the
/// production value.
contract B20Mining is ReentrancyGuard {
    /// @notice The wallet-binding contract this mining contract reads
    /// `isActiveBinding` from on every proof. Never cached.
    IB20WalletBinding public immutable walletBinding;

    /// @notice Single immutable PoW difficulty target for the whole
    /// contract lifetime. `B20PoW.isValid(..., POW_TARGET)` is the sole
    /// validity check; there is no epoch, retarget, or setter.
    uint256 public immutable POW_TARGET;

    /// @notice The one address allowed to call `openMining()` before
    /// `OPEN_DEADLINE`.
    address public immutable MINING_OPENER;

    /// @notice From this timestamp on, anyone may call `openMining()`.
    uint256 public immutable OPEN_DEADLINE;

    /// @notice Base Sepolia's chain id: the one chain with a short window.
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    /// @notice Length of the mining window: 15 days, fixed at construction.
    /// Base Sepolia gets 1 day so the testnet can run the whole cycle
    /// (mining, finalize, swap, claim) quickly with the same code as Base.
    uint256 public immutable MINING_DURATION;

    /// @notice The Eligible NFT collection this contract reads
    /// `eligibleBonus` from. Its `mining()` must equal this contract.
    IB20EligibleNFT public immutable eligibleNFT;

    /// @notice The Public NFT collection this contract reads
    /// `publicMiningQuota` from. Its `mining()` must equal this contract.
    IB20PublicNFT public immutable publicNFT;

    /// @notice The sole recipient of every collected mining fee. Fixed at
    /// deploy time; not `address(this)`, not the zero address, and must
    /// have code (so a plain, unreachable EOA typo cannot lock funds).
    address public immutable liquidityVault;

    /// @notice True once `openMining()` has run. Permanent.
    bool public miningOpened;

    /// @dev Set once by `openMining()`; read through `MINING_START()` /
    /// `MINING_END()`, which revert until mining is open.
    uint256 private _miningStart;
    uint256 private _miningEnd;

    /// @notice Global seed all owners' initial challenges are derived
    /// from. Zero until `openMining()` sets it; never changes afterward.
    bytes32 public miningSeed;

    /// @dev Owner wallet's current challenge. bytes32(0) means "no proof
    /// accepted yet for this owner" — `challengeOf` falls back to the
    /// deterministic initial-challenge formula (which requires the global
    /// seed) in that case. A real stored challenge colliding with
    /// bytes32(0) is cryptographically negligible.
    mapping(address ownerWallet => bytes32 challenge) private _storedChallenge;

    /// @notice Number of proofs ever accepted for this owner wallet.
    /// Tracked per owner, not per mining wallet, so rotating the active
    /// mining wallet neither resets nor duplicates this count.
    mapping(address ownerWallet => uint256 count) public acceptedProofs;

    /// @notice True once `ownerWallet` has called `confirmAllocation()`.
    /// Permanent: the quota below can never change afterward, and both
    /// NFT collections stop minting to this wallet.
    mapping(address ownerWallet => bool confirmed) public allocationConfirmed;

    /// @notice Snapshot base quota confirmed for this owner (18-decimal
    /// MINER units), or 0.
    mapping(address ownerWallet => uint256 quota) public baseQuota;

    /// @notice Eligible-bonus + Public NFT quota confirmed for this owner
    /// (18-decimal MINER units), or 0.
    mapping(address ownerWallet => uint256 quota) public nftQuota;

    /// @notice Sum of every owner's confirmed `baseQuota`, must never
    /// exceed `BASE_QUOTA_CAP`.
    uint256 public totalBaseQuotaAuthorized;

    /// @notice Sum of every owner's confirmed `nftQuota`, must never
    /// exceed `NFT_QUOTA_CAP`.
    uint256 public totalNftQuotaAuthorized;

    /// @notice Snapshot mining/claim reserve cap (60,000,000,000 MINER).
    uint256 public constant BASE_QUOTA_CAP = 60_000_000_000 * 1e18;

    /// @notice NFT mining reward/bonus reserve cap (1,000,000,000 MINER;
    /// `B20_REVENUE_MODEL.md` 1.36, owner decision 27 September 2026 —
    /// was 5,000,000,000). The largest NFT quota the two capped
    /// collections can create is about 195,000,000 MINER (10,000 Public
    /// NFTs × 10,000 MINER, plus 10,000 Eligible NFTs at 5% of the largest
    /// snapshot allocations), so no confirmation can ever hit this cap.
    uint256 public constant NFT_QUOTA_CAP = 1_000_000_000 * 1e18;

    /// @notice Mining price: 1 ETH buys 12,000,000 MINER, so a reward of
    /// `r` MINER token units costs `r / MINER_PER_ETH` wei — ETH's 18
    /// decimals and MINER's 18 decimals cancel out, so no separate `1e18`
    /// scaling is applied. See `B20_REVENUE_MODEL.md` §2.
    uint256 public constant MINER_PER_ETH = 12_000_000;

    /// @notice Fixed reward credited per accepted proof: 312.5 MINER
    /// (18-decimal units). An owner's last proof is capped by the remaining
    /// quota. A 50,000 MINER quota is exactly 160 proofs.
    uint256 public constant REWARD_PER_PROOF = 312_500_000_000_000_000_000;

    /// @notice Mining fee for a full-reward proof:
    /// `ceil(REWARD_PER_PROOF / MINER_PER_ETH)` = 26,041,666,666,667 wei.
    uint256 public constant MINING_FEE_PER_PROOF = (REWARD_PER_PROOF + MINER_PER_ETH - 1) / MINER_PER_ETH;

    /// @notice Owner's locked-but-unclaimed reward paid out of snapshot
    /// base quota (18-decimal MINER units). Never exceeds `baseQuota`.
    mapping(address ownerWallet => uint256 amount) public baseMinedLocked;

    /// @notice Owner's locked-but-unclaimed reward paid out of NFT quota
    /// (18-decimal MINER units). Never exceeds `nftQuota`.
    mapping(address ownerWallet => uint256 amount) public nftMinedLocked;

    /// @notice Sum of every owner's `baseMinedLocked`.
    uint256 public totalBaseMinedLocked;

    /// @notice Sum of every owner's `nftMinedLocked`.
    uint256 public totalNftMinedLocked;

    /// @notice Sum of every mining fee successfully forwarded to
    /// `liquidityVault`.
    uint256 public totalMiningFeesForwarded;

    /// @dev Internal-only bundle of one `submitProof` call's computed fee
    /// and reward split. Passed by memory reference between the helper
    /// functions below purely to keep `submitProof`'s own stack usage low
    /// — not part of any external interface.
    struct ProofRewardCalc {
        uint256 miningFee;
        uint256 totalReward;
        uint256 nftReward;
        uint256 baseReward;
        uint256 refund;
    }

    error ZeroWalletBinding();
    error ZeroPowTarget();
    error ZeroMiningOpener();
    error OpenDeadlineNotInFuture();
    error ZeroEligibleNFT();
    error ZeroPublicNFT();
    error NftMiningMismatch(address nftContract, address nftMining);
    error ZeroLiquidityVault();
    error LiquidityVaultHasNoCode(address liquidityVault);
    error LiquidityVaultIsSelf();
    error ZeroOwnerWallet();
    error NotMiningOpener(address caller);
    error MiningAlreadyOpened();
    error MiningNotOpened();
    error InactiveBinding(address ownerWallet, address miningWallet);
    error StaleChallenge(bytes32 expectedChallenge, bytes32 currentChallenge);
    error InvalidProof(address ownerWallet, address miningWallet, bytes32 challenge, uint256 nonce);
    error OutsideMiningWindow();
    error NoAuthorizedQuota(address ownerWallet);
    error AllocationAlreadyConfirmed(address ownerWallet);
    error AllocationClosed();
    error MissingBaseAllocation(address ownerWallet);
    error InvalidSnapshotProof();
    error BaseQuotaCapExceeded(uint256 attemptedTotal, uint256 cap);
    error NftQuotaCapExceeded(uint256 attemptedTotal, uint256 cap);
    error InsufficientMiningFee(uint256 provided, uint256 required);
    error LiquidityTransferFailed(address liquidityVault, uint256 amount);
    error RefundFailed(address miningWallet, uint256 amount);

    /// @notice Emitted once, when `openMining()` fixes the window and
    /// derives the global mining seed.
    event MiningOpened(uint256 miningStart, uint256 miningEnd, bytes32 seed, address indexed opener);

    /// @notice Emitted once per owner, when its allocation is confirmed.
    event AllocationConfirmed(
        address indexed ownerWallet,
        uint256 baseQuota,
        uint256 nftQuota,
        uint256 totalBaseQuotaAuthorized,
        uint256 totalNftQuotaAuthorized
    );

    /// @notice Emitted on every accepted proof.
    event ProofAccepted(
        address indexed ownerWallet,
        address indexed miningWallet,
        bytes32 previousChallenge,
        uint256 nonce,
        bytes32 proofHash,
        bytes32 newChallenge,
        uint256 acceptedProofCount
    );

    /// @notice Emitted alongside `ProofAccepted` on every accepted proof.
    event ProofRewarded(
        address indexed ownerWallet,
        address indexed miningWallet,
        uint256 totalReward,
        uint256 nftReward,
        uint256 baseReward,
        uint256 miningFee,
        uint256 refund,
        uint256 newMinedLocked,
        uint256 newRemainingQuota,
        bytes32 newChallenge
    );

    /// @dev Both NFT collections are deployed before this contract with
    /// its predicted address (`DeployB20Genesis` nonce plan) and must
    /// report it from `mining()`, so their mint gate reads this contract.
    constructor(
        address walletBinding_,
        uint256 powTarget_,
        address miningOpener_,
        uint256 openDeadline_,
        address eligibleNFT_,
        address publicNFT_,
        address liquidityVault_
    ) {
        MINING_DURATION = block.chainid == BASE_SEPOLIA_CHAIN_ID ? 1 days : 15 days;
        if (walletBinding_ == address(0)) revert ZeroWalletBinding();
        if (powTarget_ == 0) revert ZeroPowTarget();
        if (miningOpener_ == address(0)) revert ZeroMiningOpener();
        if (openDeadline_ <= block.timestamp) revert OpenDeadlineNotInFuture();
        if (eligibleNFT_ == address(0)) revert ZeroEligibleNFT();
        if (publicNFT_ == address(0)) revert ZeroPublicNFT();
        if (liquidityVault_ == address(0)) revert ZeroLiquidityVault();
        // Checked before the code-length check below: address(this) has no
        // code yet during construction, so a self-reference would
        // otherwise be misreported as LiquidityVaultHasNoCode instead of
        // the more specific, actionable LiquidityVaultIsSelf.
        if (liquidityVault_ == address(this)) revert LiquidityVaultIsSelf();
        if (liquidityVault_.code.length == 0) revert LiquidityVaultHasNoCode(liquidityVault_);

        walletBinding = IB20WalletBinding(walletBinding_);
        POW_TARGET = powTarget_;
        MINING_OPENER = miningOpener_;
        OPEN_DEADLINE = openDeadline_;
        eligibleNFT = IB20EligibleNFT(eligibleNFT_);
        publicNFT = IB20PublicNFT(publicNFT_);
        liquidityVault = liquidityVault_;

        address eligibleMining = IB20EligibleNFT(eligibleNFT_).mining();
        if (eligibleMining != address(this)) revert NftMiningMismatch(eligibleNFT_, eligibleMining);
        address publicMining = IB20PublicNFT(publicNFT_).mining();
        if (publicMining != address(this)) revert NftMiningMismatch(publicNFT_, publicMining);
    }

    // ---------------------------------------------------------------
    // Mining window
    // ---------------------------------------------------------------

    /// @notice Opens mining now: fixes `[MINING_START, MINING_END)` =
    /// `[block.timestamp, block.timestamp + MINING_DURATION)` and derives the
    /// global mining seed, exactly once. Callable by `MINING_OPENER`, or
    /// by anyone at or after `OPEN_DEADLINE`.
    ///
    /// The seed mixes `block.prevrandao` and the previous block hash of
    /// the opening block, so owner challenges — and therefore nonces —
    /// cannot be precomputed before mining is open. This is an
    /// anti-precompute input, not an unbiased randomness source; the
    /// opener's limited influence over it creates no economic right,
    /// because the seed decides no winner, allocation, reward or quota.
    function openMining() external {
        if (miningOpened) revert MiningAlreadyOpened();
        if (msg.sender != MINING_OPENER && block.timestamp < OPEN_DEADLINE) revert NotMiningOpener(msg.sender);

        uint256 start = block.timestamp;
        uint256 end = start + MINING_DURATION;
        bytes32 seed = keccak256(
            abi.encodePacked(
                "B20_MINING_SEED_V2",
                block.chainid,
                address(this),
                block.prevrandao,
                block.number,
                blockhash(block.number - 1),
                start,
                end
            )
        );

        miningOpened = true;
        _miningStart = start;
        _miningEnd = end;
        miningSeed = seed;

        emit MiningOpened(start, end, seed, msg.sender);
    }

    /// @notice Mining opened at this timestamp (inclusive). Reverts with
    /// `MiningNotOpened` before `openMining()`.
    function MINING_START() public view returns (uint256) {
        if (!miningOpened) revert MiningNotOpened();
        return _miningStart;
    }

    /// @notice Always `MINING_START + MINING_DURATION`; no proof is accepted at or
    /// after it. Reverts with `MiningNotOpened` before `openMining()`, so
    /// every downstream time check (`B20LiquidityFinalizer`,
    /// `B20ClaimVault`) fails closed until mining has actually run.
    function MINING_END() public view returns (uint256) {
        if (!miningOpened) revert MiningNotOpened();
        return _miningEnd;
    }

    /// @notice Non-reverting summary for clients: whether mining is open,
    /// its window (both 0 before opening) and `OPEN_DEADLINE`.
    function miningWindow() external view returns (bool opened, uint256 start, uint256 end, uint256 openDeadline) {
        return (miningOpened, _miningStart, _miningEnd, OPEN_DEADLINE);
    }

    /// @notice True once mining has been opened and its window is over.
    function miningEnded() public view returns (bool) {
        return miningOpened && block.timestamp >= _miningEnd;
    }

    /// @notice Whether `wallet` may still mint NFTs: until it confirms its
    /// allocation and until mining ends. Both NFT collections enforce it.
    function mintingOpenFor(address wallet) external view returns (bool) {
        return !allocationConfirmed[wallet] && !miningEnded();
    }

    // ---------------------------------------------------------------
    // Allocation
    // ---------------------------------------------------------------

    /// @notice Confirms `msg.sender`'s final mining allocation, once:
    /// its snapshot base allocation (`baseAllocation` whole MINER, proven
    /// by `snapshotProof` against the frozen Merkle root; pass `0` and an
    /// empty proof for a wallet outside the snapshot) plus its current
    /// Eligible bonus and Public NFT quota. Open from deployment until
    /// `MINING_END`; does not require mining to be open or a mining wallet
    /// to be bound. Afterwards the quota cannot change and both NFT
    /// collections refuse new mints to this wallet.
    ///
    /// A wallet holding Eligible NFTs must supply its base allocation —
    /// passing `0` would silently forfeit it, so that reverts with
    /// `MissingBaseAllocation`.
    function confirmAllocation(uint256 baseAllocation, bytes32[] calldata snapshotProof) external {
        address ownerWallet = msg.sender;
        if (allocationConfirmed[ownerWallet]) revert AllocationAlreadyConfirmed(ownerWallet);
        if (miningEnded()) revert AllocationClosed();

        uint256 eligibleBonus = eligibleNFT.eligibleBonus(ownerWallet);
        uint256 baseAmount;
        if (baseAllocation > 0) {
            if (!B20SnapshotMerkle.verify(ownerWallet, baseAllocation, snapshotProof)) {
                revert InvalidSnapshotProof();
            }
            baseAmount = baseAllocation * 1e18;
        } else if (eligibleBonus > 0) {
            revert MissingBaseAllocation(ownerWallet);
        }
        uint256 nftAmount = eligibleBonus + publicNFT.publicMiningQuota(ownerWallet);
        if (baseAmount == 0 && nftAmount == 0) revert NoAuthorizedQuota(ownerWallet);

        uint256 newTotalBase = totalBaseQuotaAuthorized + baseAmount;
        if (newTotalBase > BASE_QUOTA_CAP) revert BaseQuotaCapExceeded(newTotalBase, BASE_QUOTA_CAP);
        uint256 newTotalNft = totalNftQuotaAuthorized + nftAmount;
        if (newTotalNft > NFT_QUOTA_CAP) revert NftQuotaCapExceeded(newTotalNft, NFT_QUOTA_CAP);

        allocationConfirmed[ownerWallet] = true;
        baseQuota[ownerWallet] = baseAmount;
        nftQuota[ownerWallet] = nftAmount;
        totalBaseQuotaAuthorized = newTotalBase;
        totalNftQuotaAuthorized = newTotalNft;

        emit AllocationConfirmed(ownerWallet, baseAmount, nftAmount, newTotalBase, newTotalNft);
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    /// @notice The challenge `ownerWallet` must currently solve. For an
    /// owner with no accepted proofs yet, this is a deterministic
    /// derivation from the global mining seed — reverts with
    /// `MiningNotOpened` before `openMining()`, so there is nothing to
    /// precompute against before mining actually starts.
    function challengeOf(address ownerWallet) public view returns (bytes32) {
        bytes32 stored = _storedChallenge[ownerWallet];
        if (stored != bytes32(0)) {
            return stored;
        }
        if (!miningOpened) revert MiningNotOpened();
        return _initialChallenge(ownerWallet);
    }

    /// @notice Total quota (18-decimal MINER units) confirmed for
    /// `ownerWallet`: `baseQuota + nftQuota`. Not a remaining balance —
    /// use `remainingQuota` for what is still available to mine.
    function totalAuthorizedQuota(address ownerWallet) public view returns (uint256) {
        return baseQuota[ownerWallet] + nftQuota[ownerWallet];
    }

    /// @notice Owner's total locked-but-unclaimed reward:
    /// `baseMinedLocked + nftMinedLocked`.
    function minedLocked(address ownerWallet) public view returns (uint256) {
        return baseMinedLocked[ownerWallet] + nftMinedLocked[ownerWallet];
    }

    /// @notice Owner's remaining, not-yet-mined snapshot base quota.
    function remainingBaseQuota(address ownerWallet) public view returns (uint256) {
        return baseQuota[ownerWallet] - baseMinedLocked[ownerWallet];
    }

    /// @notice Owner's remaining, not-yet-mined NFT quota.
    function remainingNftQuota(address ownerWallet) public view returns (uint256) {
        return nftQuota[ownerWallet] - nftMinedLocked[ownerWallet];
    }

    /// @notice Owner's total remaining, not-yet-mined quota:
    /// `remainingBaseQuota + remainingNftQuota`. Always equal to
    /// `totalAuthorizedQuota(ownerWallet) - minedLocked(ownerWallet)`.
    function remainingQuota(address ownerWallet) public view returns (uint256) {
        return remainingBaseQuota(ownerWallet) + remainingNftQuota(ownerWallet);
    }

    /// @notice Mining fee for a reward of `reward` MINER token units:
    /// `ceil(reward / MINER_PER_ETH)` wei. Rounds up, so the protocol never
    /// undercharges; the per-proof overcharge is below 1 wei.
    function miningFeeFor(uint256 reward) public pure returns (uint256) {
        return (reward + MINER_PER_ETH - 1) / MINER_PER_ETH;
    }

    /// @notice What `ownerWallet`'s next accepted proof would credit and
    /// cost right now: `min(REWARD_PER_PROOF, remainingQuota)` and its
    /// `miningFeeFor`. `(0, 0)` once the quota is exhausted. Clients send
    /// exactly `miningFee` as `msg.value`; any excess is refunded.
    function quoteProof(address ownerWallet) external view returns (uint256 reward, uint256 miningFee) {
        reward = _rewardFor(ownerWallet);
        miningFee = miningFeeFor(reward);
    }

    // ---------------------------------------------------------------
    // Proofs
    // ---------------------------------------------------------------

    /// @notice Submits a PoW proof for `ownerWallet`, found by the caller
    /// (`msg.sender`), which must be `ownerWallet`'s currently active
    /// mining wallet per `walletBinding`. On success: advances the
    /// challenge, counts the proof, credits the fixed reward
    /// (`min(REWARD_PER_PROOF, remainingQuota)`) — NFT quota first, then
    /// base quota — to the owner's `Mined — Locked` balance, forwards the
    /// matching mining fee (`miningFeeFor(reward)`) to `liquidityVault`,
    /// and refunds any `msg.value` excess to the caller. Every check runs
    /// before any state is written or any ETH moves, so an invalid, stale,
    /// or under-funded proof changes nothing and costs the treasury
    /// nothing. See `docs/MINING_REWARD_ACCOUNTING_V1.md`.
    function submitProof(address ownerWallet, bytes32 expectedChallenge, uint256 nonce) external payable nonReentrant {
        address miningWallet = msg.sender;

        // ---- checks ----
        _validateProof(ownerWallet, miningWallet, expectedChallenge, nonce);
        ProofRewardCalc memory r = _quoteFeeAndReward(ownerWallet);

        // ---- effects ----
        bytes32 newChallenge = _recordProofAndReward(ownerWallet, miningWallet, expectedChallenge, nonce, r);
        _emitProofRewarded(ownerWallet, miningWallet, r, newChallenge);

        // ---- interactions ----
        _forwardFeeAndRefund(miningWallet, r.miningFee, r.refund);
    }

    /// @dev Emits `ProofRewarded`, reading `minedLocked`/`remainingQuota`
    /// fresh so the event reports post-update values.
    function _emitProofRewarded(
        address ownerWallet,
        address miningWallet,
        ProofRewardCalc memory r,
        bytes32 newChallenge
    ) internal {
        emit ProofRewarded(
            ownerWallet,
            miningWallet,
            r.totalReward,
            r.nftReward,
            r.baseReward,
            r.miningFee,
            r.refund,
            minedLocked(ownerWallet),
            remainingQuota(ownerWallet),
            newChallenge
        );
    }

    /// @dev Sends `miningFee` to `liquidityVault` and, if nonzero, refunds
    /// `refund` to `miningWallet`. Either failure reverts the whole
    /// transaction — the sole "interactions" step, called last.
    function _forwardFeeAndRefund(address miningWallet, uint256 miningFee, uint256 refund) internal {
        (bool sentFee,) = liquidityVault.call{value: miningFee}("");
        if (!sentFee) revert LiquidityTransferFailed(liquidityVault, miningFee);

        if (refund > 0) {
            (bool sentRefund,) = miningWallet.call{value: refund}("");
            if (!sentRefund) revert RefundFailed(miningWallet, refund);
        }
    }

    /// @dev All of `submitProof`'s checks (mining open and not ended,
    /// remaining quota, binding, stale-challenge, PoW validity). Reverts
    /// on the first failed check; writes no state.
    function _validateProof(address ownerWallet, address miningWallet, bytes32 expectedChallenge, uint256 nonce)
        internal
        view
    {
        if (!miningOpened) revert MiningNotOpened();
        if (block.timestamp >= _miningEnd) revert OutsideMiningWindow();
        if (remainingQuota(ownerWallet) == 0) revert NoAuthorizedQuota(ownerWallet);
        if (ownerWallet == address(0)) revert ZeroOwnerWallet();

        // Re-checked from B20WalletBinding on every call; never cached, so
        // a mining wallet its owner removed is rejected here even if its
        // transaction was already in flight before the removal landed.
        if (!walletBinding.isActiveBinding(ownerWallet, miningWallet)) {
            revert InactiveBinding(ownerWallet, miningWallet);
        }

        bytes32 currentChallenge = challengeOf(ownerWallet);
        if (expectedChallenge != currentChallenge) {
            revert StaleChallenge(expectedChallenge, currentChallenge);
        }

        bool valid = B20PoW.isValid(
            block.chainid, address(this), ownerWallet, miningWallet, expectedChallenge, nonce, POW_TARGET
        );
        if (!valid) revert InvalidProof(ownerWallet, miningWallet, expectedChallenge, nonce);
    }

    /// @dev `min(REWARD_PER_PROOF, remainingQuota(ownerWallet))`.
    function _rewardFor(address ownerWallet) internal view returns (uint256) {
        uint256 remaining = remainingQuota(ownerWallet);
        return REWARD_PER_PROOF < remaining ? REWARD_PER_PROOF : remaining;
    }

    /// @dev Computes the fixed (quota-capped) reward and its mining fee,
    /// checks `msg.value` covers the fee, and splits the reward
    /// NFT-quota-first then base-quota. Writes no state; reverts before any
    /// state is touched if underfunded.
    function _quoteFeeAndReward(address ownerWallet) internal view returns (ProofRewardCalc memory r) {
        uint256 totalReward = _rewardFor(ownerWallet);
        uint256 fee = miningFeeFor(totalReward);
        if (msg.value < fee) revert InsufficientMiningFee(msg.value, fee);

        uint256 remainingNft = remainingNftQuota(ownerWallet);
        uint256 nftReward = totalReward < remainingNft ? totalReward : remainingNft;

        r = ProofRewardCalc({
            miningFee: fee,
            totalReward: totalReward,
            nftReward: nftReward,
            baseReward: totalReward - nftReward,
            refund: msg.value - fee
        });
    }

    /// @dev Advances the challenge/proof counter, credits
    /// `Mined — Locked` accounting, and emits `ProofAccepted`. The only
    /// function that writes proof/reward state; called once, after every
    /// check has passed and before any ETH moves.
    function _recordProofAndReward(
        address ownerWallet,
        address miningWallet,
        bytes32 expectedChallenge,
        uint256 nonce,
        ProofRewardCalc memory r
    ) internal returns (bytes32 newChallenge) {
        bytes32 proofHash = B20PoW.computeHash(
            block.chainid, address(this), ownerWallet, miningWallet, expectedChallenge, nonce
        );

        uint256 newCount = acceptedProofs[ownerWallet] + 1;
        acceptedProofs[ownerWallet] = newCount;

        newChallenge = _nextChallenge(expectedChallenge, proofHash, ownerWallet, miningWallet, newCount);
        _storedChallenge[ownerWallet] = newChallenge;

        if (r.nftReward > 0) {
            nftMinedLocked[ownerWallet] += r.nftReward;
            totalNftMinedLocked += r.nftReward;
        }
        if (r.baseReward > 0) {
            baseMinedLocked[ownerWallet] += r.baseReward;
            totalBaseMinedLocked += r.baseReward;
        }
        totalMiningFeesForwarded += r.miningFee;

        emit ProofAccepted(ownerWallet, miningWallet, expectedChallenge, nonce, proofHash, newChallenge, newCount);
    }

    /// @dev keccak256(abi.encodePacked(
    ///   "B20_OWNER_CHALLENGE_V1", miningSeed, block.chainid,
    ///   address(this), ownerWallet
    /// )). Deterministic per (contract, owner) pair once `miningSeed` is
    /// set; requires no prior transaction from that owner, so
    /// `challengeOf` can return it from a plain view call.
    function _initialChallenge(address ownerWallet) internal view returns (bytes32) {
        return
            keccak256(abi.encodePacked("B20_OWNER_CHALLENGE_V1", miningSeed, block.chainid, address(this), ownerWallet));
    }

    /// @dev keccak256(abi.encodePacked(
    ///   "B20_NEXT_CHALLENGE_V1", previousChallenge, proofHash, ownerWallet,
    ///   miningWallet, newAcceptedCount, block.chainid, address(this),
    ///   block.prevrandao, block.number
    /// )). Includes `block.prevrandao` and `block.number` from the block
    /// the accepted proof lands in, so a miner cannot precompute the next
    /// challenge before that block is mined — only after their proof
    /// transaction is actually included.
    function _nextChallenge(
        bytes32 previousChallenge,
        bytes32 proofHash,
        address ownerWallet,
        address miningWallet,
        uint256 newAcceptedCount
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "B20_NEXT_CHALLENGE_V1",
                previousChallenge,
                proofHash,
                ownerWallet,
                miningWallet,
                newAcceptedCount,
                block.chainid,
                address(this),
                block.prevrandao,
                block.number
            )
        );
    }
}
