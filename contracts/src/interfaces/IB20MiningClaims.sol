// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of `B20Mining` that `B20ClaimVault` needs to read.
/// Not a full interface of that contract.
interface IB20MiningClaims {
    /// @notice Mining closes at (and after) this timestamp; also the
    /// root input for `B20ClaimVault`'s `claimDeadline()`.
    function MINING_END() external view returns (uint256);

    /// @notice Fixed snapshot/base mining reserve cap
    /// (60,000,000,000 MINER, 18-decimal units). Must equal
    /// `B20ClaimVault.BASE_RESERVE`.
    function BASE_QUOTA_CAP() external view returns (uint256);

    /// @notice Fixed NFT mining reserve cap (1,000,000,000 MINER,
    /// 18-decimal units). Must equal `B20ClaimVault.NFT_RESERVE`.
    function NFT_QUOTA_CAP() external view returns (uint256);

    /// @notice `ownerWallet`'s locked-but-unclaimed reward paid out of
    /// snapshot base quota (18-decimal MINER units).
    function baseMinedLocked(address ownerWallet) external view returns (uint256);

    /// @notice `ownerWallet`'s locked-but-unclaimed reward paid out of
    /// NFT quota (18-decimal MINER units).
    function nftMinedLocked(address ownerWallet) external view returns (uint256);

    /// @notice Sum of every owner's `baseMinedLocked`.
    function totalBaseMinedLocked() external view returns (uint256);

    /// @notice Sum of every owner's `nftMinedLocked`.
    function totalNftMinedLocked() external view returns (uint256);
}
