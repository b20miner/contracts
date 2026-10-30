// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of `B20NFTRevenueVault` that
/// `B20LiquidityFinalizer` needs. Not a full interface of that contract.
interface IB20NFTRevenueVaultFinalization {
    /// @notice The address the vault sends the liquidity half of every
    /// `distribute()` call to. Must equal the finalizer's own address —
    /// checked at `finalize()` time.
    function liquidityRecipient() external view returns (address);

    /// @notice Splits the vault's current ETH balance 50/50 between
    /// `liquidityRecipient` and `operationsRecipient`. Reverts if the
    /// balance is zero or if either transfer fails.
    function distribute() external;
}
