// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {CampaignPool} from "./CampaignPool.sol";
import {MiningCampaign} from "./MiningCampaign.sol";
import {IEthUsdFeed, ILaunchpadOpening, ILaunchpadRegistry, IMinerLiquiditySink} from "./interfaces/ILaunchpadInterfaces.sol";

/// @notice The B20 Miner Launchpad's single entry point
/// (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §3.1, §4). One transaction
/// creates a campaign:
/// 1. validates the parameters (§2);
/// 2. derives `salt = keccak256(creator, nonce)` and every address from it;
/// 3. clones `MiningCampaign` and `CampaignPool` (EIP-1167, CREATE2) and
///    initializes them;
/// 4. creates the token — a Base-native B20 Asset, admin-less — with its
///    supply cap at the full supply and nothing minted (K65, v12): the
///    campaign and the pool get `MINT_ROLE` and `BURN_ROLE`, nobody else
///    any role. Proofs mint the mining reserve as it is mined (at most 60%
///    of the supply for a 2× opening, 40% for 1×, K55), the pool mints its
///    opening, and each gives the mint role up for good; the factory keeps
///    no power over the token (v1–v11 minted both reserves here);
/// 5. takes the creation fee in ETH — half to the platform, half to MINER
///    liquidity (`FEE_ROUTER`: mainnet `MinerPool`, Base Sepolia
///    `TestMinerPool`; v1–v15 also took MINER at a 20% discount through a
///    V2 TWAP, half of it burned — removed with MINER's V4 pool, owner
///    decision 30 October 2026) — and deposits any extra
///    ETH in the pool for the creator (K21). The fee is 3 USD at Chainlink's
///    ETH/USD price of the moment (K66, v12; v1–v11 fixed it in ETH at the
///    deploy day's price); while the feed is stale or out of range it falls
///    back to `CREATION_FEE_WEI`, the deploy day's 3 USD.
/// An instant launch (K52, v6) skips mining: no `MiningCampaign`, the whole
/// supply goes to the pool, which opens trading in the same transaction at
/// `directLaunchFdvWei` (single-sided, like o1; K68, v14: a fixed ETH amount
/// worth ~5,000 USD that `GUARDIAN` refreshes — v6–v13: 1.5 ETH), with
/// optional opening anti-snipe.
/// Its extra ETH is the creator's own first buy (K56, v8): made in the same
/// transaction, before anyone else can trade and without the anti-snipe
/// surcharge (as Clanker's dev buy and pump.fun's first buy); no limit.
/// Any failure reverts the whole transaction. The creator signs for one
/// exact outcome (K41): the transaction reverts after `deadline`, and unless
/// it creates `expectedToken` — the address `predict` showed before signing
/// (another create from the same wallet, landing first, would change it).
/// It is also the registry the `PositionLocker` trusts (`poolToken`), and
/// carries the creator's announcements (events only).
///
/// v13 (owner decision, 19 Oct 2026): no MINER staking — no stake registry,
/// no stakers' window, no stake bonus (up to v12: K20, K36); the
/// name is at most `MAX_NAME_BYTES`, the symbol `MAX_SYMBOL_BYTES`.
///
/// v14 (owner decisions, 26 Oct 2026): a direct or instant launch opens at
/// `directLaunchFdvWei`, a fixed ETH amount as on o1 (K68): ~5,000 USD on
/// the deploy day, refreshed now and then by `GUARDIAN`
/// (`setDirectLaunchFdvWei`, within `MIN_DIRECT_LAUNCH_FDV_WEI` ..
/// `MAX_DIRECT_LAUNCH_FDV_WEI`); a pool keeps the value it opened with. The
/// 1% trading fee is taken in ETH by the hook and split 50% creator / 30%
/// platform / 20% MINER liquidity (K69, `PositionLocker`).
///
/// Privileged actions, `GUARDIAN` only: close this template version to new
/// campaigns (`deprecate`), once and for good, and refresh the opening FDV
/// of pools that have not opened yet. It cannot touch any open pool, any
/// campaign's terms or any funds.
contract LaunchpadFactory is ILaunchpadRegistry, ILaunchpadOpening, ReentrancyGuard {

    struct CreateParams {
        string name;
        string symbol;
        uint256 totalSupply; // whole tokens: exactly SUPPLY (K43)
        uint64 startTime; // must be 0: mining starts in the create transaction (K44)
        uint8 durationDays; // 1 | 3 | 7 | 15 (1 day since v5, K49)
        uint256 walletCapWei; // 0.1 .. 10 ETH; anyone mines (K50: no allowlist since v6)
        bytes32 metadataHash;
        bool hourlySchedule;
        uint8 openingMultiple; // the pool opens at 2 (default) or 1 × the mining price (K51); no minimum pool since v6
        uint8 claimVestingDays; // 0 | 7 | 14 | 30
        address feeRecipient; // 0 = the creator
        uint64 deadline; // the transaction reverts after this timestamp (K41)
        address expectedToken; // `predict(creator).token` the creator reviewed (K41)
        bool antiSnipe; // opening anti-snipe: instant launches only (K52); must be false for a mining token
        bool instant; // K52: no mining, trading at once at 5,000 USD FDV (K68); every mining field must be zero
    }

    struct Config {
        address miningImpl;
        address poolImpl;
        address locker;
        address feeRouter;
        address platformTreasury;
        address guardian;
        uint256 creationFeeWei;
        address ethUsdFeed;
        uint256 directLaunchFdvWei; // K68: the first opening FDV, ~5,000 USD at the deploy day's price
        uint256 proofFeeWei;
        uint256 powTarget;
    }

    struct Campaign {
        address campaign;
        address pool;
        address creator;
        uint64 createdAt;
    }

    /// @notice Every launch has the same supply (K43, owner decision 30 Sep 2026,
    /// as on o1 and BStocks). The mining price scales with the supply, so a
    /// free choice only changed the unit. Kept as a parameter so the create
    /// call and its events keep their shape.
    uint256 public constant SUPPLY = 1_000_000_000;

    /// @notice K55 (v7): the whole mining reserve costs ~6 ETH (2×) or ~4 ETH
    /// (1×), so one owner wallet mines at most 0.5 ETH (v1–v6: 0.1–10 ETH).
    uint256 public constant MIN_WALLET_CAP = 0.01 ether;
    uint256 public constant MAX_WALLET_CAP = 0.5 ether;
    /// @notice Same as `MiningCampaign.PRICE_PER_SUPPLY` (K55).
    uint256 public constant PRICE_PER_SUPPLY = 10_000;
    uint256 public constant PRICE_DEN = 100_000;
    uint256 public constant MAX_ANNOUNCEMENT_BYTES = 500;
    /// @notice v13 (owner decision, 20 Oct 2026): the name and the symbol
    /// fit in lists and wallets; UTF-8 bytes, so a Turkish letter counts 2.
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 10;
    /// @notice Must equal `CampaignPool.OPENING_BUFFER_WEI` (K53); the deploy script checks it.
    uint256 public constant OPENING_BUFFER_WEI = 1.5 ether;
    /// @notice K56: the largest share of the mining fees the pool can get —
    /// 95.4% over a full sell-out (`MiningCampaign.platformShareBps`), plus
    /// a margin for the proofs that straddle a step and for rounding.
    uint256 public constant MAX_POOL_SHARE_BPS = 9_541;
    uint256 internal constant BPS = 10_000;
    /// @notice K66: the creation fee in dollars (K6), paid in ETH at
    /// Chainlink's price of the moment.
    uint256 public constant CREATION_FEE_USD_CENTS = 300;
    /// @notice An older feed answer is not used (Base's ETH/USD feed updates
    /// at least every 20 minutes); the fee falls back to `CREATION_FEE_WEI`.
    uint256 public constant MAX_PRICE_AGE = 6 hours;
    /// @notice Outside this range (whole dollars per ETH) the answer is
    /// treated as broken and the fee falls back to `CREATION_FEE_WEI`.
    uint256 public constant MIN_ETH_USD = 500;
    uint256 public constant MAX_ETH_USD = 20_000;
    /// @notice K68 (v14): bounds of the opening FDV `GUARDIAN` can set —
    /// 5,000 USD at the feed's own sanity range (20,000 .. 500 USD per ETH).
    uint256 public constant MIN_DIRECT_LAUNCH_FDV_WEI = 0.25 ether;
    uint256 public constant MAX_DIRECT_LAUNCH_FDV_WEI = 10 ether;

    address public immutable MINING_IMPL;
    address public immutable POOL_IMPL;
    address public immutable LOCKER;
    /// @notice Where the MINER-liquidity half of each creation fee goes.
    IMinerLiquiditySink public immutable FEE_ROUTER;
    address public immutable PLATFORM_TREASURY;
    address public immutable GUARDIAN;
    /// @notice 3 USD at the deploy day's price: the fee while the feed is unusable (K66).
    uint256 public immutable CREATION_FEE_WEI;
    /// @notice Chainlink ETH/USD (K66); zero = always `CREATION_FEE_WEI`.
    IEthUsdFeed public immutable ETH_USD_FEED;
    uint256 internal immutable FEED_UNIT; // 10 ** the feed's decimals
    uint256 public immutable PROOF_FEE_WEI;
    uint256 public immutable POW_TARGET;

    bool public deprecated;
    /// @inheritdoc ILaunchpadOpening
    uint256 public directLaunchFdvWei;
    mapping(address creator => uint256) public creatorNonce;
    mapping(address pool => address token) public poolToken;
    mapping(address token => Campaign) public campaignOf;
    mapping(address token => uint256) public announcementCount;
    address[] public tokens;

    error IsDeprecated();
    error NotGuardian();
    error NotCreator();
    error InvalidName();
    error InvalidSupply();
    error InvalidStartTime();
    error InvalidDuration();
    error InvalidWalletCap();
    error InvalidVesting();
    error InvalidOpening();
    error InvalidLaunchOptions();
    error WrongFee(uint256 expected, uint256 got);
    error FeeAboveMax(uint256 fee, uint256 max);
    error TokenAddressMismatch(address expected, address got);
    error Expired(uint64 deadline);
    error UnexpectedToken(address expected, address next);
    error InvalidAnnouncement();
    error InvalidOpeningFdv(uint256 fdvWei);

    event CampaignCreated(
        address indexed token,
        address indexed creator,
        address campaign,
        address pool,
        uint256 totalSupply,
        uint64 startTime,
        uint8 durationDays,
        bytes32 metadataHash
    );
    event CampaignOptions(
        address indexed token,
        uint256 walletCapWei,
        bool hourlySchedule,
        uint8 openingMultiple,
        uint8 claimVestingDays,
        address feeRecipient,
        bool antiSnipe,
        bool instant
    );
    /// @notice `inMiner` is always false since MINER payment was removed (kept for the event's shape).
    event CreationFeePaid(address indexed token, address indexed payer, bool inMiner, uint256 amount);
    event Announcement(address indexed token, uint256 indexed id, address indexed creator, string text);
    event Deprecated();
    event DirectLaunchFdvSet(uint256 previous, uint256 current);

    constructor(Config memory c) {
        MINING_IMPL = c.miningImpl;
        POOL_IMPL = c.poolImpl;
        LOCKER = c.locker;
        FEE_ROUTER = IMinerLiquiditySink(c.feeRouter);
        PLATFORM_TREASURY = c.platformTreasury;
        GUARDIAN = c.guardian;
        CREATION_FEE_WEI = c.creationFeeWei;
        ETH_USD_FEED = IEthUsdFeed(c.ethUsdFeed);
        FEED_UNIT = c.ethUsdFeed == address(0) ? 0 : 10 ** IEthUsdFeed(c.ethUsdFeed).decimals();
        _setDirectLaunchFdv(c.directLaunchFdvWei);
        PROOF_FEE_WEI = c.proofFeeWei;
        POW_TARGET = c.powTarget;
    }

    // ------------------------------------------------------------------
    // Create
    // ------------------------------------------------------------------

    /// @notice Pays the fee in ETH. `msg.value` = `maxFeeWei` + optional pool
    /// deposit (mining) or the creator's first buy (instant, K56). The fee is
    /// `creationFeeWei()` when the transaction runs (K66); what `maxFeeWei`
    /// holds above it goes back to the caller in the same transaction, so a
    /// price move between quote and inclusion never changes the deposit.
    function create(CreateParams calldata p, uint256 maxFeeWei)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value < maxFeeWei) revert WrongFee(maxFeeWei, msg.value);
        uint256 fee = creationFeeWei();
        if (fee > maxFeeWei) revert FeeAboveMax(fee, maxFeeWei);
        uint256 extra = msg.value - maxFeeWei;
        token = _create(p, extra);
        emit CreationFeePaid(token, msg.sender, false, fee);
        uint256 toPlatform = fee / 2;
        Address.sendValue(payable(PLATFORM_TREASURY), toPlatform);
        FEE_ROUTER.depositMinerLiquidityEth{value: fee - toPlatform}();
        if (!p.instant) _deposit(token, extra);
        if (maxFeeWei > fee) Address.sendValue(payable(msg.sender), maxFeeWei - fee);
    }

    /// @notice The ETH fee now: 3 USD at Chainlink's ETH/USD, rounded up to
    /// the wei; `CREATION_FEE_WEI` while the feed is missing, reverts, is
    /// older than `MAX_PRICE_AGE` or outside `MIN_ETH_USD`..`MAX_ETH_USD` (K66).
    function creationFeeWei() public view returns (uint256) {
        (bool live, uint256 price) = ethUsdPrice();
        if (!live) return CREATION_FEE_WEI;
        return Math.mulDiv(CREATION_FEE_USD_CENTS * 1e18, FEED_UNIT, price * 100, Math.Rounding.Ceil);
    }

    /// @notice Chainlink's ETH/USD answer (feed decimals) and whether the fee
    /// uses it. Never reverts: a broken feed only means the fallback fee.
    function ethUsdPrice() public view returns (bool live, uint256 price) {
        if (FEED_UNIT == 0) return (false, 0);
        (bool ok, bytes memory data) =
            address(ETH_USD_FEED).staticcall(abi.encodeCall(IEthUsdFeed.latestRoundData, ()));
        if (!ok || data.length < 160) return (false, 0);
        (, int256 answer,, uint256 updatedAt,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_PRICE_AGE) {
            return (false, 0);
        }
        price = uint256(answer);
        live = price >= MIN_ETH_USD * FEED_UNIT && price <= MAX_ETH_USD * FEED_UNIT;
        if (!live) price = 0;
    }

    /// @notice The addresses `creator`'s next campaign will get.
    function predict(address creator) external view returns (address token, address campaign, address pool) {
        bytes32 salt = _salt(creator, creatorNonce[creator]);
        token = StdPrecompiles.B20_FACTORY.getB20Address(IB20Factory.B20Variant.ASSET, address(this), salt);
        campaign = Clones.predictDeterministicAddress(MINING_IMPL, salt);
        pool = Clones.predictDeterministicAddress(POOL_IMPL, salt);
    }

    function campaignCount() external view returns (uint256) {
        return tokens.length;
    }

    /// @dev `extra`: the instant launch's first buy (used only then).
    function _create(CreateParams calldata p, uint256 extra) internal returns (address token) {
        if (deprecated) revert IsDeprecated();
        _validate(p);

        bytes32 salt = _salt(msg.sender, creatorNonce[msg.sender]++);
        token = StdPrecompiles.B20_FACTORY.getB20Address(IB20Factory.B20Variant.ASSET, address(this), salt);
        if (token != p.expectedToken) revert UnexpectedToken(p.expectedToken, token);
        address pool = Clones.cloneDeterministic(POOL_IMPL, salt);
        address campaign;
        if (p.instant) {
            _initPool(pool, address(0), token, p, 0, 0, _feeRecipient(p));
            _createToken(token, salt, p, address(0), pool, 0, p.totalSupply * 1e18);
        } else {
            campaign = Clones.cloneDeterministic(MINING_IMPL, salt);
            _setup(token, salt, campaign, pool, p);
            // K44: open in the same transaction. The challenge seed still comes
            // from this block's randomness, as when any miner called open().
            MiningCampaign(payable(campaign)).open();
        }

        poolToken[pool] = token;
        campaignOf[token] = Campaign(campaign, pool, msg.sender, uint64(block.timestamp));
        tokens.push(token);
        // K52: registered first, since the locker opens only a registered pool.
        // K56: the creator's first buy, if any, in the same call.
        if (p.instant) CampaignPool(payable(pool)).launchInstantly{value: extra}(msg.sender);
        _emitCreated(token, campaign, pool, p);
    }

    /// @dev Initializes both clones, then creates the token into them.
    function _setup(address token, bytes32 salt, address campaign, address pool, CreateParams calldata p) internal {
        uint256 supply = p.totalSupply * 1e18;
        uint256 rm = _miningReserve(supply, p.openingMultiple);
        _initCampaign(campaign, pool, token, p, rm);
        _initPool(pool, campaign, token, p, rm, supply - rm, _feeRecipient(p));
        _createToken(token, salt, p, campaign, pool, rm, supply - rm);
    }

    /// @dev K55 (v7): a 2× opening mines 60% of the supply (40% waits for
    /// the pool); a 1× opening needs twice the pool tokens per ETH, so it
    /// mines 40% and keeps 60%. At the v7 price the 1.5 ETH opening buffer is
    /// 7.5% (2×) or 15% (1×) of the supply; either way the pool reserve
    /// covers a full sell-out, the buffer and the deposit cap. (v6: 2/3 and 1/2.)
    function _miningReserve(uint256 supply, uint8 m) internal pure returns (uint256) {
        return m == 2 ? supply * 3 / 5 : supply * 2 / 5;
    }

    function _feeRecipient(CreateParams calldata p) internal view returns (address) {
        return p.feeRecipient == address(0) ? msg.sender : p.feeRecipient;
    }

    function _emitCreated(address token, address campaign, address pool, CreateParams calldata p) internal {
        emit CampaignCreated(
            token, msg.sender, campaign, pool, p.totalSupply, uint64(block.timestamp), p.durationDays, p.metadataHash
        );
        emit CampaignOptions(
            token,
            p.walletCapWei,
            p.hourlySchedule,
            p.openingMultiple,
            p.claimVestingDays,
            _feeRecipient(p),
            p.antiSnipe,
            p.instant
        );
    }

    function _validate(CreateParams calldata p) internal view {
        if (block.timestamp > p.deadline) revert Expired(p.deadline);
        uint256 nameLen = bytes(p.name).length;
        uint256 symbolLen = bytes(p.symbol).length;
        if (nameLen == 0 || nameLen > MAX_NAME_BYTES || symbolLen == 0 || symbolLen > MAX_SYMBOL_BYTES) {
            revert InvalidName();
        }
        if (p.totalSupply != SUPPLY) revert InvalidSupply();
        // K44 (owner decision, 30 Sep 2026): mining starts with the token.
        if (p.startTime != 0) revert InvalidStartTime();
        if (p.instant) {
            // K52: no mining, so no mining option may be set.
            if (
                p.durationDays != 0 || p.walletCapWei != 0 || p.hourlySchedule || p.openingMultiple != 0
                    || p.claimVestingDays != 0
            ) revert InvalidLaunchOptions();
            return;
        }
        // K52: a mined token's pool is never protected (its miners already
        // hold their tokens); only pools that start from zero are.
        if (p.antiSnipe) revert InvalidLaunchOptions();
        uint8 d = p.durationDays;
        if (d != 1 && d != 3 && d != 7 && d != 15) revert InvalidDuration();
        // K50 (owner decision, 1 Oct 2026): no allowlist; anyone mines.
        if (p.walletCapWei < MIN_WALLET_CAP || p.walletCapWei > MAX_WALLET_CAP) revert InvalidWalletCap();
        if (p.openingMultiple != 1 && p.openingMultiple != 2) revert InvalidOpening();
        uint8 v = p.claimVestingDays;
        if (v != 0 && v != 7 && v != 14 && v != 30) revert InvalidVesting();
    }

    function _initCampaign(address campaign, address pool, address token, CreateParams calldata p, uint256 rm)
        internal
    {
        MiningCampaign(payable(campaign))
            .initialize(
                MiningCampaign.InitParams({
                token: token,
                pool: pool,
                platformTreasury: PLATFORM_TREASURY,
                powTarget: POW_TARGET,
                proofFee: PROOF_FEE_WEI,
                supplyWhole: p.totalSupply,
                miningReserve: rm,
                start: uint64(block.timestamp),
                durationDays: p.durationDays,
                walletCapWei: p.walletCapWei,
                hourlySchedule: p.hourlySchedule,
                claimVestingDays: p.claimVestingDays
            })
            );
    }

    /// @dev Deposit cap: the pool tokens left over after a full sell-out
    /// (`Rp − 0.9541 × Rm / m`), valued at the pool price, minus the 1.5 ETH
    /// opening buffer: ~0.78 ETH for a 2× opening, ~0.68 ETH for a 1×
    /// opening, at any supply (§2.1, K53, K55, K56).
    function _initPool(
        address pool,
        address campaign,
        address token,
        CreateParams calldata p,
        uint256 rm,
        uint256 rp,
        address feeRecipient
    ) internal {
        CampaignPool(payable(pool))
            .initialize(
                CampaignPool.InitParams({
                token: token,
                campaign: campaign,
                locker: LOCKER,
                creator: msg.sender,
                feeRecipient: feeRecipient,
                supplyWhole: p.totalSupply,
                depositCapWei: p.instant ? 0 : _depositCap(p, rm, rp),
                openingMultiple: p.openingMultiple,
                antiSnipe: p.antiSnipe,
                instant: p.instant
            })
            );
    }

    /// @dev What the spare pool tokens after a full sell-out are worth at
    /// the pool price, minus the 1.5 ETH opening buffer they must also hold
    /// (K53): ~0.78 ETH at 2×, ~0.68 ETH at 1× (K56; v7: 1.1 / 0.9 ETH).
    function _depositCap(CreateParams calldata p, uint256 rm, uint256 rp) internal pure returns (uint256) {
        uint256 m = p.openingMultiple;
        return (rp - rm * MAX_POOL_SHARE_BPS / (BPS * m)) * PRICE_DEN * m / (p.totalSupply * PRICE_PER_SUPPLY)
            - OPENING_BUFFER_WEI;
    }

    function _createToken(
        address expected,
        bytes32 salt,
        CreateParams calldata p,
        address campaign,
        address pool,
        uint256 rm,
        uint256 rp
    ) internal {
        bytes[] memory calls;
        if (campaign == address(0)) {
            // An instant launch (no campaign) mints everything to the pool.
            address[] memory recipients = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            recipients[0] = pool;
            amounts[0] = rp;
            calls = new bytes[](3);
            calls[0] = B20FactoryLib.encodeUpdateSupplyCap(rp);
            calls[1] = B20FactoryLib.encodeBatchMint(recipients, amounts);
            calls[2] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, pool);
        } else {
            // K65: nothing minted; proofs and the opening mint, up to the cap.
            calls = new bytes[](5);
            calls[0] = B20FactoryLib.encodeUpdateSupplyCap(rm + rp);
            calls[1] = B20FactoryLib.encodeGrantRole(B20Constants.MINT_ROLE, campaign);
            calls[2] = B20FactoryLib.encodeGrantRole(B20Constants.MINT_ROLE, pool);
            calls[3] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, campaign);
            calls[4] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, pool);
        }
        address created = StdPrecompiles.B20_FACTORY
            .createB20(
                IB20Factory.B20Variant.ASSET,
                salt,
                B20FactoryLib.encodeAssetCreateParams(p.name, p.symbol, address(0), 18),
                calls
            );
        if (created != expected) revert TokenAddressMismatch(expected, created);
    }

    function _deposit(address token, uint256 amount) internal {
        if (amount > 0) CampaignPool(payable(campaignOf[token].pool)).deposit{value: amount}(msg.sender);
    }

    function _salt(address creator, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, nonce));
    }

    // ------------------------------------------------------------------
    // Metadata and guardian
    // ------------------------------------------------------------------

    /// @notice Event only (K42): the creator posts a short announcement (at most
    /// `MAX_ANNOUNCEMENT_BYTES` of UTF-8 text) on the campaign page. It
    /// grants no power over the token, the pool or any funds.
    function announce(address token, string calldata text) external returns (uint256 id) {
        if (campaignOf[token].creator != msg.sender) revert NotCreator();
        uint256 length = bytes(text).length;
        if (length == 0 || length > MAX_ANNOUNCEMENT_BYTES) revert InvalidAnnouncement();
        id = ++announcementCount[token];
        emit Announcement(token, id, msg.sender, text);
    }

    /// @notice Closes this template version to new campaigns, for good.
    function deprecate() external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        deprecated = true;
        emit Deprecated();
    }

    /// @notice K68: the ETH amount the next direct and instant launches open
    /// at, as o1 refreshes its own (~5,000 USD worth). A pool that already
    /// opened keeps its value (`CampaignPool.directFdvWei`).
    function setDirectLaunchFdvWei(uint256 fdvWei) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        _setDirectLaunchFdv(fdvWei);
    }

    function _setDirectLaunchFdv(uint256 fdvWei) internal {
        if (fdvWei < MIN_DIRECT_LAUNCH_FDV_WEI || fdvWei > MAX_DIRECT_LAUNCH_FDV_WEI) {
            revert InvalidOpeningFdv(fdvWei);
        }
        emit DirectLaunchFdvSet(directLaunchFdvWei, fdvWei);
        directLaunchFdvWei = fdvWei;
    }
}
