// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "base-std-test/lib/BaseTest.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {DeployB20Genesis} from "../script/DeployB20Genesis.s.sol";
import {B20NativeAssetConfig} from "../src/libraries/B20NativeAssetConfig.sol";

contract DeploymentHarness is DeployB20Genesis {
    function validateForTest(Config calldata config) external view {
        _validateEnvironment(config, address(this));
    }

    function deployForTest(Config calldata config) external returns (Deployment memory deployment, uint256 firstNonce) {
        _validateEnvironment(config, address(this));
        firstNonce = vm.getNonce(address(this));
        deployment = _deploy(config, address(this), firstNonce);
        _verifyDeployment(deployment, address(this), config);
    }

    function jsonForTest(Deployment memory deployment, Config calldata config, uint256 firstNonce)
        external
        view
        returns (string memory)
    {
        return _deploymentJson(deployment, address(this), config, firstNonce);
    }

    function _afterNativeFactoryCreate(address deployer, uint256 nextNonce) internal override {
        vm.setNonce(deployer, uint64(nextNonce));
    }
}

contract B20DeploymentScriptTest is BaseTest {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    /// @notice Uniswap's V4 PoolManager on Base Sepolia (MINER's pool, 30 Oct 2026).
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    DeploymentHarness internal harness;
    DeployB20Genesis.Config internal config;

    function setUp() public override {
        super.setUp();
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.warp(1_800_000_000);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(makeAddr("poolManagerOwner")), POOL_MANAGER);
        harness = new DeploymentHarness();
        config = DeployB20Genesis.Config({
            expectedDeployer: address(harness),
            operationsTreasury: makeAddr("operationsTreasury"),
            ecosystemManager: makeAddr("ecosystemManager"),
            teamBeneficiary: makeAddr("teamBeneficiary"),
            nftOperationsRecipient: makeAddr("nftOperationsRecipient"),
            tgeTimestamp: block.timestamp + 1 days,
            miningOpener: makeAddr("miningOpener"),
            openDeadline: block.timestamp + 30 days,
            ethUsdPriceCents: 240_000,
            activationFee: 416_666_666_666_667
        });
    }

    function test_deploysExactOrderWiringAnd100BDistribution() public {
        (DeployB20Genesis.Deployment memory d, uint256 firstNonce) = harness.deployForTest(config);

        assertEq(address(d.token), B20NativeAssetConfig.predictedToken(address(harness)));
        assertEq(address(d.finalizer), vm.computeCreateAddress(address(harness), firstNonce + 8));
        assertEq(address(d.mining), vm.computeCreateAddress(address(harness), firstNonce + 9));
        assertEq(address(d.claimVault), vm.computeCreateAddress(address(harness), firstNonce + 10));
        assertEq(address(d.burner), vm.computeCreateAddress(address(harness), firstNonce + 11));
        assertEq(address(d.communityVault), vm.computeCreateAddress(address(harness), firstNonce + 12));
        // Every ordinary CREATE is accounted for: the community vault is the last (+12).
        assertEq(vm.getNonce(address(harness)), firstNonce + 13);

        // Final mining economics are baked in, not configurable.
        assertEq(d.mining.POW_TARGET(), type(uint256).max >> 24);
        assertEq(d.mining.POW_TARGET(), harness.PRODUCTION_POW_TARGET());
        assertEq(d.mining.REWARD_PER_PROOF(), 312.5e18);
        assertEq(d.mining.MINING_FEE_PER_PROOF(), 26_041_666_666_667);

        assertEq(d.token.totalSupply(), 100_000_000_000 * 1e18);
        assertEq(d.token.balanceOf(address(harness)), 0);
        // B20_REVENUE_MODEL.md 1.36: 61B claim (60B snapshot + 1B NFT), 25B
        // liquidity, 5B ecosystem, 1B team, 8B community rewards.
        assertEq(d.token.balanceOf(address(d.claimVault)), 61_000_000_000 * 1e18);
        assertEq(d.token.balanceOf(address(d.finalizer)), 25_000_000_000 * 1e18);
        assertEq(d.token.balanceOf(address(d.ecosystemVault)), 5_000_000_000 * 1e18);
        assertEq(d.token.balanceOf(address(d.teamVesting)), 1_000_000_000 * 1e18);
        assertEq(d.token.balanceOf(address(d.communityVault)), 8_000_000_000 * 1e18);
        assertEq(d.token.balanceOf(address(d.burner)), 0);
        assertEq(d.mining.NFT_QUOTA_CAP(), 1_000_000_000 * 1e18);
        assertEq(d.token.supplyCap(), 100_000_000_000 * 1e18);
        assertEq(d.token.multiplier(), 1e18);
        assertFalse(d.token.hasRole(B20Constants.DEFAULT_ADMIN_ROLE, address(harness)));
        assertFalse(d.token.hasRole(B20Constants.MINT_ROLE, address(harness)));
        assertTrue(d.token.hasRole(B20Constants.BURN_ROLE, address(d.claimVault)));
        assertTrue(d.token.hasRole(B20Constants.BURN_ROLE, address(d.finalizer)));
        assertTrue(d.token.hasRole(B20Constants.BURN_ROLE, address(d.burner)));
        assertFalse(d.token.hasRole(B20Constants.BURN_ROLE, address(d.communityVault)));
        assertEq(address(d.burner.MINER()), address(d.token));
        assertEq(address(d.communityVault.BURNER()), address(d.burner));
        assertEq(address(d.communityVault.CLAIM_VAULT()), address(d.claimVault));
        assertEq(d.communityVault.MANAGER(), config.ecosystemManager);

        assertEq(address(d.finalizer.mining()), address(d.mining));
        assertEq(address(d.finalizer.claimVault()), address(d.claimVault));
        assertEq(address(d.claimVault.finalizer()), address(d.finalizer));
        assertEq(address(d.claimVault.mining()), address(d.mining));
        assertEq(d.nftRevenueVault.liquidityRecipient(), address(d.finalizer));
        assertEq(address(d.eligibleNFT.mining()), address(d.mining));
        assertEq(address(d.publicNFT.mining()), address(d.mining));
        assertEq(d.mining.MINING_OPENER(), config.miningOpener);
        assertEq(d.mining.OPEN_DEADLINE(), config.openDeadline);
        assertFalse(d.mining.miningOpened());
        assertEq(d.walletBinding.ACTIVATION_FEE(), 416_666_666_666_667);
    }

    /// $1 at the deploy-time ETH price, in cents, rounded up to the wei.
    function test_activationFeeIsOneDollarAtDeployPrice() public view {
        assertEq(harness.activationFeeFor(240_000), 416_666_666_666_667); // $2,400.00
        assertEq(harness.activationFeeFor(400_000), 250_000_000_000_000); // $4,000.00
        assertEq(harness.activationFeeFor(333_333), 300_000_300_000_301); // $3,333.33
    }

    /// A price typed in dollars instead of cents (or with extra digits) is
    /// rejected rather than producing a 100x fee.
    function test_activationFeeRejectsImplausiblePrice() public {
        vm.expectRevert(abi.encodeWithSelector(DeployB20Genesis.EthUsdPriceOutOfRange.selector, 2_400));
        harness.activationFeeFor(2_400);
        vm.expectRevert(abi.encodeWithSelector(DeployB20Genesis.EthUsdPriceOutOfRange.selector, 240_000_000));
        harness.activationFeeFor(240_000_000);
    }

    function test_generatedJsonCarriesEveryManifestAddressAndNoSecret() public {
        (DeployB20Genesis.Deployment memory d, uint256 firstNonce) = harness.deployForTest(config);
        string memory json = harness.jsonForTest(d, config, firstNonce);

        assertEq(vm.parseJsonUint(json, ".chainId"), BASE_SEPOLIA_CHAIN_ID);
        assertEq(vm.parseJsonUint(json, ".schemaVersion"), 2);
        assertEq(vm.parseJsonString(json, ".tokenStandard.id"), "base-native-b20-asset");
        assertEq(vm.parseJsonAddress(json, ".tokenStandard.factory"), StdPrecompiles.B20_FACTORY_ADDRESS);
        assertEq(vm.parseJsonAddress(json, ".contracts.b20Token"), address(d.token));
        assertEq(vm.parseJsonAddress(json, ".contracts.b20Mining"), address(d.mining));
        assertEq(vm.parseJsonAddress(json, ".contracts.b20ClaimVault"), address(d.claimVault));
        assertEq(vm.parseJsonAddress(json, ".contracts.b20LiquidityFinalizer"), address(d.finalizer));
        assertEq(vm.parseJsonAddress(json, ".parameters.miningOpener"), config.miningOpener);
        assertEq(vm.parseJsonUint(json, ".parameters.miningOpenDeadline"), config.openDeadline);
        assertEq(vm.parseJsonString(json, ".network"), "base-sepolia");
        // Base Sepolia runs the whole cycle in 2 days (owner, 30 October 2026)
        assertEq(vm.parseJsonUint(json, ".parameters.miningDurationSeconds"), 1 days);
        assertEq(vm.parseJsonUint(json, ".parameters.claimPeriodSeconds"), 1 days);
        assertEq(vm.parseJsonUint(json, ".parameters.ethUsdPriceCentsAtDeploy"), 240_000);
        assertEq(vm.parseJsonUint(json, ".parameters.activationFeeWei"), 416_666_666_666_667);
        assertEq(vm.parseJsonBytes32(json, ".parameters.powTarget"), bytes32(type(uint256).max >> 24));
        assertEq(vm.parseJsonUint(json, ".parameters.powLeadingZeroBits"), 24);
        assertEq(vm.parseJsonUint(json, ".parameters.rewardPerProofWei"), 312.5e18);
        assertEq(vm.parseJsonUint(json, ".parameters.minerPerEth"), 12_000_000);
        assertEq(vm.parseJsonUint(json, ".parameters.poolMinerPerEth"), 6_000_000);
        assertEq(vm.parseJsonString(json, ".parameters.bindingModel"), "activate-once-open-mining");
        assertFalse(_contains(json, "b20MiningCostQuote"));
        assertFalse(_contains(json, "PRIVATE_KEY"));
    }

    function test_rejectsWrongChainBeforeDeployment() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployB20Genesis.UnsupportedChain.selector, 1));
        harness.validateForTest(config);
    }

    /// The same script on Base: the mainnet PoolManager, 15-day windows and
    /// a `base` record (owner, 30 October 2026: one script for both networks).
    function test_sameScriptDeploysOnBaseMainnet() public {
        vm.chainId(8_453);
        address mainnetPm = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(makeAddr("poolManagerOwner")), mainnetPm);
        (DeployB20Genesis.Deployment memory d, uint256 firstNonce) = harness.deployForTest(config);
        assertEq(address(d.minerPool.POOL_MANAGER()), mainnetPm);
        assertEq(d.mining.MINING_DURATION(), 15 days);
        assertEq(d.claimVault.CLAIM_PERIOD(), 15 days);
        string memory json = harness.jsonForTest(d, config, firstNonce);
        assertEq(vm.parseJsonString(json, ".network"), "base");
        assertEq(vm.parseJsonUint(json, ".chainId"), 8_453);
        assertEq(vm.parseJsonUint(json, ".parameters.miningDurationSeconds"), 15 days);
    }

    function test_baseMainnetNeedsItsOwnPoolManager() public {
        vm.chainId(8_453);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployB20Genesis.MissingDependencyCode.selector, 0x498581fF718922c3f8e6A244956aF099B2652b2b
            )
        );
        harness.validateForTest(config);
    }

    function test_rejectsPastOpenDeadlineBeforeDeployment() public {
        config.openDeadline = block.timestamp;
        vm.expectRevert();
        harness.validateForTest(config);
    }

    function test_rejectsMissingDependencyCodeBeforeDeployment() public {
        vm.etch(POOL_MANAGER, "");
        vm.expectRevert(abi.encodeWithSelector(DeployB20Genesis.MissingDependencyCode.selector, POOL_MANAGER));
        harness.validateForTest(config);
    }

    function test_rejectsMissingNativeB20FactoryBeforeDeployment() public {
        // base-forge refuses to etch over a precompile, so the factory read
        // is made to fail instead, as it does on a chain without the factory.
        vm.mockCallRevert(
            StdPrecompiles.B20_FACTORY_ADDRESS, abi.encodeWithSelector(IB20Factory.getB20Address.selector), ""
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployB20Genesis.NativeB20FactoryUnavailable.selector, StdPrecompiles.B20_FACTORY_ADDRESS
            )
        );
        harness.validateForTest(config);
    }

    function test_nativeAssetRejectsUnauthorizedUserBurnAndMint() public {
        (DeployB20Genesis.Deployment memory d,) = harness.deployForTest(config);
        address user = makeAddr("nativeB20User");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IB20.AccessControlUnauthorizedAccount.selector, user, B20Constants.BURN_ROLE)
        );
        d.token.burn(1);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IB20.AccessControlUnauthorizedAccount.selector, user, B20Constants.MINT_ROLE)
        );
        d.token.mint(user, 1);
    }

    function test_rejectsUnexpectedDeployerSender() public {
        config.expectedDeployer = makeAddr("differentDeployer");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployB20Genesis.UnexpectedDeployer.selector, config.expectedDeployer, address(harness)
            )
        );
        harness.validateForTest(config);
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory haystack = bytes(value);
        bytes memory wanted = bytes(needle);
        if (wanted.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - wanted.length; i++) {
            bool matches = true;
            for (uint256 j = 0; j < wanted.length; j++) {
                if (haystack[i + j] != wanted[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}
