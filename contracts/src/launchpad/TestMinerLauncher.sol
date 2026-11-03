// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {MinerBurner} from "../MinerBurner.sol";
import {MinerPool} from "../MinerPool.sol";

/// @notice Base Sepolia only: the testnet Launchpad's platform token tMINER
/// on mainnet MINER's own pool code (owner, 3 November 2026: the real MINER
/// mines on Base, the public testnet Launchpad pays into tMINER instead).
/// Everything happens in the constructor, in one transaction, and the
/// contract has no function afterwards:
///
/// 1. `MinerBurner` and `MinerPool` are deployed unchanged (the mainnet
///    code: hookless V4 pool, 0.3% LP fee, buy support anchored to flush
///    samples, sale fees burned). This contract is the pool's `FINALIZER`,
///    the only caller of `open`.
/// 2. tMINER is created through Base's native B20 factory: no admin, the
///    whole supply minted to the pool and `BURN_ROLE` to the burner only,
///    so nobody can ever mint again and burns lower `totalSupply`.
/// 3. `open` puts the sent ETH and `msg.value × 6,000,000` tMINER in as one
///    full-range position at 1 ETH = 6,000,000 tMINER, as B20MINER's
///    finalize does on mainnet. The supply is exactly that amount: as on
///    mainnet, the opening ETH decides how much of the token exists.
///
/// The pool is open from the start, so the Launchpad's MINER-liquidity share
/// becomes buy support from its first `flush`; nothing waits for mining.
contract TestMinerLauncher {
    string public constant NAME = "B20MINER Test";
    string public constant SYMBOL = "tMINER";
    bytes32 public constant SALT = keccak256("B20MINER tMINER v19");
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    address public immutable TOKEN;
    MinerBurner public immutable BURNER;
    MinerPool public immutable POOL;
    /// @notice Liquidity of the opening position.
    uint128 public immutable OPENING_LIQUIDITY;

    error WrongChain(uint256 chainId);
    error ZeroAmount();
    error TokenAddressMismatch(address expected, address got);

    constructor(address poolManager) payable {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        if (msg.value == 0) revert ZeroAmount();
        address token = StdPrecompiles.B20_FACTORY.getB20Address(IB20Factory.B20Variant.ASSET, address(this), SALT);
        MinerBurner burner = new MinerBurner(token);
        MinerPool pool = new MinerPool(poolManager, token, address(burner), address(this));
        uint256 supply = msg.value * pool.POOL_MINER_PER_ETH();

        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        to[0] = address(pool);
        amounts[0] = supply;
        bytes[] memory calls = new bytes[](3);
        calls[0] = B20FactoryLib.encodeUpdateSupplyCap(supply);
        calls[1] = B20FactoryLib.encodeBatchMint(to, amounts);
        calls[2] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, address(burner));
        address created = StdPrecompiles.B20_FACTORY.createB20(
            IB20Factory.B20Variant.ASSET, SALT, B20FactoryLib.encodeAssetCreateParams(NAME, SYMBOL, address(0), 18), calls
        );
        if (created != token) revert TokenAddressMismatch(token, created);

        TOKEN = token;
        BURNER = burner;
        POOL = pool;
        OPENING_LIQUIDITY = pool.open{value: msg.value}(supply);
    }
}
