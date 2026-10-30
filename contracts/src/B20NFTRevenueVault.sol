// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Collects mint ETH from both NFT collections and splits it
/// 50/50 between two immutable recipients on demand.
///
/// Distribution is not automatic at mint time; `distribute()` is a
/// separate, permissionless call anyone may trigger. The caller cannot
/// change the recipients or the split — those are fixed forever at
/// deploy time. There is no owner, admin, arbitrary withdrawal,
/// delegatecall or upgrade path.
contract B20NFTRevenueVault is ReentrancyGuard {
    address public immutable liquidityRecipient;
    address public immutable operationsRecipient;

    uint256 public totalDistributedToLiquidity;
    uint256 public totalDistributedToOperations;

    error ZeroLiquidityRecipient();
    error ZeroOperationsRecipient();
    error RecipientsMustDiffer();
    error NothingToDistribute();
    error TransferFailed();

    event Received(address indexed from, uint256 amount);
    event Distributed(uint256 liquidityShare, uint256 operationsShare);

    constructor(address liquidityRecipient_, address operationsRecipient_) {
        if (liquidityRecipient_ == address(0)) revert ZeroLiquidityRecipient();
        if (operationsRecipient_ == address(0)) revert ZeroOperationsRecipient();
        if (liquidityRecipient_ == operationsRecipient_) revert RecipientsMustDiffer();
        liquidityRecipient = liquidityRecipient_;
        operationsRecipient = operationsRecipient_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Splits the current balance 50/50 (any odd wei goes to
    /// `operationsRecipient`). Permissionless; reverts on a zero balance
    /// or if either transfer fails, undoing the whole distribution.
    function distribute() external nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToDistribute();

        uint256 liquidityShare = balance / 2;
        uint256 operationsShare = balance - liquidityShare;

        totalDistributedToLiquidity += liquidityShare;
        totalDistributedToOperations += operationsShare;

        emit Distributed(liquidityShare, operationsShare);

        (bool successLiquidity,) = liquidityRecipient.call{value: liquidityShare}("");
        if (!successLiquidity) revert TransferFailed();

        (bool successOperations,) = operationsRecipient.call{value: operationsShare}("");
        if (!successOperations) revert TransferFailed();
    }
}
