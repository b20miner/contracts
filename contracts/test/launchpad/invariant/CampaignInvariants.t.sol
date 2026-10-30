// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CampaignPool} from "../../../src/launchpad/CampaignPool.sol";
import {MiningCampaign} from "../../../src/launchpad/MiningCampaign.sol";
import {MockCampaignToken} from "../MiningCampaign.t.sol";

/// @dev Stands in for `PositionLocker` (the V4 path is covered by the fork
/// tests): takes the ETH and exactly the tokens the pool offers, through
/// either path.
contract MockLocker {
    uint256 public ethIn;
    uint256 public tokenIn;
    bool public direct;

    uint256 public floorIn;

    /// `floorTokens == 0`: a direct launch (no floor); else a mined pool
    /// whose bid must hold every mined token (K54).
    function lock(address token, address, uint256 tokenAmount, uint256 floorTokens, uint160, bool)
        external
        payable
        returns (uint128, uint256, uint256)
    {
        floorIn = floorTokens;
        direct = floorTokens == 0;
        return _take(token, tokenAmount);
    }

    function _take(address token, uint256 tokenAmount) internal returns (uint128, uint256, uint256) {
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        ethIn += msg.value;
        tokenIn += tokenAmount;
        return (1, msg.value, tokenAmount);
    }
}

