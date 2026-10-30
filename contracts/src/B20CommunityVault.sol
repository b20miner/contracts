// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IB20MiningClaims} from "./interfaces/IB20MiningClaims.sol";

interface IB20ClaimDeadline {
    function claimDeadline() external view returns (uint256);
}

interface IB20MinerBurner {
    function MINER() external view returns (address);
    function burn() external returns (uint256);
}

/// @notice The 8,000,000,000 MINER community rewards reserve
/// (`B20_REVENUE_MODEL.md` 1.36; owner decisions of 27 September 2026).
/// Unlike the ecosystem vault, which the project spends as it sees fit,
/// this reserve can only ever go to users, by fixed rules:
///
/// **1. Scaling at the end of mining (`settle`, anyone, once).** The
/// reserve shrinks with participation, like the unmined snapshot quota:
/// it keeps `max(1,000,000,000, 8,000,000,000 × baseMined / 60,000,000,000)`
/// and burns the rest through `MinerBurner`. `baseMined` is B20Mining's
/// total snapshot quota mined, final from `MINING_END`.
///
/// **2. Staking rewards — 3/8 of what is kept.** Streamed over five years
/// — 30%, 25%, 20%, 15%, 10% — linearly within each year, starting at
/// B20MINER's claim deadline (`MINING_END + CLAIM_PERIOD`, 15 days; 1 day on
/// Base Sepolia), so everybody can
/// claim and stake before the first second of rewards. Only the staking
/// contract (`stakingRecipient`) can pull what has streamed; it is set
/// once by `MANAGER` behind a 48-hour public timelock and can never change
/// afterwards. Nothing streams to anyone else.
///
/// **3. Airdrops — 5/8 of what is kept.** In rounds whose criteria the
/// owner chooses each time (Launchpad use, staking, NFT holders, or
/// anything else), published as a Merkle list:
/// - `MANAGER` queues a round (root + amount); it waits 48 hours in public
///   before anyone can start it;
/// - a round is at most 50% of the airdrop share, and rounds start at
///   least 30 days apart;
/// - each round is claimable for 90 days; what is left then returns to the
///   airdrop share for later rounds.
/// Tokens leave this vault only to the staking contract, to listed
/// claimants, or to the burner. `MANAGER` (the ecosystem multisig) can
/// queue and cancel, never move tokens itself. No upgrade, no other
/// withdrawal.
contract B20CommunityVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant COMMUNITY_RESERVE = 8_000_000_000 * 1e18;
    uint256 public constant FLOOR = 1_000_000_000 * 1e18;
    uint256 public constant BASE_QUOTA_CAP = 60_000_000_000 * 1e18;
    uint256 public constant STAKING_SHARE_NUM = 3; // 3/8 staking, 5/8 airdrops
    uint256 public constant STAKING_SHARE_DEN = 8;
    uint256 public constant STAKING_YEARS = 5;
    uint256 public constant YEAR = 365 days;
    uint256 public constant BPS = 10_000;
    uint256 public constant TIMELOCK = 48 hours;
    uint256 public constant ROUND_MAX_BPS = 5_000; // 50% of the airdrop share
    uint256 public constant ROUND_INTERVAL = 30 days;
    uint256 public constant ROUND_CLAIM_WINDOW = 90 days;

    IERC20 public immutable MINER;
    IB20MiningClaims public immutable MINING;
    IB20ClaimDeadline public immutable CLAIM_VAULT;
    IB20MinerBurner public immutable BURNER;
    address public immutable MANAGER;

    // ---- settlement ----
    bool public settled;
    uint256 public baseMinedAtSettle;
    uint256 public keptTotal;
    uint256 public stakingPot;
    uint256 public airdropPot;
    uint256 public rewardsStart;

    // ---- staking stream ----
    address public stakingRecipient;
    address public pendingStakingRecipient;
    uint256 public pendingStakingRecipientReadyAt;
    uint256 public stakingReleased;

    // ---- airdrop rounds ----
    struct Round {
        bytes32 merkleRoot;
        uint256 amount;
        uint256 claimed;
        uint64 readyAt;
        uint64 startedAt;
        uint64 deadline;
        bool cancelled;
        bool closed;
    }

    Round[] internal _rounds;
    mapping(uint256 roundId => mapping(address account => bool)) public claimedIn;
    uint256 public airdropUnallocated;
    uint256 public lastRoundStartedAt;

    error ZeroAddress();
    error BaseQuotaCapMismatch(uint256 mining, uint256 expected);
    error BurnerTokenMismatch(address burnerMiner, address miner);
    error NotManager();
    error AlreadySettled();
    error NotSettled();
    error MiningNotEnded(uint256 miningEnd);
    error NotFunded(uint256 balance);
    error NotStakingRecipient();
    error StakingRecipientAlreadySet();
    error NoPendingStakingRecipient();
    error TimelockActive(uint256 readyAt);
    error InvalidRound();
    error RoundTooLarge(uint256 amount, uint256 max);
    error InsufficientAirdrop(uint256 amount, uint256 unallocated);
    error RoundNotStartable();
    error RoundIntervalActive(uint256 nextAllowedAt);
    error RoundNotOpen();
    error RoundStillOpen(uint256 deadline);
    error AlreadyClaimed();
    error BadProof();
    error RoundBudgetExceeded();

    event Settled(
        uint256 baseMined, uint256 kept, uint256 burned, uint256 stakingPot, uint256 airdropPot, uint256 rewardsStart
    );
    event StakingRecipientQueued(address indexed recipient, uint256 readyAt);
    event StakingRecipientCancelled(address indexed recipient);
    event StakingRecipientSet(address indexed recipient);
    event StakingReleased(address indexed recipient, uint256 amount, uint256 totalReleased);
    event RoundQueued(uint256 indexed roundId, bytes32 merkleRoot, uint256 amount, uint256 readyAt);
    event RoundCancelled(uint256 indexed roundId);
    event RoundStarted(uint256 indexed roundId, uint256 amount, uint256 deadline);
    event AirdropClaimed(uint256 indexed roundId, address indexed account, uint256 amount);
    event RoundClosed(uint256 indexed roundId, uint256 returned);

    constructor(address miner, address mining, address claimVault, address burner, address manager) {
        if (miner == address(0) || mining == address(0) || claimVault == address(0) || burner == address(0)) {
            revert ZeroAddress();
        }
        if (manager == address(0)) revert ZeroAddress();
        uint256 cap = IB20MiningClaims(mining).BASE_QUOTA_CAP();
        if (cap != BASE_QUOTA_CAP) revert BaseQuotaCapMismatch(cap, BASE_QUOTA_CAP);
        address burnerMiner = IB20MinerBurner(burner).MINER();
        if (burnerMiner != miner) revert BurnerTokenMismatch(burnerMiner, miner);
        MINER = IERC20(miner);
        MINING = IB20MiningClaims(mining);
        CLAIM_VAULT = IB20ClaimDeadline(claimVault);
        BURNER = IB20MinerBurner(burner);
        MANAGER = manager;
    }

    modifier onlyManager() {
        if (msg.sender != MANAGER) revert NotManager();
        _;
    }

    // ------------------------------------------------------------------
    // 1. Settlement
    // ------------------------------------------------------------------

    /// @notice What `settle` would keep for a given snapshot quota mined.
    function keptFor(uint256 baseMined) public pure returns (uint256) {
        uint256 scaled = COMMUNITY_RESERVE * baseMined / BASE_QUOTA_CAP;
        if (scaled < FLOOR) return FLOOR;
        return scaled > COMMUNITY_RESERVE ? COMMUNITY_RESERVE : scaled;
    }

    /// @notice Anyone, once, from `MINING_END`: scales the reserve to
    /// participation, burns the rest and fixes both shares.
    function settle() external nonReentrant {
        if (settled) revert AlreadySettled();
        uint256 miningEnd = MINING.MINING_END(); // reverts until mining is opened
        if (block.timestamp < miningEnd) revert MiningNotEnded(miningEnd);
        uint256 balance = MINER.balanceOf(address(this));
        if (balance < COMMUNITY_RESERVE) revert NotFunded(balance);

        uint256 baseMined = MINING.totalBaseMinedLocked();
        uint256 kept = keptFor(baseMined);
        uint256 excess = COMMUNITY_RESERVE - kept;
        uint256 staking = kept * STAKING_SHARE_NUM / STAKING_SHARE_DEN;

        settled = true;
        baseMinedAtSettle = baseMined;
        keptTotal = kept;
        stakingPot = staking;
        airdropPot = kept - staking;
        airdropUnallocated = kept - staking;
        rewardsStart = CLAIM_VAULT.claimDeadline();
        emit Settled(baseMined, kept, excess, staking, kept - staking, rewardsStart);

        if (excess > 0) {
            MINER.safeTransfer(address(BURNER), excess);
            BURNER.burn();
        }
    }

    // ------------------------------------------------------------------
    // 2. Staking stream
    // ------------------------------------------------------------------

    /// @notice Share of the staking pot for year `index` (0-based), in BPS.
    function yearBps(uint256 index) public pure returns (uint256) {
        if (index == 0) return 3_000;
        if (index == 1) return 2_500;
        if (index == 2) return 2_000;
        if (index == 3) return 1_500;
        if (index == 4) return 1_000;
        return 0;
    }

    /// @notice Staking rewards streamed from `rewardsStart` up to `timestamp`.
    function stakingVestedAt(uint256 timestamp) public view returns (uint256) {
        if (!settled || timestamp <= rewardsStart) return 0;
        uint256 elapsed = timestamp - rewardsStart;
        uint256 year = elapsed / YEAR;
        if (year >= STAKING_YEARS) return stakingPot;
        uint256 doneBps;
        for (uint256 i = 0; i < year; i++) {
            doneBps += yearBps(i);
        }
        uint256 intoYear = elapsed - year * YEAR;
        return stakingPot * doneBps / BPS + stakingPot * yearBps(year) * intoYear / (BPS * YEAR);
    }

    function stakingReleasable() public view returns (uint256) {
        return stakingVestedAt(block.timestamp) - stakingReleased;
    }

    /// @notice The staking contract pulls what has streamed so far.
    function releaseStaking() external nonReentrant returns (uint256 amount) {
        if (msg.sender != stakingRecipient || msg.sender == address(0)) revert NotStakingRecipient();
        amount = stakingReleasable();
        if (amount == 0) return 0;
        stakingReleased += amount;
        emit StakingReleased(msg.sender, amount, stakingReleased);
        MINER.safeTransfer(msg.sender, amount);
    }

    /// @notice Queues the staking contract (once, 48-hour timelock).
    function queueStakingRecipient(address recipient) external onlyManager {
        if (stakingRecipient != address(0)) revert StakingRecipientAlreadySet();
        if (recipient == address(0)) revert ZeroAddress();
        pendingStakingRecipient = recipient;
        pendingStakingRecipientReadyAt = block.timestamp + TIMELOCK;
        emit StakingRecipientQueued(recipient, pendingStakingRecipientReadyAt);
    }

    function cancelStakingRecipient() external onlyManager {
        address pending = pendingStakingRecipient;
        if (pending == address(0)) revert NoPendingStakingRecipient();
        pendingStakingRecipient = address(0);
        pendingStakingRecipientReadyAt = 0;
        emit StakingRecipientCancelled(pending);
    }

    /// @notice Anyone, after the timelock: makes the queued recipient final.
    function confirmStakingRecipient() external {
        if (stakingRecipient != address(0)) revert StakingRecipientAlreadySet();
        address pending = pendingStakingRecipient;
        if (pending == address(0)) revert NoPendingStakingRecipient();
        if (block.timestamp < pendingStakingRecipientReadyAt) revert TimelockActive(pendingStakingRecipientReadyAt);
        stakingRecipient = pending;
        pendingStakingRecipient = address(0);
        pendingStakingRecipientReadyAt = 0;
        emit StakingRecipientSet(pending);
    }

    // ------------------------------------------------------------------
    // 3. Airdrop rounds
    // ------------------------------------------------------------------

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function round(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    /// @notice Largest amount one round may distribute (50% of the share).
    function maxRoundAmount() public view returns (uint256) {
        return airdropPot * ROUND_MAX_BPS / BPS;
    }

    /// @notice `MANAGER` queues a round; it can start 48 hours later.
    function queueRound(bytes32 merkleRoot, uint256 amount) external onlyManager returns (uint256 roundId) {
        if (!settled) revert NotSettled();
        if (merkleRoot == bytes32(0) || amount == 0) revert InvalidRound();
        uint256 max = maxRoundAmount();
        if (amount > max) revert RoundTooLarge(amount, max);
        if (amount > airdropUnallocated) revert InsufficientAirdrop(amount, airdropUnallocated);
        roundId = _rounds.length;
        uint64 readyAt = uint64(block.timestamp + TIMELOCK);
        _rounds.push(
            Round({
                merkleRoot: merkleRoot,
                amount: amount,
                claimed: 0,
                readyAt: readyAt,
                startedAt: 0,
                deadline: 0,
                cancelled: false,
                closed: false
            })
        );
        emit RoundQueued(roundId, merkleRoot, amount, readyAt);
    }

    function cancelRound(uint256 roundId) external onlyManager {
        Round storage r = _rounds[roundId];
        if (r.startedAt != 0 || r.cancelled) revert RoundNotStartable();
        r.cancelled = true;
        emit RoundCancelled(roundId);
    }

    /// @notice Anyone: starts a queued round once its timelock has passed
    /// and at least 30 days after the previous round started.
    function startRound(uint256 roundId) external {
        Round storage r = _rounds[roundId];
        if (r.cancelled || r.startedAt != 0) revert RoundNotStartable();
        if (block.timestamp < r.readyAt) revert TimelockActive(r.readyAt);
        if (lastRoundStartedAt != 0 && block.timestamp < lastRoundStartedAt + ROUND_INTERVAL) {
            revert RoundIntervalActive(lastRoundStartedAt + ROUND_INTERVAL);
        }
        if (r.amount > airdropUnallocated) revert InsufficientAirdrop(r.amount, airdropUnallocated);
        airdropUnallocated -= r.amount;
        r.startedAt = uint64(block.timestamp);
        r.deadline = uint64(block.timestamp + ROUND_CLAIM_WINDOW);
        lastRoundStartedAt = block.timestamp;
        emit RoundStarted(roundId, r.amount, r.deadline);
    }

    /// @notice Pays `account` its listed amount (anyone may submit; the
    /// tokens always go to `account`). Leaf: `keccak256(bytes.concat(
    /// keccak256(abi.encode(account, amount))))`, OpenZeppelin style.
    function claim(uint256 roundId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Round storage r = _rounds[roundId];
        if (r.startedAt == 0 || r.closed || block.timestamp >= r.deadline) revert RoundNotOpen();
        if (claimedIn[roundId][account]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, r.merkleRoot, leaf)) revert BadProof();
        if (r.claimed + amount > r.amount) revert RoundBudgetExceeded();
        claimedIn[roundId][account] = true;
        r.claimed += amount;
        emit AirdropClaimed(roundId, account, amount);
        MINER.safeTransfer(account, amount);
    }

    /// @notice Anyone, after a round's 90 days: returns what was not claimed
    /// to the airdrop share.
    function closeRound(uint256 roundId) external {
        Round storage r = _rounds[roundId];
        if (r.startedAt == 0 || r.closed) revert RoundNotOpen();
        if (block.timestamp < r.deadline) revert RoundStillOpen(r.deadline);
        r.closed = true;
        uint256 unclaimed = r.amount - r.claimed;
        airdropUnallocated += unclaimed;
        emit RoundClosed(roundId, unclaimed);
    }
}
