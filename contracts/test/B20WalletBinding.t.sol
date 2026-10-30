// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {B20WalletBinding} from "../src/B20WalletBinding.sol";

/// @notice A contract with no receive/fallback, used to make the treasury
/// transfer fail on purpose in the revert test below.
contract RejectingTreasury {}

/// @notice A treasury that tries to re-enter `activate` while receiving
/// the fee.
contract ReenteringTreasury {
    B20WalletBinding public binding;

    function set(B20WalletBinding binding_) external {
        binding = binding_;
    }

    receive() external payable {
        binding.activate{value: msg.value}();
    }
}

/// @notice B20WalletBinding (v5): an owner wallet pays the activation fee
/// once; after that any mining wallet may mine for it.
contract B20WalletBindingTest is Test {
    uint256 internal constant ACTIVATION_FEE = 416_666_666_666_667;
    bytes32 internal constant SNAPSHOT_ROOT = 0xa5ebaa9d888946e87b9926ce7ed11e88169a7c9885c55d582f97de045f432e20;

    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");
    address internal treasury = makeAddr("treasury");
    address internal browserWallet = makeAddr("browserWallet");
    address internal cliWallet = makeAddr("cliWallet");

    B20WalletBinding internal binding;

    function setUp() public {
        binding = new B20WalletBinding(treasury, SNAPSHOT_ROOT, ACTIVATION_FEE);
        vm.deal(ownerA, 10 ether);
        vm.deal(ownerB, 10 ether);
    }

    function _activate(address ownerWallet) internal {
        vm.prank(ownerWallet);
        binding.activate{value: ACTIVATION_FEE}();
    }

    function test_constructor_setsImmutablesAndRejectsZeros() public {
        assertEq(binding.ACTIVATION_FEE(), ACTIVATION_FEE);
        assertEq(binding.operationsTreasury(), treasury);
        assertEq(binding.snapshotRoot(), SNAPSHOT_ROOT);
        vm.expectRevert(B20WalletBinding.ZeroActivationFee.selector);
        new B20WalletBinding(treasury, SNAPSHOT_ROOT, 0);
        vm.expectRevert(B20WalletBinding.ZeroTreasury.selector);
        new B20WalletBinding(address(0), SNAPSHOT_ROOT, ACTIVATION_FEE);
        vm.expectRevert(B20WalletBinding.ZeroSnapshotRoot.selector);
        new B20WalletBinding(treasury, bytes32(0), ACTIVATION_FEE);
    }

    function test_activate_paysOnceAndForwardsTheFee() public {
        vm.expectEmit(true, false, false, true, address(binding));
        emit B20WalletBinding.Activated(ownerA, ACTIVATION_FEE);
        _activate(ownerA);
        assertTrue(binding.isActivated(ownerA));
        assertEq(treasury.balance, ACTIVATION_FEE, "the fee goes to the treasury in full");
        assertEq(address(binding).balance, 0, "the binding never holds ETH");
    }

    function test_activate_twiceReverts() public {
        _activate(ownerA);
        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(B20WalletBinding.AlreadyActivated.selector, ownerA));
        binding.activate{value: ACTIVATION_FEE}();
    }

    function test_activate_wrongFeeReverts() public {
        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(B20WalletBinding.IncorrectActivationFee.selector, ACTIVATION_FEE - 1, ACTIVATION_FEE));
        binding.activate{value: ACTIVATION_FEE - 1}();
        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(B20WalletBinding.IncorrectActivationFee.selector, 0, ACTIVATION_FEE));
        binding.activate();
        assertFalse(binding.isActivated(ownerA));
    }

    function test_activate_revertsWhenTreasuryRejectsEth() public {
        B20WalletBinding rejecting = new B20WalletBinding(address(new RejectingTreasury()), SNAPSHOT_ROOT, ACTIVATION_FEE);
        vm.prank(ownerA);
        vm.expectRevert(B20WalletBinding.TreasuryTransferFailed.selector);
        rejecting.activate{value: ACTIVATION_FEE}();
        assertFalse(rejecting.isActivated(ownerA));
    }

    function test_activate_isNotReenterable() public {
        ReenteringTreasury evil = new ReenteringTreasury();
        B20WalletBinding guarded = new B20WalletBinding(address(evil), SNAPSHOT_ROOT, ACTIVATION_FEE);
        evil.set(guarded);
        vm.prank(ownerA);
        vm.expectRevert(B20WalletBinding.TreasuryTransferFailed.selector);
        guarded.activate{value: ACTIVATION_FEE}();
        assertFalse(guarded.isActivated(address(evil)));
    }

    function test_beforeActivation_noMiningWalletMayMine() public view {
        assertFalse(binding.isActiveBinding(ownerA, browserWallet));
        assertFalse(binding.isActiveBinding(ownerA, cliWallet));
        assertFalse(binding.isActivated(ownerA));
    }

    function test_afterActivation_anyMiningWalletMayMine_withoutRegistration() public {
        _activate(ownerA);
        assertTrue(binding.isActiveBinding(ownerA, browserWallet));
        assertTrue(binding.isActiveBinding(ownerA, cliWallet), "a CLI wallet mines with no extra step");
        assertTrue(binding.isActiveBinding(ownerA, ownerB), "even someone else's wallet may mine for ownerA");
        assertFalse(binding.isActiveBinding(ownerA, address(0)));
        assertFalse(binding.isActiveBinding(ownerB, browserWallet), "activation is per owner wallet");
    }

    function test_twoOwners_eachPayOnce_oneMiningWalletServesBoth() public {
        _activate(ownerA);
        _activate(ownerB);
        assertEq(treasury.balance, 2 * ACTIVATION_FEE);
        assertTrue(binding.isActiveBinding(ownerA, browserWallet));
        assertTrue(binding.isActiveBinding(ownerB, browserWallet));
    }

    function testFuzz_activationIsPerOwner(address someone, address miningWallet) public {
        vm.assume(someone != ownerA && miningWallet != address(0));
        _activate(ownerA);
        assertTrue(binding.isActiveBinding(ownerA, miningWallet));
        assertEq(binding.isActiveBinding(someone, miningWallet), binding.isActivated(someone));
        assertFalse(binding.isActivated(someone));
    }
}
