// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Fixed, non-bypassable vesting schedule for the 1,000,000,000
/// MINER Team Allocation (`B20_REVENUE_MODEL.md` 1.36, owner decision
/// 27 September 2026 — was 5,000,000,000; the schedule is unchanged).
///
/// Schedule (see B20_REVENUE_MODEL.md v1.17 / DEPLOYMENT_PARAMETERS.md
/// §1.4): a 12-period cliff, then 48 periods of linear monthly vesting.
/// `VESTING_PERIOD_SECONDS = 365 days / 12 = 2,628,000 seconds` — Solidity
/// has no native calendar-month arithmetic, so this fixed protocol period
/// is the on-chain definition of "one vesting month". First unlock at
/// TGE + 13 periods, final unlock (full amount) at TGE + 60 periods.
///
/// There is no early-release, acceleration, beneficiary-change, owner
/// withdrawal, emergency withdrawal or admin bypass path of any kind.
/// `release()` is callable by anyone, but tokens only ever move to the
/// immutable `BENEFICIARY` address.
contract B20TeamVesting {
    using SafeERC20 for IERC20;

    uint256 internal constant TOTAL_TEAM_ALLOCATION = 1_000_000_000 * 1e18;
    uint256 internal constant VESTING_PERIOD_SECONDS = 2_628_000; // 365 days / 12
    uint256 internal constant CLIFF_PERIODS = 12;
    uint256 internal constant VESTING_PERIODS = 48;

    IERC20 public immutable TOKEN;
    address public immutable BENEFICIARY;
    uint256 public immutable TGE;
    uint256 public immutable FIRST_UNLOCK;
    uint256 public immutable FINAL_UNLOCK;

    uint256 public released;

    error ZeroToken();
    error ZeroBeneficiary();
    error ZeroTGE();
    error NothingToRelease();
    error InsufficientFunding(uint256 requested, uint256 available);

    event TokensReleased(address indexed beneficiary, uint256 amount);

    constructor(address token, address beneficiary, uint256 tge) {
        if (token == address(0)) revert ZeroToken();
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (tge == 0) revert ZeroTGE();

        TOKEN = IERC20(token);
        BENEFICIARY = beneficiary;
        TGE = tge;
        FIRST_UNLOCK = tge + CLIFF_PERIODS * VESTING_PERIOD_SECONDS + VESTING_PERIOD_SECONDS;
        FINAL_UNLOCK = tge + VESTING_PERIODS * VESTING_PERIOD_SECONDS + CLIFF_PERIODS * VESTING_PERIOD_SECONDS;
    }

    /// @notice Number of full vesting periods completed as of `timestamp`,
    /// after the 12-period cliff, capped at VESTING_PERIODS (48).
    function _completedVestingPeriods(uint256 timestamp) internal view returns (uint256) {
        if (timestamp < TGE) return 0;
        uint256 elapsedPeriods = (timestamp - TGE) / VESTING_PERIOD_SECONDS;
        if (elapsedPeriods <= CLIFF_PERIODS) return 0;
        uint256 completed = elapsedPeriods - CLIFF_PERIODS;
        return completed > VESTING_PERIODS ? VESTING_PERIODS : completed;
    }

    /// @notice Total amount vested (earned, whether released or not) as of
    /// `timestamp`. Zero before TGE + 13 periods; exactly
    /// TOTAL_TEAM_ALLOCATION at and after TGE + 60 periods.
    function vestedAmount(uint256 timestamp) public view returns (uint256) {
        uint256 completed = _completedVestingPeriods(timestamp);
        return (TOTAL_TEAM_ALLOCATION * completed) / VESTING_PERIODS;
    }

    /// @notice Amount currently vested but not yet released.
    function releasable() public view returns (uint256) {
        return vestedAmount(block.timestamp) - released;
    }

    /// @notice Releases whatever is currently releasable to BENEFICIARY.
    /// Callable by anyone; funds only ever move to the immutable
    /// beneficiary address.
    function release() external {
        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();

        uint256 available = TOKEN.balanceOf(address(this));
        if (available < amount) revert InsufficientFunding(amount, available);

        released += amount;
        emit TokensReleased(BENEFICIARY, amount);
        TOKEN.safeTransfer(BENEFICIARY, amount);
    }
}
