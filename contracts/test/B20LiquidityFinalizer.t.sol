// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {B20LiquidityFinalizer} from "../src/B20LiquidityFinalizer.sol";
import {MinerBurner} from "../src/MinerBurner.sol";
import {MinerPool} from "../src/MinerPool.sol";
import {IB20MiningFinalization} from "../src/interfaces/IB20MiningFinalization.sol";
import {IB20ClaimVaultFinalization} from "../src/interfaces/IB20ClaimVaultFinalization.sol";
import {IB20NFTRevenueVaultFinalization} from "../src/interfaces/IB20NFTRevenueVaultFinalization.sol";

// ---------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------

/// @notice Test-only ERC20Burnable standing in for the production native B20
/// Asset's ERC-20-compatible transfer and role-authorized burn surface.
contract MockMinerTokenF is ERC20, ERC20Burnable {
    constructor() ERC20("Mock MINER", "MMINER") {
        _mint(msg.sender, 1_000_000_000_000 * 1e18);
    }
}

/// @notice Minimal, directly settable mock of the subset of B20Mining
/// that B20LiquidityFinalizer reads. Deployed normally — its address is
/// a plain constructor argument to the finalizer, never a hardcoded
/// constant, so it needs no `vm.etch`.
contract MockMiningF is IB20MiningFinalization {
    uint256 public miningEndValue;
    address public liquidityVaultAddr;

    constructor(uint256 miningEndValue_) {
        miningEndValue = miningEndValue_;
    }

    function setLiquidityVault(address addr) external {
        liquidityVaultAddr = addr;
    }

    function MINING_END() external view returns (uint256) {
        return miningEndValue;
    }

    function liquidityVault() external view returns (address) {
        return liquidityVaultAddr;
    }
}

/// @notice Minimal, directly settable mock of the subset of B20ClaimVault
/// that B20LiquidityFinalizer reads/calls. `finalizeReservesCallCount`
/// lets tests prove `finalizeReserves()` was actually invoked — and,
/// combined with EVM revert semantics, that a later failure in
/// `finalize()` undoes that call's effects too.
contract MockClaimVaultF is IB20ClaimVaultFinalization {
    address public miningAddr;
    address public finalizerAddr;
    address public minerTokenAddr;
    uint256 public finalizeReservesCallCount;
    bool public shouldRevertOnFinalizeReserves;

    constructor(address mining_, address minerToken_) {
        miningAddr = mining_;
        minerTokenAddr = minerToken_;
    }

    function setFinalizer(address finalizer_) external {
        finalizerAddr = finalizer_;
    }

    function setMining(address mining_) external {
        miningAddr = mining_;
    }

    function setMinerToken(address token_) external {
        minerTokenAddr = token_;
    }

    function setShouldRevertOnFinalizeReserves(bool value) external {
        shouldRevertOnFinalizeReserves = value;
    }

    function mining() external view returns (address) {
        return miningAddr;
    }

    function finalizer() external view returns (address) {
        return finalizerAddr;
    }

    function minerToken() external view returns (address) {
        return minerTokenAddr;
    }

    function finalizeReserves() external {
        if (shouldRevertOnFinalizeReserves) revert("mock: finalizeReserves failure");
        finalizeReservesCallCount++;
    }
}

/// @notice Minimal, directly settable mock of B20NFTRevenueVault's
/// finalizer-facing surface. `distribute()` forwards its entire balance
/// to `liquidityRecipient` — simple enough to exercise the finalizer's
/// accounting without reproducing the real 50/50 split.
contract MockNftRevenueVaultF is IB20NFTRevenueVaultFinalization {
    address public liquidityRecipientAddr;
    bool public shouldRevertOnDistribute;
    uint256 public distributeCallCount;

    function setLiquidityRecipient(address addr) external {
        liquidityRecipientAddr = addr;
    }

    function setShouldRevertOnDistribute(bool value) external {
        shouldRevertOnDistribute = value;
    }

    receive() external payable {}

    function liquidityRecipient() external view returns (address) {
        return liquidityRecipientAddr;
    }

    function distribute() external {
        if (shouldRevertOnDistribute) revert("mock: distribute failure");
        distributeCallCount++;
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok,) = liquidityRecipientAddr.call{value: balance}("");
            require(ok, "mock: distribute transfer failed");
        }
    }
}

