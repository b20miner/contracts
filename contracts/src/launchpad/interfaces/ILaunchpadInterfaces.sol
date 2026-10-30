// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A campaign token as the Launchpad uses it: an ERC-20 whose
/// holders with `BURN_ROLE` can burn their own balance and whose holders of
/// `MINT_ROLE` mint up to `supplyCap` (K65: a mining token is minted by its
/// proofs and its pool's opening, never in advance). The production token is
/// a Base-native B20 Asset (`IB20.burn`, `IB20.mint`).
interface ICampaignToken is IERC20 {
    function burn(uint256 amount) external;
    function mint(address to, uint256 amount) external;
    function supplyCap() external view returns (uint256);
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

/// @notice What `CampaignPool` needs from its `MiningCampaign`.
interface IMiningCampaignSettlement {
    function miningOver() external view returns (bool);
    function poolAccrued() external view returns (uint256);
    function minedTotal() external view returns (uint256);
    /// @notice K63: enough was mined, by enough miners, to keep a 2× opening.
    function doubleOpeningQualified() external view returns (bool);
    /// @notice K63: every owner has had their delivery; the pool may open.
    function distributionDone() external view returns (bool);
    /// @notice K63: delivers to the next `max` owners (anyone may call).
    function distribute(uint256 max) external returns (uint256 served);
    /// @notice Called once by the campaign's pool: claims open and the pool
    /// share is sent to the pool (returned). `direct` = the token launches
    /// directly (K49: nobody mined). K65 (v12): the campaign gives up its
    /// `MINT_ROLE` here — the unmined reserve was never minted, so there is
    /// nothing to hand over; the pool mints only what its opening needs.
    function settle(bool direct) external returns (uint256 ethToPool);
}

/// @notice The factory's registry, as `PositionLocker` reads it.
interface ILaunchpadRegistry {
    /// @notice The token of the campaign whose `CampaignPool` is `pool`, or
    /// address(0) if `pool` is not a Launchpad pool.
    function poolToken(address pool) external view returns (address);
}

/// @notice What `CampaignPool` reads from its factory when it opens a
/// direct or instant launch (K68, v14).
interface ILaunchpadOpening {
    /// @notice The opening FDV in ETH wei: a fixed amount (~5,000 USD) the
    /// factory's guardian refreshes now and then, as o1 does.
    function directLaunchFdvWei() external view returns (uint256);
}

/// @notice Where the MINER-liquidity share of trading fees goes (mainnet `MinerPool`, Base Sepolia `TestMinerPool`).
interface IMinerLiquiditySink {
    function depositMinerLiquidityEth() external payable;
}

/// @notice What `CampaignPool` calls on the locker at finalize.
interface IPositionLocker {
    /// @notice Opens the pool at `sqrtPriceX96` rounded to a usable tick:
    /// `tokenAmount` single-sided from the opening price up (the ask) and
    /// the ETH sent single-sided just below it (the bid). `floorTokens`
    /// sizes the bid so exactly that many tokens fit in it (K54, the miners'
    /// tokens); 0 lets the bid reach the lowest price (direct and instant
    /// launches).
    function lock(
        address token,
        address feeRecipient,
        uint256 tokenAmount,
        uint256 floorTokens,
        uint160 sqrtPriceX96,
        bool antiSnipe
    ) external payable returns (uint128 liquidity, uint256 ethUsed, uint256 tokenUsed);

    /// @notice K56: an instant launch's creator buy, right after `lock` in
    /// the same transaction — every ETH sent swaps into `token` for
    /// `recipient`, free of the anti-snipe surcharge. Returns the tokens bought.
    function buyAtOpening(address token, address recipient) external payable returns (uint256 tokensOut);
}

/// @notice Chainlink's AggregatorV3 view the factory prices its creation fee
/// with (K66).
interface IEthUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