/// @notice Drives one campaign and its pool through random sequences:
/// time jumps, opening, proofs by several owners and mining wallets,
/// deposits, platform withdrawals, finalize (full-range pool or direct
/// launch, K49), claims and the final burn. Calls that the contracts must accept are
/// wrapped so that an unexpected revert is recorded, not ignored.
contract CampaignHandler is Test {
    struct Config {
        bool hourly;
        uint8 vestingDays;
        uint8 multiple; // pool opening × mining price (K51): 0 = 2 (default), or 1
        uint256 proofFee; // 0 = PROOF_FEE
        uint256 walletCapWei; // 0 = WALLET_CAP
    }

    // 1,000,000 whole tokens: 120 tokens per ETH; the 666,666-token mining
    // reserve sells out at ~5,555 ETH of fees (at any supply, §2.1)
    /// @notice This handler is the pool's factory (K68): direct launches open at 1.5 ETH FDV.
    function directLaunchFdvWei() external pure returns (uint256) {
        return 1.5 ether;
    }

    uint256 public constant SUPPLY = 1_000_000;
    uint256 public constant PROOF_FEE = 0.25 ether; // 25,000 tokens per full proof (K55)
    uint256 public constant WALLET_CAP = 2 ether; // 200,000 tokens per owner before bonus: 8 proofs
    uint256 public proofFee;
    address public constant TREASURY = address(0x7EA5);
    address public constant FEE_RECIPIENT = address(0xFEE);

    MockCampaignToken public token;
    MockLocker public locker;
    MiningCampaign public campaign;
    CampaignPool public pool;
    Config public cfg;
    uint256 public rm;
    uint256 public rp;

    address[4] public owners = [address(0xA0), address(0xA1), address(0xA2), address(0xA3)];
    address[2] public wallets = [address(0xB0), address(0xB1)];
    address[2] public depositors = [address(0xD0), address(0xD1)];

    // ---- ghosts ----
    uint256 public feesPaid;
    uint256 public claimedTotal;
    uint256 public poolShareAtSettle;
    bool public unexpectedRevert;
    bool public scheduleBreach;
    string public lastFailure;
    // path counters (coverage of the random runs)
    uint256 public nProofs;
    uint256 public nShareBatches;
    uint256 public nPoolFinalized;
    uint256 public nDirect;
    uint256 public nClaims;
    uint256 public nUnclaimedBurns;
    uint256 public nSoldOut;

    constructor(Config memory c) {
        cfg = c;
        proofFee = c.proofFee == 0 ? PROOF_FEE : c.proofFee;
        token = new MockCampaignToken();
        locker = new MockLocker();

        campaign = MiningCampaign(payable(Clones.clone(address(new MiningCampaign()))));
        pool = CampaignPool(payable(Clones.clone(address(new CampaignPool()))));
        uint256 supply = SUPPLY * 1e18;
        rm = _multiple(c) == 2 ? supply * 3 / 5 : supply * 2 / 5; // K55: 60% / 40%
        rp = supply - rm;
        _initCampaign(c);
        _initPool(c);
        token.setSupplyCap(rm + rp); // K65: nothing minted up front

        for (uint256 i; i < 2; i++) {
            vm.deal(wallets[i], 1_000_000 ether);
            vm.deal(depositors[i], 1_000 ether);
        }
    }

    function _initCampaign(Config memory c) internal {
        MiningCampaign.InitParams memory p;
        p.token = address(token);
        p.pool = address(pool);
        p.platformTreasury = TREASURY;
        p.powTarget = type(uint256).max;
        p.proofFee = proofFee;
        p.supplyWhole = SUPPLY;
        p.miningReserve = rm;
        p.start = uint64(block.timestamp + 1 hours);
        p.durationDays = 3;
        p.hourlySchedule = c.hourly;
        p.claimVestingDays = c.vestingDays;
        p.walletCapWei = c.walletCapWei == 0 ? WALLET_CAP : c.walletCapWei;
        campaign.initialize(p);
    }

    function _initPool(Config memory c) internal {
        pool.initialize(
            CampaignPool.InitParams({
                token: address(token),
                campaign: address(campaign),
                locker: address(locker),
                creator: address(this),
                feeRecipient: FEE_RECIPIENT,
                supplyWhole: SUPPLY,
                depositCapWei: (rp - rm * 9_541 / (10_000 * uint256(_multiple(c)))) * 100_000 * _multiple(c) / (SUPPLY * 10_000) - 1.5 ether, // K56
                openingMultiple: _multiple(c),
                antiSnipe: false,
                instant: false
            })
        );
    }

    function _multiple(Config memory c) internal pure returns (uint8) {
        return c.multiple == 0 ? 2 : c.multiple;
    }

    function ownerCount() external pure returns (uint256) {
        return 4;
    }

    function _fail(string memory what) internal {
        unexpectedRevert = true;
        lastFailure = what;
    }

    // ------------------------------------------------------------ actions

    function warp(uint256 seed) external {
        // mostly minutes to hours; once mining is over, days (vesting, deadlines)
        uint256 dt = campaign.miningOver() && seed % 2 == 0
            ? bound(seed >> 8, 1 days, 10 days)
            : bound(seed >> 8, 1 minutes, 12 hours);
        vm.warp(block.timestamp + dt);
    }

    function open() external {
        if (campaign.opened() || block.timestamp < campaign.start() || block.timestamp >= campaign.end()) return;
        try campaign.open() {}
        catch {
            _fail("open");
        }
    }

    function mine(uint256 ownerSeed, uint256 walletSeed, uint256 overpay) external {
        address owner = owners[ownerSeed % 4];
        address wallet = wallets[walletSeed % 2];
        if (campaign.status() != MiningCampaign.Status.Active || block.timestamp >= campaign.end()) return;
        if (!campaign.opened()) {
            // the first miner's client opens the campaign when its start comes
            if (block.timestamp < campaign.start()) vm.warp(campaign.start());
            try campaign.open() {}
            catch {
                _fail("open before first proof");
                return;
            }
        }

        (uint256 reward, uint256 fee) = campaign.quoteProof(owner);
        if (reward == 0) return;
        _submit(owner, wallet, fee, bound(overpay, 0, 1 ether), uint256(keccak256(abi.encode(ownerSeed, walletSeed))));
    }

    function _submit(address owner, address wallet, uint256 fee, uint256 extra, uint256 nonce) internal {
        uint256 releasedBefore = campaign.releasedReserve();
        bytes32 current = campaign.challengeOf(owner);
        uint256 balBefore = wallet.balance;
        // K58: half the time the same reward comes as a batch of 16 shares
        // (every hash meets the easiest target; nonces only need to ascend).
        bool shares = nonce % 2 == 0;
        bytes memory data = shares
            ? abi.encodeCall(MiningCampaign.submitShares, (owner, current, _batch(nonce)))
            : abi.encodeCall(MiningCampaign.submitProof, (owner, current, nonce));
        vm.prank(wallet);
        (bool ok,) = address(campaign).call{value: fee + extra}(data);
        if (ok) {
            feesPaid += fee;
            nProofs++;
            if (shares) nShareBatches++;
            if (campaign.minedTotal() == rm) nSoldOut++;
            if (balBefore - wallet.balance != fee) _fail("excess not refunded");
            if (cfg.hourly && campaign.minedTotal() > releasedBefore) scheduleBreach = true;
        } else {
            _fail(shares ? "submitShares" : "submitProof");
        }
    }

    function _batch(uint256 nonce) internal pure returns (uint256[16] memory b) {
        for (uint256 i; i < 16; ++i) b[i] = (nonce >> 8) + i;
    }

    function deposit(uint256 seed, uint256 amount) external {
        if (pool.status() != CampaignPool.Status.Active) return;
        uint256 room = pool.depositCapWei() - pool.totalDeposited();
        if (room == 0) return;
        amount = bound(amount, 1, room < 1 ether ? room : 1 ether);
        address d = depositors[seed % 2];
        vm.prank(d);
        try pool.deposit{value: amount}(d) {}
        catch {
            _fail("deposit");
        }
    }

    function withdrawPlatformFees() external {
        try campaign.withdrawPlatformFees() {}
        catch {
            _fail("withdrawPlatformFees");
        }
    }

    function finalize() external {
        if (pool.status() != CampaignPool.Status.Active || !campaign.miningOver()) return;
        uint256 accrued = campaign.poolAccrued();
        uint256 claimedBefore = _claimedSum();
        try pool.finalize() {
            poolShareAtSettle = accrued;
            // K63: finalize delivers to the owners (everything, or the first tranche)
            claimedTotal += _claimedSum() - claimedBefore;
            if (pool.directLaunch()) nDirect++;
            else nPoolFinalized++;
        } catch {
            _fail("finalize");
        }
    }

    function _claimedSum() internal view returns (uint256 sum) {
        for (uint256 i; i < 4; ++i) {
            sum += campaign.claimedOf(owners[i]);
        }
    }

    function claim(uint256 ownerSeed) external {
        address owner = owners[ownerSeed % 4];
        if (campaign.status() != MiningCampaign.Status.Finalized) return;
        if (block.timestamp > campaign.claimDeadline()) return;
        uint256 amount = campaign.claimable(owner);
        if (amount == 0) return;
        vm.prank(owner);
        try campaign.claim() {
            claimedTotal += amount;
            nClaims++;
        } catch {
            _fail("claim");
        }
    }

    function burnUnclaimed() external {
        if (campaign.status() != MiningCampaign.Status.Finalized || campaign.unclaimedBurned()) return;
        if (block.timestamp <= campaign.claimDeadline()) return;
        try campaign.burnUnclaimed() {
            nUnclaimedBurns++;
        } catch {
            _fail("burnUnclaimed");
        }
    }
}

