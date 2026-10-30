// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IB20MiningFinalization} from "./interfaces/IB20MiningFinalization.sol";
import {IB20ClaimVaultFinalization} from "./interfaces/IB20ClaimVaultFinalization.sol";
import {IB20NFTRevenueVaultFinalization} from "./interfaces/IB20NFTRevenueVaultFinalization.sol";

/// @dev The one MINER capability this contract needs beyond the ERC-20
/// compatible surface: burning its own balance. The production MINER is a
/// Base-native B20 Asset and this contract alone (beside B20ClaimVault) is
/// granted its `BURN_ROLE` during the Factory bootstrap transaction.
interface IB20BurnableToken is IERC20 {
    function burn(uint256 value) external;
}

/// @dev What this contract needs from `MinerPool`.
interface IMinerPoolOpen {
    function MINER() external view returns (address);
    function FINALIZER() external view returns (address);
    function open(uint256 minerAmount) external payable returns (uint128 liquidity);
}

/// @notice One-shot, permissionless `T+15` finalizer: verifies mining
/// has ended, distributes NFT revenue, triggers `B20ClaimVault`'s
/// unmined-reserve burn, burns the unused liquidity reserve and opens
/// MINER's one official pool — the Uniswap V4 pool `MinerPool` holds for
/// good (owner decision 30 October 2026; until then a V2 pair with its LP
/// tokens in `B20LPLocker`) — all inside one atomic transaction. Whatever a
/// stranger did to the public V4 pool key beforehand cannot block it
/// (`MinerPool.open`). See `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md` for the
/// full design this contract implements.
///
/// No owner, admin, setter, pause, upgrade, or rescue function anywhere.
/// Every dependency is an immutable set once at construction; the only
/// state this contract's own logic ever writes is the bookkeeping for
/// its one `finalize()` call and the running `accountedLiquidityEth`
/// total `receive()` maintains beforehand.
contract B20LiquidityFinalizer is ReentrancyGuard {
    /// @notice Fixed liquidity reserve (25,000,000,000 MINER). At most
    /// this much MINER is ever added to the pool; whatever is unused is
    /// burned during `finalize()`.
    uint256 public constant LIQUIDITY_RESERVE = 25_000_000_000 * 1e18;

    /// @notice `minerForPool = min(LIQUIDITY_RESERVE, ethToAdd ×
    /// POOL_MINER_PER_ETH)`. Half of `B20Mining.MINER_PER_ETH`
    /// (12,000,000): every mined MINER paid its fee at 1 ETH =
    /// 12,000,000 MINER, and the pool opens at 1 ETH = 6,000,000 MINER, so
    /// the opening price per MINER is twice the fee paid per MINER
    /// (owner decision 25 Sep 2026, `B20_REVENUE_MODEL.md` §6.1). The
    /// unused part of `LIQUIDITY_RESERVE` is burned. No separate `1e18`
    /// scaling is applied anywhere in this contract.
    uint256 public constant POOL_MINER_PER_ETH = 6_000_000;

    /// @notice The MINER token this contract holds, burns from, and
    /// adds to the pool.
    IB20BurnableToken public immutable minerToken;

    /// @notice Source of truth for when mining ended. Its
    /// `liquidityVault()` must equal this contract's own address —
    /// verified at `finalize()` time, not at construction (see the
    /// predicted-address deployment note on the constructor).
    IB20MiningFinalization public immutable mining;

    /// @notice The claim vault whose `finalizeReserves()` this contract
    /// calls, once, from inside `finalize()`.
    IB20ClaimVaultFinalization public immutable claimVault;

    /// @notice The NFT revenue vault this contract distributes from
    /// before computing how much ETH is available for liquidity.
    IB20NFTRevenueVaultFinalization public immutable nftRevenueVault;

    /// @notice MINER's pool: receives the liquidity and holds it for good.
    IMinerPoolOpen public immutable minerPool;

    /// @notice Running total of ETH this contract has accepted from
    /// `mining` and `nftRevenueVault` — the only figure `finalize()`
    /// treats as real liquidity funding. Never derived from
    /// `address(this).balance`, which a forced send could inflate.
    uint256 public accountedLiquidityEth;

    /// @notice True once `finalize()` has fully succeeded. Permanent —
    /// `finalize()` reverts on a second call, and `receive()` stops
    /// accepting ETH once this is true.
    bool public finalized;

    /// @notice MINER actually added to the pool (`== minerForPool` on
    /// success).
    uint256 public minerAdded;

    /// @notice ETH actually added to the pool (`== accountedLiquidityEth`
    /// at the time of `finalize()`, on success).
    uint256 public ethAdded;

    /// @notice Liquidity of the opening full-range position `minerPool` holds.
    uint256 public liquidityMinted;

    /// @notice The portion of `LIQUIDITY_RESERVE` burned because it
    /// wasn't needed to reach `minerForPool`.
    uint256 public liquidityReserveBurned;

    error ZeroMinerToken();
    error MinerTokenHasNoCode(address minerToken);
    error ZeroMining();
    error ZeroClaimVault();
    error ZeroNftRevenueVault();
    error NftRevenueVaultHasNoCode(address nftRevenueVault);
    error ZeroMinerPool();
    error MinerPoolHasNoCode(address minerPool);
    error MinerPoolTokenMismatch(address poolMiner, address expected);
    error MinerPoolFinalizerMismatch(address poolFinalizer, address expected);

    error UnauthorizedEthSender(address sender);

    error AlreadyFinalized();
    error TooEarly();
    error MiningHasNoCode();
    error ClaimVaultHasNoCode();
    error MiningLiquidityVaultMismatch(address actual, address expected);
    error ClaimVaultMiningMismatch(address actual, address expected);
    error ClaimVaultFinalizerMismatch(address actual, address expected);
    error ClaimVaultMinerTokenMismatch(address actual, address expected);
    error NftRevenueVaultLiquidityRecipientMismatch(address actual, address expected);

    error NoLiquidityEth();
    error InsufficientEthBalance(uint256 balance, uint256 required);
    error InsufficientMinerFunding(uint256 balance, uint256 required);

    error ZeroMinerForPool();
    error ZeroLiquidityMinted();

    /// @notice Emitted on every accepted `mining`/`nftRevenueVault` ETH
    /// transfer.
    event LiquidityEthReceived(address indexed source, uint256 amount, uint256 newAccountedTotal);

    /// @notice Emitted once, at the very end of a successful `finalize()`.
    event Finalized(
        address indexed minerPool,
        uint256 minerAdded,
        uint256 ethAdded,
        uint256 liquidityMinted,
        uint256 liquidityReserveBurned
    );

    /// @dev `mining_` and `claimVault_` are checked only for the zero
    /// address here — **not** for code length. Production deployment
    /// wires this contract in with the *predicted* (not-yet-deployed)
    /// addresses of `B20Mining` and `B20ClaimVault`, computed via
    /// nonce-based `CREATE` prediction (see
    /// `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md` §7): this contract must
    /// itself already have code before `B20Mining`'s constructor will
    /// accept it (`liquidityVault_.code.length > 0` there), which means
    /// this contract is deployed *before* `B20Mining` exists. The actual
    /// code-length and cross-contract wiring checks for `mining`/
    /// `claimVault` happen at `finalize()` time instead (see
    /// `_verifyRuntimeWiring`), by which point deployment has long since
    /// completed. `nftRevenueVault_`/`minerPool_`, by contrast, are
    /// required to already exist here, since neither of them needs this
    /// contract's own address to already have code at *their*
    /// construction time (see `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md`
    /// §7.2). `minerPool_` takes this contract's predicted address as its
    /// only `open` caller; both directions are checked here.
    constructor(
        address minerToken_,
        address mining_,
        address claimVault_,
        address nftRevenueVault_,
        address minerPool_
    ) {
        if (minerToken_ == address(0)) revert ZeroMinerToken();
        if (minerToken_.code.length == 0) revert MinerTokenHasNoCode(minerToken_);

        if (mining_ == address(0)) revert ZeroMining();
        if (claimVault_ == address(0)) revert ZeroClaimVault();

        if (nftRevenueVault_ == address(0)) revert ZeroNftRevenueVault();
        if (nftRevenueVault_.code.length == 0) revert NftRevenueVaultHasNoCode(nftRevenueVault_);

        if (minerPool_ == address(0)) revert ZeroMinerPool();
        if (minerPool_.code.length == 0) revert MinerPoolHasNoCode(minerPool_);
        address poolMiner = IMinerPoolOpen(minerPool_).MINER();
        if (poolMiner != minerToken_) revert MinerPoolTokenMismatch(poolMiner, minerToken_);
        address poolFinalizer = IMinerPoolOpen(minerPool_).FINALIZER();
        if (poolFinalizer != address(this)) revert MinerPoolFinalizerMismatch(poolFinalizer, address(this));

        minerToken = IB20BurnableToken(minerToken_);
        mining = IB20MiningFinalization(mining_);
        claimVault = IB20ClaimVaultFinalization(claimVault_);
        nftRevenueVault = IB20NFTRevenueVaultFinalization(nftRevenueVault_);
        minerPool = IMinerPoolOpen(minerPool_);
    }

    /// @notice Accepts ETH only from `mining` (mining fees) or
    /// `nftRevenueVault` (its liquidity-half `distribute()` transfer),
    /// and only before `finalize()` has succeeded. Every other sender —
    /// any EOA, any other contract — is rejected outright; there is no
    /// `fallback()` either, so calldata-bearing sends are rejected the
    /// same way.
    receive() external payable {
        if (finalized) revert AlreadyFinalized();
        if (msg.sender != address(mining) && msg.sender != address(nftRevenueVault)) {
            revert UnauthorizedEthSender(msg.sender);
        }
        accountedLiquidityEth += msg.value;
        emit LiquidityEthReceived(msg.sender, msg.value, accountedLiquidityEth);
    }

    /// @notice Runs the full `T+15` finalization sequence exactly once:
    /// distribute NFT revenue, burn the claim vault's unmined reserves,
    /// burn this contract's own unused liquidity reserve and open
    /// `minerPool` with the ETH and the matching MINER. If any step fails, the
    /// entire transaction — including every burn — reverts with nothing
    /// committed. See `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md` §3 for
    /// the full rationale behind this exact order.
    function finalize() external nonReentrant {
        if (finalized) revert AlreadyFinalized();
        // Wiring is verified — code-length first, then live cross-contract
        // reads — before the time check below makes its own live call to
        // `mining.MINING_END()`. Otherwise, an unwired `mining` address
        // with no code would revert on that live call with an opaque
        // ABI-decode failure instead of the intended `MiningHasNoCode`.
        _verifyRuntimeWiring();
        if (block.timestamp < mining.MINING_END()) revert TooEarly();

        _distributeNftRevenueIfAny();

        uint256 ethToAdd = _resolveEthToAdd();

        uint256 minerBalance = minerToken.balanceOf(address(this));
        if (minerBalance < LIQUIDITY_RESERVE) revert InsufficientMinerFunding(minerBalance, LIQUIDITY_RESERVE);

        claimVault.finalizeReserves();

        (uint256 minerForPool, uint256 unusedLiquidity) = _burnUnusedLiquidity(ethToAdd);

        uint256 liquidity = _addLiquidity(minerForPool, ethToAdd);

        minerAdded = minerForPool;
        ethAdded = ethToAdd;
        liquidityMinted = liquidity;
        liquidityReserveBurned = unusedLiquidity;

        emit Finalized(address(minerPool), minerForPool, ethToAdd, liquidity, unusedLiquidity);

        finalized = true;
    }

    /// @dev Confirms `mining`/`claimVault` now actually have code (they
    /// were only address-checked at construction, see the constructor's
    /// NatSpec) and that every cross-contract immutable wiring this
    /// system depends on actually resolved to what was intended.
    function _verifyRuntimeWiring() internal view {
        if (address(mining).code.length == 0) revert MiningHasNoCode();
        if (address(claimVault).code.length == 0) revert ClaimVaultHasNoCode();

        address miningLiquidityVault = mining.liquidityVault();
        if (miningLiquidityVault != address(this)) {
            revert MiningLiquidityVaultMismatch(miningLiquidityVault, address(this));
        }

        address claimVaultMining = claimVault.mining();
        if (claimVaultMining != address(mining)) revert ClaimVaultMiningMismatch(claimVaultMining, address(mining));

        address claimVaultFinalizer = claimVault.finalizer();
        if (claimVaultFinalizer != address(this)) {
            revert ClaimVaultFinalizerMismatch(claimVaultFinalizer, address(this));
        }

        address claimVaultMinerToken = claimVault.minerToken();
        if (claimVaultMinerToken != address(minerToken)) {
            revert ClaimVaultMinerTokenMismatch(claimVaultMinerToken, address(minerToken));
        }

        address nftVaultRecipient = nftRevenueVault.liquidityRecipient();
        if (nftVaultRecipient != address(this)) {
            revert NftRevenueVaultLiquidityRecipientMismatch(nftVaultRecipient, address(this));
        }
    }

    /// @dev No `try`/`catch` — a failed distribution reverts `finalize()`
    /// in full. See `docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md` §6 for why
    /// this fail-closed behavior is deliberate.
    function _distributeNftRevenueIfAny() internal {
        if (address(nftRevenueVault).balance > 0) {
            nftRevenueVault.distribute();
        }
    }

    /// @dev Reads `accountedLiquidityEth` — never `address(this).balance`
    /// directly, which a forced send could inflate — and confirms the
    /// contract's real balance actually covers it.
    function _resolveEthToAdd() internal view returns (uint256 ethToAdd) {
        ethToAdd = accountedLiquidityEth;
        if (ethToAdd == 0) revert NoLiquidityEth();
        if (address(this).balance < ethToAdd) revert InsufficientEthBalance(address(this).balance, ethToAdd);
    }

    /// @dev `minerForPool = min(LIQUIDITY_RESERVE, ethToAdd ×
    /// POOL_MINER_PER_ETH)`; burns exactly `LIQUIDITY_RESERVE - minerForPool`
    /// from this contract's own balance.
    function _burnUnusedLiquidity(uint256 ethToAdd) internal returns (uint256 minerForPool, uint256 unusedLiquidity) {
        uint256 uncappedMiner = ethToAdd * POOL_MINER_PER_ETH;
        minerForPool = uncappedMiner < LIQUIDITY_RESERVE ? uncappedMiner : LIQUIDITY_RESERVE;
        if (minerForPool == 0) revert ZeroMinerForPool();

        unusedLiquidity = LIQUIDITY_RESERVE - minerForPool;
        if (unusedLiquidity > 0) minerToken.burn(unusedLiquidity);
    }

    /// @dev Sends `minerForPool` MINER to `minerPool`, then opens it with
    /// the ETH. The pool holds the position for good; no LP token exists.
    function _addLiquidity(uint256 minerForPool, uint256 ethToAdd) internal returns (uint256 liquidity) {
        SafeERC20.safeTransfer(minerToken, address(minerPool), minerForPool);
        liquidity = minerPool.open{value: ethToAdd}(minerForPool);
        if (liquidity == 0) revert ZeroLiquidityMinted();
    }
}
