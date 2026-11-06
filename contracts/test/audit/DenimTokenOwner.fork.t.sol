// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignPool} from "../../src/launchpad/CampaignPool.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {LaunchpadFactoryForkTest} from "../launchpad/LaunchpadFactory.fork.t.sol";

/// Denim readiness (6 Nov 2026, ROADMAP 3.312): since Denim a B20 token
/// refuses a transfer to its own address (`InvalidReceiver`). Before the fix
/// `submitProof` accepted `owner = token`, and `finalize` then reverted at
/// that owner forever (`InvalidReceiver(token)`, seen on this fork). Runs on
/// a Base Sepolia fork with the native B20 precompile (base-forge v1.5.1).
contract DenimTokenOwnerForkTest is LaunchpadFactoryForkTest {
    function _proof(MiningCampaign c, address owner, uint256 nonce) internal {
        (, uint256 fee) = c.quoteProof(owner);
        bytes32 challenge = c.challengeOf(owner);
        vm.prank(MINER_WALLET);
        c.submitProof{value: fee}(owner, challenge, nonce);
    }

    function test_denim_tokenRefusesItselfAsReceiver() public {
        address token = _create(_params(), CREATION_FEE);
        (MiningCampaign c,) = _parts(token);
        _proof(c, OWNER, 0);
        vm.prank(address(c));
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (token, 1)));
        assertFalse(ok, "Denim: the token refuses its own address");
        assertEq(bytes4(ret), bytes4(0x9cfea583), "InvalidReceiver(address)");
    }

    function test_denim_tokenCannotBeAnOwnerAndTheOpeningCompletes() public {
        address token = _create(_params(), CREATION_FEE);
        (MiningCampaign c, CampaignPool pool) = _parts(token);
        for (uint256 i = 0; i < 3; i++) {
            _proof(c, OWNER, i);
        }
        (, uint256 fee) = c.quoteProof(OWNER);
        bytes32 challenge = c.challengeOf(token);
        vm.prank(MINER_WALLET);
        vm.expectRevert(MiningCampaign.TokenOwner.selector);
        c.submitProof{value: fee}(token, challenge, 0);

        vm.warp(c.end());
        pool.finalize();
        assertTrue(c.distributionDone());
        assertEq(IERC20(token).balanceOf(OWNER), c.minedTotal());
    }
}