/// @notice Invariants I1–I4, I12–I14 and I16 of
/// `docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §10, checked after every call.
abstract contract CampaignInvariantsBase is StdInvariant, Test {
    CampaignHandler handler;

    function _config() internal pure virtual returns (CampaignHandler.Config memory);

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new CampaignHandler(_config());
        targetContract(address(handler));
    }

    uint256[6] internal _paths;
    uint256 internal _shareBatches;

    /// @dev Adds up which paths each run reached (printed with -vv).
    function afterInvariant() public {
        _paths[0] += handler.nProofs();
        _shareBatches += handler.nShareBatches();
        _paths[1] += handler.nPoolFinalized();
        _paths[2] += handler.nDirect();
        _paths[3] += handler.nClaims();
        _paths[4] += handler.nUnclaimedBurns();
        _paths[5] += handler.nSoldOut();
        emit log_named_uint("of the proofs, share batches (K58)", _shareBatches);
        emit log_named_string(
            "paths (proofs, pools, direct launches, claims, unclaimed burns, sold out)",
            string.concat(
                vm.toString(_paths[0]),
                ", ",
                vm.toString(_paths[1]),
                ", ",
                vm.toString(_paths[2]),
                ", ",
                vm.toString(_paths[3]),
                ", ",
                vm.toString(_paths[4]),
                ", ",
                vm.toString(_paths[5])
            )
        );
    }

    function _sumMined() internal view returns (uint256 total) {
        MiningCampaign c = handler.campaign();
        for (uint256 i; i < 4; i++) {
            total += c.minedOf(handler.owners(i));
        }
    }

    /// No call the contracts must accept was refused; no proof beat the
    /// hourly schedule. (I16, the stakers' window, went with v13.)
    function invariant_noUnexpectedRevertOrBreach() public view {
        assertFalse(handler.unexpectedRevert(), handler.lastFailure());
        assertFalse(handler.scheduleBreach(), "hourly schedule breached (I12)");
    }

    /// I1–I3: supply only grows by mining and the pool's opening, never past
    /// the cap (K65), and is otherwise only burned; every token
    /// sits in the campaign, the pool, the locker or with an owner; mined
    /// never exceeds the reserve and claimed never exceeds mined.
    function invariant_supplyAndMining() public view {
        MiningCampaign c = handler.campaign();
        CampaignPool p = handler.pool();
        MockCampaignToken t = handler.token();
        uint256 held = t.balanceOf(address(c)) + t.balanceOf(address(p)) + t.balanceOf(address(handler.locker()));
        uint256 claimed;
        for (uint256 i; i < 4; i++) {
            address o = handler.owners(i);
            held += t.balanceOf(o);
            claimed += c.claimedOf(o);
            assertLe(c.claimedOf(o), c.minedOf(o), "claimed > mined");
            assertEq(t.balanceOf(o), c.claimedOf(o), "owner tokens != claimed");
        }
        assertEq(held, t.totalSupply(), "tokens outside the system");
        assertLe(t.totalSupply(), handler.rm() + handler.rp(), "supply grew");
        assertEq(c.minedTotal(), _sumMined(), "minedTotal != sum of minedOf");
        assertLe(c.minedTotal(), handler.rm(), "mined > reserve");
        assertEq(claimed, handler.claimedTotal(), "claim ghost");

        if (p.status() == CampaignPool.Status.Active) {
            // I2 (K65): before finalize only mined tokens exist, all in the campaign escrow
            assertEq(t.balanceOf(address(c)), c.minedTotal(), "campaign escrow != mined before finalize");
            assertEq(t.balanceOf(address(p)), 0, "pool minted before finalize");
            assertEq(t.totalSupply(), c.minedTotal(), "supply != mined before finalize");
        } else {
            // finalized: what is left is claims (or already burned) plus the pool tokens
            uint256 inCampaign = c.unclaimedBurned() ? 0 : c.minedTotal() - claimed;
            assertEq(t.balanceOf(address(c)), inCampaign, "campaign balance after finalize");
            assertEq(t.balanceOf(address(p)), 0, "pool kept tokens after finalize");
            assertEq(t.balanceOf(address(handler.locker())), p.tokenAdded(), "locker tokens");
            // K65: the supply is what was mined plus what the pool minted for its opening;
            // the rest of the cap was never created
            assertEq(t.totalSupply() + (c.unclaimedBurned() ? c.minedTotal() - claimed : 0), c.minedTotal() + p.tokenAdded(), "supply != mined + pool opening");
            if (p.directLaunch()) {
                // K49: nobody mined or below the minimum: every unmined token goes
                // to the pool, nothing is burned (I13)
                assertTrue(handler.locker().direct(), "direct launch took the full-range path");
                assertEq(c.minedTotal(), 0, "direct launch although somebody mined");
                assertEq(p.tokenAdded(), handler.rp() + handler.rm() - c.minedTotal(), "direct launch left tokens out");
            } else {
                assertFalse(handler.locker().direct(), "full-range pool took the direct path");
                // K53: the full range at the chosen opening, plus tokens worth 1.5 ETH as the buffer
                // K53/K54: the ask holds the ETH's tokens at the opening plus the 1.5 ETH buffer,
                // and the bid is sized for every mined token
                // (at a full sell-out with the largest deposit the pool may hold a
                // few hundred thousand wei less, which `finalize` absorbs with `min`;
                // K63: a 1× fall-back of a large raise from few miners can only use
                // the tokens there are: the pool reserve plus the unmined reserve)
                uint256 ideal = p.tokensFor(p.ethAdded()) + p.tokensFor(p.OPENING_BUFFER_WEI());
                uint256 available = handler.rp() + handler.rm() - c.minedTotal();
                assertApproxEqAbs(
                    p.tokenAdded(), ideal < available ? ideal : available, 1e9, "ask not at the opening price"
                );
                // K63: below the threshold a 2× choice opens at 1×
                if (!c.doubleOpeningQualified()) assertEq(p.openingMultiple(), 1, "2x without qualifying");
                assertEq(handler.locker().floorIn(), c.minedTotal(), "floor not sized for the mined tokens");
            }
        }
    }

    /// Quota: nobody mines past the per-wallet cap (I11; v13: no stake bonus).
    function invariant_quotas() public view {
        MiningCampaign c = handler.campaign();
        for (uint256 i; i < 4; i++) {
            address o = handler.owners(i);
            assertLe(c.minedOf(o), c.quotaOf(o), "mined above quota");
        }
    }

    /// I4: every wei of fees is either platform (accrued or sent) or the
    /// pool's share (held, then sent to the pool). Nothing is refunded (K49).
    function invariant_feesAndEth() public view {
        MiningCampaign c = handler.campaign();
        CampaignPool p = handler.pool();
        uint256 platformSent = handler.TREASURY().balance;
        uint256 fees = handler.feesPaid();
        uint256 platformTotal = c.platformAccrued() + platformSent;

        if (c.status() == MiningCampaign.Status.Finalized) {
            assertEq(c.poolAccrued(), 0);
            assertEq(platformTotal + handler.poolShareAtSettle(), fees, "fee split (finalized)");
            assertEq(address(c).balance, c.platformAccrued(), "campaign ETH (finalized)");
            assertEq(handler.locker().ethIn(), handler.poolShareAtSettle() + p.totalDeposited(), "pool ETH to locker");
            assertEq(address(p).balance, 0, "pool kept ETH");
        } else {
            assertEq(platformTotal + c.poolAccrued(), fees, "fee split");
            assertEq(address(c).balance, c.platformAccrued() + c.poolAccrued(), "campaign ETH");
            assertEq(address(p).balance, p.totalDeposited(), "pool ETH");
        }
        // K56: the platform share is 1–5% of each fee, rounded down: never more than 5%
        assertLe(platformTotal * 20, fees, "platform above 5%");
    }

    /// I14: claims never run ahead of vesting; after it, everything is claimable.
    function invariant_vesting() public view {
        MiningCampaign c = handler.campaign();
        if (c.status() != MiningCampaign.Status.Finalized) return;
        uint256 vestEnd = uint256(c.finalizedAt()) + uint256(c.claimVestingDays()) * 1 days;
        for (uint256 i; i < 4; i++) {
            address o = handler.owners(i);
            uint256 open = c.claimedOf(o) + c.claimable(o);
            assertLe(open, c.minedOf(o), "vested above mined");
            if (block.timestamp >= vestEnd) assertEq(open, c.minedOf(o), "not fully vested after vesting");
        }
    }

    /// I15 (K63): a mined pool is open only after every owner had their
    /// delivery — at least the first tranche (everything without vesting).
    function invariant_openOnlyAfterDelivery() public view {
        CampaignPool p = handler.pool();
        if (p.status() != CampaignPool.Status.Finalized || p.directLaunch()) return;
        MiningCampaign c = handler.campaign();
        assertTrue(c.distributionDone(), "pool open before delivery");
        for (uint256 i; i < 4; i++) {
            address o = handler.owners(i);
            uint256 due = c.claimVestingDays() == 0 ? c.minedOf(o) : c.minedOf(o) / 4;
            assertGe(c.claimedOf(o), due, "owner not delivered");
        }
    }
}

