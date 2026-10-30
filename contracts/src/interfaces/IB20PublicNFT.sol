// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The two read functions `B20Mining` needs from `B20PublicNFT`.
/// Not a full interface of that contract.
interface IB20PublicNFT {
    /// @notice Total onchain mining quota (18-decimal MINER units) earned
    /// by `wallet` from all Public NFTs it has minted.
    function publicMiningQuota(address wallet) external view returns (uint256);

    /// @notice The `B20Mining` contract whose mint gate this collection
    /// follows. Must equal that `B20Mining` exactly.
    function mining() external view returns (address);
}
