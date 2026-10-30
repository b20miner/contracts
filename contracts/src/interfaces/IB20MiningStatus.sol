// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The two `B20Mining` reads both NFT collections gate on. Not a
/// full interface of that contract.
interface IB20MiningStatus {
    /// @notice False once `wallet` has confirmed its allocation or mining
    /// has ended — the NFT collections refuse to mint to it from then on.
    function mintingOpenFor(address wallet) external view returns (bool);

    /// @notice True once mining has been opened and its 15 days are over.
    /// NFT transfers unlock from then on.
    function miningEnded() external view returns (bool);
}
