// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMinerBurnable is IERC20 {
    function burn(uint256 amount) external;
}

/// @notice The single place where MINER is burned after launch
/// (`B20_REVENUE_MODEL.md` 1.36, owner decisions 27 September 2026). It
/// burns MINER only — nothing else, not Launchpad campaign tokens.
///
/// MINER sent to this address is burned: other contracts (Launchpad fees
/// paid in MINER, sponsored listing auctions, treasury buy-backs) transfer
/// it here and call `burn()` in the same transaction; anyone else may
/// simply transfer MINER here, and anyone may call `burn()` to burn
/// everything waiting. A token transfer runs no code on the receiver, so
/// MINER sent with a plain transfer sits here until the next `burn()`.
///
/// MINER is an immutable Base-native B20 Asset: `BURN_ROLE` can only be
/// granted when the token is created, never afterwards. This contract gets
/// that role at creation, so burns really lower `totalSupply` instead of
/// parking tokens at a dead address. It can only burn its own balance, so
/// nobody else's MINER can ever be touched. No admin, no other function,
/// no way to take anything out; any other token sent here is stuck for good.
contract MinerBurner {
    IMinerBurnable public immutable MINER;

    /// @notice Everything this contract has burned.
    uint256 public totalBurned;

    event Burned(uint256 amount, uint256 totalBurned);

    constructor(address miner) {
        MINER = IMinerBurnable(miner);
    }

    /// @notice Burns every MINER this contract holds. Anyone may call.
    function burn() external returns (uint256 amount) {
        amount = MINER.balanceOf(address(this));
        if (amount == 0) return 0;
        totalBurned += amount;
        emit Burned(amount, totalBurned);
        MINER.burn(amount);
    }
}
