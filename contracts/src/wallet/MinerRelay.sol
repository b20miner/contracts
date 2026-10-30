// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice K62: sends many relayed mining orders in one transaction.
///
/// Stateless and permissionless: it holds no ETH, has no owner and no
/// privileges; a `MinerWallet` does not trust its caller, only the signed
/// order, and pays the gas back to the transaction's sender. One failing
/// call never stops the others.
contract MinerRelay {
    struct Call {
        address wallet;
        bytes data;
    }

    /// @notice A call that reverted (an order that failed its checks).
    event CallFailed(uint256 indexed index, address indexed wallet);

    function relay(Call[] calldata calls) external {
        uint256 n = calls.length;
        for (uint256 i; i < n; ++i) {
            address wallet = calls[i].wallet;
            bytes calldata data = calls[i].data;
            bool ok;
            assembly {
                let ptr := mload(0x40)
                calldatacopy(ptr, data.offset, data.length)
                // No return data is copied (a large revert cannot cost the batch).
                ok := call(gas(), wallet, 0, ptr, data.length, 0, 0)
            }
            if (!ok) emit CallFailed(i, wallet);
        }
    }
}
