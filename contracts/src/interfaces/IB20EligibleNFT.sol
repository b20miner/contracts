// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The two read functions `B20Mining` needs from `B20EligibleNFT`.
/// Not a full interface of that contract.
interface IB20EligibleNFT {
    /// @notice Total onchain mining bonus (18-decimal MINER units) earned
    /// by `wallet` from all Eligible NFTs it has minted.
    function eligibleBonus(address wallet) external view returns (uint256);

    /// @notice The `B20Mining` contract whose mint gate this collection
    /// follows. Must equal that `B20Mining` exactly.
    function mining() external view returns (address);
}
