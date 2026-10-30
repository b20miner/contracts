// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {B20PoW} from "../src/B20PoW.sol";

/// @notice Minimal external wrapper around B20PoW's internal library
/// functions, so the test contract below can call them like any other
/// contract would (B20PoW itself has no state, constructor or storage).
contract B20PoWHarness {
    function computeHash(
        uint256 chainId,
        address miningContract,
        address snapshotWallet,
        address miningWallet,
        bytes32 challenge,
        uint256 nonce
    ) external pure returns (bytes32) {
        return B20PoW.computeHash(chainId, miningContract, snapshotWallet, miningWallet, challenge, nonce);
    }

    function isValid(
        uint256 chainId,
        address miningContract,
        address snapshotWallet,
        address miningWallet,
        bytes32 challenge,
        uint256 nonce,
        uint256 target
    ) external pure returns (bool) {
        return B20PoW.isValid(chainId, miningContract, snapshotWallet, miningWallet, challenge, nonce, target);
    }
}

/// @notice Critical targeted tests for B20PoW only. Not fuzz/invariant.
contract B20PoWTest is Test {
    B20PoWHarness internal harness;

    // Canonical vector, independently derived via Python/pycryptodome
    // Keccak-256 before this library existed (see
    // pow-reference/vectors/pow-v1.json — the JS reference module must
    // reproduce the same hashes).
    uint256 internal constant CHAIN_ID = 8453;
    address internal constant MINING_CONTRACT = 0x1111111111111111111111111111111111111111;
    address internal constant SNAPSHOT_WALLET = 0x2222222222222222222222222222222222222222;
    address internal constant MINING_WALLET = 0x3333333333333333333333333333333333333333;
    bytes32 internal constant CHALLENGE = 0x4444444444444444444444444444444444444444444444444444444444444444;
    uint256 internal constant NONCE = 123456789;
    bytes32 internal constant EXPECTED_HASH = 0x14467ce4d90f928a400417a20fa4f10789915962352157f13955b8cd1442a41b;

    uint256 internal constant MAX_NONCE = type(uint256).max;
    bytes32 internal constant EXPECTED_MAX_NONCE_HASH =
        0x28c958f8e6d124fcc5f2b39b05e056ba013a969ec20188c4dc8ad10d56c28a6e;

    function setUp() public {
        harness = new B20PoWHarness();
    }

    /// 1. Canonical vector hash matches the expected constant exactly.
    function test_computeHash_matchesCanonicalVector() public view {
        bytes32 hash = harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE);
        assertEq(hash, EXPECTED_HASH);
    }

    /// 2. target == uint256(hash) accepts the proof.
    function test_isValid_acceptsWhenTargetEqualsHash() public view {
        bool valid = harness.isValid(
            CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE, uint256(EXPECTED_HASH)
        );
        assertTrue(valid);
    }

    /// 3. target == uint256(hash) - 1 rejects the proof.
    function test_isValid_rejectsWhenTargetOneBelowHash() public view {
        bool valid = harness.isValid(
            CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE, uint256(EXPECTED_HASH) - 1
        );
        assertFalse(valid);
    }

    /// 4. type(uint256).max target accepts any normal hash.
    function test_isValid_acceptsAnyHashAtMaxTarget() public view {
        bool valid = harness.isValid(
            CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE, type(uint256).max
        );
        assertTrue(valid);
    }

    /// 5. Changing any one field changes the hash.
    function test_computeHash_changesWhenAnyFieldChanges() public view {
        bytes32 base = harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE);

        assertTrue(
            base != harness.computeHash(CHAIN_ID + 1, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE)
        );
        assertTrue(
            base
                != harness.computeHash(
                    CHAIN_ID, address(uint160(MINING_CONTRACT) + 1), SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE
                )
        );
        assertTrue(
            base
                != harness.computeHash(
                    CHAIN_ID, MINING_CONTRACT, address(uint160(SNAPSHOT_WALLET) + 1), MINING_WALLET, CHALLENGE, NONCE
                )
        );
        assertTrue(
            base
                != harness.computeHash(
                    CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, address(uint160(MINING_WALLET) + 1), CHALLENGE, NONCE
                )
        );
        assertTrue(
            base
                != harness.computeHash(
                    CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, bytes32(uint256(CHALLENGE) ^ 1), NONCE
                )
        );
        assertTrue(
            base != harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE + 1)
        );
    }

    /// 6. Same inputs produce the same hash on every call.
    function test_computeHash_isDeterministic() public view {
        bytes32 first = harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE);
        bytes32 second =
            harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE);
        assertEq(first, second);
    }

    /// 7. A large (type(uint256).max) nonce encodes correctly, matching an
    /// independently-derived expected hash.
    function test_computeHash_largeNonceMatchesExpectedVector() public view {
        bytes32 hash =
            harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, MAX_NONCE);
        assertEq(hash, EXPECTED_MAX_NONCE_HASH);
    }

    /// 8. The canonical vector test (#1) is itself the guard against field
    /// reordering: swapping the packed field order would change the
    /// preimage bytes and therefore the resulting hash, so a passing #1
    /// pins the exact field order as well as the values.
    function test_canonicalVector_pinsFieldOrder() public view {
        // Sanity: reversing chainId and nonce's positions in a manual
        // preimage would not reproduce EXPECTED_HASH unless the library's
        // field order matches B20_POW_V1 exactly. We re-assert #1 here
        // under a name that documents *why* it matters.
        bytes32 hash = harness.computeHash(CHAIN_ID, MINING_CONTRACT, SNAPSHOT_WALLET, MINING_WALLET, CHALLENGE, NONCE);
        assertEq(hash, EXPECTED_HASH);
    }
}
