// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The single read function `B20Mining` needs from
/// `B20WalletBinding`. Not a full interface of that contract.
interface IB20WalletBinding {
    /// @notice True iff `miningWallet` may currently submit proofs for
    /// `ownerWallet` (the owner is activated, added it and has not removed
    /// it). Must be re-checked on every call, never cached.
    function isActiveBinding(address ownerWallet, address miningWallet) external view returns (bool);
}
