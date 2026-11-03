// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Internal audit (2 Nov 2026): which receivers does the real B20 precompile
/// refuse? `MiningCampaign.distribute` sends to every owner in one loop, so a
/// receiver the token refuses would stop distribution (and the pool's opening)
/// for good. Runs against live Base Sepolia (base-forge, real precompile).
contract B20ReceiversForkTest is Test {
    // 3 Nov 2026: the v17 MINETEST holder sold out, so the sender is now the
    // live Sepolia genesis's claim vault, holding MINER (deployer v15).
    IToken constant TOKEN = IToken(0xb200000000000000000000f05e939E87Fc68e8e5); // MINER (3 Nov 2026 genesis)
    address constant HOLDER = 0x34018C4b59903946746d5FdDA4443826957d5bC9; // its B20ClaimVault
    address constant CAMPAIGN = 0x15C908c3A5C38e8Ba3aE595EaC1A2A0782Ff6C4A;
    address constant MINER = 0xb200000000000000000000c9FEC3181Ce714dEa9; // a retired MINER

    function setUp() public {
        vm.createSelectFork("https://sepolia.base.org");
    }

    function _try(address to) internal returns (bool ok) {
        vm.prank(HOLDER);
        (ok,) = address(TOKEN).call(abi.encodeCall(IToken.transfer, (to, 1)));
    }

    function test_receivers() public {
        assertGt(TOKEN.balanceOf(HOLDER), 10);
        // Only address(0) fails (checked live 2 Nov 2026), so no owner can stop distribute.
        assertTrue(_try(HOLDER), "self");
        assertTrue(_try(address(TOKEN)), "token itself");
        assertTrue(_try(MINER), "another B20 (MINER)");
        assertTrue(_try(0xB20f000000000000000000000000000000000000), "B20 factory precompile");
        assertTrue(_try(CAMPAIGN), "campaign");
        assertTrue(_try(address(1)), "ecrecover precompile 0x01");
        assertTrue(_try(address(0xdead)), "0xdead");
        assertTrue(_try(0xb200000000000000000000000000000000000001), "unused B20 prefix address");
        assertFalse(_try(address(0)), "zero is refused (MiningCampaign rejects a zero owner)");
    }
}
