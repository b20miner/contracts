// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stateless B20MINER PoW V1 hash and validity primitives.
///
/// This library only computes and checks the domain-separated challenge
/// hash. It holds no state, has no constructor, no owner/admin, and no
/// target setter — the single immutable `POW_TARGET` (calibrated after
/// the Base Sepolia benchmark) will live in the future `B20Mining`
/// contract, not here. Policy concerns such as zero-address checks,
/// challenge issuance and replay protection are also `B20Mining`'s
/// responsibility, not this library's.
library B20PoW {
    /// @notice keccak256(abi.encodePacked("B20_POW_V1", chainId,
    /// miningContract, snapshotWallet, miningWallet, challenge, nonce)).
    /// Uses abi.encodePacked (not abi.encode) so the domain literal's raw
    /// UTF-8 bytes sit directly at the start of the preimage, with no
    /// length prefix or padding, per B20_POW_V1's exact field order.
    function computeHash(
        uint256 chainId,
        address miningContract,
        address snapshotWallet,
        address miningWallet,
        bytes32 challenge,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("B20_POW_V1", chainId, miningContract, snapshotWallet, miningWallet, challenge, nonce)
        );
    }

    /// @notice True iff uint256(computeHash(...)) <= target.
    function isValid(
        uint256 chainId,
        address miningContract,
        address snapshotWallet,
        address miningWallet,
        bytes32 challenge,
        uint256 nonce,
        uint256 target
    ) internal pure returns (bool) {
        return uint256(computeHash(chainId, miningContract, snapshotWallet, miningWallet, challenge, nonce)) <= target;
    }
}
