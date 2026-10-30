// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IB20MiningClaims} from "./interfaces/IB20MiningClaims.sol";
import {IB20FinalizationStatus} from "./interfaces/IB20FinalizationStatus.sol";

/// @dev The one MINER capability this contract needs beyond the ERC-20
/// compatible surface: burning its own balance. The production MINER is a
/// Base-native B20 Asset and this contract alone is granted its `BURN_ROLE`
/// during the Factory bootstrap transaction.
interface IB20BurnableToken is IERC20 {
    function burn(uint256 value) external;
}

/// @notice Holds the combined 61,000,000,000 MINER claim reserve
/// (60B snapshot/base + 1B NFT; the NFT part was 5B before
/// `B20_REVENUE_MODEL.md` 1.36) and pays out each owner's
/// `baseMinedLocked + nftMinedLocked` exactly once, sourced live from
/// `B20Mining` — no separate list of owners, no duplicate reward
/// accounting. See `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md` §1–§2, §5,
/// §8, §9 for the full design this contract implements.
///
/// Base and NFT accounting share this one contract's token balance but
/// are tracked through four independent counters
/// (`baseReserveRemaining`/`nftReserveRemaining`/`totalBaseClaimed`/
/// `totalNftClaimed`) — a deliberate, logical-not-physical separation
/// (see the design doc §1.3): fewer contracts and external calls, at the
/// cost of not being structurally impossible for a bug to cross the two
/// buckets the way two separate contracts would be. Neither bucket is
/// ever computed from this contract's raw token balance — only from
/// `B20Mining`'s own counters and this contract's own claimed-totals —
/// so tokens sent here directly, outside the one official funding
/// transfer, are never folded into official reserve/burn accounting and
/// have no rescue path back out.
///
/// No owner, admin, setter, pause, or upgrade path of any kind.
/// `finalizeReserves()` is the only privileged-caller function, and its
/// "privilege" is a single immutable address fixed forever at
/// construction — not a role that can be reassigned.
contract B20ClaimVault is ReentrancyGuard {
    /// @notice The MINER token this vault holds and pays out.
    IB20BurnableToken public immutable minerToken;

    /// @notice Source of truth for what each owner earned and when
    /// mining ended. Read live on every call — never cached beyond the
    /// per-call counters below.
    IB20MiningClaims public immutable mining;

    /// @notice The only address allowed to call `finalizeReserves()`,
    /// and the single flag `claim()` gates on alongside
    /// `reservesFinalized`.
    IB20FinalizationStatus public immutable finalizer;

    /// @notice Fixed snapshot/base claim reserve (60,000,000,000 MINER).
    /// Must equal `mining.BASE_QUOTA_CAP()` — checked once, at
    /// construction.
    uint256 public constant BASE_RESERVE = 60_000_000_000 * 1e18;

    /// @notice Fixed NFT claim reserve (1,000,000,000 MINER). Must equal
    /// `mining.NFT_QUOTA_CAP()` — checked once, at construction.
    uint256 public constant NFT_RESERVE = 1_000_000_000 * 1e18;

    /// @notice Base Sepolia's chain id: the one chain with a short window.
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    /// @notice Claim window length after `mining.MINING_END()`: 15 days,
    /// 1 day on Base Sepolia (like `B20Mining.MINING_DURATION`).
    uint256 public immutable CLAIM_PERIOD;

    /// @notice Base-bucket balance still payable to owners. Set exactly
    /// once by `finalizeReserves()`, then only ever decremented by
    /// `claim()`.
    uint256 public baseReserveRemaining;

    /// @notice NFT-bucket balance still payable to owners. Same
    /// lifecycle as `baseReserveRemaining`, tracked independently.
    uint256 public nftReserveRemaining;

    /// @notice Sum of every successful claim's base component.
    uint256 public totalBaseClaimed;

    /// @notice Sum of every successful claim's NFT component.
    uint256 public totalNftClaimed;

    /// @notice True once `ownerWallet` has claimed — permanent, no path
    /// to reset it.
    mapping(address ownerWallet => bool hasClaimed) public claimed;

    /// @notice True once `finalizeReserves()` has run successfully.
    /// Permanent — `finalizeReserves()` reverts on a second call.
    bool public reservesFinalized;

    /// @notice True once `burnUnclaimed()` has run successfully.
    /// Permanent — `burnUnclaimed()` reverts on a second call.
    bool public unclaimedReserveBurned;

    error ZeroMinerToken();
    error MinerTokenHasNoCode(address minerToken);
    error ZeroMining();
    error MiningHasNoCode(address mining);
    error ZeroFinalizer();
    error FinalizerHasNoCode(address finalizer);
    error BaseQuotaCapMismatch(uint256 actual, uint256 expected);
    error NftQuotaCapMismatch(uint256 actual, uint256 expected);
    error NotFinalizer();
    error TooEarly();
    error AlreadyFinalizedReserves();
    error InsufficientFunding(uint256 balance, uint256 required);
    error ExceedsBaseReserve(uint256 totalBase, uint256 cap);
    error ExceedsNftReserve(uint256 totalNft, uint256 cap);
    error ReservesNotFinalized();
    error FinalizationNotComplete();
    error ClaimWindowClosed();
    error AlreadyClaimed(address ownerWallet);
    error NothingToClaim(address ownerWallet);
    error ClaimWindowStillOpen();
    error AlreadyBurnedUnclaimed();
    error BaseReserveMismatch(uint256 baseReserveRemaining, uint256 unclaimedBase);
    error NftReserveMismatch(uint256 nftReserveRemaining, uint256 unclaimedNft);

    /// @notice Emitted once, when `finalizeReserves()` succeeds.
    event ReservesFinalized(uint256 baseBurned, uint256 nftBurned, uint256 baseLiability, uint256 nftLiability);

    /// @notice Emitted on every successful `claim()`.
    event Claimed(address indexed ownerWallet, uint256 baseAmount, uint256 nftAmount);

    /// @notice Emitted once, when `burnUnclaimed()` succeeds.
    event UnclaimedReserveBurned(uint256 baseAmount, uint256 nftAmount);

    /// @dev Does not require the vault to already hold any MINER — the
    /// combined 65B reserve is expected to arrive afterward via an
    /// ordinary token transfer (see the design doc §4.5), not as part of
    /// construction.
    constructor(address minerToken_, address mining_, address finalizer_) {
        CLAIM_PERIOD = block.chainid == BASE_SEPOLIA_CHAIN_ID ? 1 days : 15 days;
        if (minerToken_ == address(0)) revert ZeroMinerToken();
        if (minerToken_.code.length == 0) revert MinerTokenHasNoCode(minerToken_);
        if (mining_ == address(0)) revert ZeroMining();
        if (mining_.code.length == 0) revert MiningHasNoCode(mining_);
        if (finalizer_ == address(0)) revert ZeroFinalizer();
        if (finalizer_.code.length == 0) revert FinalizerHasNoCode(finalizer_);

        minerToken = IB20BurnableToken(minerToken_);
        mining = IB20MiningClaims(mining_);
        finalizer = IB20FinalizationStatus(finalizer_);

        uint256 baseCap = IB20MiningClaims(mining_).BASE_QUOTA_CAP();
        if (baseCap != BASE_RESERVE) revert BaseQuotaCapMismatch(baseCap, BASE_RESERVE);
        uint256 nftCap = IB20MiningClaims(mining_).NFT_QUOTA_CAP();
        if (nftCap != NFT_RESERVE) revert NftQuotaCapMismatch(nftCap, NFT_RESERVE);
    }

    /// @notice The last timestamp (exclusive) `claim()` will pay out —
    /// `mining.MINING_END() + CLAIM_PERIOD`. `burnUnclaimed()` becomes
    /// callable starting exactly here.
    function claimDeadline() public view returns (uint256) {
        return mining.MINING_END() + CLAIM_PERIOD;
    }

    /// @notice What `ownerWallet` could claim right now: `0` if claiming
    /// is not open yet, the claim window has closed, or `ownerWallet`
    /// already claimed — otherwise `baseMinedLocked + nftMinedLocked`.
    function claimable(address ownerWallet) external view returns (uint256) {
        if (!reservesFinalized || !finalizer.finalized()) return 0;
        if (block.timestamp >= claimDeadline()) return 0;
        if (claimed[ownerWallet]) return 0;
        return mining.baseMinedLocked(ownerWallet) + mining.nftMinedLocked(ownerWallet);
    }

    /// @notice Burns the unmined portion of both reserves and freezes
    /// `baseReserveRemaining`/`nftReserveRemaining` at the real
    /// liability. Callable only by the immutable `finalizer` address,
    /// only at or after `mining.MINING_END()`, and only once. Reverts
    /// (undoing everything, including any burn) if the vault is not yet
    /// funded with at least `BASE_RESERVE + NFT_RESERVE`, or if
    /// `B20Mining` somehow reports more mined than its own caps allow.
    /// Any balance beyond the required funding (a donation) is left
    /// untouched — the burned amounts are derived from `B20Mining`'s
    /// counters against the fixed reserve constants, never from this
    /// contract's own `balanceOf`.
    function finalizeReserves() external nonReentrant {
        if (msg.sender != address(finalizer)) revert NotFinalizer();
        if (block.timestamp < mining.MINING_END()) revert TooEarly();
        if (reservesFinalized) revert AlreadyFinalizedReserves();

        uint256 required = BASE_RESERVE + NFT_RESERVE;
        uint256 balance = minerToken.balanceOf(address(this));
        if (balance < required) revert InsufficientFunding(balance, required);

        uint256 totalBase = mining.totalBaseMinedLocked();
        uint256 totalNft = mining.totalNftMinedLocked();
        if (totalBase > BASE_RESERVE) revert ExceedsBaseReserve(totalBase, BASE_RESERVE);
        if (totalNft > NFT_RESERVE) revert ExceedsNftReserve(totalNft, NFT_RESERVE);

        uint256 unminedBase = BASE_RESERVE - totalBase;
        uint256 unminedNft = NFT_RESERVE - totalNft;

        baseReserveRemaining = totalBase;
        nftReserveRemaining = totalNft;
        reservesFinalized = true;

        uint256 unminedTotal = unminedBase + unminedNft;
        if (unminedTotal > 0) minerToken.burn(unminedTotal);

        emit ReservesFinalized(unminedBase, unminedNft, totalBase, totalNft);
    }

    /// @notice Pays `msg.sender` its exact `baseMinedLocked +
    /// nftMinedLocked` from `B20Mining`, once. There is no address
    /// parameter of any kind — the caller is always both the lookup key
    /// and the payout recipient, so neither a bound mining wallet nor
    /// any third party can claim or redirect another owner's reward.
    function claim() external nonReentrant {
        if (!reservesFinalized) revert ReservesNotFinalized();
        if (!finalizer.finalized()) revert FinalizationNotComplete();
        if (block.timestamp >= claimDeadline()) revert ClaimWindowClosed();
        if (claimed[msg.sender]) revert AlreadyClaimed(msg.sender);

        uint256 baseAmount = mining.baseMinedLocked(msg.sender);
        uint256 nftAmount = mining.nftMinedLocked(msg.sender);
        uint256 total = baseAmount + nftAmount;
        if (total == 0) revert NothingToClaim(msg.sender);

        claimed[msg.sender] = true;
        baseReserveRemaining -= baseAmount;
        nftReserveRemaining -= nftAmount;
        totalBaseClaimed += baseAmount;
        totalNftClaimed += nftAmount;

        SafeERC20.safeTransfer(minerToken, msg.sender, total);

        emit Claimed(msg.sender, baseAmount, nftAmount);
    }

    /// @notice Permissionlessly burns whatever earned-but-never-claimed
    /// MINER remains once the claim window has fully closed — computed
    /// as the exact liability (`mining.totalBaseMinedLocked() -
    /// totalBaseClaimed`, and the NFT equivalent), never as this
    /// contract's raw token balance. Reverts if that exact liability does
    /// not match `baseReserveRemaining`/`nftReserveRemaining` (an
    /// internal consistency check), and reverts on a second call — any
    /// balance beyond the computed liability (a donation) is left
    /// untouched and permanently unrecoverable, by design: there is no
    /// rescue function anywhere in this contract.
    function burnUnclaimed() external nonReentrant {
        if (block.timestamp < claimDeadline()) revert ClaimWindowStillOpen();
        if (!reservesFinalized) revert ReservesNotFinalized();
        if (!finalizer.finalized()) revert FinalizationNotComplete();
        if (unclaimedReserveBurned) revert AlreadyBurnedUnclaimed();

        uint256 unclaimedBase = mining.totalBaseMinedLocked() - totalBaseClaimed;
        uint256 unclaimedNft = mining.totalNftMinedLocked() - totalNftClaimed;

        if (baseReserveRemaining != unclaimedBase) revert BaseReserveMismatch(baseReserveRemaining, unclaimedBase);
        if (nftReserveRemaining != unclaimedNft) revert NftReserveMismatch(nftReserveRemaining, unclaimedNft);

        unclaimedReserveBurned = true;
        baseReserveRemaining = 0;
        nftReserveRemaining = 0;

        uint256 amount = unclaimedBase + unclaimedNft;
        if (amount > 0) minerToken.burn(amount);

        emit UnclaimedReserveBurned(unclaimedBase, unclaimedNft);
    }
}