/// Every creator option on: hourly schedule, 7-day vesting, a 1× opening
/// (K51). (v4–v12 also had a 24-hour stakers' window.)
contract CampaignInvariantsAllOptions is CampaignInvariantsBase {
    function _config() internal pure override returns (CampaignHandler.Config memory c) {
        c.hourly = true;
        c.vestingDays = 7;
        c.multiple = 1;
    }
}

/// No options.
contract CampaignInvariantsPlain is CampaignInvariantsBase {
    function _config() internal pure override returns (CampaignHandler.Config memory c) {}
}

/// 500-ETH proofs (60,000 tokens) and a 2,000-ETH wallet
/// cap: the reserve sells out within a run, so early finalize and the
/// largest pools are covered.
contract CampaignInvariantsSellOut is CampaignInvariantsBase {
    function _config() internal pure override returns (CampaignHandler.Config memory c) {
        c.proofFee = 500 ether;
        c.walletCapWei = 2_000 ether;
        c.vestingDays = 14;
    }
}

/// The smallest wallet cap (0.1 ETH, 12 tokens: a full proof and a partial
/// one), 30-day vesting. It replaced the allowlist suite (K50).
contract CampaignInvariantsSmallCap is CampaignInvariantsBase {
    function _config() internal pure override returns (CampaignHandler.Config memory c) {
        c.walletCapWei = 0.1 ether;
        c.vestingDays = 30;
    }
}

/// A 1× opening (K51) that sells out: the pool half covers every proof
/// plus deposits.
contract CampaignInvariantsSellOutOneX is CampaignInvariantsBase {
    function _config() internal pure override returns (CampaignHandler.Config memory c) {
        c.proofFee = 500 ether;
        c.walletCapWei = 2_000 ether;
        c.multiple = 1;
    }
}
