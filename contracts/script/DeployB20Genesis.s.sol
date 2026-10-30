// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";

import {B20WalletBinding} from "../src/B20WalletBinding.sol";
import {B20EcosystemVault} from "../src/B20EcosystemVault.sol";
import {B20TeamVesting} from "../src/B20TeamVesting.sol";
import {B20NFTRevenueVault} from "../src/B20NFTRevenueVault.sol";
import {B20EligibleNFT} from "../src/B20EligibleNFT.sol";
import {B20PublicNFT} from "../src/B20PublicNFT.sol";
import {B20LiquidityFinalizer} from "../src/B20LiquidityFinalizer.sol";
import {B20Mining} from "../src/B20Mining.sol";
import {B20ClaimVault} from "../src/B20ClaimVault.sol";
import {B20CommunityVault} from "../src/B20CommunityVault.sol";
import {MinerBurner} from "../src/MinerBurner.sol";
import {MinerPool} from "../src/MinerPool.sol";
import {B20SnapshotMerkle} from "../src/B20SnapshotMerkle.sol";
import {B20NativeAssetConfig} from "../src/libraries/B20NativeAssetConfig.sol";

/// @notice Deterministic B20MINER genesis script, one for both networks:
/// Base (8453) and Base Sepolia (84532). The chain id picks the PoolManager,
/// the public-inputs file and the record folder; every contract and check
/// is the same, so what runs on the testnet is what runs on mainnet
/// (owner, 30 October 2026). On Base Sepolia the mining and claim windows
/// are 1 day instead of 15 (`B20Mining.MINING_DURATION`,
/// `B20ClaimVault.CLAIM_PERIOD`), chosen by the contracts themselves.
/// @dev `forge script` without `--broadcast` is the intended first step:
/// it simulates every deployment and invariant without spending ETH. A real
/// broadcast is deliberately a separate operator decision. The broadcaster is
/// the canonical public deployer from public-inputs.json; real signing uses
/// Foundry's encrypted keystore (`forge script --account ...`), so this script
/// never reads or writes a raw private key.
contract DeployB20Genesis is Script {
    uint256 internal constant BASE_CHAIN_ID = 8_453;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    /// @notice Final production PoW target: 24 leading zero bits, i.e.
    /// `hash <= 2^232 − 1` (DEPLOYMENT_PARAMETERS.md §1.9). Not an env
    /// input — every deployment uses exactly this value.
    uint256 public constant PRODUCTION_POW_TARGET = type(uint256).max >> 24;
    /// @notice Uniswap's V4 PoolManagers (`MinerPool` pins the same two).
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    struct Config {
        address expectedDeployer;
        address operationsTreasury;
        address ecosystemManager;
        address teamBeneficiary;
        address nftOperationsRecipient;
        uint256 tgeTimestamp;
        address miningOpener;
        uint256 openDeadline;
        uint256 ethUsdPriceCents;
        uint256 activationFee;
    }

    struct Deployment {
        IB20Asset token;
        B20WalletBinding walletBinding;
        MinerPool minerPool;
        B20EcosystemVault ecosystemVault;
        B20TeamVesting teamVesting;
        B20NFTRevenueVault nftRevenueVault;
        B20EligibleNFT eligibleNFT;
        B20PublicNFT publicNFT;
        B20LiquidityFinalizer finalizer;
        B20Mining mining;
        B20ClaimVault claimVault;
        MinerBurner burner;
        B20CommunityVault communityVault;
    }

    error UnsupportedChain(uint256 chainId);
    error WrongPublicInputsChain(uint256 actual, uint256 expected);
    error UnexpectedDeployer(address expected, address actual);
    error ZeroConfigAddress(string field);
    error InvalidTimestamp(string field, uint256 value);
    error EthUsdPriceOutOfRange(uint256 cents);
    error MissingDependencyCode(address dependency);
    error NativeB20FactoryUnavailable(address factory);
    error PredictedAddressMismatch(string contractName, address predicted, address actual);
    error SupplyDistributionMismatch();
    error DeploymentConfigurationMismatch();
    error DeployerRetainedTokens(uint256 balance);

    function run() external returns (Deployment memory deployment) {
        Config memory config = _loadConfig();
        address deployer = config.expectedDeployer;
        _validateEnvironment(config, deployer);

        uint256 firstNonce = vm.getNonce(deployer);
        vm.startBroadcast(deployer);
        deployment = _deploy(config, deployer, firstNonce);
        vm.stopBroadcast();

        _verifyDeployment(deployment, deployer, config);
        string memory outputPath = vm.envOr(
            "DEPLOYMENT_OUTPUT_PATH",
            string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/launch-flow-deployment.json")
        );
        vm.writeJson(_deploymentJson(deployment, deployer, config, firstNonce), outputPath);
        _logDeployment(deployment, outputPath);
    }

    function _loadConfig() internal view returns (Config memory config) {
        string memory publicInputsPath = vm.envOr(
            "PUBLIC_INPUTS_PATH",
            string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/public-inputs.json")
        );
        string memory publicInputs = vm.readFile(publicInputsPath);
        uint256 publicInputsChainId = vm.parseJsonUint(publicInputs, ".chainId");
        if (publicInputsChainId != block.chainid) {
            revert WrongPublicInputsChain(publicInputsChainId, block.chainid);
        }
        config = Config({
            expectedDeployer: vm.parseJsonAddress(publicInputs, ".addresses.deployer"),
            operationsTreasury: vm.parseJsonAddress(publicInputs, ".addresses.operationsTreasury"),
            ecosystemManager: vm.parseJsonAddress(publicInputs, ".addresses.ecosystemManager"),
            teamBeneficiary: vm.parseJsonAddress(publicInputs, ".addresses.teamBeneficiary"),
            nftOperationsRecipient: vm.parseJsonAddress(publicInputs, ".addresses.nftOperationsRecipient"),
            tgeTimestamp: vm.envUint("TGE_TIMESTAMP"),
            miningOpener: vm.envOr("MINING_OPENER", vm.parseJsonAddress(publicInputs, ".addresses.deployer")),
            openDeadline: vm.envUint("MINING_OPEN_DEADLINE"),
            ethUsdPriceCents: vm.envUint("ETH_USD_PRICE_CENTS"),
            activationFee: 0
        });
        config.activationFee = activationFeeFor(config.ethUsdPriceCents);
    }

    /// @notice The activation fee in wei: 1 USD at `ethUsdPriceCents`
    /// (the ETH/USD market price the operator reads at deploy time, in
    /// cents), rounded up to the wei. Example: 2,400.00 USD → 240000 →
    /// 416,666,666,666,667 wei. There is no oracle; the result is fixed in
    /// `B20WalletBinding` for good (`DEPLOYMENT_PARAMETERS.md` §1.3).
    function activationFeeFor(uint256 ethUsdPriceCents) public pure returns (uint256) {
        // 100 USD .. 100,000 USD per ETH: rejects a price typed in dollars
        // instead of cents, or with extra digits.
        if (ethUsdPriceCents < 10_000 || ethUsdPriceCents > 10_000_000) revert EthUsdPriceOutOfRange(ethUsdPriceCents);
        return (100 ether + ethUsdPriceCents - 1) / ethUsdPriceCents;
    }

    /// @notice The record folder and `network` field: `base` or `base-sepolia`.
    function _networkName() internal view returns (string memory) {
        if (block.chainid == BASE_CHAIN_ID) return "base";
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return "base-sepolia";
        revert UnsupportedChain(block.chainid);
    }

    /// @notice Uniswap's V4 PoolManager on this chain.
    function _poolManager() internal view returns (address) {
        if (block.chainid == BASE_CHAIN_ID) return BASE_POOL_MANAGER;
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_POOL_MANAGER;
        revert UnsupportedChain(block.chainid);
    }

    function _validateEnvironment(Config memory config, address actualDeployer) internal view {
        address poolManager = _poolManager(); // reverts on any other chain
        if (config.expectedDeployer == address(0)) revert ZeroConfigAddress("EXPECTED_DEPLOYER");
        if (actualDeployer != config.expectedDeployer) {
            revert UnexpectedDeployer(config.expectedDeployer, actualDeployer);
        }
        if (config.operationsTreasury == address(0)) revert ZeroConfigAddress("OPERATIONS_TREASURY");
        if (config.ecosystemManager == address(0)) revert ZeroConfigAddress("ECOSYSTEM_MANAGER");
        if (config.teamBeneficiary == address(0)) revert ZeroConfigAddress("TEAM_BENEFICIARY");
        if (config.nftOperationsRecipient == address(0)) revert ZeroConfigAddress("NFT_OPERATIONS_RECIPIENT");
        if (config.tgeTimestamp == 0) revert InvalidTimestamp("TGE_TIMESTAMP", config.tgeTimestamp);
        if (config.miningOpener == address(0)) revert ZeroConfigAddress("MINING_OPENER");
        if (config.openDeadline <= block.timestamp) {
            revert InvalidTimestamp("MINING_OPEN_DEADLINE", config.openDeadline);
        }
        _requireCode(poolManager);
        _requireNativeB20Factory(config.expectedDeployer);
    }

    function _requireCode(address dependency) internal view {
        if (dependency.code.length == 0) revert MissingDependencyCode(dependency);
    }

    /// @dev Native precompiles intentionally report no ordinary runtime
    /// bytecode, so code-length is not a valid availability probe. A typed
    /// read with a full return value distinguishes the live Factory from an
    /// empty EVM account.
    function _requireNativeB20Factory(address creator) internal view {
        (bool ok, bytes memory result) = B20NativeAssetConfig.FACTORY_ADDRESS
            .staticcall(
                abi.encodeCall(
                    IB20Factory.getB20Address,
                    (IB20Factory.B20Variant.ASSET, creator, B20NativeAssetConfig.CREATION_SALT)
                )
            );
        if (!ok || result.length < 32 || abi.decode(result, (address)) == address(0)) {
            revert NativeB20FactoryUnavailable(B20NativeAssetConfig.FACTORY_ADDRESS);
        }
    }

    /// @dev `firstNonce` must be the broadcaster's nonce before the first
    /// transaction. The native Factory call consumes offset +0, followed by
    /// twelve ordinary CREATEs at +1…+12: +11 `MinerBurner` and +12
    /// `B20CommunityVault` were added with `B20_REVENUE_MODEL.md` 1.36 (the
    /// token's genesis mints the community reserve to +12 and grants
    /// `BURN_ROLE` to +11). This is consensus-critical for the circular
    /// Finalizer/Mining/ClaimVault wiring and the genesis recipients.
    function _deploy(Config memory config, address deployer, uint256 firstNonce)
        internal
        returns (Deployment memory d)
    {
        // Genesis recipients (+3 ecosystem, +4 team, +8 finalizer, +10 claim
        // vault, +11 burner, +12 community vault) and +9 mining, predicted.
        B20NativeAssetConfig.Reserves memory p = B20NativeAssetConfig.Reserves({
            claimVault: vm.computeCreateAddress(deployer, firstNonce + 10),
            liquidityFinalizer: vm.computeCreateAddress(deployer, firstNonce + 8),
            ecosystemVault: vm.computeCreateAddress(deployer, firstNonce + 3),
            teamVesting: vm.computeCreateAddress(deployer, firstNonce + 4),
            communityVault: vm.computeCreateAddress(deployer, firstNonce + 12),
            burner: vm.computeCreateAddress(deployer, firstNonce + 11)
        });
        address predictedMining = vm.computeCreateAddress(deployer, firstNonce + 9);

        // +0: Base-native B20 Factory call. The full fixed supply is minted
        // directly to the five predicted reserve addresses inside the same
        // atomic bootstrap transaction; the deployer never receives MINER.
        d.token = B20NativeAssetConfig.create(deployer, p);
        _afterNativeFactoryCreate(deployer, firstNonce + 1);
        d.walletBinding = new B20WalletBinding( // +1
            config.operationsTreasury,
            B20SnapshotMerkle.MERKLE_ROOT,
            config.activationFee
        );
        // +2: MINER's V4 pool (B20_REVENUE_MODEL.md §6, 30 October 2026; the
        // V2 LP locker until then); only the predicted finalizer may open it.
        d.minerPool = new MinerPool(_poolManager(), address(d.token), p.burner, p.liquidityFinalizer);
        d.ecosystemVault = new B20EcosystemVault(address(d.token), config.ecosystemManager); // +3
        d.teamVesting = new B20TeamVesting(address(d.token), config.teamBeneficiary, config.tgeTimestamp); // +4

        d.nftRevenueVault = new B20NFTRevenueVault(p.liquidityFinalizer, config.nftOperationsRecipient); // +5
        d.eligibleNFT = new B20EligibleNFT( // +6
            "B20 Eligible NFT",
            "B20E",
            B20SnapshotMerkle.MERKLE_ROOT,
            address(d.nftRevenueVault),
            predictedMining
        );
        d.publicNFT = new B20PublicNFT( // +7
            "B20 Public NFT",
            "B20P",
            address(d.nftRevenueVault),
            predictedMining
        );
        d.finalizer = new B20LiquidityFinalizer( // +8
            address(d.token),
            predictedMining,
            p.claimVault,
            address(d.nftRevenueVault),
            address(d.minerPool)
        );
        d.mining = new B20Mining( // +9
            address(d.walletBinding),
            PRODUCTION_POW_TARGET,
            config.miningOpener,
            config.openDeadline,
            address(d.eligibleNFT),
            address(d.publicNFT),
            address(d.finalizer)
        );
        d.claimVault = new B20ClaimVault(address(d.token), address(d.mining), address(d.finalizer)); // +10
        d.burner = new MinerBurner(address(d.token)); // +11
        d.communityVault = new B20CommunityVault( // +12
            address(d.token),
            address(d.mining),
            address(d.claimVault),
            address(d.burner),
            config.ecosystemManager
        );

        _requirePredicted(d, p, predictedMining);
    }

    function _requirePredicted(Deployment memory d, B20NativeAssetConfig.Reserves memory p, address predictedMining)
        internal
        pure
    {
        if (address(d.finalizer) != p.liquidityFinalizer) {
            revert PredictedAddressMismatch("B20LiquidityFinalizer", p.liquidityFinalizer, address(d.finalizer));
        }
        if (address(d.mining) != predictedMining) {
            revert PredictedAddressMismatch("B20Mining", predictedMining, address(d.mining));
        }
        if (address(d.claimVault) != p.claimVault) {
            revert PredictedAddressMismatch("B20ClaimVault", p.claimVault, address(d.claimVault));
        }
        if (address(d.ecosystemVault) != p.ecosystemVault) {
            revert PredictedAddressMismatch("B20EcosystemVault", p.ecosystemVault, address(d.ecosystemVault));
        }
        if (address(d.teamVesting) != p.teamVesting) {
            revert PredictedAddressMismatch("B20TeamVesting", p.teamVesting, address(d.teamVesting));
        }
        if (address(d.burner) != p.burner) {
            revert PredictedAddressMismatch("MinerBurner", p.burner, address(d.burner));
        }
        if (address(d.communityVault) != p.communityVault) {
            revert PredictedAddressMismatch("B20CommunityVault", p.communityVault, address(d.communityVault));
        }
    }

    /// @dev A real broadcasted EOA call to the native Factory consumes nonce
    /// `firstNonce`. Foundry's script broadcaster models that automatically.
    /// A Solidity test harness calls `_deploy` from a contract, where a plain
    /// external CALL does not consume the caller contract's CREATE nonce; the
    /// test-only override advances it so the harness exercises the real EOA
    /// address sequence. Production keeps this no-op.
    function _afterNativeFactoryCreate(address, uint256) internal virtual {}

    function _verifyDeployment(Deployment memory d, address deployer, Config memory config) internal view {
        B20NativeAssetConfig.verifyConfiguration(d.token, deployer, _reserves(d));
        if (
            d.token.totalSupply() != B20NativeAssetConfig.TOTAL_SUPPLY
                || d.token.balanceOf(address(d.claimVault)) != B20NativeAssetConfig.BASE_AND_NFT_RESERVE
                || d.token.balanceOf(address(d.finalizer)) != B20NativeAssetConfig.LIQUIDITY_RESERVE
                || d.token.balanceOf(address(d.ecosystemVault)) != B20NativeAssetConfig.ECOSYSTEM_RESERVE
                || d.token.balanceOf(address(d.teamVesting)) != B20NativeAssetConfig.TEAM_RESERVE
                || d.token.balanceOf(address(d.communityVault)) != B20NativeAssetConfig.COMMUNITY_RESERVE
        ) revert SupplyDistributionMismatch();
        if (
            address(d.burner.MINER()) != address(d.token) || address(d.communityVault.MINER()) != address(d.token)
                || address(d.communityVault.MINING()) != address(d.mining)
                || address(d.communityVault.CLAIM_VAULT()) != address(d.claimVault)
                || address(d.communityVault.BURNER()) != address(d.burner)
                || d.communityVault.MANAGER() != config.ecosystemManager || d.communityVault.settled()
                || d.mining.NFT_QUOTA_CAP() != d.claimVault.NFT_RESERVE()
        ) revert DeploymentConfigurationMismatch();
        if (d.mining.MINING_DURATION() != _windowFor() || d.claimVault.CLAIM_PERIOD() != _windowFor()) {
            revert DeploymentConfigurationMismatch();
        }
        uint256 deployerBalance = d.token.balanceOf(deployer);
        if (deployerBalance != 0) revert DeployerRetainedTokens(deployerBalance);

        if (
            address(d.finalizer.mining()) != address(d.mining)
                || address(d.finalizer.claimVault()) != address(d.claimVault)
                || address(d.claimVault.mining()) != address(d.mining)
                || address(d.claimVault.finalizer()) != address(d.finalizer)
                || address(d.nftRevenueVault.liquidityRecipient()) != address(d.finalizer)
                || d.walletBinding.operationsTreasury() != config.operationsTreasury
                || d.walletBinding.ACTIVATION_FEE() != config.activationFee
        ) revert DeploymentConfigurationMismatch();

        if (
            d.walletBinding.snapshotRoot() != B20SnapshotMerkle.MERKLE_ROOT
                || address(d.ecosystemVault.TOKEN()) != address(d.token)
                || d.ecosystemVault.MANAGER() != config.ecosystemManager
                || address(d.teamVesting.TOKEN()) != address(d.token)
                || d.teamVesting.BENEFICIARY() != config.teamBeneficiary || d.teamVesting.TGE() != config.tgeTimestamp
                || d.nftRevenueVault.operationsRecipient() != config.nftOperationsRecipient
                || d.eligibleNFT.snapshotRoot() != B20SnapshotMerkle.MERKLE_ROOT
                || d.eligibleNFT.revenueVault() != address(d.nftRevenueVault)
                || address(d.eligibleNFT.mining()) != address(d.mining)
                || d.publicNFT.revenueVault() != address(d.nftRevenueVault)
                || address(d.publicNFT.mining()) != address(d.mining)
                || address(d.mining.walletBinding()) != address(d.walletBinding)
                || d.mining.POW_TARGET() != PRODUCTION_POW_TARGET || d.mining.MINING_OPENER() != config.miningOpener
                || d.mining.OPEN_DEADLINE() != config.openDeadline || d.mining.miningOpened()
                || address(d.mining.eligibleNFT()) != address(d.eligibleNFT)
                || address(d.mining.publicNFT()) != address(d.publicNFT)
                || d.mining.liquidityVault() != address(d.finalizer)
                || address(d.finalizer.minerToken()) != address(d.token)
                || address(d.finalizer.nftRevenueVault()) != address(d.nftRevenueVault)
                || address(d.finalizer.minerPool()) != address(d.minerPool)
                || address(d.minerPool.POOL_MANAGER()) != _poolManager()
                || address(d.minerPool.MINER()) != address(d.token)
                || address(d.minerPool.BURNER()) != address(d.burner)
                || d.minerPool.FINALIZER() != address(d.finalizer) || d.minerPool.opened()
                || d.minerPool.POOL_MINER_PER_ETH() != d.finalizer.POOL_MINER_PER_ETH()
                // The pool opens at twice the price miners paid per MINER.
                || d.finalizer.POOL_MINER_PER_ETH() * 2 != d.mining.MINER_PER_ETH()
                || address(d.claimVault.minerToken()) != address(d.token)
        ) revert DeploymentConfigurationMismatch();
    }

    /// @notice The mining and claim window the contracts must have chosen:
    /// 15 days on Base, 1 day on Base Sepolia.
    function _windowFor() internal view returns (uint256) {
        return block.chainid == BASE_SEPOLIA_CHAIN_ID ? 1 days : 15 days;
    }

    function _reserves(Deployment memory d) internal pure returns (B20NativeAssetConfig.Reserves memory) {
        return B20NativeAssetConfig.Reserves({
            claimVault: address(d.claimVault),
            liquidityFinalizer: address(d.finalizer),
            ecosystemVault: address(d.ecosystemVault),
            teamVesting: address(d.teamVesting),
            communityVault: address(d.communityVault),
            burner: address(d.burner)
        });
    }

    function _deploymentJson(Deployment memory d, address deployer, Config memory config, uint256 firstNonce)
        internal
        view
        returns (string memory)
    {
        string memory header = string.concat(
            '{"schemaVersion":2,"network":"',
            _networkName(),
            '","chainId":',
            vm.toString(block.chainid),
            ',"deployer":"',
            vm.toString(deployer),
            '","firstNonce":',
            vm.toString(firstNonce),
            ',"tokenStandard":{"id":"base-native-b20-asset","variant":"ASSET","factory":"',
            vm.toString(B20NativeAssetConfig.FACTORY_ADDRESS),
            '","creationSalt":"',
            vm.toString(B20NativeAssetConfig.CREATION_SALT),
            '","baseStdVersion":"v1.1.0","baseStdCommit":"bbfb352e9fe2f67bf6ca33ea4d9a7f2fe0cca20d","initialAdmin":"0x0000000000000000000000000000000000000000","supplyCapWei":"100000000000000000000000000000"},"snapshot":{"version":"v1","block":51310062,"merkleRoot":"',
            vm.toString(B20SnapshotMerkle.MERKLE_ROOT),
            '","domainSeparator":"0x964fcc7123be7cca1178379e4a8b5b7a87dfea508e50baedb7a6c08c39e96552"},'
        );
        return string.concat(header, _parametersJson(config, d), ',"contracts":{', _contractAddressesJson(d), "}}");
    }

    /// @dev Mining economics are read back from the deployed `B20Mining`,
    /// so the record states what is actually on-chain.
    function _parametersJson(Config memory config, Deployment memory d) internal view returns (string memory) {
        return string.concat(
            '"parameters":{"tgeTimestamp":',
            vm.toString(config.tgeTimestamp),
            ',"miningOpener":"',
            vm.toString(config.miningOpener),
            '","miningOpenDeadline":',
            vm.toString(config.openDeadline),
            _windowsJson(d),
            ',"ethUsdPriceCentsAtDeploy":',
            vm.toString(config.ethUsdPriceCents),
            ',"activationFeeWei":"',
            vm.toString(d.walletBinding.ACTIVATION_FEE()),
            '","powTarget":"',
            vm.toString(bytes32(d.mining.POW_TARGET())),
            '","powLeadingZeroBits":24,"rewardPerProofWei":"',
            vm.toString(d.mining.REWARD_PER_PROOF()),
            '","miningFeePerProofWei":"',
            vm.toString(d.mining.MINING_FEE_PER_PROOF()),
            '","minerPerEth":',
            vm.toString(d.mining.MINER_PER_ETH()),
            ',"poolMinerPerEth":',
            vm.toString(d.finalizer.POOL_MINER_PER_ETH()),
            ',"bindingModel":"activate-once-open-mining",',
            _tokenomicsJson(d),
            "}"
        );
    }

    function _windowsJson(Deployment memory d) internal view returns (string memory) {
        return string.concat(
            ',"miningDurationSeconds":',
            vm.toString(d.mining.MINING_DURATION()),
            ',"claimPeriodSeconds":',
            vm.toString(d.claimVault.CLAIM_PERIOD())
        );
    }

    function _tokenomicsJson(Deployment memory d) internal view returns (string memory) {
        return string.concat(
            '"tokenomics":"B20_REVENUE_MODEL.md 1.36","nftQuotaCapWei":"',
            vm.toString(d.mining.NFT_QUOTA_CAP()),
            '","communityReserveWei":"',
            vm.toString(d.communityVault.COMMUNITY_RESERVE()),
            '"'
        );
    }

    function _contractAddressesJson(Deployment memory d) internal view returns (string memory) {
        return string.concat(
            '"b20Token":"',
            vm.toString(address(d.token)),
            '","b20WalletBinding":"',
            vm.toString(address(d.walletBinding)),
            '","b20Mining":"',
            vm.toString(address(d.mining)),
            '","b20EligibleNFT":"',
            vm.toString(address(d.eligibleNFT)),
            '","b20PublicNFT":"',
            vm.toString(address(d.publicNFT)),
            '","b20NFTRevenueVault":"',
            vm.toString(address(d.nftRevenueVault)),
            '","b20ClaimVault":"',
            vm.toString(address(d.claimVault)),
            '","b20LiquidityFinalizer":"',
            vm.toString(address(d.finalizer)),
            '","minerPool":"',
            vm.toString(address(d.minerPool)),
            '","b20TeamVesting":"',
            vm.toString(address(d.teamVesting)),
            '","b20EcosystemVault":"',
            vm.toString(address(d.ecosystemVault)),
            '",',
            _tokenomicsContractsJson(d)
        );
    }

    function _tokenomicsContractsJson(Deployment memory d) internal view returns (string memory) {
        return string.concat(
            '"minerBurner":"',
            vm.toString(address(d.burner)),
            '","b20CommunityVault":"',
            vm.toString(address(d.communityVault)),
            '"'
        );
    }

    function _logDeployment(Deployment memory d, string memory outputPath) internal view {
        console2.log("Base-native B20 Asset", address(d.token));
        console2.log("B20Mining", address(d.mining));
        console2.log("B20ClaimVault", address(d.claimVault));
        console2.log("B20LiquidityFinalizer", address(d.finalizer));
        console2.log("MinerBurner", address(d.burner));
        console2.log("B20CommunityVault", address(d.communityVault));
        console2.log("Deployment JSON", outputPath);
    }
}
