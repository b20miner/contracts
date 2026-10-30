// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Timelocked MINER transfer vault for the Ecosystem & Treasury
/// allocation (see DEPLOYMENT_PARAMETERS.md §1.5).
///
/// Every outgoing transfer must be queued by the immutable manager and
/// waits a fixed, non-bypassable 48-hour delay before it can be executed.
/// Anyone may call `executeTransfer` once the delay has passed, but the
/// recipient and amount are always exactly what was queued — the caller
/// cannot redirect or resize a transfer. There is no arbitrary call,
/// delegatecall, ETH withdrawal, instant manager change or timelock
/// bypass of any kind.
contract B20EcosystemVault {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_DELAY = 48 hours;

    IERC20 public immutable TOKEN;
    address public immutable MANAGER;

    enum Status {
        None,
        Queued,
        Canceled,
        Executed
    }

    struct Operation {
        address recipient;
        uint256 amount;
        uint256 executeAfter;
        Status status;
    }

    mapping(bytes32 => Operation) public operations;
    uint256 public nonce;

    error ZeroToken();
    error ZeroManager();
    error NotManager();
    error ZeroRecipient();
    error ZeroAmount();
    error OperationNotQueued(bytes32 operationId);
    error TimelockNotExpired(bytes32 operationId, uint256 executeAfter);

    event TransferQueued(
        bytes32 indexed operationId, address indexed recipient, uint256 amount, uint256 executeAfter, uint256 nonce
    );
    event TransferCanceled(bytes32 indexed operationId);
    event TransferExecuted(bytes32 indexed operationId, address indexed recipient, uint256 amount);

    modifier onlyManager() {
        if (msg.sender != MANAGER) revert NotManager();
        _;
    }

    constructor(address token, address manager) {
        if (token == address(0)) revert ZeroToken();
        if (manager == address(0)) revert ZeroManager();
        TOKEN = IERC20(token);
        MANAGER = manager;
    }

    /// @notice Queues a MINER transfer. Only callable by MANAGER.
    function queueTransfer(address recipient, uint256 amount)
        external
        onlyManager
        returns (bytes32 operationId, uint256 executeAfter)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();

        uint256 currentNonce = nonce++;
        operationId = keccak256(abi.encode(address(this), currentNonce, recipient, amount));
        executeAfter = block.timestamp + MIN_DELAY;

        operations[operationId] =
            Operation({recipient: recipient, amount: amount, executeAfter: executeAfter, status: Status.Queued});

        emit TransferQueued(operationId, recipient, amount, executeAfter, currentNonce);
    }

    /// @notice Cancels a queued transfer. Only callable by MANAGER.
    function cancelTransfer(bytes32 operationId) external onlyManager {
        Operation storage op = operations[operationId];
        if (op.status != Status.Queued) revert OperationNotQueued(operationId);
        op.status = Status.Canceled;
        emit TransferCanceled(operationId);
    }

    /// @notice Executes a queued transfer once its 48-hour delay has
    /// passed. Callable by anyone; always uses the recipient/amount
    /// recorded at queue time.
    function executeTransfer(bytes32 operationId) external {
        Operation storage op = operations[operationId];
        if (op.status != Status.Queued) revert OperationNotQueued(operationId);
        if (block.timestamp < op.executeAfter) revert TimelockNotExpired(operationId, op.executeAfter);

        address recipient = op.recipient;
        uint256 amount = op.amount;
        op.status = Status.Executed;

        emit TransferExecuted(operationId, recipient, amount);
        TOKEN.safeTransfer(recipient, amount);
    }

    /// @notice Current MINER balance held by this vault.
    function tokenBalance() external view returns (uint256) {
        return TOKEN.balanceOf(address(this));
    }
}
