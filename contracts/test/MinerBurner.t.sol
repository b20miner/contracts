// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "base-std-test/lib/BaseTest.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {MinerBurner} from "../src/MinerBurner.sol";

/// @notice The burner against base-std's reference B20 factory: with
/// `BURN_ROLE` granted at creation it really lowers `totalSupply`; without
/// it, it cannot burn at all; and it only ever burns its own balance.
contract MinerBurnerTest is BaseTest {
    bytes32 constant SALT = keccak256("burner-test");
    uint256 constant SUPPLY = 1_000_000e18;

    IB20Asset token;
    MinerBurner burner;

    function _create(bool grantBurn) internal {
        address predicted = StdPrecompiles.B20_FACTORY.getB20Address(IB20Factory.B20Variant.ASSET, address(this), SALT);
        burner = new MinerBurner(predicted);
        address[] memory to = new address[](2);
        to[0] = address(this);
        to[1] = alice;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SUPPLY / 2;
        amounts[1] = SUPPLY / 2;
        bytes[] memory calls = new bytes[](grantBurn ? 3 : 2);
        calls[0] = B20FactoryLib.encodeUpdateSupplyCap(SUPPLY);
        calls[1] = B20FactoryLib.encodeBatchMint(to, amounts);
        if (grantBurn) calls[2] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, address(burner));
        token = IB20Asset(
            StdPrecompiles.B20_FACTORY.createB20(
                IB20Factory.B20Variant.ASSET,
                SALT,
                B20FactoryLib.encodeAssetCreateParams("MINER", "MINER", address(0), 18),
                calls
            )
        );
        assertEq(address(token), predicted);
    }

    function test_plainTransfersAreBurnedByAnyone() public {
        _create(true);
        token.transfer(address(burner), 1_000e18);
        vm.prank(bob); // anyone
        assertEq(burner.burn(), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY - 1_000e18);
        assertEq(token.balanceOf(address(burner)), 0);
        assertEq(burner.burn(), 0); // empty: no-op
        assertEq(burner.totalBurned(), 1_000e18);

        // MINER waits here until the next burn(), then all of it goes
        token.transfer(address(burner), 5e18);
        token.transfer(address(burner), 7e18);
        assertEq(token.totalSupply(), SUPPLY - 1_000e18);
        assertEq(burner.burn(), 12e18);
        assertEq(token.totalSupply(), SUPPLY - 1_012e18);
    }

    function test_onlyItsOwnBalance() public {
        _create(true);
        uint256 aliceBefore = token.balanceOf(alice);
        token.transfer(address(burner), 1e18);
        burner.burn();
        assertEq(token.balanceOf(alice), aliceBefore); // nobody else's tokens are touched
    }

    function test_withoutTheRoleNothingCanBeBurned() public {
        _create(false);
        token.transfer(address(burner), 1e18);
        vm.expectRevert();
        burner.burn();
        assertEq(token.totalSupply(), SUPPLY);
    }
}
