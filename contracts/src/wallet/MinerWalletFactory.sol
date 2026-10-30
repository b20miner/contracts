// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MinerWallet} from "./MinerWallet.sol";

/// @notice K59–K62: creates one `MinerWallet` per owner wallet, for gas only.
/// Each wallet is a minimal proxy (EIP-1167) of one fixed implementation
/// at a CREATE2 address derived from the owner, so the address is known
/// before it exists and an owner can never have a second one. Nothing here
/// has an owner, an admin or an upgrade path.
contract MinerWalletFactory {
    MinerWallet public immutable IMPLEMENTATION;

    mapping(address owner => address wallet) public walletOf;

    error AlreadyCreated(address wallet);

    event WalletCreated(address indexed owner, address indexed wallet);

    constructor(address b20Mining, address launchpadFactory) {
        IMPLEMENTATION = new MinerWallet(b20Mining, launchpadFactory);
    }

    /// @notice The caller's wallet address, before or after creation.
    function predict(address owner) public view returns (address) {
        return Clones.predictDeterministicAddress(address(IMPLEMENTATION), _salt(owner));
    }

    /// @notice Creates the caller's wallet. Any ETH sent is deposited.
    function create() external payable returns (address wallet) {
        if (walletOf[msg.sender] != address(0)) revert AlreadyCreated(walletOf[msg.sender]);
        wallet = Clones.cloneDeterministic(address(IMPLEMENTATION), _salt(msg.sender));
        walletOf[msg.sender] = wallet;
        MinerWallet(payable(wallet)).initialize(msg.sender);
        emit WalletCreated(msg.sender, wallet);
        if (msg.value > 0) MinerWallet(payable(wallet)).deposit{value: msg.value}();
    }

    function _salt(address owner) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }
}
