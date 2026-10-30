// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice One-time activation of an owner (snapshot / main) wallet for
/// mining.
///
/// An owner wallet pays the fixed `ACTIVATION_FEE` once with `activate()`.
/// From then on ANY mining wallet may submit proofs for it: a browser, a
/// command-line miner, several devices, or even someone else. There is
/// nothing to register per device. This is safe because nothing a mining
/// wallet does can take value from the owner: every reward accrues to the
/// owner named in the proof (`B20Mining`), a proof's hash includes the
/// mining wallet so nobody can reuse another miner's proof, and claims pay
/// only the owner wallet. A mining wallet that mines for someone else pays
/// the mining fee and gas itself and gives that owner the MINER.
///
/// What activation gates: an owner who never activated cannot be mined
/// for at all (`isActiveBinding` is false), so the fee keeps both its
/// revenue role and its meaning as the owner's own opt-in. Eligibility and
/// quota are confirmed separately in `B20Mining`.
///
/// `ACTIVATION_FEE` is fixed at deployment: 1 USD converted at the ETH
/// market price the deployer reads at that moment
/// (`DEPLOYMENT_PARAMETERS.md` §1.3). No price oracle is read, ever; the
/// wei amount never changes afterward. The fee is forwarded to
/// `operationsTreasury` in the same transaction; this contract holds no ETH.
contract B20WalletBinding is ReentrancyGuard {
    /// @notice One-time fee, in wei, per owner wallet. Set once in the
    /// constructor; forwarded in full to `operationsTreasury`.
    uint256 public immutable ACTIVATION_FEE;

    address public immutable operationsTreasury;

    /// @notice The snapshot this deployment belongs to (kept for
    /// verification tooling; not used in any check here).
    bytes32 public immutable snapshotRoot;

    mapping(address ownerWallet => bool) private _activated;

    error ZeroTreasury();
    error ZeroSnapshotRoot();
    error ZeroActivationFee();
    error IncorrectActivationFee(uint256 sent, uint256 required);
    error AlreadyActivated(address ownerWallet);
    error TreasuryTransferFailed();

    event Activated(address indexed ownerWallet, uint256 activationFee);

    constructor(address operationsTreasury_, bytes32 snapshotRoot_, uint256 activationFee_) {
        if (operationsTreasury_ == address(0)) revert ZeroTreasury();
        if (snapshotRoot_ == bytes32(0)) revert ZeroSnapshotRoot();
        if (activationFee_ == 0) revert ZeroActivationFee();
        operationsTreasury = operationsTreasury_;
        snapshotRoot = snapshotRoot_;
        ACTIVATION_FEE = activationFee_;
    }

    /// @notice Activates the caller (the owner wallet) for mining, paying
    /// the fixed activation fee. Once per owner wallet.
    function activate() external payable nonReentrant {
        address ownerWallet = msg.sender;
        if (_activated[ownerWallet]) revert AlreadyActivated(ownerWallet);
        if (msg.value != ACTIVATION_FEE) revert IncorrectActivationFee(msg.value, ACTIVATION_FEE);

        _activated[ownerWallet] = true;
        emit Activated(ownerWallet, msg.value);

        (bool success,) = operationsTreasury.call{value: msg.value}("");
        if (!success) revert TreasuryTransferFailed();
    }

    /// @notice True iff `ownerWallet` has paid the activation fee.
    function isActivated(address ownerWallet) external view returns (bool) {
        return _activated[ownerWallet];
    }

    /// @notice True iff `miningWallet` may submit proofs for `ownerWallet`:
    /// any non-zero mining wallet may, once the owner is activated.
    /// `B20Mining` calls this on every proof rather than caching it.
    function isActiveBinding(address ownerWallet, address miningWallet) external view returns (bool) {
        return miningWallet != address(0) && _activated[ownerWallet];
    }
}
