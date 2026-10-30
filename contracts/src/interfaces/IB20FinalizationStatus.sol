// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The single read function `B20ClaimVault` needs from the
/// liquidity finalizer (`B20LiquidityFinalizer`, not part of this task).
/// Not a full interface of that contract.
interface IB20FinalizationStatus {
    /// @notice True once the one-shot `T+15` finalization (liquidity
    /// added, unused reserves burned, LP sent to the permanent locker)
    /// has fully succeeded. `B20ClaimVault.claim()` will not pay out
    /// until this is true.
    function finalized() external view returns (bool);
}
