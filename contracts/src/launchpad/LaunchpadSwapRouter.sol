// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title LaunchpadSwapRouter
/// @notice One exact-input swap in one Uniswap V4 pool, paid by the caller
/// and paid out to the caller (16 Oct 2026, web app doc §4.6zp).
///
/// A sale needs a plain ERC-20 `approve` of this router, once per token, and
/// then the swap: two transactions the first time, one after, and no
/// signature. Through the Universal Router a sale needs Permit2 (an approve
/// to Permit2 and a signed allowance), and Permit2 refuses the signature of
/// an EIP-7702 smart account (MetaMask's), which then needs a third
/// transaction.
///
/// What it can do, and nothing else:
/// - it moves tokens only from `msg.sender`, only the amount the swap used,
///   only inside that sender's own swap, straight to the PoolManager;
/// - the output goes to `msg.sender`, and unused ETH goes back to them;
/// - no owner, no upgrade, no storage, no arbitrary calls, no other payer
///   or recipient. It holds nothing between transactions.
///
/// Any V4 pool works; the Launchpad hook does not look at which router
/// swaps (its opening surcharge is in the swap's deltas). Exact input with
/// no price limit: the hook refuses partial fills in a protected opening.
contract LaunchpadSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable POOL_MANAGER;

    /// @notice One swap: who traded, in which pool, which way, what went in and came out.
    event Swap(address indexed trader, PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    error NotPoolManager();
    error Expired(uint256 deadline);
    error ZeroAmount();
    error AmountTooLarge(uint256 amountIn);
    error WrongValue(uint256 sent, uint256 expected);
    error TooLittleReceived(uint256 amountOut, uint256 minOut);
    error EthTransferFailed(address to, uint256 amount);

    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// @notice Swaps exactly `amountIn` of the input currency for at least `minOut` of the other.
    /// @param zeroForOne true: currency0 in (in a Launchpad pool, ETH in: a buy); false: currency1 in (a sale).
    /// @param amountIn ETH sent with the call when the input is native (`msg.value` must equal it);
    /// otherwise pulled from the caller (who approved this router).
    /// @return amountOut What the caller received.
    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        payable
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge(amountIn);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        uint256 expected = input.isAddressZero() ? amountIn : 0;
        if (msg.value != expected) revert WrongValue(msg.value, expected);

        uint256 paid;
        (amountOut, paid) =
            abi.decode(POOL_MANAGER.unlock(abi.encode(msg.sender, key, zeroForOne, amountIn)), (uint256, uint256));
        if (amountOut < minOut) revert TooLittleReceived(amountOut, minOut);
        // A swap the pool could not fill in full (out of liquidity): the rest of the ETH goes back.
        if (expected > paid) _sendEth(msg.sender, expected - paid);
        emit Swap(msg.sender, key.toId(), zeroForOne, paid, amountOut);
    }

    /// @dev Only inside this router's own `unlock`: the PoolManager calls back the contract that unlocked it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (address payer, PoolKey memory key, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (address, PoolKey, bool, uint256));
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 paid = inDelta < 0 ? uint256(uint128(-inDelta)) : 0;
        uint256 out = outDelta > 0 ? uint256(uint128(outDelta)) : 0;

        if (paid > 0) {
            if (input.isAddressZero()) {
                POOL_MANAGER.settle{value: paid}();
            } else {
                POOL_MANAGER.sync(input);
                IERC20(Currency.unwrap(input)).safeTransferFrom(payer, address(POOL_MANAGER), paid);
                POOL_MANAGER.settle();
            }
        }
        if (out > 0) POOL_MANAGER.take(output, payer, out);
        return abi.encode(out, paid);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed(to, amount);
    }
}
