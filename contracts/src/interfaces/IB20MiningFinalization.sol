// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of `B20Mining` that `B20LiquidityFinalizer` needs.
/// Not a full interface of that contract.
interface IB20MiningFinalization {
    /// @notice Mining closes at (and after) this timestamp — the
    /// earliest moment `finalize()` may run.
    function MINING_END() external view returns (uint256);

    /// @notice The address `B20Mining` forwards every mining fee to.
    /// Must equal the finalizer's own address — checked at
    /// `finalize()` time as part of runtime wiring verification.
    function liquidityVault() external view returns (address);
}
