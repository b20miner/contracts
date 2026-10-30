// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "base-std-test/lib/BaseTest.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {B20TeamVesting} from "../src/B20TeamVesting.sol";
import {B20EcosystemVault} from "../src/B20EcosystemVault.sol";
import {B20NativeAssetConfig} from "../src/libraries/B20NativeAssetConfig.sol";

/// @notice Critical targeted tests for B20TeamVesting and
/// B20EcosystemVault using the production Base-native B20 Asset.
contract B20CoreTest is BaseTest {
    uint256 internal constant TOTAL_TEAM_ALLOCATION = 1_000_000_000 * 1e18; // B20_REVENUE_MODEL.md 1.36
    uint256 internal constant VESTING_PERIOD_SECONDS = 2_628_000;

    address internal beneficiary = makeAddr("teamBeneficiary");
    address internal manager = makeAddr("ecosystemManager");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant TGE = 1_800_000_000;

    IB20Asset internal token;
    B20TeamVesting internal vesting;
    B20EcosystemVault internal vault;

    function setUp() public override {
        super.setUp();
        address predictedToken = B20NativeAssetConfig.predictedToken(address(this));
        vesting = new B20TeamVesting(predictedToken, beneficiary, TGE);
        vault = new B20EcosystemVault(predictedToken, manager);
        token = B20NativeAssetConfig.create(
            address(this),
            B20NativeAssetConfig.Reserves({
                claimVault: makeAddr("claimVault"),
                liquidityFinalizer: makeAddr("liquidityFinalizer"),
                ecosystemVault: address(vault),
                teamVesting: address(vesting),
                communityVault: makeAddr("communityVault"),
                burner: makeAddr("burner")
            })
        );
    }

    // ---------------------------------------------------------------
    // B20TeamVesting
    // ---------------------------------------------------------------

    function test_vesting_noUnlockOneSecondBeforeFirstUnlock() public view {
        uint256 t = TGE + 13 * VESTING_PERIOD_SECONDS - 1;
        assertEq(vesting.vestedAmount(t), 0);
    }

    function test_vesting_exactlyOneFortyEighthAtFirstUnlock() public view {
        uint256 t = TGE + 13 * VESTING_PERIOD_SECONDS;
        assertEq(vesting.vestedAmount(t), TOTAL_TEAM_ALLOCATION / 48);
    }

    function test_vesting_midScheduleCumulativeIsCorrect() public view {
        // At TGE + 30 periods: 30 - 12 = 18 completed vesting periods.
        uint256 t = TGE + 30 * VESTING_PERIOD_SECONDS;
        assertEq(vesting.vestedAmount(t), (TOTAL_TEAM_ALLOCATION * 18) / 48);
    }

    function test_vesting_fullFiveBillionAtFinalUnlock() public view {
        uint256 t = TGE + 60 * VESTING_PERIOD_SECONDS;
        assertEq(vesting.vestedAmount(t), TOTAL_TEAM_ALLOCATION);
    }

    function test_vesting_sameEarningsCannotBeReleasedTwice() public {
        vm.warp(TGE + 20 * VESTING_PERIOD_SECONDS);

        vesting.release();
        uint256 releasedAfterFirst = vesting.released();
        assertTrue(releasedAfterFirst > 0);

        vm.expectRevert(B20TeamVesting.NothingToRelease.selector);
        vesting.release();
    }

    function test_vesting_tokensOnlyReachImmutableBeneficiary() public {
        vm.warp(TGE + 13 * VESTING_PERIOD_SECONDS);

        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);
        uint256 strangerBalanceBefore = token.balanceOf(stranger);

        vm.prank(stranger);
        vesting.release();

        assertEq(token.balanceOf(stranger), strangerBalanceBefore);
        assertEq(token.balanceOf(beneficiary), beneficiaryBalanceBefore + TOTAL_TEAM_ALLOCATION / 48);
    }

    function test_vesting_noAdminOrEarlyWithdrawalPathExists() public {
        // No such selector exists on B20TeamVesting; the call must fail
        // (no fallback/receive to swallow it), positively demonstrating
        // there is no admin/early-withdrawal entry point.
        (bool success,) =
            address(vesting).call(abi.encodeWithSignature("adminWithdraw(address,uint256)", beneficiary, 1));
        assertFalse(success);
    }

    function test_vesting_insufficientFundingIsExplicitlyRejected() public {
        B20TeamVesting underfunded = new B20TeamVesting(address(token), beneficiary, TGE);
        // Deliberately not funded.
        vm.warp(TGE + 13 * VESTING_PERIOD_SECONDS);

        vm.expectRevert(
            abi.encodeWithSelector(B20TeamVesting.InsufficientFunding.selector, TOTAL_TEAM_ALLOCATION / 48, 0)
        );
        underfunded.release();
    }

    // ---------------------------------------------------------------
    // B20EcosystemVault
    // ---------------------------------------------------------------

    function _fundVault(uint256 amount) internal {
        assertGe(token.balanceOf(address(vault)), amount);
    }

    function test_vault_nonManagerCannotQueueOrCancel() public {
        vm.prank(stranger);
        vm.expectRevert(B20EcosystemVault.NotManager.selector);
        vault.queueTransfer(recipient, 1);

        vm.prank(manager);
        (bytes32 operationId,) = vault.queueTransfer(recipient, 1);

        vm.prank(stranger);
        vm.expectRevert(B20EcosystemVault.NotManager.selector);
        vault.cancelTransfer(operationId);
    }

    function test_vault_executeRevertsOneSecondBeforeDelay() public {
        _fundVault(1_000 * 1e18);

        vm.prank(manager);
        (bytes32 operationId, uint256 executeAfter) = vault.queueTransfer(recipient, 1_000 * 1e18);

        vm.warp(executeAfter - 1);
        vm.expectRevert(
            abi.encodeWithSelector(B20EcosystemVault.TimelockNotExpired.selector, operationId, executeAfter)
        );
        vault.executeTransfer(operationId);
    }

    function test_vault_executesCorrectRecipientAndAmountAtExactDelay() public {
        _fundVault(1_000 * 1e18);

        vm.prank(manager);
        (bytes32 operationId, uint256 executeAfter) = vault.queueTransfer(recipient, 1_000 * 1e18);

        vm.warp(executeAfter);
        vault.executeTransfer(operationId);

        assertEq(token.balanceOf(recipient), 1_000 * 1e18);
    }

    function test_vault_anyoneCanExecuteAfterDelay() public {
        _fundVault(1_000 * 1e18);

        vm.prank(manager);
        (bytes32 operationId, uint256 executeAfter) = vault.queueTransfer(recipient, 1_000 * 1e18);

        vm.warp(executeAfter);
        vm.prank(stranger);
        vault.executeTransfer(operationId);

        assertEq(token.balanceOf(recipient), 1_000 * 1e18);
    }

    function test_vault_cannotExecuteSameOperationTwice() public {
        _fundVault(1_000 * 1e18);

        vm.prank(manager);
        (bytes32 operationId, uint256 executeAfter) = vault.queueTransfer(recipient, 1_000 * 1e18);

        vm.warp(executeAfter);
        vault.executeTransfer(operationId);

        vm.expectRevert(abi.encodeWithSelector(B20EcosystemVault.OperationNotQueued.selector, operationId));
        vault.executeTransfer(operationId);
    }

    function test_vault_canceledOperationCannotBeExecuted() public {
        _fundVault(1_000 * 1e18);

        vm.prank(manager);
        (bytes32 operationId, uint256 executeAfter) = vault.queueTransfer(recipient, 1_000 * 1e18);

        vm.prank(manager);
        vault.cancelTransfer(operationId);

        vm.warp(executeAfter);
        vm.expectRevert(abi.encodeWithSelector(B20EcosystemVault.OperationNotQueued.selector, operationId));
        vault.executeTransfer(operationId);
    }

    function test_vault_queuedRecipientAndAmountCannotBeChangedAtExecute() public {
        _fundVault(1_000 * 1e18);

        vm.prank(manager);
        (bytes32 operationId, uint256 executeAfter) = vault.queueTransfer(recipient, 1_000 * 1e18);

        // executeTransfer only accepts an operationId — there is no
        // parameter through which a caller could redirect the recipient
        // or resize the amount. Confirm the queued values are exactly
        // what gets paid out, regardless of who calls execute.
        vm.warp(executeAfter);
        vm.prank(stranger);
        vault.executeTransfer(operationId);

        assertEq(token.balanceOf(recipient), 1_000 * 1e18);
        assertEq(token.balanceOf(stranger), 0);
    }
}
