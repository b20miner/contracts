// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Verifies a wallet's B20MINER Snapshot V1 base mining quota
/// against the frozen, off-chain-computed Merkle root.
///
/// This is a pure verification primitive only. It has no claim tracking,
/// no proof-usage bookkeeping, no ownership/binding logic and no admin
/// controls — those belong to a future claim/mining contract, not here.
///
/// The leaf format, domain separator and sorted-pair tree algorithm must
/// match scripts/merkle_common.py exactly; see docs/MERKLE_SNAPSHOT_V1.md.
library B20SnapshotMerkle {
    bytes32 internal constant MERKLE_ROOT = 0xa5ebaa9d888946e87b9926ce7ed11e88169a7c9885c55d582f97de045f432e20;

    bytes32 internal constant DOMAIN_SEPARATOR = 0x964fcc7123be7cca1178379e4a8b5b7a87dfea508e50baedb7a6c08c39e96552;

    uint256 internal constant SNAPSHOT_CHAIN_ID = 8453;
    uint256 internal constant SNAPSHOT_BLOCK = 51310062;

    /// @dev Leaf preimage is exactly (bytes32,uint256,uint256,address,uint256)
    /// ABI-encoded, matching scripts/merkle_common.py's encode_leaf_preimage.
    /// `baseQuotaB20` is whole $MINER tokens, never multiplied by 10**decimals.
    function leafFor(address snapshotWallet, uint256 baseQuotaB20) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR, SNAPSHOT_CHAIN_ID, SNAPSHOT_BLOCK, snapshotWallet, baseQuotaB20));
    }

    /// @notice Returns true iff `proof` proves that `snapshotWallet` was
    /// allocated `baseQuotaB20` whole $MINER tokens in Snapshot V1.
    function verify(address snapshotWallet, uint256 baseQuotaB20, bytes32[] calldata proof)
        internal
        pure
        returns (bool)
    {
        bytes32 leaf = leafFor(snapshotWallet, baseQuotaB20);
        return MerkleProof.verifyCalldata(proof, MERKLE_ROOT, leaf);
    }
}
