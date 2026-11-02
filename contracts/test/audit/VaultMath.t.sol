// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {B20CommunityVault} from "../../src/B20CommunityVault.sol";
import {B20TeamVesting} from "../../src/B20TeamVesting.sol";
import {MinerBurner} from "../../src/MinerBurner.sol";
import {MockCampaignToken} from "../launchpad/MiningCampaign.t.sol";
import {MockMiningTotals, MockClaimDeadline} from "../B20CommunityVault.t.sol";

/// Internal audit (2 Nov 2026): rounding in the two time-based MINER streams.
/// A stream that ever goes down, or past its pot, would make `releasable()`
/// underflow (stuck funds) or pay more than the vault was given.
contract VaultMathAuditTest is Test {
    uint256 constant RESERVE = 8_000_000_000e18;
    uint256 constant TEAM = 1_000_000_000e18;
    uint256 constant PERIOD = 2_628_000;

    MockCampaignToken miner;
    B20CommunityVault vault;
    uint256 rewardsStart;

    function setUp() public {
        vm.warp(1_800_000_000);
        miner = new MockCampaignToken();
        MinerBurner burner = new MinerBurner(address(miner));
        MockMiningTotals mining = new MockMiningTotals();
        MockClaimDeadline claimVault = new MockClaimDeadline(mining);
        vault = new B20CommunityVault(address(miner), address(mining), address(claimVault), address(burner), address(1));
        miner.mint(address(vault), RESERVE);
        uint256 end = block.timestamp + 15 days;
        mining.set(end, 37_123_456_789e18 + 7); // odd amount so every division rounds
        vm.warp(end);
        vault.settle();
        rewardsStart = vault.rewardsStart();
    }

    /// The staking stream never goes down and never passes the pot, across
    /// every year boundary (year shares 30/25/20/15/10 %).
    function testFuzz_stakingStreamMonotonicAndCapped(uint256 a, uint256 b) public view {
        a = bound(a, 0, 6 * 365 days);
        b = bound(b, a, 6 * 365 days);
        uint256 va = vault.stakingVestedAt(rewardsStart + a);
        uint256 vb = vault.stakingVestedAt(rewardsStart + b);
        assertLe(va, vb, "stream went down");
        assertLe(vb, vault.stakingPot(), "stream passed the pot");
    }

    function test_stakingStreamAtYearEdges() public view {
        uint256 pot = vault.stakingPot();
        for (uint256 y = 1; y <= 5; y++) {
            uint256 t = rewardsStart + y * 365 days;
            assertLe(vault.stakingVestedAt(t - 1), vault.stakingVestedAt(t), "edge");
        }
        assertEq(vault.stakingVestedAt(rewardsStart + 5 * 365 days), pot, "full pot after 5 years");
    }

    /// Staking pot + airdrop pot is exactly what was kept, so the two
    /// streams together can never pay more than the vault holds.
    function test_potsAddUpToKept() public view {
        assertEq(vault.stakingPot() + vault.airdropPot(), vault.keptTotal());
        assertLe(vault.keptTotal(), miner.balanceOf(address(vault)));
    }

    /// Team vesting: nothing before TGE + 13 periods, 1/48 steps after,
    /// never more than 1B, never down.
    function testFuzz_teamVesting(uint256 a, uint256 b) public {
        B20TeamVesting v = new B20TeamVesting(address(miner), address(0xBEEF), 1_800_000_000);
        a = bound(a, 0, 70 * PERIOD);
        b = bound(b, a, 70 * PERIOD);
        uint256 va = v.vestedAmount(1_800_000_000 + a);
        uint256 vb = v.vestedAmount(1_800_000_000 + b);
        assertLe(va, vb);
        assertLe(vb, TEAM);
        if (a < 13 * PERIOD) assertEq(va, 0, "cliff");
        if (b >= 60 * PERIOD) assertEq(vb, TEAM, "fully vested");
    }
}
