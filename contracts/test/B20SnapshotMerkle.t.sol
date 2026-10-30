// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {B20SnapshotMerkle} from "../src/B20SnapshotMerkle.sol";

/// @notice Proves that the Python-generated Snapshot V1 Merkle leaves and
/// proofs verify correctly against OpenZeppelin's MerkleProof in Solidity,
/// using five real records pulled from the production artifacts.
///
/// This test file only proves Python <-> Solidity leaf/proof compatibility.
/// It does not exercise or imply any claim, mining, NFT, fee or wallet
/// binding contract — none of that exists here.
contract B20SnapshotMerkleTest is Test {
    uint256 internal constant FIXTURE_COUNT = 5;

    string internal fixturesJson;

    struct Fixture {
        address wallet;
        uint256 allocation;
        bytes32 leaf;
        uint256 leafIndex;
        bytes32[] proof;
    }

    function setUp() public {
        fixturesJson = vm.readFile("test/fixtures/snapshot-v1-proofs.json");
    }

    /// @dev `B20SnapshotMerkle.verify` takes `bytes32[] calldata` by design
    /// (matching the spec exactly). Fixtures are loaded into memory via JSON
    /// cheatcodes, so this external wrapper re-encodes them as calldata —
    /// it adds no logic of its own, purely a call-context bridge for tests.
    function _verifyExternal(address wallet, uint256 allocation, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        return B20SnapshotMerkle.verify(wallet, allocation, proof);
    }

    function _loadFixture(uint256 i) internal view returns (Fixture memory f) {
        string memory base = string.concat(".[", vm.toString(i), "]");
        f.wallet = vm.parseJsonAddress(fixturesJson, string.concat(base, ".wallet"));
        f.allocation = vm.parseJsonUint(fixturesJson, string.concat(base, ".allocation_b20"));
        f.leaf = vm.parseJsonBytes32(fixturesJson, string.concat(base, ".leaf"));
        f.leafIndex = vm.parseJsonUint(fixturesJson, string.concat(base, ".leaf_index"));
        f.proof = vm.parseJsonBytes32Array(fixturesJson, string.concat(base, ".proof"));
    }

    /// 1. Solidity-computed domain separator matches the hardcoded constant.
    function test_domainSeparator_matchesComputedValue() public pure {
        bytes32 computed = keccak256(bytes("B20_SNAPSHOT_V1"));
        assertEq(computed, B20SnapshotMerkle.DOMAIN_SEPARATOR);
        assertEq(B20SnapshotMerkle.DOMAIN_SEPARATOR, 0x964fcc7123be7cca1178379e4a8b5b7a87dfea508e50baedb7a6c08c39e96552);
    }

    /// 2. leafFor() reproduces the Python-computed leaf for all 5 real fixtures.
    function test_leafFor_matchesPythonLeaf_forAllFixtures() public view {
        for (uint256 i = 0; i < FIXTURE_COUNT; i++) {
            Fixture memory f = _loadFixture(i);
            bytes32 computed = B20SnapshotMerkle.leafFor(f.wallet, f.allocation);
            assertEq(computed, f.leaf, "leaf mismatch");
        }
    }

    /// 3. All 5 real proofs verify against the production root.
    function test_verify_acceptsAllFixtures_againstProductionRoot() public view {
        for (uint256 i = 0; i < FIXTURE_COUNT; i++) {
            Fixture memory f = _loadFixture(i);
            assertTrue(this._verifyExternal(f.wallet, f.allocation, f.proof), "valid proof rejected");
        }
        assertEq(B20SnapshotMerkle.MERKLE_ROOT, 0xa5ebaa9d888946e87b9926ce7ed11e88169a7c9885c55d582f97de045f432e20);
    }

    /// 4. The last leaf's proof (shorter than the others, because leaf_index
    /// 999346 is repeatedly promoted unchanged through several odd-node
    /// levels) is explicitly accepted.
    function test_verify_acceptsLastLeaf_oddNodePromotionPath() public view {
        Fixture memory last = _loadFixture(1); // fixtures[1] == "last_leaf"
        assertEq(last.leafIndex, 999346);
        assertTrue(this._verifyExternal(last.wallet, last.allocation, last.proof));
    }

    /// 5. Flipping a single bit of the wallet address is rejected.
    function test_verify_rejectsTamperedWallet() public view {
        Fixture memory f = _loadFixture(0);
        address tamperedWallet = address(uint160(f.wallet) ^ uint160(1));
        assertFalse(this._verifyExternal(tamperedWallet, f.allocation, f.proof));
    }

    /// 6. Incrementing the allocation by 1 is rejected.
    function test_verify_rejectsTamperedAllocation() public view {
        Fixture memory f = _loadFixture(0);
        assertFalse(this._verifyExternal(f.wallet, f.allocation + 1, f.proof));
    }

    /// 7. Flipping a bit inside one proof element is rejected.
    function test_verify_rejectsTamperedProofHash() public view {
        Fixture memory f = _loadFixture(0);
        bytes32[] memory tamperedProof = f.proof;
        tamperedProof[0] = tamperedProof[0] ^ bytes32(uint256(1));
        assertFalse(this._verifyExternal(f.wallet, f.allocation, tamperedProof));
    }

    /// 8. An empty proof is rejected for a real, non-single-leaf fixture.
    function test_verify_rejectsEmptyProof_forRealMultiLeafFixture() public view {
        Fixture memory f = _loadFixture(0);
        assertTrue(f.proof.length > 0);
        bytes32[] memory emptyProof = new bytes32[](0);
        assertFalse(this._verifyExternal(f.wallet, f.allocation, emptyProof));
    }
}
