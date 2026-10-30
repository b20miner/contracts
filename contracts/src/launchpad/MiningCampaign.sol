// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {B20PoW} from "../B20PoW.sol";
import {ICampaignToken, IMiningCampaignSettlement} from "./interfaces/ILaunchpadInterfaces.sol";

/// @notice One Launchpad campaign's mining, claim and burn
/// (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §3.2). Deployed once as an
/// implementation; every campaign is an EIP-1167 clone of it, initialized
/// once by `LaunchpadFactory` in the creation transaction. There is no
/// admin, no upgrade and no pause: after `initialize` nothing about the
/// campaign can change.
///
/// Proofs use the exact B20MINER PoW preimage (`B20PoW`, domain
/// `B20_POW_V1`) with this clone's address as the contract field, so the
/// web and CLI hashers work unchanged and a proof can never be replayed on
/// another campaign, chain, owner or mining wallet.
///
/// Price (K55, Launchpad v7, owner decision of 1 October 2026): 1 ETH buys
/// `S / 10` tokens — 100,000,000 at the fixed supply of 1 billion, so the
/// whole supply is worth 10 ETH at the mining price. In the smallest units,
/// `tokenWei = ethWei × S × 10,000 / 100,000`, exact for every whole-number
/// supply (§2.2). Each full proof pays `proofFee` (0.0001 ETH since K57,
/// Launchpad v9; v7–v8: 0.000025 ETH) and earns `proofFee × S × 10,000 /
/// 100,000` token units (10,000 tokens; v7–v8: 2,500); a smaller
/// last proof pays a proportionally smaller fee, rounded up to the wei.
/// (v1–v6: 1 ETH bought `S × 12 / 100,000` tokens, 120,000 at 1 billion.)
///
/// Fees (K56, Launchpad v8, owner decision of 4 October 2026): the
/// platform's share of each proof fee rises with the mined amount — 1%
/// while less than 4% of the mining reserve is mined, then 2%, 3%, 4% at
/// each further 4%, and 5% from 16% on (five equal steps over the first
/// 20%); a proof pays the rate of the highest step it reaches, so the
/// pool never gets more than the steps give it. The platform share
/// is paid out by `withdrawPlatformFees` (anyone may call); the rest —
/// rounding in its favour — is the campaign pool's share. Over a full
/// sell-out the platform takes 4.6% and the pool 95.4% (v1–v7: a flat 10%). It
/// stays here until `CampaignPool` settles the campaign and is then sent to
/// the pool. Since Launchpad v5 nothing is refunded (K49): a campaign that
/// misses its minimum pool, or that nobody mined, launches directly (v5–v11:
/// its unmined reserve went to the pool; since v12 it is never minted, K65).
///
/// Who mines: anyone (K50, Launchpad v6 — the allowlist mode of K19 is
/// gone). Every owner mines up to the same per-wallet cap in ETH (K31).
/// Launchpad v13 (owner decision, 19 Oct 2026) has no MINER staking: up to
/// v12 a stake bonus raised the cap (K20) and an optional stakers' window
/// let only stakers mine first (K36).
///
/// Opening (K63, Launchpad v11, owner decision of 8 October 2026): nobody has
/// to claim. Once `CampaignPool` settles the campaign, `distribute` (anyone;
/// the B20MINER relay in practice) sends every owner their tokens in batches,
/// in the order they first mined, and the pool only opens for trading after
/// the last owner has them — everyone starts on the same line. With claim
/// vesting, `distribute` sends the first tranche (`FIRST_TRANCHE_BPS`, 25%)
/// and the rest vests linearly and is claimed. A 2× campaign opens at 2×
/// only if `doubleOpeningQualified` (at least 0.5 ETH mined by at least 10
/// miners of 0.005 ETH or more); otherwise its pool opens at 1×.
///
/// Mined, not pre-minted (K65, Launchpad v12, owner decision of 8 October
/// 2026): the token starts with no supply. Every accepted proof (or batch of
/// 16 shares) mints its reward — the campaign holds `MINT_ROLE` and mints
/// into its own escrow, delivered by `distribute` as before — so the supply
/// is exactly what was mined; the unmined reserve is never minted. Each
/// proof is also a block of the token's own chain: height, parent hash, the
/// proof hash, the owner, the mining wallet and the amount minted, chained
/// from the campaign seed (`TokenBlock`). At settle the campaign gives up
/// `MINT_ROLE` for good. Difficulty and price are unchanged.
contract MiningCampaign is IMiningCampaignSettlement, ReentrancyGuard {
    using SafeERC20 for ICampaignToken;

    enum Status {
        Active,
        Finalized // pool created (full range or direct launch), claims open
    }

    struct InitParams {
        address token;
        address pool;
        address platformTreasury;
        uint256 powTarget;
        uint256 proofFee; // wei, one full proof
        uint256 supplyWhole; // S, whole tokens
        uint256 miningReserve; // Rm, token units: the most its proofs can mint (K65)
        uint64 start;
        uint8 durationDays;
        uint256 walletCapWei; // per-owner cap
        bool hourlySchedule;
        uint8 claimVestingDays;
    }

    uint256 public constant PRICE_DEN = 100_000;
    /// @notice `priceNum = S × PRICE_PER_SUPPLY` (K55); the factory and the
    /// pool use the same number, which the deploy script checks.
    uint256 public constant PRICE_PER_SUPPLY = 10_000;
    uint256 public constant BPS = 10_000;
    /// @notice K56: the platform share starts at 1% and rises by 1% for every
    /// `PLATFORM_STEPS`-th of the first fifth of the reserve, to 5%.
    uint256 public constant PLATFORM_MIN_BPS = 100;
    uint256 public constant PLATFORM_MAX_BPS = 500;
    uint256 public constant PLATFORM_STEPS = 5;
    /// @notice The share is 5% from `PLATFORM_RAMP_BPS` − one step (16%) of the reserve on.
    uint256 public constant PLATFORM_RAMP_BPS = 2_000;
    /// @notice K58 (Launchpad v10): a batch of this many shares earns one
    /// proof's reward for one proof's fee (`submitShares`).
    uint256 public constant SHARES_PER_PROOF = 16;
    /// @notice A share's target is the proof target × 2^SHARE_SHIFT
    /// (16 times easier), so 16 shares are one proof's work on average.
    uint256 public constant SHARE_SHIFT = 4;
    uint256 public constant CLAIM_WINDOW = 15 days;
    /// @notice K63: with claim vesting, the share of each owner's tokens
    /// vested at finalize and sent by `distribute`; the rest vests linearly.
    uint256 public constant FIRST_TRANCHE_BPS = 2_500;
    /// @notice K63: a 2× campaign keeps its 2× opening only with at least
    /// this much mined (in ETH at the mining price) …
    uint256 public constant DOUBLE_MIN_MINED_WEI = 0.5 ether;
    /// @notice … by at least this many miners …
    uint256 public constant DOUBLE_MIN_MINERS = 10;
    /// @notice … each of whom mined at least this much (in ETH).
    uint256 public constant MINER_MIN_WEI = 0.005 ether;

    // ---- set once by initialize ----
    address public factory;
    ICampaignToken public token;
    address public pool;
    address public platformTreasury;
    uint256 public powTarget;
    uint256 public proofFee;
    uint256 public priceNum; // S × PRICE_PER_SUPPLY: tokenWei = ethWei × priceNum / PRICE_DEN
    uint256 public rewardPerProof;
    uint256 public miningReserve;
    uint64 public start;
    uint64 public end;
    uint256 public capTokens; // per-owner cap (the quota of every owner)
    bool public hourlySchedule;
    uint8 public claimVestingDays;

    // ---- mining ----
    bool public opened;
    bytes32 public seed;
    uint256 public minedTotal;
    uint256 public platformAccrued;
    uint256 public poolAccrued;
    mapping(address owner => uint256) public minedOf;
    mapping(address owner => uint256) public poolPaidOf;
    mapping(address owner => uint256) public acceptedProofs;
    mapping(address owner => bytes32) private _storedChallenge;
    /// @notice K63: tokens an owner needs to count towards `DOUBLE_MIN_MINERS`.
    uint256 public minerMinTokens;
    /// @notice K63: owners who mined at least `minerMinTokens`.
    uint256 public qualifiedMiners;
    /// @dev Every owner, in the order of their first proof (K63 distribution).
    address[] private _owners;
    /// @notice K65: blocks of the token's chain so far (one per accepted proof).
    uint256 public tokenBlocks;
    /// @notice K65: the hash of the latest block (the campaign seed before the first).
    bytes32 public tokenBlockHash;

    // ---- settlement ----
    Status public status;
    uint64 public finalizedAt;
    bool public unclaimedBurned;
    mapping(address owner => uint256) public claimedOf;
    /// @notice K63: owners `distribute` has served so far (a prefix of the list).
    uint256 public distributedCount;

    error AlreadyInitialized();
    error InvalidInit();
    error NotPool();
    error NotStarted();
    error WindowClosed();
    error AlreadyOpened();
    error NotOpened();
    error ZeroOwner();
    error StaleChallenge(bytes32 expected, bytes32 current);
    error InvalidProof();
    error SharesNotAscending(uint256 index);
    error InvalidShare(uint256 index);
    error ReserveExhausted();
    error QuotaExhausted(address owner);
    error HourlyLimitReached(uint256 nextHourAt);
    error InsufficientFee(uint256 provided, uint256 required);
    error MiningNotOver();
    error NotActive();
    error NotFinalized();
    error ClaimClosed();
    error NothingToClaim();
    error DeadlineNotReached();
    error AlreadyBurned();
    error DistributionPending();
    error EthTransferFailed(address to, uint256 amount);

    event Opened(bytes32 seed, uint64 start, uint64 end, address indexed opener);
    event ProofRewarded(
        address indexed owner,
        address indexed miner,
        uint256 reward,
        uint256 fee,
        uint256 minedOfOwner,
        uint256 minedTotal,
        bytes32 newChallenge
    );
    /// @notice K65: block `height` of the token's chain — `minted` tokens
    /// brought into existence by `proofHash` (one proof, or the hash of a
    /// batch's 16 share hashes) for `owner`, found by `miner`.
    event TokenBlock(
        uint256 indexed height,
        address indexed owner,
        address indexed miner,
        bytes32 blockHash,
        bytes32 parentHash,
        bytes32 proofHash,
        uint256 minted
    );
    event PlatformFeesWithdrawn(address indexed treasury, uint256 amount);
    event Settled(bool direct, uint256 ethToPool, uint256 tokensToPool, uint256 burned);
    /// @notice A claim, or (K63) a delivery by `distribute`.
    event Claimed(address indexed owner, uint256 amount, uint256 claimedTotal);
    /// @notice K63: `distribute` has served `served` of `owners` owners.
    event Distributed(uint256 served, uint256 owners);
    event UnclaimedBurned(uint256 amount);

    /// @dev The implementation itself can never be initialized; only clones.
    constructor() {
        factory = address(1);
    }

    function initialize(InitParams calldata p) external {
        if (factory != address(0)) revert AlreadyInitialized();
        if (
            p.token == address(0) || p.pool == address(0) || p.platformTreasury == address(0) || p.powTarget == 0
                || p.proofFee == 0 || p.supplyWhole == 0 || p.miningReserve == 0 || p.durationDays == 0
                || p.walletCapWei == 0
        ) revert InvalidInit();

        factory = msg.sender;
        token = ICampaignToken(p.token);
        pool = p.pool;
        platformTreasury = p.platformTreasury;
        powTarget = p.powTarget;
        proofFee = p.proofFee;
        priceNum = p.supplyWhole * PRICE_PER_SUPPLY;
        rewardPerProof = p.proofFee * priceNum / PRICE_DEN;
        if (rewardPerProof == 0) revert InvalidInit();
        miningReserve = p.miningReserve;
        start = p.start;
        end = p.start + uint64(p.durationDays) * 1 days;
        capTokens = p.walletCapWei * priceNum / PRICE_DEN;
        minerMinTokens = MINER_MIN_WEI * priceNum / PRICE_DEN;
        hourlySchedule = p.hourlySchedule;
        claimVestingDays = p.claimVestingDays;
    }

    // ------------------------------------------------------------------
    // Opening
    // ------------------------------------------------------------------

    /// @notice Anyone, from `start` until `end`; the web app and the CLI
    /// send it for the first miner. The seed comes from the opening block,
    /// so nobody — the creator included — can know a challenge, let alone
    /// mine, before it. (A proof cannot open the campaign itself: its
    /// challenge would come from the same block and could not be known in
    /// advance.) The window is `[start, end)` whenever `open` is called.
    function open() external {
        if (opened) revert AlreadyOpened();
        if (block.timestamp < start) revert NotStarted();
        if (block.timestamp >= end) revert WindowClosed();
        bytes32 s = keccak256(
            abi.encodePacked(
                "B20_CAMPAIGN_SEED_V1",
                block.chainid,
                address(this),
                block.prevrandao,
                block.number,
                blockhash(block.number - 1)
            )
        );
        opened = true;
        seed = s;
        emit Opened(s, start, end, msg.sender);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function challengeOf(address owner) public view returns (bytes32) {
        bytes32 stored = _storedChallenge[owner];
        if (stored != bytes32(0)) return stored;
        if (!opened) return bytes32(0);
        return keccak256(abi.encodePacked("B20_OWNER_CHALLENGE_V1", seed, block.chainid, address(this), owner));
    }

    /// @notice The owner's total quota: the per-wallet cap, the same for
    /// everyone (v13: no stake bonus). Kept as a function so readers of
    /// earlier versions keep one call.
    function quotaOf(address) public view returns (uint256) {
        return capTokens;
    }

    function remainingQuota(address owner) public view returns (uint256) {
        uint256 q = quotaOf(owner);
        uint256 m = minedOf[owner];
        return q > m ? q - m : 0;
    }

    /// @notice Reserve released so far. Without the hourly schedule, all of
    /// it. With it, `miningReserve × hours started / total hours` (§2.4).
    function releasedReserve() public view returns (uint256) {
        if (!hourlySchedule) return miningReserve;
        if (block.timestamp < start) return 0;
        uint256 totalHours = uint256(end - start) / 1 hours;
        uint256 hoursStarted = (block.timestamp - start) / 1 hours + 1;
        if (hoursStarted >= totalHours) return miningReserve;
        return miningReserve * hoursStarted / totalHours;
    }

    /// @notice When the next hour's share is released (0 without the schedule).
    function nextReleaseAt() public view returns (uint256) {
        if (!hourlySchedule) return 0;
        if (block.timestamp < start) return start;
        return uint256(start) + ((block.timestamp - start) / 1 hours + 1) * 1 hours;
    }

    function miningFeeFor(uint256 reward) public view returns (uint256) {
        return (reward * PRICE_DEN + priceNum - 1) / priceNum;
    }

    /// @notice K58: the target a share must meet — `powTarget` × 16 (all
    /// ones below), capped at the largest value. 2^236 − 1 at the 24-bit
    /// proof target: one share takes 2^20 hashes on average.
    function shareTarget() public view returns (uint256) {
        uint256 t = powTarget;
        if (t > type(uint256).max >> SHARE_SHIFT) return type(uint256).max;
        return (t << SHARE_SHIFT) | ((1 << SHARE_SHIFT) - 1);
    }

    /// @notice What `owner`'s next proof would earn and cost now; (0, 0) when
    /// it cannot earn anything (outside the window, quota, reserve or hour).
    function quoteProof(address owner) public view returns (uint256 reward, uint256 fee) {
        if (block.timestamp < start || block.timestamp >= end || status != Status.Active) return (0, 0);
        reward = _rewardFor(remainingQuota(owner));
        fee = reward == 0 ? 0 : miningFeeFor(reward);
    }

    /// @dev `min(rewardPerProof, remaining quota, released − mined)`.
    function _rewardFor(uint256 remaining) internal view returns (uint256 reward) {
        reward = rewardPerProof;
        if (remaining < reward) reward = remaining;
        uint256 released = releasedReserve();
        uint256 avail = released > minedTotal ? released - minedTotal : 0;
        if (avail < reward) reward = avail;
    }

    /// @inheritdoc IMiningCampaignSettlement
    function miningOver() public view returns (bool) {
        return block.timestamp >= end || minedTotal >= miningReserve;
    }

    function claimDeadline() public view returns (uint256) {
        if (status != Status.Finalized) return 0;
        return uint256(finalizedAt) + uint256(claimVestingDays) * 1 days + CLAIM_WINDOW;
    }

    /// @notice Tokens `owner` may claim now (vesting applied).
    function claimable(address owner) public view returns (uint256) {
        if (status != Status.Finalized) return 0;
        return _vested(owner) - claimedOf[owner];
    }

    /// @dev K63: without vesting, everything; with it, the first tranche at
    /// finalize and the rest linearly over `claimVestingDays`.
    function _vested(address owner) internal view returns (uint256) {
        uint256 total = minedOf[owner];
        if (claimVestingDays == 0) return total;
        uint256 duration = uint256(claimVestingDays) * 1 days;
        uint256 elapsed = block.timestamp - finalizedAt;
        if (elapsed >= duration) return total;
        uint256 first = total * FIRST_TRANCHE_BPS / BPS;
        return first + (total - first) * elapsed / duration;
    }

    /// @notice Owners who have mined, in the order of their first proof.
    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    function ownerAt(uint256 index) external view returns (address) {
        return _owners[index];
    }

    /// @notice K63: the mined amount in ETH at the mining price.
    function minedEth() public view returns (uint256) {
        return minedTotal * PRICE_DEN / priceNum;
    }

    /// @inheritdoc IMiningCampaignSettlement
    function doubleOpeningQualified() public view returns (bool) {
        return minedEth() >= DOUBLE_MIN_MINED_WEI && qualifiedMiners >= DOUBLE_MIN_MINERS;
    }

    /// @inheritdoc IMiningCampaignSettlement
    function distributionDone() public view returns (bool) {
        return distributedCount == _owners.length;
    }

    // ------------------------------------------------------------------
    // Proofs
    // ------------------------------------------------------------------

    /// @notice Submits a PoW proof found by `msg.sender` (the mining
    /// wallet) for `owner`, who is credited the reward. Any excess ETH is
    /// refunded to the caller. Every check runs before any state change.
    function submitProof(address owner, bytes32 expectedChallenge, uint256 nonce) external payable nonReentrant {
        if (!opened) revert NotOpened();
        if (block.timestamp >= end) revert WindowClosed();
        if (status != Status.Active) revert NotActive();
        if (owner == address(0)) revert ZeroOwner();

        uint256 reward = _checkedReward(owner);

        bytes32 current = challengeOf(owner);
        if (expectedChallenge != current) revert StaleChallenge(expectedChallenge, current);
        bytes32 proofHash = B20PoW.computeHash(block.chainid, address(this), owner, msg.sender, current, nonce);
        if (uint256(proofHash) > powTarget) revert InvalidProof();

        uint256 fee = miningFeeFor(reward);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        _record(owner, current, proofHash, reward, fee);

        uint256 excess = msg.value - fee;
        if (excess > 0) _sendEth(msg.sender, excess);
    }

    /// @notice K58 (Launchpad v10, experimental): submits exactly
    /// `SHARES_PER_PROOF` shares found by `msg.sender` (the mining wallet)
    /// for `owner` under the owner's current challenge, for one proof's
    /// reward and fee — the same as `submitProof`, but the work comes in 16
    /// steps of `shareTarget` instead of one at `powTarget` (the same work on
    /// average, much less luck). Nonces must be strictly ascending, so no
    /// share counts twice; the challenge then advances as after a proof, so
    /// unsent shares of an earlier challenge are worth nothing. There is no
    /// partial batch: a session that stops before 16 shares sends nothing.
    function submitShares(address owner, bytes32 expectedChallenge, uint256[16] calldata nonces)
        external
        payable
        nonReentrant
    {
        if (!opened) revert NotOpened();
        if (block.timestamp >= end) revert WindowClosed();
        if (status != Status.Active) revert NotActive();
        if (owner == address(0)) revert ZeroOwner();

        uint256 reward = _checkedReward(owner);

        bytes32 current = challengeOf(owner);
        if (expectedChallenge != current) revert StaleChallenge(expectedChallenge, current);
        uint256 target = shareTarget();
        bytes32[16] memory hashes;
        // The B20PoW preimage built once; only its last word (the nonce)
        // changes per share (`B20PoW.computeHash`, tested equal).
        bytes memory preimage = abi.encodePacked("B20_POW_V1", block.chainid, address(this), owner, msg.sender, current, uint256(0));
        uint256 len = preimage.length;
        for (uint256 i; i < SHARES_PER_PROOF; ++i) {
            uint256 nonce = nonces[i];
            if (i > 0 && nonce <= nonces[i - 1]) revert SharesNotAscending(i);
            bytes32 h;
            assembly ("memory-safe") {
                let data := add(preimage, 0x20)
                mstore(add(data, sub(len, 0x20)), nonce)
                h := keccak256(data, len)
            }
            if (uint256(h) > target) revert InvalidShare(i);
            hashes[i] = h;
        }

        uint256 fee = miningFeeFor(reward);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        _record(owner, current, keccak256(abi.encodePacked(hashes)), reward, fee);

        uint256 excess = msg.value - fee;
        if (excess > 0) _sendEth(msg.sender, excess);
    }

    /// @dev Advances the owner's challenge, credits the reward and splits
    /// the fee: the platform share of the step the proof's last token falls
    /// in (K56), the rest (rounding in its favour) pool. K65: adds the
    /// token's next block and mints the reward into this escrow.
    function _record(address owner, bytes32 current, bytes32 proofHash, uint256 reward, uint256 fee) internal {
        uint256 platformShare = fee * _shareBps(minedTotal + reward - 1) / BPS;
        uint256 poolShare = fee - platformShare;

        uint256 count = acceptedProofs[owner] + 1;
        acceptedProofs[owner] = count;
        bytes32 next = keccak256(
            abi.encodePacked(
                "B20_NEXT_CHALLENGE_V1",
                current,
                proofHash,
                owner,
                msg.sender,
                count,
                block.chainid,
                address(this),
                block.prevrandao,
                block.number
            )
        );
        _storedChallenge[owner] = next;
        uint256 before = minedOf[owner];
        if (before == 0) _owners.push(owner);
        uint256 ownerTotal = before + reward;
        if (before < minerMinTokens && ownerTotal >= minerMinTokens) ++qualifiedMiners;
        minedOf[owner] = ownerTotal;
        minedTotal += reward;
        poolPaidOf[owner] += poolShare;
        platformAccrued += platformShare;
        poolAccrued += poolShare;

        emit ProofRewarded(owner, msg.sender, reward, fee, ownerTotal, minedTotal, next);
        _mintBlock(owner, proofHash, reward);
    }

    /// @dev K65: the token's next block — chained from the campaign seed,
    /// committing to the proof, the owner, the mining wallet and the amount
    /// — and the mint of its reward into this escrow.
    function _mintBlock(address owner, bytes32 proofHash, uint256 reward) internal {
        uint256 height = tokenBlocks + 1;
        bytes32 parent = height == 1 ? seed : tokenBlockHash;
        bytes32 hash = keccak256(
            abi.encodePacked(
                "B20_TOKEN_BLOCK_V1",
                block.chainid,
                address(this),
                height,
                parent,
                proofHash,
                owner,
                msg.sender,
                reward
            )
        );
        tokenBlocks = height;
        tokenBlockHash = hash;
        emit TokenBlock(height, owner, msg.sender, hash, parent, proofHash, reward);
        token.mint(address(this), reward);
    }

    /// @dev The reward, with the specific reason when it is zero.
    function _checkedReward(address owner) internal view returns (uint256 reward) {
        if (minedTotal >= miningReserve) revert ReserveExhausted();
        uint256 quota = capTokens;
        uint256 mined = minedOf[owner];
        if (quota <= mined) revert QuotaExhausted(owner);
        reward = _rewardFor(quota - mined);
        if (reward == 0) revert HourlyLimitReached(nextReleaseAt());
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------

    /// @notice K56: the platform's share (bps) of the fee for the next token
    /// mined — 1% below 4% of the reserve mined, +1% per further 4%, 5% from
    /// 16% on. A proof pays the rate of its last token.
    function platformShareBps() external view returns (uint256) {
        return _shareBps(minedTotal);
    }

    /// @dev The step of the token at position `mined` (0-based) in the reserve.
    function _shareBps(uint256 mined) internal view returns (uint256) {
        uint256 step = mined * BPS * PLATFORM_STEPS / (miningReserve * PLATFORM_RAMP_BPS);
        if (step >= PLATFORM_STEPS - 1) return PLATFORM_MAX_BPS;
        return PLATFORM_MIN_BPS * (step + 1);
    }

    /// @notice Sends the accrued platform share (K56: 1–5%) to the treasury.
    function withdrawPlatformFees() external nonReentrant {
        uint256 amount = platformAccrued;
        if (amount == 0) return;
        platformAccrued = 0;
        _sendEth(platformTreasury, amount);
        emit PlatformFeesWithdrawn(platformTreasury, amount);
    }

    // ------------------------------------------------------------------
    // Settlement (by CampaignPool only)
    // ------------------------------------------------------------------

    /// @inheritdoc IMiningCampaignSettlement
    function settle(bool direct) external nonReentrant returns (uint256 ethToPool) {
        if (msg.sender != pool) revert NotPool();
        if (status != Status.Active) revert NotActive();
        if (!miningOver()) revert MiningNotOver();

        status = Status.Finalized;
        finalizedAt = uint64(block.timestamp);
        // K65: the unmined reserve was never minted, so no token moves
        // (`tokensToPool` is always 0); mining is over, the mint role goes.
        ethToPool = poolAccrued;
        poolAccrued = 0;
        emit Settled(direct, ethToPool, 0, 0);
        token.renounceRole(B20Constants.MINT_ROLE, address(this));
        if (ethToPool > 0) _sendEth(pool, ethToPool);
    }

    // ------------------------------------------------------------------
    // Distribution (K63), claim, burn
    // ------------------------------------------------------------------

    /// @notice Anyone, after settlement: sends the next `max` owners (in the
    /// order of their first proof) what they can claim now — everything, or
    /// with vesting the first tranche — so nobody has to claim. Owners who
    /// already claimed are skipped. The pool opens for trading only once
    /// every owner has been served (`distributionDone`).
    function distribute(uint256 max) external nonReentrant returns (uint256 served) {
        if (status != Status.Finalized) revert NotFinalized();
        uint256 i = distributedCount;
        uint256 n = _owners.length;
        uint256 stop = n - i > max ? i + max : n;
        for (; i < stop; ++i) {
            address owner = _owners[i];
            uint256 amount = claimable(owner);
            if (amount == 0) continue;
            uint256 total = claimedOf[owner] + amount;
            claimedOf[owner] = total;
            emit Claimed(owner, amount, total);
            token.safeTransfer(owner, amount);
        }
        served = stop - distributedCount;
        distributedCount = stop;
        emit Distributed(stop, n);
    }

    /// @notice The owner claims what has vested so far, until the deadline.
    function claim() external nonReentrant {
        if (status != Status.Finalized) revert NotFinalized();
        if (block.timestamp > claimDeadline()) revert ClaimClosed();
        uint256 amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimedOf[msg.sender] += amount;
        emit Claimed(msg.sender, amount, claimedOf[msg.sender]);
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice After the deadline, anyone burns every unclaimed token — only
    /// once every owner has had their delivery (K63).
    function burnUnclaimed() external nonReentrant {
        if (status != Status.Finalized) revert NotFinalized();
        if (block.timestamp <= claimDeadline()) revert DeadlineNotReached();
        if (!distributionDone()) revert DistributionPending();
        if (unclaimedBurned) revert AlreadyBurned();
        unclaimedBurned = true;
        uint256 amount = token.balanceOf(address(this));
        emit UnclaimedBurned(amount);
        if (amount > 0) token.burn(amount);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }
}
