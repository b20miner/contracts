// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {MockCampaignToken} from "./MiningCampaign.t.sol";

/// @dev Stands in for a B20 token after Denim: it refuses `refused` (and
/// itself) as a receiver with `InvalidReceiver`, fails `broken` with another
/// error and `silent` with no data (as running out of gas does).
contract DenimToken is MockCampaignToken {
    error InvalidReceiver(address receiver);

    address public refused;
    address public broken;
    address public silent;

    function set(address refused_, address broken_, address silent_) external {
        (refused, broken, silent) = (refused_, broken_, silent_);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (to == refused || to == address(this)) revert InvalidReceiver(to);
            if (to == broken) revert("broken");
            if (to == silent) {
                assembly ("memory-safe") {
                    revert(0, 0)
                }
            }
        }
        super._update(from, to, value);
    }
}

/// Denim (Base Sepolia 21 Oct, mainnet 5 Nov 2026; ROADMAP 3.312): a B20
/// token refuses its own address as a receiver, so an owner the token
/// refuses must neither enter the owner list nor stop the opening.
contract MiningCampaignDenimTest is Test {
    uint256 constant EASY = type(uint256).max;
    uint256 constant PROOF_FEE = 0.001 ether;
    address constant MINER = address(0xA11CE);
    address constant TREASURY = address(0x7EA5);
    address constant A = address(0x1001);
    address constant B = address(0x1002);
    address constant REFUSED = address(0xBAD);

    MiningCampaign impl;
    DenimToken token;

    receive() external payable {} // this test contract plays the CampaignPool

    function setUp() public {
        vm.warp(1_800_000_000);
        impl = new MiningCampaign();
        token = new DenimToken();
        vm.deal(MINER, 1_000 ether);
    }

    function _campaign() internal returns (MiningCampaign c) {
        MiningCampaign.InitParams memory p;
        p.token = address(token);
        p.pool = address(this);
        p.platformTreasury = TREASURY;
        p.powTarget = EASY;
        p.proofFee = PROOF_FEE;
        p.supplyWhole = 1_000_000_000;
        p.miningReserve = p.supplyWhole * 1e18 * 2 / 3;
        p.start = uint64(block.timestamp + 1 hours);
        p.durationDays = 7;
        p.walletCapWei = 1 ether;
        c = MiningCampaign(payable(Clones.clone(address(impl))));
        c.initialize(p);
        vm.warp(c.start());
        c.open();
    }

    function _mine(MiningCampaign c, address owner) internal {
        (, uint256 fee) = c.quoteProof(owner);
        bytes32 challenge = c.challengeOf(owner);
        vm.prank(MINER);
        c.submitProof{value: fee}(owner, challenge, 7);
    }

    function test_theTokenItselfCannotBeAnOwner() public {
        MiningCampaign c = _campaign();
        bytes32 ch = c.challengeOf(address(token));
        vm.prank(MINER);
        vm.expectRevert(MiningCampaign.TokenOwner.selector);
        c.submitProof{value: PROOF_FEE}(address(token), ch, 7);

        uint256[16] memory nonces;
        for (uint256 i; i < 16; ++i) {
            nonces[i] = i + 1;
        }
        vm.prank(MINER);
        vm.expectRevert(MiningCampaign.TokenOwner.selector);
        c.submitShares{value: PROOF_FEE}(address(token), ch, nonces);
        assertEq(c.ownerCount(), 0);
    }

    function test_distributeMovesPastARefusedOwnerAndTheRestBurns() public {
        MiningCampaign c = _campaign();
        token.set(REFUSED, address(0), address(0));
        _mine(c, A);
        _mine(c, REFUSED);
        _mine(c, B);
        uint256 reward = c.rewardPerProof();
        vm.warp(c.end());
        c.settle(false);

        vm.expectEmit(true, false, false, true, address(c));
        emit MiningCampaign.DeliveryRefused(REFUSED, reward);
        assertEq(c.distribute(10), 3);
        assertTrue(c.distributionDone(), "the opening is not blocked");
        assertEq(token.balanceOf(A), reward);
        assertEq(token.balanceOf(B), reward);
        assertEq(token.balanceOf(REFUSED), 0);
        assertEq(c.claimedOf(REFUSED), 0, "nothing counted as claimed");
        assertEq(c.claimable(REFUSED), reward);
        assertEq(token.balanceOf(address(c)), reward);

        // the refused share is burned with the unclaimed rest after the deadline
        vm.warp(c.claimDeadline() + 1);
        c.burnUnclaimed();
        assertEq(token.balanceOf(address(c)), 0);
    }

    function test_anyOtherFailureStillReverts() public {
        MiningCampaign c = _campaign();
        token.set(address(0), B, address(0));
        _mine(c, A);
        _mine(c, B);
        vm.warp(c.end());
        c.settle(false);
        vm.expectRevert(bytes("broken"));
        c.distribute(10);
        assertEq(c.distributedCount(), 0);
    }

    /// A failure without data (what running out of gas looks like) is not a
    /// refusal: the caller's gas cannot make an owner be skipped.
    function test_aFailureWithoutDataReverts() public {
        MiningCampaign c = _campaign();
        token.set(address(0), address(0), B);
        _mine(c, A);
        _mine(c, B);
        vm.warp(c.end());
        c.settle(false);
        vm.expectRevert();
        c.distribute(10);
        assertEq(c.distributedCount(), 0);
        assertEq(c.claimedOf(A), 0);
    }

    function test_tooLittleGasRevertsInsteadOfSkipping() public {
        MiningCampaign c = _campaign();
        for (uint256 i = 1; i <= 5; i++) {
            _mine(c, address(uint160(0x2000 + i)));
        }
        vm.warp(c.end());
        c.settle(false);
        // try every gas budget around a single transfer's cost: either the call
        // reverts or every owner it served got their tokens
        for (uint256 g = 60_000; g < 260_000; g += 7_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(c).call{gas: g}(abi.encodeCall(MiningCampaign.distribute, (5)));
            if (ok) {
                for (uint256 i = 0; i < c.distributedCount(); i++) {
                    address o = c.ownerAt(i);
                    assertEq(token.balanceOf(o), c.claimedOf(o), "served means paid");
                    assertGt(token.balanceOf(o), 0, "nobody skipped");
                }
            }
            vm.revertToState(snap);
        }
    }
}