/// @notice A malicious NFT revenue vault whose `distribute()` attempts to
/// reenter `finalize()` — used only by the reentrancy test.
contract ReentrantNftRevenueVaultF is IB20NFTRevenueVaultFinalization {
    address public liquidityRecipientAddr;
    B20LiquidityFinalizer public target;
    uint256 public reentryAttempts;
    bool public reentryReverted;

    function setLiquidityRecipient(address addr) external {
        liquidityRecipientAddr = addr;
    }

    function setTarget(B20LiquidityFinalizer target_) external {
        target = target_;
    }

    receive() external payable {}

    function liquidityRecipient() external view returns (address) {
        return liquidityRecipientAddr;
    }

    function distribute() external {
        reentryAttempts++;
        if (reentryAttempts == 1) {
            try target.finalize() {
                reentryReverted = false;
            } catch {
                reentryReverted = true;
            }
        }
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok,) = liquidityRecipientAddr.call{value: balance}("");
            require(ok, "reentrant mock: forward failed");
        }
    }
}

/// @notice A contract with no receive/fallback, used to force a plain
/// ETH transfer to the finalizer to fail (for the "other senders are
/// rejected" test — using an EOA already suffices there, this is for
/// completeness) and, mainly, to force ETH onto the finalizer via
/// `selfdestruct`, bypassing `receive()` entirely.
contract EthForcer {
    receive() external payable {}

    function forceSend(address payable target) external {
        selfdestruct(target);
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// @notice B20LiquidityFinalizer with MINER's V4 pool (owner decision 30
/// October 2026): a real Uniswap V4 PoolManager and a real `MinerPool` are
/// deployed here; mining, the claim vault and the NFT revenue vault are
/// mocks. No fork, no network.
contract B20LiquidityFinalizerTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MINING_END = 1_800_000_000;
    uint256 internal constant LIQUIDITY_RESERVE = 25_000_000_000 * 1e18;
    uint256 internal constant POOL_MINER_PER_ETH = 6_000_000;

    PoolManager internal pm;
    MockMinerTokenF internal minerToken;
    MinerBurner internal burner;
    MockMiningF internal mining;
    MockClaimVaultF internal claimVault;
    MockNftRevenueVaultF internal nftRevenueVault;
    MinerPool internal pool;
    B20LiquidityFinalizer internal finalizer;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        pm = new PoolManager(address(this));
        minerToken = new MockMinerTokenF();
        burner = new MinerBurner(address(minerToken));
        mining = new MockMiningF(MINING_END);
        claimVault = new MockClaimVaultF(address(mining), address(minerToken));
        nftRevenueVault = new MockNftRevenueVaultF();

        (pool, finalizer) = _deploy(address(mining), address(claimVault), address(nftRevenueVault));

        // Wire the mocks back to the real finalizer — production achieves
        // this via predicted-address construction (see
        // docs/FINALIZATION_LIQUIDITY_CLAIM_V1.md §7).
        mining.setLiquidityVault(address(finalizer));
        claimVault.setFinalizer(address(finalizer));
        nftRevenueVault.setLiquidityRecipient(address(finalizer));
    }

    /// @dev The pool first, naming the finalizer's predicted address (as the
    /// deploy script does), then the finalizer.
    function _deploy(address mining_, address claimVault_, address nftRevenueVault_)
        internal
        returns (MinerPool p, B20LiquidityFinalizer f)
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        p = new MinerPool(address(pm), address(minerToken), address(burner), predicted);
        f = new B20LiquidityFinalizer(address(minerToken), mining_, claimVault_, nftRevenueVault_, address(p));
        assertEq(address(f), predicted);
    }

    function _fundMiner(uint256 amount) internal {
        minerToken.transfer(address(finalizer), amount);
    }

    function _sendEthAsMining(uint256 amount) internal {
        vm.deal(address(mining), amount);
        vm.prank(address(mining));
        (bool ok,) = address(finalizer).call{value: amount}("");
        require(ok, "test: mining ETH send failed");
    }

    function _prepare(uint256 ethAmount) internal {
        _fundMiner(LIQUIDITY_RESERVE);
        _sendEthAsMining(ethAmount);
        vm.warp(MINING_END);
    }

    function _price() internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(pm)).getSlot0(pool.poolKey().toId());
    }

    // ---------------------------------------------------------------
    // 1. Constructor
    // ---------------------------------------------------------------

    function test_constructor_rejectsMinerTokenWithNoCode() public {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(B20LiquidityFinalizer.MinerTokenHasNoCode.selector, noCode));
        new B20LiquidityFinalizer(noCode, address(mining), address(claimVault), address(nftRevenueVault), address(pool));
    }

    function test_constructor_rejectsNftRevenueVaultWithNoCode() public {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(B20LiquidityFinalizer.NftRevenueVaultHasNoCode.selector, noCode));
        new B20LiquidityFinalizer(address(minerToken), address(mining), address(claimVault), noCode, address(pool));
    }

    function test_constructor_rejectsZeroMinerPool() public {
        vm.expectRevert(B20LiquidityFinalizer.ZeroMinerPool.selector);
        new B20LiquidityFinalizer(
            address(minerToken), address(mining), address(claimVault), address(nftRevenueVault), address(0)
        );
    }

    function test_constructor_rejectsMinerPoolWithNoCode() public {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(B20LiquidityFinalizer.MinerPoolHasNoCode.selector, noCode));
        new B20LiquidityFinalizer(address(minerToken), address(mining), address(claimVault), address(nftRevenueVault), noCode);
    }

    function test_constructor_rejectsPoolOfAnotherToken() public {
        MockMinerTokenF other = new MockMinerTokenF();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MinerPool p = new MinerPool(address(pm), address(other), address(burner), predicted);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.MinerPoolTokenMismatch.selector, address(other), address(minerToken)
            )
        );
        new B20LiquidityFinalizer(address(minerToken), address(mining), address(claimVault), address(nftRevenueVault), address(p));
    }

    function test_constructor_rejectsPoolThatNamesAnotherFinalizer() public {
        // `pool` names the setUp finalizer as its only `open` caller
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.MinerPoolFinalizerMismatch.selector, address(finalizer), next
            )
        );
        new B20LiquidityFinalizer(
            address(minerToken), address(mining), address(claimVault), address(nftRevenueVault), address(pool)
        );
    }

    // ---------------------------------------------------------------
    // 2. receive()
    // ---------------------------------------------------------------

    function test_receive_acceptsFromMiningAndIncrementsAccounted() public {
        _sendEthAsMining(1 ether);
        assertEq(finalizer.accountedLiquidityEth(), 1 ether);
    }

    function test_receive_acceptsFromNftRevenueVaultAndIncrementsAccounted() public {
        vm.deal(address(nftRevenueVault), 2 ether);
        vm.prank(address(nftRevenueVault));
        (bool ok,) = address(finalizer).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(finalizer.accountedLiquidityEth(), 2 ether);
    }

    function test_receive_rejectsOtherSenders() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(finalizer).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(B20LiquidityFinalizer.UnauthorizedEthSender.selector, stranger));
    }

    function test_receive_rejectsAfterFinalized() public {
        _prepare(1 ether);
        finalizer.finalize();
        vm.deal(address(mining), 1 ether);
        vm.prank(address(mining));
        (bool ok, bytes memory ret) = address(finalizer).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(B20LiquidityFinalizer.AlreadyFinalized.selector));
    }

    // ---------------------------------------------------------------
    // 3. finalize(): timing, wiring, funding
    // ---------------------------------------------------------------

    function test_finalize_rejectsBeforeMiningEnd() public {
        _fundMiner(LIQUIDITY_RESERVE);
        _sendEthAsMining(1 ether);
        vm.warp(MINING_END - 1);
        vm.expectRevert(B20LiquidityFinalizer.TooEarly.selector);
        finalizer.finalize();
    }

    function test_finalize_rejectsSecondCall() public {
        _prepare(1 ether);
        finalizer.finalize();
        vm.expectRevert(B20LiquidityFinalizer.AlreadyFinalized.selector);
        finalizer.finalize();
    }

    function test_finalize_rejectsMiningLiquidityVaultMismatch() public {
        _prepare(1 ether);
        mining.setLiquidityVault(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.MiningLiquidityVaultMismatch.selector, stranger, address(finalizer)
            )
        );
        finalizer.finalize();
    }

    function test_finalize_rejectsClaimVaultMiningMismatch() public {
        _prepare(1 ether);
        claimVault.setMining(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(B20LiquidityFinalizer.ClaimVaultMiningMismatch.selector, stranger, address(mining))
        );
        finalizer.finalize();
    }

    function test_finalize_rejectsClaimVaultFinalizerMismatch() public {
        _prepare(1 ether);
        claimVault.setFinalizer(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.ClaimVaultFinalizerMismatch.selector, stranger, address(finalizer)
            )
        );
        finalizer.finalize();
    }

    function test_finalize_rejectsClaimVaultMinerTokenMismatch() public {
        _prepare(1 ether);
        claimVault.setMinerToken(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.ClaimVaultMinerTokenMismatch.selector, stranger, address(minerToken)
            )
        );
        finalizer.finalize();
    }

    function test_finalize_rejectsNftRevenueVaultLiquidityRecipientMismatch() public {
        _prepare(1 ether);
        nftRevenueVault.setLiquidityRecipient(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.NftRevenueVaultLiquidityRecipientMismatch.selector, stranger, address(finalizer)
            )
        );
        finalizer.finalize();
    }

    function test_finalize_rejectsWhenMiningHasNoCode() public {
        (MinerPool p, B20LiquidityFinalizer f) =
            _deploy(makeAddr("noMining"), address(claimVault), address(nftRevenueVault));
        p;
        vm.expectRevert(B20LiquidityFinalizer.MiningHasNoCode.selector);
        f.finalize();
    }

    function test_finalize_rejectsWhenClaimVaultHasNoCode() public {
        (MinerPool p, B20LiquidityFinalizer f) =
            _deploy(address(mining), makeAddr("noClaimVault"), address(nftRevenueVault));
        p;
        vm.expectRevert(B20LiquidityFinalizer.ClaimVaultHasNoCode.selector);
        f.finalize();
    }

    function test_finalize_rejectsZeroAccountedEth() public {
        _fundMiner(LIQUIDITY_RESERVE);
        vm.warp(MINING_END);
        vm.expectRevert(B20LiquidityFinalizer.NoLiquidityEth.selector);
        finalizer.finalize();
    }

    function test_finalize_rejectsInsufficientMinerFunding() public {
        _fundMiner(LIQUIDITY_RESERVE - 1);
        _sendEthAsMining(1 ether);
        vm.warp(MINING_END);
        vm.expectRevert(
            abi.encodeWithSelector(
                B20LiquidityFinalizer.InsufficientMinerFunding.selector, LIQUIDITY_RESERVE - 1, LIQUIDITY_RESERVE
            )
        );
        finalizer.finalize();
    }

    function test_finalize_forcedEthDoesNotAffectAccountedOrPoolAmount() public {
        _prepare(1 ether);
        EthForcer forcer = new EthForcer();
        vm.deal(address(forcer), 5 ether);
        forcer.forceSend(payable(address(finalizer)));
        assertEq(address(finalizer).balance, 6 ether);
        assertEq(finalizer.accountedLiquidityEth(), 1 ether);

        finalizer.finalize();

        assertEq(finalizer.ethAdded(), 1 ether);
        assertEq(finalizer.minerAdded(), 1 ether * POOL_MINER_PER_ETH);
        assertEq(address(finalizer).balance, 5 ether, "the forced 5 ether stays on the finalizer");
    }

    // ---------------------------------------------------------------
    // 4. NFT revenue
    // ---------------------------------------------------------------

    function test_finalize_includesNftRevenueInLiquidity() public {
        _prepare(1 ether);
        vm.deal(address(nftRevenueVault), 2 ether);
        finalizer.finalize();
        assertEq(nftRevenueVault.distributeCallCount(), 1);
        assertEq(finalizer.ethAdded(), 3 ether);
    }

    function test_finalize_revertsIfNftDistributionFails() public {
        _prepare(1 ether);
        vm.deal(address(nftRevenueVault), 1 ether);
        nftRevenueVault.setShouldRevertOnDistribute(true);
        vm.expectRevert("mock: distribute failure");
        finalizer.finalize();
        assertFalse(finalizer.finalized());
        assertEq(claimVault.finalizeReservesCallCount(), 0);
        assertFalse(pool.opened());
    }

    // ---------------------------------------------------------------
    // 5. The opening: amounts, burn, the pool
    // ---------------------------------------------------------------

    function test_finalize_belowCapOpensThePoolAndBurnsTheRest() public {
        uint256 ethAmount = 100 ether;
        _prepare(ethAmount);
        uint256 supplyBefore = minerToken.totalSupply();

        finalizer.finalize();

        uint256 minerForPool = ethAmount * POOL_MINER_PER_ETH;
        assertEq(finalizer.minerAdded(), minerForPool);
        assertEq(finalizer.ethAdded(), ethAmount);
        assertEq(finalizer.liquidityReserveBurned(), LIQUIDITY_RESERVE - minerForPool);
        assertGt(finalizer.liquidityMinted(), 0);
        assertTrue(finalizer.finalized());
        assertTrue(pool.opened());
        assertEq(_price(), pool.openingSqrtPriceX96(), "1 ETH = 6,000,000 MINER");
        // the reserve's unused part plus the opening's rounding dust: nothing else burned
        assertApproxEqAbs(supplyBefore - minerToken.totalSupply(), LIQUIDITY_RESERVE - minerForPool, 1e12);
        assertApproxEqAbs(minerToken.balanceOf(address(pm)), minerForPool, 1e12);
        assertApproxEqAbs(address(pm).balance, ethAmount, 1e6);
        assertEq(minerToken.balanceOf(address(finalizer)), 0);
        assertEq(address(finalizer).balance, 0);
        assertEq(minerToken.balanceOf(address(pool)), 0);
    }

    function test_finalize_aboveCapUsesTheWholeReserveAndTheRestOfTheEthIsBuySupport() public {
        uint256 ethAmount = 5_000 ether; // more than 25B / 6M ≈ 4,166.67 ETH
        _prepare(ethAmount);
        finalizer.finalize();
        assertEq(finalizer.minerAdded(), LIQUIDITY_RESERVE);
        assertEq(finalizer.liquidityReserveBurned(), 0);
        assertEq(finalizer.ethAdded(), ethAmount);
        assertEq(_price(), pool.openingSqrtPriceX96(), "the price stays at the opening");
        uint256 inFullRange = LIQUIDITY_RESERVE / POOL_MINER_PER_ETH;
        assertApproxEqRel(pool.totalEthAdded(), ethAmount - inFullRange, 1e12, "the rest went in as buy support");
        assertApproxEqAbs(address(pm).balance, ethAmount, 1e6);
    }

    function test_finalize_callsClaimVaultFinalizeReserves() public {
        _prepare(1 ether);
        finalizer.finalize();
        assertEq(claimVault.finalizeReservesCallCount(), 1);
    }

    function test_finalize_claimVaultFailureRevertsEverything() public {
        _prepare(1 ether);
        claimVault.setShouldRevertOnFinalizeReserves(true);
        uint256 supplyBefore = minerToken.totalSupply();
        vm.expectRevert("mock: finalizeReserves failure");
        finalizer.finalize();
        assertFalse(finalizer.finalized());
        assertFalse(pool.opened());
        assertEq(minerToken.totalSupply(), supplyBefore);
    }

    function test_finalize_neverApprovesAnyone() public {
        _prepare(1 ether);
        finalizer.finalize();
        assertEq(minerToken.allowance(address(finalizer), address(pool)), 0);
        assertEq(minerToken.allowance(address(finalizer), address(pm)), 0);
    }

    function test_finalize_poolKeyInitializedByAStrangerDoesNotBlock() public {
        _prepare(10 ether);
        pm.initialize(pool.poolKey(), TickMath.getSqrtPriceAtTick(-120_000));
        finalizer.finalize();
        assertTrue(finalizer.finalized());
        assertEq(_price(), pool.openingSqrtPriceX96(), "moved back to the opening price");
    }

    function test_finalize_onlyTheFinalizerOpensThePool() public {
        minerToken.transfer(address(pool), 6_000_000e18);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MinerPool.NotFinalizer.selector, stranger));
        pool.open{value: 1 ether}(6_000_000e18);
    }

    function test_finalize_reentrancyIsBlocked() public {
        ReentrantNftRevenueVaultF attacker = new ReentrantNftRevenueVaultF();
        (MinerPool p2, B20LiquidityFinalizer f2) = _deploy(address(mining), address(claimVault), address(attacker));
        p2;
        mining.setLiquidityVault(address(f2));
        claimVault.setFinalizer(address(f2));
        attacker.setLiquidityRecipient(address(f2));
        attacker.setTarget(f2);

        minerToken.transfer(address(f2), LIQUIDITY_RESERVE);
        vm.deal(address(mining), 1 ether);
        vm.prank(address(mining));
        (bool ok,) = address(f2).call{value: 1 ether}("");
        require(ok, "funding failed");
        vm.deal(address(attacker), 1 ether);
        vm.warp(MINING_END);

        f2.finalize();

        assertEq(attacker.reentryAttempts(), 1);
        assertTrue(attacker.reentryReverted());
        assertTrue(f2.finalized());
    }

    function test_finalize_excessMinerDonationNotIncludedInBurnOrPool() public {
        uint256 ethAmount = 100 ether;
        _fundMiner(LIQUIDITY_RESERVE);
        uint256 donation = 999 * 1e18;
        minerToken.transfer(address(finalizer), donation);
        _sendEthAsMining(ethAmount);
        vm.warp(MINING_END);

        finalizer.finalize();

        uint256 expectedMinerForPool = ethAmount * POOL_MINER_PER_ETH;
        assertEq(finalizer.minerAdded(), expectedMinerForPool);
        assertEq(finalizer.liquidityReserveBurned(), LIQUIDITY_RESERVE - expectedMinerForPool);
        assertEq(minerToken.balanceOf(address(finalizer)), donation, "the donation stays untouched");
    }
}
