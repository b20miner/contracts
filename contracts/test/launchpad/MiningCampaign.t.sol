// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {B20PoW} from "../../src/B20PoW.sol";

/// @dev Anyone may mint (tests seed balances freely); `renounced` records who
/// gave up `MINT_ROLE` (K65) and a renounced minter cannot mint again.
contract MockCampaignToken is ERC20 {
    uint256 public supplyCap = type(uint128).max;
    mapping(address => bool) public renounced;

    constructor() ERC20("Kedi", "KEDI") {}

    function setSupplyCap(uint256 cap) external {
        supplyCap = cap;
    }

    function mint(address to, uint256 amount) external {
        require(!renounced[msg.sender], "mint role renounced");
        require(totalSupply() + amount <= supplyCap, "supply cap");
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @dev Test-only: tokens that arrive from elsewhere, ignoring the cap.
    function seed(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function renounceRole(bytes32, address callerConfirmation) external {
        require(callerConfirmation == msg.sender, "bad confirmation");
        renounced[msg.sender] = true;
    }
}

contract RejectingMiner {
    function mine(MiningCampaign c, address owner, uint256 value) external {
        c.submitProof{value: value}(owner, c.challengeOf(owner), 1);
    }
}

contract MiningCampaignTest is Test {
    using stdStorage for StdStorage;

    uint256 constant PROOF_FEE = 100_000_000_000_000; // 0.0001 ETH (K57, v9)
    uint256 constant EASY = type(uint256).max;
    address constant TREASURY = address(0x7EA5);
    address constant OWNER = address(0xA11CE);
    address constant OWNER2 = address(0xB0B);
    address constant MINER = address(0x3141);

    MiningCampaign impl;
    MockCampaignToken token;
    uint64 startAt;

    receive() external payable {} // this test contract plays the CampaignPool

    function setUp() public {
        vm.warp(1_800_000_000);
        impl = new MiningCampaign();
        token = new MockCampaignToken();
        startAt = uint64(block.timestamp + 1 hours);
        vm.deal(MINER, 1_000 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _params(uint256 supplyWhole) internal view returns (MiningCampaign.InitParams memory p) {
        p.token = address(token);
        p.pool = address(this);
        p.platformTreasury = TREASURY;
        p.powTarget = EASY;
        p.proofFee = PROOF_FEE;
        p.supplyWhole = supplyWhole;
        p.miningReserve = supplyWhole * 1e18 * 2 / 3;
        p.start = startAt;
        p.durationDays = 7;
        p.walletCapWei = 1 ether;
    }

    function _deploy(MiningCampaign.InitParams memory p) internal returns (MiningCampaign c) {
        c = MiningCampaign(payable(Clones.clone(address(impl))));
        c.initialize(p);
    }

    function _openAt(MiningCampaign c) internal {
        vm.warp(c.start());
        c.open();
    }

    function _mine(MiningCampaign c, address owner) internal returns (uint256 reward, uint256 fee) {
        (reward, fee) = c.quoteProof(owner);
        bytes32 challenge = c.challengeOf(owner); // before the prank, which the next call uses up
        vm.prank(MINER);
        c.submitProof{value: fee}(owner, challenge, 7);
    }

    // ------------------------------------------------------------- initialize

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(MiningCampaign.AlreadyInitialized.selector);
        impl.initialize(_params(1_000_000_000));
    }

    function test_cloneInitializesOnce() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        vm.expectRevert(MiningCampaign.AlreadyInitialized.selector);
        c.initialize(_params(1_000_000_000));
        assertEq(c.factory(), address(this));
        assertEq(c.end(), startAt + 7 days);
    }

    /// K50: anyone mines, always up to a per-wallet cap; a zero cap is invalid.
    function test_rejectsZeroWalletCap() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.walletCapWei = 0;
        MiningCampaign c = MiningCampaign(payable(Clones.clone(address(impl))));
        vm.expectRevert(MiningCampaign.InvalidInit.selector);
        c.initialize(p);
    }

    // ----------------------------------------------------------------- prices

    function test_priceAtOneBillion() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        // K57: 1 ETH = 100,000,000 tokens; a full proof pays 0.0001 ETH and earns exactly 10,000 tokens.
        assertEq(c.priceNum(), 10_000_000_000_000);
        assertEq(c.rewardPerProof(), 10_000e18);
        assertEq(c.miningFeeFor(c.rewardPerProof()), PROOF_FEE);
        assertEq(c.capTokens(), 100_000_000e18); // a 1 ETH cap
    }

    function test_memeSupplyWorks() public {
        MiningCampaign c = _deploy(_params(69_420_000)); // 6,942,000 tokens per ETH
        assertEq(c.capTokens(), 6_942_000e18);
        assertEq(c.miningFeeFor(c.rewardPerProof()), PROOF_FEE);
    }

    function testFuzz_fullProofAlwaysCostsTheProofFee(uint256 supply) public {
        supply = bound(supply, 1_000_000, 1_000_000_000_000);
        MiningCampaign c = _deploy(_params(supply));
        assertGt(c.rewardPerProof(), 0);
        assertEq(c.miningFeeFor(c.rewardPerProof()), PROOF_FEE);
        // a partial reward costs its exact price rounded up to the wei: enough, and 1 wei less is not
        uint256 part = c.rewardPerProof() / 3;
        uint256 fee = c.miningFeeFor(part);
        assertGe(fee * c.priceNum(), part * 100_000);
        assertLt((fee - 1) * c.priceNum(), part * 100_000);
    }

    // ------------------------------------------------------------------ open

    function test_openTimingAndSeed() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        vm.expectRevert(MiningCampaign.NotStarted.selector);
        c.open();
        assertEq(c.challengeOf(OWNER), bytes32(0));

        vm.warp(startAt);
        vm.prank(address(0xDEAD)); // anyone
        c.open();
        assertTrue(c.opened());
        assertTrue(c.seed() != bytes32(0));
        assertTrue(c.challengeOf(OWNER) != bytes32(0));
        assertTrue(c.challengeOf(OWNER) != c.challengeOf(OWNER2));

        vm.expectRevert(MiningCampaign.AlreadyOpened.selector);
        c.open();
    }

    function test_cannotOpenAfterEnd() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        vm.warp(c.end());
        vm.expectRevert(MiningCampaign.WindowClosed.selector);
        c.open();
    }

    function test_proofNeedsOpen() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        vm.warp(startAt);
        vm.prank(MINER);
        vm.expectRevert(MiningCampaign.NotOpened.selector);
        c.submitProof{value: PROOF_FEE}(OWNER, bytes32(0), 1);
    }

    // ---------------------------------------------------------------- proofs

    function test_proofCreditsOwnerSplitsFeeAndRefundsExcess() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        uint256 before = MINER.balance;
        vm.prank(MINER);
        c.submitProof{value: PROOF_FEE + 5}(OWNER, ch, 42);

        assertEq(c.minedOf(OWNER), c.rewardPerProof());
        assertEq(c.minedTotal(), c.rewardPerProof());
        // K56: 1% to the platform while under 4% of the reserve is mined.
        assertEq(c.platformAccrued(), PROOF_FEE / 100);
        assertEq(c.poolAccrued(), PROOF_FEE - PROOF_FEE / 100);
        assertEq(c.poolPaidOf(OWNER), PROOF_FEE - PROOF_FEE / 100);
        assertEq(MINER.balance, before - PROOF_FEE);
        assertEq(address(c).balance, PROOF_FEE);
        assertTrue(c.challengeOf(OWNER) != ch);
        assertEq(c.acceptedProofs(OWNER), 1);
    }

    /// Half of all hashes are valid at 2^255: every nonce is accepted
    /// exactly when the B20MINER preimage hash is at or under the target.
    function test_proofUsesTheB20MinerPreimage() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.powTarget = 1 << 255;
        MiningCampaign c = _deploy(p);
        _openAt(c);
        uint256 accepted;
        uint256 rejected;
        for (uint256 nonce = 0; nonce < 24; nonce++) {
            bytes32 ch = c.challengeOf(OWNER);
            bytes32 h = B20PoW.computeHash(block.chainid, address(c), OWNER, MINER, ch, nonce);
            vm.prank(MINER);
            if (uint256(h) <= p.powTarget) {
                c.submitProof{value: PROOF_FEE}(OWNER, ch, nonce);
                accepted++;
            } else {
                vm.expectRevert(MiningCampaign.InvalidProof.selector);
                c.submitProof{value: PROOF_FEE}(OWNER, ch, nonce);
                rejected++;
            }
        }
        assertEq(c.acceptedProofs(OWNER), accepted);
        assertGt(accepted, 0);
        assertGt(rejected, 0);
    }

    function test_rejectsStaleChallengeAndBadProof() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.powTarget = 1; // practically impossible
        MiningCampaign c = _deploy(p);
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        vm.startPrank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.StaleChallenge.selector, bytes32(uint256(5)), ch));
        c.submitProof{value: PROOF_FEE}(OWNER, bytes32(uint256(5)), 1);
        vm.expectRevert(MiningCampaign.InvalidProof.selector);
        c.submitProof{value: PROOF_FEE}(OWNER, ch, 1);
        vm.stopPrank();
    }

    function test_rejectsUnderpaymentAndZeroOwner() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        vm.startPrank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.InsufficientFee.selector, PROOF_FEE - 1, PROOF_FEE));
        c.submitProof{value: PROOF_FEE - 1}(OWNER, ch, 1);
        vm.expectRevert(MiningCampaign.ZeroOwner.selector);
        c.submitProof{value: PROOF_FEE}(address(0), bytes32(0), 1);
        vm.stopPrank();
    }

    function test_noProofAfterEnd() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        vm.warp(c.end());
        bytes32 ch = c.challengeOf(OWNER);
        vm.prank(MINER);
        vm.expectRevert(MiningCampaign.WindowClosed.selector);
        c.submitProof{value: PROOF_FEE}(OWNER, ch, 1);
        (uint256 r, uint256 f) = c.quoteProof(OWNER);
        assertEq(r, 0);
        assertEq(f, 0);
    }

    // ----------------------------------------------------------- Public cap

    function test_publicCapWithPartialLastProof() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.walletCapWei = PROOF_FEE * 2 + PROOF_FEE / 2; // 2.5 proofs
        MiningCampaign c = _deploy(p);
        _openAt(c);
        _mine(c, OWNER);
        _mine(c, OWNER);
        (uint256 reward, uint256 fee) = c.quoteProof(OWNER);
        assertEq(reward, c.capTokens() - 2 * c.rewardPerProof());
        assertApproxEqAbs(fee, PROOF_FEE / 2, 1);
        _mine(c, OWNER);
        assertEq(c.minedOf(OWNER), c.capTokens());
        assertEq(c.remainingQuota(OWNER), 0);

        bytes32 ch = c.challengeOf(OWNER);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.QuotaExhausted.selector, OWNER));
        c.submitProof{value: PROOF_FEE}(OWNER, ch, 1);
        // another owner is unaffected
        _mine(c, OWNER2);
    }

    /// v13: no stake bonus and no stakers' window — every owner has the
    /// same quota and anyone mines from the opening.
    function test_everyOwnerSameQuotaAndMinesFromTheOpening() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        assertEq(c.quotaOf(OWNER), c.capTokens());
        assertEq(c.quotaOf(OWNER2), c.capTokens());
        _openAt(c);
        (uint256 r,) = _mine(c, OWNER2);
        assertEq(r, c.rewardPerProof());
    }

    // ------------------------------------------------------ reserve & hours

    function test_reserveSellOutEndsMiningEarly() public {
        MiningCampaign.InitParams memory p = _params(1_000_000); // reward 10 tokens
        p.miningReserve = 16e18; // 16 tokens: one full proof and a partial one
        MiningCampaign c = _deploy(p);
        _openAt(c);
        assertFalse(c.miningOver());
        _mine(c, OWNER);
        (uint256 r,) = c.quoteProof(OWNER2);
        assertEq(r, p.miningReserve - c.rewardPerProof());
        _mine(c, OWNER2);
        assertEq(c.minedTotal(), p.miningReserve);
        assertTrue(c.miningOver());
        bytes32 ch = c.challengeOf(OWNER);
        vm.prank(MINER);
        vm.expectRevert(MiningCampaign.ReserveExhausted.selector);
        c.submitProof{value: PROOF_FEE}(OWNER, ch, 1);
    }

    function test_hourlyScheduleReleasesTheReserveOverTime() public {
        MiningCampaign.InitParams memory p = _params(1_000_000);
        p.durationDays = 1; // 24 hours
        p.hourlySchedule = true;
        p.miningReserve = 24 * 16e18; // 16 tokens per hour
        MiningCampaign c = _deploy(p);
        assertEq(c.releasedReserve(), 0);
        _openAt(c);
        assertEq(c.releasedReserve(), 16e18);
        assertEq(c.nextReleaseAt(), startAt + 1 hours);

        _mine(c, OWNER); // 10
        _mine(c, OWNER); // 6 (partial: hour's share)
        assertEq(c.minedTotal(), 16e18);
        bytes32 ch = c.challengeOf(OWNER);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.HourlyLimitReached.selector, uint256(startAt) + 1 hours));
        c.submitProof{value: PROOF_FEE}(OWNER, ch, 1);

        vm.warp(startAt + 3 hours); // two unused hours roll forward
        assertEq(c.releasedReserve(), 4 * 16e18);
        (uint256 r,) = c.quoteProof(OWNER);
        assertEq(r, c.rewardPerProof());
        vm.warp(c.end() - 1);
        assertEq(c.releasedReserve(), p.miningReserve);
    }

    // ------------------------------------------------------------ settle

    function test_onlyPoolSettlesAndOnlyWhenOver() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        vm.prank(address(0xBAD));
        vm.expectRevert(MiningCampaign.NotPool.selector);
        c.settle(false);
        vm.expectRevert(MiningCampaign.MiningNotOver.selector);
        c.settle(false);
    }

    /// K65 (v12): settle moves no token — the unmined reserve was never
    /// minted — sends the pool share, gives up the mint role and opens claims;
    /// the mined tokens stay here for delivery.
    function test_settleSendsPoolShareRenouncesMintAndOpensClaim() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        _mine(c, OWNER);
        _mine(c, OWNER2);
        vm.warp(c.end());
        uint256 poolShare = c.poolAccrued();
        uint256 balBefore = address(this).balance;
        uint256 sent = c.settle(false);

        assertEq(sent, poolShare);
        assertEq(address(this).balance, balBefore + poolShare);
        assertEq(token.balanceOf(address(c)), c.minedTotal());
        assertEq(token.balanceOf(address(this)), 0, "no unmined tokens exist");
        assertEq(token.totalSupply(), c.minedTotal(), "supply = mined");
        assertTrue(token.renounced(address(c)), "mint role given up");
        assertEq(uint8(c.status()), uint8(MiningCampaign.Status.Finalized));
        vm.expectRevert(MiningCampaign.NotActive.selector);
        c.settle(false);

        vm.prank(OWNER);
        c.claim();
        assertEq(token.balanceOf(OWNER), c.rewardPerProof());
        vm.prank(OWNER);
        vm.expectRevert(MiningCampaign.NothingToClaim.selector);
        c.claim();
    }

    /// K49 (v5): a direct launch refunds nothing. Claims open and the pool
    /// share goes to the pool; K65: no unmined token exists to hand over.
    function test_directSettleOpensClaimsAndMovesNoToken() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        _mine(c, OWNER);
        _mine(c, OWNER);
        _mine(c, OWNER2);
        vm.warp(c.end());
        uint256 poolShare = c.poolAccrued();
        uint256 ethBefore = address(this).balance;

        assertEq(c.settle(true), poolShare);
        assertEq(address(this).balance, ethBefore + poolShare);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(c)), c.minedTotal(), "mined tokens stay for claims");
        assertEq(token.totalSupply(), c.minedTotal());
        assertEq(uint8(c.status()), uint8(MiningCampaign.Status.Finalized));

        vm.prank(OWNER);
        c.claim();
        assertEq(token.balanceOf(OWNER), 2 * c.rewardPerProof());
        // the platform share is untouched
        c.withdrawPlatformFees();
        assertEq(TREASURY.balance, 3 * (PROOF_FEE / 100));
    }

    function test_directSettleWithNobodyMiningLeavesNoSupply() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        vm.warp(c.end());
        assertEq(c.settle(true), 0);
        assertEq(token.totalSupply(), 0);
        assertTrue(token.renounced(address(c)));
    }

    // ------------------------------------------------ K65: mined, not minted

    /// Every proof mints exactly its reward into the campaign's escrow; the
    /// supply is the mined total, nothing more.
    function test_eachProofMintsItsReward() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        assertEq(token.totalSupply(), 0);
        (uint256 r1,) = _mine(c, OWNER);
        assertEq(token.totalSupply(), r1);
        (uint256 r2,) = _mine(c, OWNER2);
        assertEq(token.totalSupply(), r1 + r2);
        assertEq(token.balanceOf(address(c)), c.minedTotal());
    }

    /// A smaller last proof (the reserve's end) mints only what it earns,
    /// and the campaign can never mint past the mining reserve.
    function test_mintStopsAtTheMiningReserve() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.miningReserve = 25_000e18; // 2.5 proofs
        MiningCampaign c = _deploy(p);
        _openAt(c);
        _mine(c, OWNER);
        _mine(c, OWNER);
        (uint256 last,) = _mine(c, OWNER);
        assertEq(last, 5_000e18);
        assertEq(token.totalSupply(), 25_000e18);
        bytes32 challenge = c.challengeOf(OWNER);
        vm.prank(MINER);
        vm.expectRevert(MiningCampaign.ReserveExhausted.selector);
        c.submitProof{value: PROOF_FEE}(OWNER, challenge, 7);
    }

    /// The token's own chain: block 1's parent is the campaign seed, each
    /// next block's parent is the previous hash, and the hash commits to the
    /// height, parent, proof, owner, mining wallet and amount.
    function test_tokenBlocksChainFromTheSeed() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        assertEq(c.tokenBlocks(), 0);

        bytes32 ch = c.challengeOf(OWNER);
        bytes32 proof1 = B20PoW.computeHash(block.chainid, address(c), OWNER, MINER, ch, 7);
        uint256 reward = c.rewardPerProof();
        bytes32 h1 = keccak256(
            abi.encodePacked(
                "B20_TOKEN_BLOCK_V1", block.chainid, address(c), uint256(1), c.seed(), proof1, OWNER, MINER, reward
            )
        );
        vm.expectEmit(true, true, true, true, address(c));
        emit MiningCampaign.TokenBlock(1, OWNER, MINER, h1, c.seed(), proof1, reward);
        _mine(c, OWNER);
        assertEq(c.tokenBlocks(), 1);
        assertEq(c.tokenBlockHash(), h1);

        ch = c.challengeOf(OWNER2);
        bytes32 proof2 = B20PoW.computeHash(block.chainid, address(c), OWNER2, MINER, ch, 7);
        bytes32 h2 = keccak256(
            abi.encodePacked("B20_TOKEN_BLOCK_V1", block.chainid, address(c), uint256(2), h1, proof2, OWNER2, MINER, reward)
        );
        vm.expectEmit(true, true, true, true, address(c));
        emit MiningCampaign.TokenBlock(2, OWNER2, MINER, h2, h1, proof2, reward);
        _mine(c, OWNER2);
        assertEq(c.tokenBlocks(), 2);
        assertEq(c.tokenBlockHash(), h2);
    }

    /// A 16-share batch is one block; its proof hash is the hash of the 16
    /// share hashes.
    function test_shareBatchIsOneBlock() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        uint256[16] memory nonces;
        bytes32[16] memory hashes;
        for (uint256 i; i < 16; ++i) {
            nonces[i] = i + 1;
            hashes[i] = B20PoW.computeHash(block.chainid, address(c), OWNER, MINER, ch, i + 1);
        }
        (uint256 reward, uint256 fee) = c.quoteProof(OWNER);
        bytes32 proof = keccak256(abi.encodePacked(hashes));
        bytes32 h1 = keccak256(
            abi.encodePacked("B20_TOKEN_BLOCK_V1", block.chainid, address(c), uint256(1), c.seed(), proof, OWNER, MINER, reward)
        );
        vm.expectEmit(true, true, true, true, address(c));
        emit MiningCampaign.TokenBlock(1, OWNER, MINER, h1, c.seed(), proof, reward);
        vm.prank(MINER);
        c.submitShares{value: fee}(OWNER, ch, nonces);
        assertEq(c.tokenBlocks(), 1);
        assertEq(token.totalSupply(), reward);
    }

    // ------------------------------------------------- vesting and deadline

    function test_vestingReleasesLinearlyAndDeadlineMovesWithIt() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.claimVestingDays = 7;
        MiningCampaign c = _deploy(p);
        _openAt(c);
        for (uint256 i = 0; i < 4; i++) {
            _mine(c, OWNER);
        }
        vm.warp(c.end());
        c.settle(false);
        uint256 total = c.minedOf(OWNER);
        uint256 first = total / 4; // K63: 25% at finalize
        assertEq(c.claimable(OWNER), first);
        assertEq(c.claimDeadline(), block.timestamp + 7 days + 15 days);

        // the first tranche is delivered; the rest vests linearly
        c.distribute(10);
        assertEq(token.balanceOf(OWNER), first);
        assertEq(c.claimable(OWNER), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(c.claimable(OWNER), (total - first) / 7);
        vm.prank(OWNER);
        c.claim();
        vm.warp(block.timestamp + 6 days);
        vm.prank(OWNER);
        c.claim();
        assertEq(token.balanceOf(OWNER), total);
    }

    function test_burnUnclaimedAfterDeadlineOnly() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        _mine(c, OWNER);
        vm.warp(c.end());
        c.settle(false);
        uint256 deadline = c.claimDeadline();
        vm.expectRevert(MiningCampaign.DeadlineNotReached.selector);
        c.burnUnclaimed();
        vm.warp(deadline + 1);
        vm.prank(OWNER);
        vm.expectRevert(MiningCampaign.ClaimClosed.selector);
        c.claim();
        // K63: nothing is burned before every owner had their delivery
        vm.expectRevert(MiningCampaign.DistributionPending.selector);
        c.burnUnclaimed();
        c.distribute(10);
        assertEq(token.balanceOf(OWNER), c.minedOf(OWNER));
        c.burnUnclaimed();
        assertEq(token.balanceOf(address(c)), 0);
        vm.expectRevert(MiningCampaign.AlreadyBurned.selector);
        c.burnUnclaimed();
    }

    // ------------------------------------------------- K63 distribution

    function test_ownersAreListedOnceInFirstProofOrder() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        _mine(c, OWNER2);
        _mine(c, OWNER);
        _mine(c, OWNER2);
        assertEq(c.ownerCount(), 2);
        assertEq(c.ownerAt(0), OWNER2);
        assertEq(c.ownerAt(1), OWNER);
    }

    function test_distributeDeliversInBatchesAndSkipsWhoClaimed() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        address[5] memory owners = [address(0x1001), address(0x1002), address(0x1003), address(0x1004), address(0x1005)];
        for (uint256 i; i < owners.length; ++i) {
            _mine(c, owners[i]);
        }
        vm.warp(c.end());
        vm.expectRevert(MiningCampaign.NotFinalized.selector);
        c.distribute(1);
        c.settle(false);
        assertFalse(c.distributionDone());

        // owner 3 claims for themselves first; distribution skips them
        vm.prank(owners[2]);
        c.claim();
        assertEq(c.distribute(2), 2);
        assertEq(c.distributedCount(), 2);
        assertEq(token.balanceOf(owners[0]), c.rewardPerProof());
        assertEq(token.balanceOf(owners[3]), 0);
        assertEq(c.distribute(10), 3);
        assertTrue(c.distributionDone());
        for (uint256 i; i < owners.length; ++i) {
            assertEq(token.balanceOf(owners[i]), c.rewardPerProof());
            assertEq(c.claimedOf(owners[i]), c.rewardPerProof());
        }
        assertEq(token.balanceOf(address(c)), 0);
        // a further call serves nobody
        assertEq(c.distribute(10), 0);
    }

    function test_qualifiedMinersCountOncePastTheMinimum() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        // 0.005 ETH at the mining price = 50 proofs
        assertEq(c.minerMinTokens(), 50 * c.rewardPerProof());
        for (uint256 i; i < 49; ++i) {
            _mine(c, OWNER);
        }
        assertEq(c.qualifiedMiners(), 0);
        _mine(c, OWNER);
        assertEq(c.qualifiedMiners(), 1);
        _mine(c, OWNER);
        assertEq(c.qualifiedMiners(), 1);
        _mine(c, OWNER2);
        assertEq(c.qualifiedMiners(), 1);
    }

    function test_doubleOpeningNeedsHalfAnEthAndTenMiners() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        _mine(c, OWNER);
        uint256 halfEth = 0.5 ether * c.priceNum() / c.PRICE_DEN();
        stdstore.target(address(c)).sig("minedTotal()").checked_write(halfEth - 1);
        stdstore.target(address(c)).sig("qualifiedMiners()").checked_write(10);
        assertFalse(c.doubleOpeningQualified(), "just under 0.5 ETH");
        stdstore.target(address(c)).sig("minedTotal()").checked_write(halfEth);
        assertTrue(c.doubleOpeningQualified());
        assertEq(c.minedEth(), 0.5 ether);
        stdstore.target(address(c)).sig("qualifiedMiners()").checked_write(9);
        assertFalse(c.doubleOpeningQualified(), "nine miners");
    }

    function test_vestingFirstTrancheIsAQuarter() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.claimVestingDays = 30;
        MiningCampaign c = _deploy(p);
        _openAt(c);
        _mine(c, OWNER);
        vm.warp(c.end());
        c.settle(false);
        c.distribute(1);
        assertEq(token.balanceOf(OWNER), c.rewardPerProof() / 4);
        vm.warp(block.timestamp + 30 days);
        vm.prank(OWNER);
        c.claim();
        assertEq(token.balanceOf(OWNER), c.rewardPerProof());
    }

    // -------------------------------------------------------------- fees

    function test_platformFeesGoToTreasury() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        _mine(c, OWNER);
        c.withdrawPlatformFees();
        assertEq(TREASURY.balance, PROOF_FEE / 100);
        assertEq(c.platformAccrued(), 0);
        c.withdrawPlatformFees(); // no-op
    }

    /// K56: 1% under 4% of the reserve mined, +1% per further 4%, 5% from 16% on.
    function test_platformShareRampsFromOneToFivePercent() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.miningReserve = 600_000_000e18; // a 2× opening's reserve (K55)
        MiningCampaign c = _deploy(p);
        uint256 r = c.miningReserve();
        uint256[9] memory mined = [0, r / 25 - 1, r / 25, r * 2 / 25, r * 3 / 25, r * 4 / 25 - 1, r * 4 / 25, r / 5, r - 1];
        uint256[9] memory bps = [uint256(100), 100, 200, 300, 400, 400, 500, 500, 500];
        for (uint256 i; i < mined.length; ++i) {
            stdstore.target(address(c)).sig("minedTotal()").checked_write(mined[i]);
            assertEq(c.platformShareBps(), bps[i]);
        }
    }

    /// K56: a proof pays the platform the rate of the step its last token falls in.
    function test_proofPaysTheRateInForce() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.miningReserve = 400_000_000e18; // a 1× opening's reserve (K55)
        MiningCampaign c = _deploy(p);
        _openAt(c);
        stdstore.target(address(c)).sig("minedTotal()").checked_write(c.miningReserve() * 3 / 25);
        (, uint256 fee) = _mine(c, OWNER);
        assertEq(c.platformAccrued(), fee * 4 / 100);
        assertEq(c.poolAccrued(), fee - fee * 4 / 100);
    }

    /// K56: a proof that straddles a step pays the higher rate.
    function test_proofStraddlingAStepPaysTheHigherRate() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.miningReserve = 600_000_000e18;
        MiningCampaign c = _deploy(p);
        _openAt(c);
        stdstore.target(address(c)).sig("minedTotal()").checked_write(c.miningReserve() / 25 - 1);
        assertEq(c.platformShareBps(), 100);
        (, uint256 fee) = _mine(c, OWNER);
        assertEq(c.platformAccrued(), fee * 2 / 100);
    }

    function test_minerThatRejectsItsRefundCannotMine() public {
        MiningCampaign c = _deploy(_params(1_000_000_000));
        _openAt(c);
        RejectingMiner m = new RejectingMiner();
        vm.deal(address(m), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.EthTransferFailed.selector, address(m), 1));
        m.mine(c, OWNER, PROOF_FEE + 1);
    }
    // ------------------------------------------------------------ shares (K58)

    /// The first 16 ascending nonces from `from` whose hashes meet the share target.
    function _shares(MiningCampaign c, address owner, uint256 from) internal view returns (uint256[16] memory nonces) {
        bytes32 ch = c.challengeOf(owner);
        uint256 target = c.shareTarget();
        uint256 n;
        for (uint256 nonce = from; n < 16; nonce++) {
            if (uint256(B20PoW.computeHash(block.chainid, address(c), owner, MINER, ch, nonce)) <= target) {
                nonces[n++] = nonce;
            }
        }
    }

    function _copy(uint256[16] memory a) internal pure returns (uint256[16] memory b) {
        for (uint256 i; i < 16; ++i) b[i] = a[i];
    }

    function test_shareTargetIsSixteenTimesTheProofTarget() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.powTarget = type(uint256).max >> 24;
        MiningCampaign c = _deploy(p);
        assertEq(c.shareTarget(), type(uint256).max >> 20);
        assertEq(c.SHARES_PER_PROOF(), 16);
        // Easiest proof target: the share target cannot overflow.
        assertEq(_deploy(_params(1_000_000_000)).shareTarget(), type(uint256).max);
    }

    /// 16 shares earn exactly one proof's reward for one proof's fee and
    /// advance the challenge like a proof.
    function test_sixteenSharesEarnOneProof() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.powTarget = type(uint256).max >> 5; // share target 2^255 - 1: half of all hashes
        MiningCampaign c = _deploy(p);
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        uint256[16] memory nonces = _shares(c, OWNER, 0);
        vm.prank(MINER);
        c.submitShares{value: PROOF_FEE + 3}(OWNER, ch, nonces);
        assertEq(c.minedOf(OWNER), c.rewardPerProof());
        assertEq(c.minedOf(OWNER), 10_000e18);
        assertEq(c.platformAccrued() + c.poolAccrued(), PROOF_FEE);
        assertEq(c.acceptedProofs(OWNER), 1);
        assertTrue(c.challengeOf(OWNER) != ch);
        assertEq(address(c).balance, PROOF_FEE); // the 3 wei excess went back

        // The same shares are worth nothing under the new challenge.
        bytes32 next = c.challengeOf(OWNER);
        vm.prank(MINER);
        vm.expectRevert();
        c.submitShares{value: PROOF_FEE}(OWNER, next, nonces);
    }

    function test_sharesMustAscendAndEachMeetTheTarget() public {
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.powTarget = type(uint256).max >> 5;
        MiningCampaign c = _deploy(p);
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        uint256[16] memory nonces = _shares(c, OWNER, 0);

        uint256[16] memory dup = _copy(nonces);
        dup[9] = dup[8]; // a share counted twice
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.SharesNotAscending.selector, 9));
        c.submitShares{value: PROOF_FEE}(OWNER, ch, dup);

        uint256[16] memory swapped = _copy(nonces);
        (swapped[3], swapped[4]) = (swapped[4], swapped[3]);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.SharesNotAscending.selector, 4));
        c.submitShares{value: PROOF_FEE}(OWNER, ch, swapped);

        // A nonce between two shares that misses the target.
        uint256 target = c.shareTarget();
        uint256 bad = nonces[14] + 1;
        while (uint256(B20PoW.computeHash(block.chainid, address(c), OWNER, MINER, ch, bad)) <= target) bad++;
        uint256[16] memory invalid = _copy(nonces);
        invalid[15] = bad;
        if (bad > nonces[14]) {
            vm.prank(MINER);
            vm.expectRevert(abi.encodeWithSelector(MiningCampaign.InvalidShare.selector, 15));
            c.submitShares{value: PROOF_FEE}(OWNER, ch, invalid);
        }

        // Another mining wallet cannot use them: the hash binds msg.sender.
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        c.submitShares{value: PROOF_FEE}(OWNER, ch, nonces);

        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.InsufficientFee.selector, PROOF_FEE - 1, PROOF_FEE));
        c.submitShares{value: PROOF_FEE - 1}(OWNER, ch, nonces);

        assertEq(c.minedOf(OWNER), 0);
    }

    /// Shares follow every rule a proof does: stale challenge, quota, the
    /// partial last batch and the platform tiers.
    function test_sharesFollowTheProofRules() public {
        MiningCampaign.InitParams memory p = _params(1_000_000);
        p.powTarget = type(uint256).max >> 5;
        p.walletCapWei = PROOF_FEE + PROOF_FEE / 2; // 1.5 proofs
        MiningCampaign c = _deploy(p);
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        uint256[16] memory first = _shares(c, OWNER, 0);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.StaleChallenge.selector, bytes32(uint256(1)), ch));
        c.submitShares{value: PROOF_FEE}(OWNER, bytes32(uint256(1)), first);

        vm.prank(MINER);
        c.submitShares{value: PROOF_FEE}(OWNER, ch, first);
        assertEq(c.platformAccrued(), PROOF_FEE / 100); // 1% tier

        // Half a proof left: a full batch of 16 shares earns the half.
        (uint256 reward, uint256 fee) = c.quoteProof(OWNER);
        assertEq(reward, c.rewardPerProof() / 2);
        bytes32 ch2 = c.challengeOf(OWNER);
        uint256[16] memory second = _shares(c, OWNER, 0);
        vm.prank(MINER);
        c.submitShares{value: fee}(OWNER, ch2, second);
        assertEq(c.minedOf(OWNER), c.rewardPerProof() * 3 / 2);

        bytes32 ch3 = c.challengeOf(OWNER);
        uint256[16] memory more = _shares(c, OWNER, 0);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningCampaign.QuotaExhausted.selector, OWNER));
        c.submitShares{value: PROOF_FEE}(OWNER, ch3, more);
    }

    /// Fuzz: any 16 ascending valid shares credit one proof, never more.
    function testFuzz_sharesNeverCreditMoreThanOneProof(uint256 from) public {
        from = bound(from, 0, type(uint128).max);
        MiningCampaign.InitParams memory p = _params(1_000_000_000);
        p.powTarget = type(uint256).max >> 6;
        MiningCampaign c = _deploy(p);
        _openAt(c);
        bytes32 ch = c.challengeOf(OWNER);
        uint256[16] memory nonces = _shares(c, OWNER, from);
        vm.prank(MINER);
        c.submitShares{value: PROOF_FEE}(OWNER, ch, nonces);
        assertEq(c.minedTotal(), c.rewardPerProof());
    }
}
