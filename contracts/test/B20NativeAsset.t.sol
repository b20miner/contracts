// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "base-std-test/lib/BaseTest.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {B20NativeAssetConfig} from "../src/libraries/B20NativeAssetConfig.sol";

/// @notice Production-configuration tests for the Base-native MINER B20 Asset.
/// These run against base-std's reference precompiles under ordinary Forge and
/// can also run against live Base precompiles in the base-anvil workflow.
contract B20NativeAssetTest is BaseTest {
    uint256 internal constant TOTAL_SUPPLY = 100_000_000_000 * 1e18;
    // B20_REVENUE_MODEL.md 1.36: 60B snapshot + 1B NFT, 25B liquidity,
    // 5B ecosystem, 1B team, 8B community rewards.
    uint256 internal constant CLAIM_RESERVE = 61_000_000_000 * 1e18;
    uint256 internal constant LIQUIDITY_RESERVE = 25_000_000_000 * 1e18;
    uint256 internal constant ECOSYSTEM_RESERVE = 5_000_000_000 * 1e18;
    uint256 internal constant TEAM_RESERVE = 1_000_000_000 * 1e18;
    uint256 internal constant COMMUNITY_RESERVE = 8_000_000_000 * 1e18;

    address internal claimVault;
    address internal liquidityFinalizer;
    address internal ecosystemVault;
    address internal teamVesting;
    address internal communityVault;
    address internal burner;
    IB20Asset internal token;

    function setUp() public override {
        super.setUp();
        claimVault = makeAddr("claimVault");
        liquidityFinalizer = makeAddr("liquidityFinalizer");
        ecosystemVault = makeAddr("ecosystemVault");
        teamVesting = makeAddr("teamVesting");
        communityVault = makeAddr("communityVault");
        burner = makeAddr("burner");

        token = B20NativeAssetConfig.create(address(this), _reserves());
    }

    function _reserves() internal view returns (B20NativeAssetConfig.Reserves memory) {
        return B20NativeAssetConfig.Reserves({
            claimVault: claimVault,
            liquidityFinalizer: liquidityFinalizer,
            ecosystemVault: ecosystemVault,
            teamVesting: teamVesting,
            communityVault: communityVault,
            burner: burner
        });
    }

    function test_exactIdentitySupplyAndDeterministicAddress() public view {
        assertEq(address(token), B20NativeAssetConfig.predictedToken(address(this)));
        assertTrue(StdPrecompiles.B20_FACTORY.isB20Initialized(address(token)));
        assertEq(token.name(), "B20MINER");
        assertEq(token.symbol(), "MINER");
        assertEq(token.decimals(), 18);
        assertEq(token.supplyCap(), TOTAL_SUPPLY);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        // multiplier() is the canonical name. Cobalt (live on both Base
        // networks since 30 Sep 2026) added the ERC-8056 alias uiMultiplier()
        // and the pending-schedule reads; they are not asserted while the
        // local base-forge v1.1.0 runs the Beryl precompile (see
        // B20NativeAssetConfig.verifyConfiguration's comment).
        assertEq(token.multiplier(), 1e18);
    }

    function test_exactFiveWayDistribution() public view {
        assertEq(token.balanceOf(claimVault), CLAIM_RESERVE);
        assertEq(token.balanceOf(liquidityFinalizer), LIQUIDITY_RESERVE);
        assertEq(token.balanceOf(ecosystemVault), ECOSYSTEM_RESERVE);
        assertEq(token.balanceOf(teamVesting), TEAM_RESERVE);
        assertEq(token.balanceOf(communityVault), COMMUNITY_RESERVE);
        assertEq(token.balanceOf(burner), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(CLAIM_RESERVE + LIQUIDITY_RESERVE + ECOSYSTEM_RESERVE + TEAM_RESERVE + COMMUNITY_RESERVE, TOTAL_SUPPLY);
    }

    function test_onlyReserveBurnersHoldAnyProductionRole() public view {
        assertTrue(token.hasRole(B20Constants.BURN_ROLE, claimVault));
        assertTrue(token.hasRole(B20Constants.BURN_ROLE, liquidityFinalizer));
        assertTrue(token.hasRole(B20Constants.BURN_ROLE, burner));

        bytes32[9] memory forbiddenRoles = [
            B20Constants.DEFAULT_ADMIN_ROLE,
            B20Constants.MINT_ROLE,
            B20Constants.BURN_BLOCKED_ROLE,
            B20Constants.SEIZE_ROLE,
            B20Constants.PAUSE_ROLE,
            B20Constants.UNPAUSE_ROLE,
            B20Constants.METADATA_ROLE,
            B20Constants.OPERATOR_ROLE,
            keccak256("UNUSED_SENTINEL_ROLE")
        ];
        address[7] memory accounts =
            [address(this), claimVault, liquidityFinalizer, ecosystemVault, teamVesting, communityVault, burner];

        for (uint256 i; i < accounts.length; i++) {
            for (uint256 j; j < forbiddenRoles.length; j++) {
                assertFalse(token.hasRole(forbiddenRoles[j], accounts[i]));
            }
        }
        assertFalse(token.hasRole(B20Constants.BURN_ROLE, address(this)));
        assertFalse(token.hasRole(B20Constants.BURN_ROLE, ecosystemVault));
        assertFalse(token.hasRole(B20Constants.BURN_ROLE, teamVesting));
        assertFalse(token.hasRole(B20Constants.BURN_ROLE, communityVault));
    }

    function test_allPoliciesRemainAlwaysAllowDefaults() public view {
        // The four Beryl-era policy scopes are always dialable — a revert
        // here is a genuine failure, never tolerated.
        assertEq(token.policyId(B20Constants.TRANSFER_SENDER_POLICY), 0);
        assertEq(token.policyId(B20Constants.TRANSFER_RECEIVER_POLICY), 0);
        assertEq(token.policyId(B20Constants.TRANSFER_EXECUTOR_POLICY), 0);
        assertEq(token.policyId(B20Constants.MINT_RECEIVER_POLICY), 0);

        // SEIZE_EXEMPT_POLICY/SEIZE_RECEIVER_POLICY came with Cobalt
        // (changelog/02_Cobalt_B20_seize.md; live on Base Sepolia since
        // 23 Sep 2026 and Base mainnet since 30 Sep 2026): both must read
        // exactly `0`. The shared helper still tolerates only the official
        // `IB20.UnsupportedPolicyType` revert of the Beryl-only local
        // precompile (`base-forge test` v1.1.0); anything else
        // propagates as `NativeB20UnexpectedPolicyRevert` and fails loudly.
        _assertSeizePolicyIsZeroWhereSupported(B20Constants.SEIZE_EXEMPT_POLICY);
        _assertSeizePolicyIsZeroWhereSupported(B20Constants.SEIZE_RECEIVER_POLICY);
    }

    function _assertSeizePolicyIsZeroWhereSupported(bytes32 policyScope) internal view {
        (bool isSupported, uint64 value) = B20NativeAssetConfig._readPolicyIdIfSupported(token, policyScope);
        if (isSupported) {
            assertEq(value, 0, "a supported Cobalt seize policy must default to 0");
        }
    }

    function test_standardTransferApproveAndTransferFromRemainCompatible() public {
        uint256 transferred = 100 ether;
        vm.prank(claimVault);
        assertTrue(token.transfer(alice, transferred));
        assertEq(token.balanceOf(alice), transferred);

        vm.prank(alice);
        assertTrue(token.approve(bob, 40 ether));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, ecosystemVault, 40 ether));

        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(ecosystemVault), ECOSYSTEM_RESERVE + 40 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_authorizedReserveContractsBurnOnlyTheirOwnBalances() public {
        vm.prank(claimVault);
        token.burn(11 ether);
        vm.prank(liquidityFinalizer);
        token.burn(13 ether);

        assertEq(token.balanceOf(claimVault), CLAIM_RESERVE - 11 ether);
        assertEq(token.balanceOf(liquidityFinalizer), LIQUIDITY_RESERVE - 13 ether);
        assertEq(token.totalSupply(), TOTAL_SUPPLY - 24 ether);
    }

    function test_userCannotBurnOrMint() public {
        vm.prank(claimVault);
        token.transfer(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IB20.AccessControlUnauthorizedAccount.selector, alice, B20Constants.BURN_ROLE)
        );
        token.burn(1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IB20.AccessControlUnauthorizedAccount.selector, alice, B20Constants.MINT_ROLE)
        );
        token.mint(alice, 1 ether);
    }

    function test_noOneCanReconfigureMetadataMultiplierPolicyPauseOrSeizure() public {
        vm.startPrank(attacker);

        vm.expectRevert();
        token.updateName("ATTACK");
        vm.expectRevert();
        token.updateUIMultiplier(2e18, block.timestamp + 1 days);
        vm.expectRevert();
        token.updatePolicy(B20Constants.TRANSFER_SENDER_POLICY, 1);

        IB20.PausableFeature[] memory features = new IB20.PausableFeature[](1);
        features[0] = IB20.PausableFeature.TRANSFER;
        vm.expectRevert();
        token.pause(features);

        vm.expectRevert();
        token.seizeWithMemo(claimVault, attacker, 1 ether, bytes32(0));
        vm.stopPrank();

        assertEq(token.name(), "B20MINER");
        assertEq(token.multiplier(), 1e18);
        assertEq(token.policyId(B20Constants.TRANSFER_SENDER_POLICY), 0);
        assertEq(token.pausedFeatures().length, 0);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_libraryPostCreationVerifierAcceptsCanonicalState() public view {
        B20NativeAssetConfig.verifyConfiguration(token, address(this), _reserves());
    }
}
