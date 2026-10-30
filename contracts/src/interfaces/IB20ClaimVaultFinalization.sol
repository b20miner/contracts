// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of `B20ClaimVault` that `B20LiquidityFinalizer`
/// needs. Not a full interface of that contract.
interface IB20ClaimVaultFinalization {
    /// @notice The `B20Mining` instance the claim vault reads its
    /// mined/claimed totals from. Must equal the finalizer's own
    /// `mining` immutable — checked at `finalize()` time.
    function mining() external view returns (address);

    /// @notice The only address allowed to call `finalizeReserves()`.
    /// Must equal the finalizer's own address — checked at
    /// `finalize()` time.
    function finalizer() external view returns (address);

    /// @notice The MINER token the claim vault holds and pays out.
    /// Must equal the finalizer's own `minerToken` immutable — checked
    /// at `finalize()` time.
    function minerToken() external view returns (address);

    /// @notice Burns the unmined portion of the base/NFT reserves and
    /// freezes the claimable liability. Callable only by
    /// `B20LiquidityFinalizer`, called once, from inside `finalize()`.
    function finalizeReserves() external;
}
