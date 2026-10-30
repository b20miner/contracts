// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {B20CommunityVault} from "../src/B20CommunityVault.sol";
import {MinerBurner} from "../src/MinerBurner.sol";
import {MockCampaignToken} from "./launchpad/MiningCampaign.t.sol";

contract MockMiningTotals {
    uint256 public constant BASE_QUOTA_CAP = 60_000_000_000 * 1e18;
    uint256 public miningEnd;
    uint256 public totalBaseMinedLocked;
    bool public opened;

    function set(uint256 end_, uint256 mined) external {
        miningEnd = end_;
        totalBaseMinedLocked = mined;
        opened = true;
    }

    function MINING_END() external view returns (uint256) {
        require(opened, "MiningNotOpened");
        return miningEnd;
    }
}

contract MockClaimDeadline {
    MockMiningTotals immutable mining;

    constructor(MockMiningTotals m) {
        mining = m;
    }

    function claimDeadline() external view returns (uint256) {
        return mining.MINING_END() + 15 days;
    }
}

contract WrongCapMining {
    function BASE_QUOTA_CAP() external pure returns (uint256) {
        return 1;
    }
}

contract B20CommunityVaultTest is Test {
    uint256 constant RESERVE = 8_000_000_000e18;
    uint256 constant FLOOR = 1_000_000_000e18;
    uint256 constant BASE_CAP = 60_000_000_000e18;
    address constant MANAGER = address(0x6A2D);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant STAKING = address(0x57A4E);

    MockCampaignToken miner;
    MinerBurner burner;
    MockMiningTotals mining;
    MockClaimDeadline claimVault;
    B20CommunityVault vault;
    uint256 miningEnd;

    function setUp() public {
        vm.warp(1_800_000_000);
        miner = new MockCampaignToken();
        burner = new MinerBurner(address(miner));
        mining = new MockMiningTotals();
        claimVault = new MockClaimDeadline(mining);
        vault = new B20CommunityVault(address(miner), address(mining), address(claimVault), address(burner), MANAGER);
        miner.mint(address(vault), RESERVE);
        miningEnd = block.timestamp + 15 days;
    }

    function _settleWith(uint256 baseMined) internal {
        mining.set(miningEnd, baseMined);
        vm.warp(miningEnd);
        vault.settle();
    }

    // ---------------------------------------------------------- construction

    function test_constructorChecks() public {
        vm.expectRevert(B20CommunityVault.ZeroAddress.selector);
        new B20CommunityVault(address(miner), address(mining), address(claimVault), address(burner), address(0));
        WrongCapMining bad = new WrongCapMining();
        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.BaseQuotaCapMismatch.selector, 1, BASE_CAP));
        new B20CommunityVault(address(miner), address(bad), address(claimVault), address(burner), MANAGER);
        MinerBurner otherBurner = new MinerBurner(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(B20CommunityVault.BurnerTokenMismatch.selector, address(0xDEAD), address(miner))
        );
        new B20CommunityVault(address(miner), address(mining), address(claimVault), address(otherBurner), MANAGER);
    }

    // ------------------------------------------------------------ settlement

    function test_settleOnlyAfterMiningEndsAndOnce() public {
        vm.expectRevert(); // mining not opened: MINING_END reverts
        vault.settle();
        mining.set(miningEnd, 0);
        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.MiningNotEnded.selector, miningEnd));
        vault.settle();
        vm.warp(miningEnd);
        vault.settle();
        vm.expectRevert(B20CommunityVault.AlreadySettled.selector);
        vault.settle();
    }

    function test_settleNeedsTheFullReserve() public {
        B20CommunityVault empty =
            new B20CommunityVault(address(miner), address(mining), address(claimVault), address(burner), MANAGER);
        mining.set(miningEnd, 0);
        vm.warp(miningEnd);
        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.NotFunded.selector, 0));
        empty.settle();
    }

    /// The decided table: 1B floor, then 8B × share of the 60B snapshot mined.
    function test_scalingTable() public pure {
        uint256[6] memory mined = [uint256(0), 3e27, 6e27, 15e27, 30e27, 60e27]; // 0, 5%, 10%, 25%, 50%, 100%
        uint256[6] memory kept = [FLOOR, FLOOR, FLOOR, 2e27, 4e27, 8e27];
        for (uint256 i; i < 6; i++) {
            assertEq(_keptFor(mined[i]), kept[i]);
        }
    }

    function _keptFor(uint256 baseMined) internal pure returns (uint256) {
        uint256 scaled = RESERVE * baseMined / BASE_CAP;
        return scaled < FLOOR ? FLOOR : scaled;
    }

    function test_settleAtTenPercentKeepsTheFloorAndBurnsTheRest() public {
        _settleWith(6_000_000_000e18); // 10% of the snapshot: 0.8B < 1B floor
        assertTrue(vault.settled());
        assertEq(vault.keptTotal(), FLOOR);
        assertEq(vault.stakingPot(), 375_000_000e18);
        assertEq(vault.airdropPot(), 625_000_000e18);
        assertEq(vault.airdropUnallocated(), 625_000_000e18);
        assertEq(miner.balanceOf(address(vault)), FLOOR);
        assertEq(miner.totalSupply(), FLOOR); // 7B really burned
        assertEq(burner.totalBurned(), 7_000_000_000e18);
        assertEq(vault.rewardsStart(), miningEnd + 15 days);
    }

    function test_settleAtFullParticipationBurnsNothing() public {
        _settleWith(BASE_CAP);
        assertEq(vault.keptTotal(), RESERVE);
        assertEq(vault.stakingPot(), 3_000_000_000e18);
        assertEq(vault.airdropPot(), 5_000_000_000e18);
        assertEq(burner.totalBurned(), 0);
    }

    function testFuzz_settleSplitsExactly(uint256 baseMined) public {
        baseMined = bound(baseMined, 0, BASE_CAP);
        _settleWith(baseMined);
        uint256 kept = vault.keptTotal();
        assertEq(kept, _keptFor(baseMined));
        assertEq(vault.keptFor(baseMined), kept);
        assertEq(vault.stakingPot() + vault.airdropPot(), kept);
        assertEq(vault.stakingPot(), kept * 3 / 8);
        assertEq(miner.balanceOf(address(vault)), kept);
        assertEq(miner.totalSupply(), kept);
    }

    // --------------------------------------------------------- staking stream

    function _setStaking() internal {
        vm.prank(MANAGER);
        vault.queueStakingRecipient(STAKING);
        vm.warp(block.timestamp + 48 hours);
        vault.confirmStakingRecipient();
    }

    function test_stakingStreamsFiveYearsFromTheClaimDeadline() public {
        _settleWith(BASE_CAP); // staking pot 3B
        uint256 pot = vault.stakingPot();
        uint256 start = vault.rewardsStart();
        assertEq(vault.stakingVestedAt(start), 0);
        assertEq(vault.stakingVestedAt(start + 182.5 days), pot * 1_500 / 10_000); // half of year 1 (30%)
        assertEq(vault.stakingVestedAt(start + 365 days), pot * 3_000 / 10_000);
        assertEq(vault.stakingVestedAt(start + 2 * 365 days), pot * 5_500 / 10_000);
        assertEq(vault.stakingVestedAt(start + 3 * 365 days), pot * 7_500 / 10_000);
        assertEq(vault.stakingVestedAt(start + 4 * 365 days), pot * 9_000 / 10_000);
        assertEq(vault.stakingVestedAt(start + 5 * 365 days), pot);
        assertEq(vault.stakingVestedAt(start + 9 * 365 days), pot);
    }

    function testFuzz_stakingStreamIsMonotonicAndCapped(uint256 a, uint256 b) public {
        _settleWith(30_000_000_000e18);
        uint256 start = vault.rewardsStart();
        a = bound(a, start, start + 7 * 365 days);
        b = bound(b, a, start + 7 * 365 days);
        assertLe(vault.stakingVestedAt(a), vault.stakingVestedAt(b));
        assertLe(vault.stakingVestedAt(b), vault.stakingPot());
    }

    function test_onlyTheStakingContractPullsWhatStreamed() public {
        _settleWith(BASE_CAP);
        vm.expectRevert(B20CommunityVault.NotStakingRecipient.selector);
        vault.releaseStaking();
        _setStaking();
        vm.warp(vault.rewardsStart() + 365 days);
        vm.prank(STAKING);
        uint256 got = vault.releaseStaking();
        assertEq(got, vault.stakingPot() * 3_000 / 10_000);
        assertEq(miner.balanceOf(STAKING), got);
        vm.prank(STAKING);
        assertEq(vault.releaseStaking(), 0); // nothing new in the same second
        vm.prank(ALICE);
        vm.expectRevert(B20CommunityVault.NotStakingRecipient.selector);
        vault.releaseStaking();
    }

    function test_stakingRecipientTimelockAndFinality() public {
        vm.prank(ALICE);
        vm.expectRevert(B20CommunityVault.NotManager.selector);
        vault.queueStakingRecipient(STAKING);

        vm.prank(MANAGER);
        vault.queueStakingRecipient(STAKING);
        vm.expectRevert(
            abi.encodeWithSelector(B20CommunityVault.TimelockActive.selector, block.timestamp + 48 hours)
        );
        vault.confirmStakingRecipient();
        vm.prank(MANAGER);
        vault.cancelStakingRecipient();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(B20CommunityVault.NoPendingStakingRecipient.selector);
        vault.confirmStakingRecipient();

        _setStaking();
        assertEq(vault.stakingRecipient(), STAKING);
        vm.prank(MANAGER);
        vm.expectRevert(B20CommunityVault.StakingRecipientAlreadySet.selector);
        vault.queueStakingRecipient(ALICE);
    }

    // ---------------------------------------------------------- airdrop rounds

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _root(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_roundRulesEndToEnd() public {
        _settleWith(BASE_CAP); // airdrop share 5B, a round at most 2.5B
        uint256 half = vault.maxRoundAmount();
        assertEq(half, 2_500_000_000e18);

        bytes32 la = _leaf(ALICE, 1_000e18);
        bytes32 lb = _leaf(BOB, 2_000e18);
        bytes32 root = _root(la, lb);
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = lb;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = la;

        vm.prank(ALICE);
        vm.expectRevert(B20CommunityVault.NotManager.selector);
        vault.queueRound(root, 3_000e18);
        vm.startPrank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.RoundTooLarge.selector, half + 1, half));
        vault.queueRound(root, half + 1);
        uint256 id = vault.queueRound(root, 3_000e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.TimelockActive.selector, block.timestamp + 48 hours));
        vault.startRound(id);
        vm.expectRevert(B20CommunityVault.RoundNotOpen.selector);
        vault.claim(id, ALICE, 1_000e18, proofA);

        vm.warp(block.timestamp + 48 hours);
        vault.startRound(id);
        assertEq(vault.airdropUnallocated(), 5_000_000_000e18 - 3_000e18);

        vault.claim(id, ALICE, 1_000e18, proofA); // anyone may submit; tokens go to ALICE
        assertEq(miner.balanceOf(ALICE), 1_000e18);
        vm.expectRevert(B20CommunityVault.AlreadyClaimed.selector);
        vault.claim(id, ALICE, 1_000e18, proofA);
        vm.expectRevert(B20CommunityVault.BadProof.selector);
        vault.claim(id, BOB, 2_001e18, proofB);

        // a second round waits 30 days after the first one started
        vm.prank(MANAGER);
        uint256 id2 = vault.queueRound(keccak256("next"), 1e18);
        vm.warp(block.timestamp + 48 hours);
        uint256 started = vault.round(id).startedAt;
        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.RoundIntervalActive.selector, started + 30 days));
        vault.startRound(id2);

        // after 90 days: BOB missed it, his 2,000 returns to the share
        vm.warp(started + 90 days);
        vm.expectRevert(B20CommunityVault.RoundNotOpen.selector);
        vault.claim(id, BOB, 2_000e18, proofB);
        vault.closeRound(id);
        assertEq(vault.airdropUnallocated(), 5_000_000_000e18 - 1_000e18);
        vm.expectRevert(B20CommunityVault.RoundNotOpen.selector);
        vault.closeRound(id);
        vault.startRound(id2); // more than 30 days later now
    }

    function test_roundBudgetCapsClaimsEvenIfTheListIsLarger() public {
        _settleWith(BASE_CAP);
        bytes32 la = _leaf(ALICE, 1_000e18);
        bytes32 lb = _leaf(BOB, 2_000e18);
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = lb;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = la;
        vm.prank(MANAGER);
        uint256 id = vault.queueRound(_root(la, lb), 2_500e18); // less than the list's 3,000
        vm.warp(block.timestamp + 48 hours);
        vault.startRound(id);
        vault.claim(id, BOB, 2_000e18, proofB);
        vm.expectRevert(B20CommunityVault.RoundBudgetExceeded.selector);
        vault.claim(id, ALICE, 1_000e18, proofA);
    }

    function test_cancelledRoundCannotStart() public {
        _settleWith(BASE_CAP);
        vm.prank(MANAGER);
        uint256 id = vault.queueRound(keccak256("r"), 1e18);
        vm.prank(MANAGER);
        vault.cancelRound(id);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(B20CommunityVault.RoundNotStartable.selector);
        vault.startRound(id);
    }

    function test_noRoundsBeforeSettlement() public {
        vm.prank(MANAGER);
        vm.expectRevert(B20CommunityVault.NotSettled.selector);
        vault.queueRound(keccak256("r"), 1e18);
    }

    function test_roundsCannotExceedTheShare() public {
        _settleWith(0); // floor: airdrop share 625M, a round at most 312.5M
        uint256 max = vault.maxRoundAmount();
        vm.startPrank(MANAGER);
        vault.queueRound(keccak256("a"), max);
        vault.queueRound(keccak256("b"), max);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vault.startRound(0);
        vm.warp(block.timestamp + 30 days);
        vault.startRound(1);
        assertEq(vault.airdropUnallocated(), 0);
        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(B20CommunityVault.InsufficientAirdrop.selector, 1, 0));
        vault.queueRound(keccak256("c"), 1);
    }
}
