// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {
    ICampaignToken,
    ILaunchpadOpening,
    IMiningCampaignSettlement,
    IPositionLocker
} from "./interfaces/ILaunchpadInterfaces.sol";

/// @notice One Launchpad campaign's pool reserve, pool ETH and finalize
/// (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §3.3, §6.1). An EIP-1167
/// clone, initialized once by `LaunchpadFactory`. No admin, no upgrade.
///
/// It holds the right to the pool reserve (40% of supply for a 2× opening, 60% for 1×, K55) and any ETH
/// deposited for the pool (K21). Since v12 (K65) a mining token's reserve is
/// not minted in advance: the pool holds `MINT_ROLE` and, when it opens, mints
/// exactly what the opening places — the same ask as before (the tokens for
/// the ETH raised plus the 1.5 ETH opening buffer, at 1× and 2× alike), or
/// the whole remaining supply for a direct launch — then gives the role up.
/// Nothing is minted only to be burned. At finalize — anyone, once mining is over — it always opens
/// the official Uniswap V4 pool through `PositionLocker` (locked for good)
/// and claims open in `MiningCampaign`. Two shapes:
/// - somebody mined: at the opening the creator chose (K51, Launchpad v6):
///   twice the mining price (K12, the default) or the mining price itself.
///   The ask holds the tokens matching the ETH raised plus the 1.5 ETH
///   opening buffer (K53); the bid holds all the ETH just below the opening,
///   sized so every mined token fits in it — the floor (K54): miners selling
///   everything get all the ETH back, and the price never falls below it.
///   v1–v11 burned every token left (K17); since v12 those are never minted
///   (K65) and only the locker's rounding remainder is burned;
/// - direct launch (K49): nobody mined. Like o1, every token goes into one
///   single-sided position opening at the factory's `directLaunchFdvWei`
///   for the whole supply — a fixed ETH amount worth ~5,000 USD, refreshed
///   by the factory's guardian as o1 does (K68, v14; v5–v13: 1.5 ETH) — and any ETH deposited
///   becomes locked buy support just below that price. Nothing is refunded and nothing is burned
///   beyond rounding.
/// Since v6 there is no minimum pool (K51): it sent a token that raised a
/// little into the direct launch, far below the price its miners paid.
///
/// Opening (K63, Launchpad v11, owner decision of 8 October 2026): when
/// somebody mined, `finalize` (the B20MINER relay in practice; anyone may)
/// settles the campaign, fixes the opening — a 2× choice falls back to 1×
/// unless the campaign `doubleOpeningQualified` — and starts the campaign's
/// `distribute`, which sends every owner their tokens. The pool is created
/// (and so can trade) only once every owner has them: in `finalize` itself
/// when the first batch reaches everyone, otherwise in `open` (anyone)
/// after the remaining `distribute` batches. Until then nobody can trade.
///
/// Instant launch (K52, v6): a token created without mining. The factory
/// mints the whole supply here (unchanged by K65) and calls `launchInstantly` in the create
/// transaction: the same single-sided position at 5,000 USD FDV (K68),
/// trading at once. There is no `MiningCampaign` (`campaign` is zero) and no deposit.
/// The creator may buy first in that same call (K56, v8): any amount of
/// ETH, swapped before anyone else can trade, paying the 1% fee but not the
/// anti-snipe surcharge (like o1's and Clanker's dev buy). The amount
/// and the tokens it bought are public here (`creatorBuyEth`,
/// `creatorBuyTokens`) so every buyer can see them.
///
/// Opening anti-snipe (K52): only a pool that starts from zero (at 5,000
/// USD FDV) is protected. An instant launch takes the creator's choice; a
/// mining token's direct launch (nobody mined) is always protected; a
/// mined token's full-range pool never is — its miners already hold their
/// tokens, so early buyers only buy from them.
///
/// Pool price: `tokenWei = ethWei × S × 10,000 / (m × 100,000)` for an
/// opening at `m` × the mining price (`m` = 2 or 1; the mining rate is
/// `S × 10,000 / 100,000`, K55), i.e.
/// `sqrtPriceX96 = √(poolPriceNum × 2¹⁹² / 100,000)` with ETH as currency0.
contract CampaignPool is ReentrancyGuard {
    using SafeERC20 for ICampaignToken;

    enum Status {
        Active,
        Finalized, // the pool is open
        Distributing // K63: settled, owners receiving their tokens, pool not open yet
    }

    struct InitParams {
        address token;
        address campaign;
        address locker;
        address creator;
        address feeRecipient;
        uint256 supplyWhole;
        uint256 depositCapWei;
        uint8 openingMultiple; // 2 (default) or 1 × the mining price (K51); 0 when instant
        bool antiSnipe; // instant launches only (K52)
        bool instant; // no mining: the factory launches it in the create transaction (K52)
    }

    uint256 public constant PRICE_DEN = 100_000;
    /// @notice Same as `MiningCampaign.PRICE_PER_SUPPLY` (K55).
    uint256 public constant PRICE_PER_SUPPLY = 10_000;
    /// @notice The opening buffer of a mined pool (K53, owner decision of
    /// 1 October 2026): tokens worth 1.5 ETH at the opening price, kept from
    /// the burn and placed single-sided from that price up — the depth an
    /// o1 pool opening at 1.5 ETH FDV gave its buyers then — whatever was
    /// mined. Stays in ETH in v14 (K68): the factory's deposit cap subtracts it.
    uint256 public constant OPENING_BUFFER_WEI = 1.5 ether;
    /// @notice K63: owners `finalize` serves itself; `distribute` serves the rest.
    uint256 public constant FINALIZE_BATCH = 150;

    address public factory;
    ICampaignToken public token;
    IMiningCampaignSettlement public campaign;
    IPositionLocker public locker;
    address public creator;
    address public feeRecipient;
    uint256 public poolPriceNum; // S × PRICE_PER_SUPPLY / openingMultiple
    uint256 public depositCapWei;
    /// @notice The pool opens at this multiple of the mining price (K51);
    /// from finalize on, the actual opening (K63: 1× when a 2× campaign
    /// did not qualify).
    uint8 public openingMultiple;
    /// @notice The creator's choice (K51), kept after a K63 fall-back.
    uint8 public chosenMultiple;
    uint256 public supplyWhole;
    /// @notice Instant launch only: the creator chose the opening anti-snipe (K52).
    bool public antiSnipe;
    /// @notice Created without mining, trading from the create transaction (K52).
    bool public instant;
    /// @notice The pool opened as a direct launch (K49).
    bool public directLaunch;

    Status public status;
    uint256 public totalDeposited;
    uint256 public creatorDeposited;
    mapping(address depositor => uint256) public depositOf;

    /// @notice K63: the ETH the pool will open with, held while distributing.
    uint256 public pendingEth;

    uint256 public ethAdded;
    uint256 public tokenAdded;
    uint128 public liquidity;

    /// @notice K68: the FDV in ETH wei a direct or instant launch opened at
    /// (the factory's `directLaunchFdvWei` at that moment); 0 otherwise.
    uint256 public directFdvWei;

    /// @notice Instant launch only (K56): the creator's first buy, in the create transaction.
    uint256 public creatorBuyEth;
    uint256 public creatorBuyTokens;

    error AlreadyInitialized();
    error InvalidInit();
    error NotActive();
    error MiningNotOver();
    error ZeroDeposit();
    error DepositAboveCap(uint256 cap);
    error UnexpectedEth(address from);
    error NotFactory();
    error NotDistributing();
    error DistributionPending();
    error EthTransferFailed(address to, uint256 amount);

    event Deposited(address indexed depositor, uint256 amount, uint256 totalDeposited, bool byCreator);
    event Finalized(
        uint256 ethAdded, uint256 tokenAdded, uint128 liquidity, uint256 tokensBurned, uint160 sqrtPriceX96
    );
    event DirectLaunch(uint256 deposited);
    /// @notice K63: the opening fixed at finalize (`opening` < `chosen` = the 1× fall-back).
    event OpeningSet(uint8 chosen, uint8 opening);
    event CreatorBuy(address indexed creator, uint256 ethIn, uint256 tokensOut);

    constructor() {
        factory = address(1); // the implementation can never be initialized
    }

    function initialize(InitParams calldata p) external {
        if (factory != address(0)) revert AlreadyInitialized();
        if (
            p.token == address(0) || p.locker == address(0) || p.creator == address(0)
                || p.feeRecipient == address(0) || p.supplyWhole == 0
        ) revert InvalidInit();
        if (
            p.instant
                ? (p.campaign != address(0) || p.openingMultiple != 0 || p.depositCapWei != 0)
                : (p.campaign == address(0) || (p.openingMultiple != 1 && p.openingMultiple != 2) || p.antiSnipe)
        ) revert InvalidInit();
        factory = msg.sender;
        token = ICampaignToken(p.token);
        campaign = IMiningCampaignSettlement(p.campaign);
        locker = IPositionLocker(p.locker);
        creator = p.creator;
        feeRecipient = p.feeRecipient;
        if (!p.instant) poolPriceNum = p.supplyWhole * PRICE_PER_SUPPLY / p.openingMultiple;
        openingMultiple = p.openingMultiple;
        chosenMultiple = p.openingMultiple;
        supplyWhole = p.supplyWhole;
        depositCapWei = p.depositCapWei;
        antiSnipe = p.antiSnipe;
        instant = p.instant;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice ETH the pool would open with right now.
    function poolEth() public view returns (uint256) {
        if (instant) return 0;
        if (status == Status.Distributing) return pendingEth;
        return campaign.poolAccrued() + totalDeposited;
    }

    /// @notice Tokens that `ethAmount` pairs with at the opening price.
    function tokensFor(uint256 ethAmount) public view returns (uint256) {
        return ethAmount * poolPriceNum / PRICE_DEN;
    }

    function sqrtPriceX96() public view returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(poolPriceNum, 1 << 192, PRICE_DEN)));
    }

    /// @notice The direct launch's target opening price if it opened now:
    /// the whole supply worth the factory's `directLaunchFdvWei` (token wei
    /// per ETH wei, as sqrtPriceX96). The locker rounds it to a usable tick.
    function directSqrtPriceX96() public view returns (uint160) {
        return _directSqrtPriceX96(ILaunchpadOpening(factory).directLaunchFdvWei());
    }

    function _directSqrtPriceX96(uint256 fdvWei) internal view returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(supplyWhole * 1e18, 1 << 192, fdvWei)));
    }

    /// @notice Whether finalizing now would launch directly: nobody mined.
    function wouldLaunchDirectly() public view returns (bool) {
        return instant || campaign.minedTotal() == 0;
    }

    // ------------------------------------------------------------------
    // Deposits (K21)
    // ------------------------------------------------------------------

    /// @notice Adds ETH to the pool for `depositor`, until finalize. It buys
    /// no tokens; it only deepens the pool (or, in a direct launch, the buy
    /// support), locked for good. The creator's deposits earn the "Deep
    /// pool" badge.
    function deposit(address depositor) external payable nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (msg.value == 0 || depositor == address(0)) revert ZeroDeposit();
        uint256 total = totalDeposited + msg.value;
        if (total > depositCapWei) revert DepositAboveCap(depositCapWei);
        totalDeposited = total;
        depositOf[depositor] += msg.value;
        bool byCreator = depositor == creator;
        if (byCreator) creatorDeposited += msg.value;
        emit Deposited(depositor, msg.value, total, byCreator);
    }

    // ------------------------------------------------------------------
    // Instant launch (K52)
    // ------------------------------------------------------------------

    /// @notice The factory, in the create transaction: every token into the
    /// single-sided position at 5,000 USD FDV (K68), with the creator's anti-snipe
    /// choice; then the ETH sent, if any, buys for `buyer` (the creator,
    /// K56) — the pool's first trade, free of the anti-snipe surcharge.
    function launchInstantly(address buyer) external payable nonReentrant {
        if (msg.sender != factory || !instant) revert NotFactory();
        if (status != Status.Active) revert NotActive();
        status = Status.Finalized;
        directLaunch = true;
        emit DirectLaunch(0);
        _lockDirect(0, antiSnipe);
        if (msg.value == 0) return;
        uint256 out = locker.buyAtOpening{value: msg.value}(address(token), buyer);
        creatorBuyEth = msg.value;
        creatorBuyTokens = out;
        emit CreatorBuy(buyer, msg.value, out);
    }

    // ------------------------------------------------------------------
    // Finalize
    // ------------------------------------------------------------------

    function finalize() external nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (!campaign.miningOver()) revert MiningNotOver();

        bool direct = wouldLaunchDirectly();
        directLaunch = direct;

        if (direct) {
            // K52: nobody mined, so the pool starts from zero at 5,000 USD FDV (K68);
            // always protected. There is nobody to deliver to.
            status = Status.Finalized;
            uint256 eth = campaign.settle(true) + totalDeposited;
            emit DirectLaunch(totalDeposited);
            _lockDirect(eth, true);
            return;
        }
        // K63: a 2× campaign that did not qualify opens at 1×.
        if (openingMultiple == 2 && !campaign.doubleOpeningQualified()) {
            openingMultiple = 1;
            poolPriceNum = supplyWhole * PRICE_PER_SUPPLY;
        }
        emit OpeningSet(chosenMultiple, openingMultiple);
        status = Status.Distributing;
        pendingEth = campaign.settle(false) + totalDeposited;
        campaign.distribute(FINALIZE_BATCH);
        if (campaign.distributionDone()) _open();
    }

    /// @notice K63, anyone: opens the pool once every owner has their tokens
    /// (after the `distribute` batches `finalize` did not cover).
    function open() external nonReentrant {
        if (status != Status.Distributing) revert NotDistributing();
        if (!campaign.distributionDone()) revert DistributionPending();
        _open();
    }

    /// @dev The reserve covers a full sell-out, the deposit cap and the
    /// opening buffer at the creator's choice (§2.1, K53); the unmined
    /// reserve counts too (K63). `min` absorbs wei-level rounding and, in a
    /// 1× fall-back of a campaign that raised a lot from few miners, a
    /// thinner ask. A mined token's pool is never protected (K52).
    /// K54: the ask holds the tokens matching the ETH plus the buffer; the
    /// bid holds all the ETH, sized so that every mined token fits in it —
    /// the floor. K65: the ask is minted here, bounded by the supply not yet
    /// minted (= the old balance: the pool reserve plus the unmined reserve).
    function _open() internal {
        status = Status.Finalized;
        uint256 eth = pendingEth;
        pendingEth = 0;
        uint256 ask = _mintOpening(tokensFor(eth) + tokensFor(OPENING_BUFFER_WEI));
        uint160 price = sqrtPriceX96();
        token.forceApprove(address(locker), ask);
        (uint128 liq, uint256 ethUsed, uint256 tokenUsed) =
            locker.lock{value: eth}(address(token), feeRecipient, ask, campaign.minedTotal(), price, false);
        _settled(liq, ethUsed, tokenUsed, price);
    }

    /// @dev Every token held into the single-sided position at the
    /// factory's opening FDV of the moment (K68, ~5,000 USD in ETH),
    /// `eth` (if any) as buy support below it. K65: a mining token nobody
    /// mined has no supply yet; the pool mints all of it here.
    function _lockDirect(uint256 eth, bool protect) internal {
        if (!instant) _mintOpening(type(uint256).max);
        uint256 tokens = token.balanceOf(address(this));
        token.forceApprove(address(locker), tokens);
        uint256 fdvWei = ILaunchpadOpening(factory).directLaunchFdvWei();
        directFdvWei = fdvWei;
        uint160 price = _directSqrtPriceX96(fdvWei);
        (uint128 liq, uint256 ethUsed, uint256 tokenUsed) =
            locker.lock{value: eth}(address(token), feeRecipient, tokens, 0, price, protect);
        _settled(liq, ethUsed, tokenUsed, price);
    }

    /// @dev K65: mints `want` (at most the supply not yet minted) to this
    /// pool and gives up `MINT_ROLE` for good — the token's supply is final.
    function _mintOpening(uint256 want) internal returns (uint256 amount) {
        amount = Math.min(want, token.supplyCap() - token.totalSupply());
        if (amount > 0) token.mint(address(this), amount);
        token.renounceRole(B20Constants.MINT_ROLE, address(this));
    }

    /// @dev Records what the pool opened with and burns what is left.
    function _settled(uint128 liq, uint256 ethUsed, uint256 tokenUsed, uint160 price) internal {
        liquidity = liq;
        ethAdded = ethUsed;
        tokenAdded = tokenUsed;

        uint256 burned = token.balanceOf(address(this));
        emit Finalized(ethUsed, tokenUsed, liq, burned, price);
        if (burned > 0) token.burn(burned);
    }

    /// @dev Only the campaign's pool share arrives here (`settle`).
    receive() external payable {
        if (msg.sender != address(campaign)) revert UnexpectedEth(msg.sender);
    }
}
