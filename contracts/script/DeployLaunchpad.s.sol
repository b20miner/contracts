// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {CampaignPool} from "../src/launchpad/CampaignPool.sol";
import {LaunchpadFactory} from "../src/launchpad/LaunchpadFactory.sol";
import {LaunchpadHook} from "../src/launchpad/LaunchpadHook.sol";
import {MiningCampaign} from "../src/launchpad/MiningCampaign.sol";
import {PositionLocker} from "../src/launchpad/PositionLocker.sol";
import {MinerPool} from "../src/MinerPool.sol";
import {IEthUsdFeed} from "../src/launchpad/interfaces/ILaunchpadInterfaces.sol";

interface IEthUsdFeedDescription {
    function description() external view returns (string memory);
}

/// @notice B20 Miner Launchpad deployment, one script for both networks:
/// Base (8453) and Base Sepolia (84532) (owner, 30 October 2026: what runs
/// on the testnet is what runs on mainnet). The chain id picks the
/// PoolManager, the Chainlink ETH/USD feed and the record folder.
/// (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §1, §14.2, §41.)
/// @dev Run without `--broadcast` first, with `base-forge` (campaign tokens
/// are created through Base's native B20 factory). The broadcaster is the
/// public deployer from `public-inputs.json`, signing with its encrypted
/// Foundry keystore (`--account`); no private key is read or written here.
///
/// v16: the MINER-liquidity sink is the real MINER's V4 `MinerPool` from
/// this network's B20MINER genesis record (`launch-flow-deployment.json`,
/// `DeployB20Genesis.s.sol`) — the hook's 20% share and half the creation
/// fee wait there until the pool opens at B20MINER's finalize, then every
/// `flush` adds the ETH as buy support and burns the pool's MINER fees.
/// v15's test tMINER and `TestMinerPool` are not part of this script.
///
/// Five contracts, in this order (nonces from the deployer's first nonce):
///   +0 `MiningCampaign` (implementation)   +1 `CampaignPool` (implementation)
///   +2 `PositionLocker`   +3 `LaunchpadHook` (CREATE2, see below)
///   +4 `LaunchpadFactory`
/// (v13: no MINER staking. v14: direct and instant launches open at a fixed
/// ETH amount — 5,000 USD at the deploy day's price, then refreshed by the
/// guardian (`RefreshDirectLaunchFdv.s.sol`, K68) — and the hook takes the
/// 1% trading fee in ETH, split 50/30/20 creator / platform / MINER
/// liquidity on every swap (K69).)
/// The locker needs the factory's and the hook's addresses, the hook the
/// locker's: both are predicted before anything is sent. A Uniswap V4 hook
/// must carry its permissions in its address, so the hook is created through
/// the deterministic CREATE2 deployer with a salt, searched here, that gives
/// an address whose low 14 bits are exactly its permissions: the pool gate
/// (`beforeInitialize`) and the trading fee with the opening anti-snipe
/// (`beforeSwap`, `afterSwap` and both return deltas) — 0x20CC (K40, K69).
contract DeployLaunchpad is Script {
    uint256 internal constant BASE_CHAIN_ID = 8_453;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @notice Chainlink ETH/USD (K66: the creation fee is 3 USD at its
    /// price of the moment); `ETH_USD_FEED` overrides it.
    address internal constant BASE_ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant BASE_SEPOLIA_ETH_USD_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    /// @notice 24 bits, as B20MINER (§2).
    uint256 public constant POW_TARGET = type(uint256).max >> 24;
    /// @notice One full proof: 0.0001 ETH (~0.27 USD), for 10,000 tokens at
    /// the v7 price (K57: four times v7–v8's 0.000025 ETH / 2,500 tokens, a
    /// quarter of the transactions; the PoW target is unchanged).
    uint256 public constant PROOF_FEE_WEI = 100_000_000_000_000;
    uint160 internal constant HOOK_MASK = 0x3FFF; // Hooks.ALL_HOOK_MASK
    /// @dev BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
    uint160 internal constant HOOK_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint256 internal constant HOOK_SALT_SEARCH = 1_000_000;

    struct Config {
        address deployer;
        address miner; // MINER, from the genesis record
        address minerPool; // MINER's V4 pool, from the genesis record
        address platformTreasury;
        address guardian;
        uint256 ethUsdPriceCents;
        uint256 creationFeeWei; // K66: the fallback while the feed is unusable
        address ethUsdFeed;
        uint256 directLaunchFdvWei; // K68: the first opening FDV (5,000 USD on the deploy day)
        bool fresh; // `run`: the opening FDV must still be the first one (the guardian may refresh it later)
    }

    struct Deployment {
        MinerPool minerPool;
        MiningCampaign miningImpl;
        CampaignPool poolImpl;
        PositionLocker locker;
        LaunchpadHook hook;
        LaunchpadFactory factory;
        bytes32 hookSalt;
    }

    error UnsupportedChain(uint256 chainId);
    error ZeroConfigAddress(string field);
    error EthUsdPriceOutOfRange(uint256 cents);
    error MissingDependencyCode(address dependency);
    error NativeB20FactoryUnavailable(address factory);
    error HookSaltNotFound();
    error PredictedAddressMismatch(string contractName, address predicted, address actual);
    error CheckFailed(string what);

    uint256 internal _checks;

    function run() external returns (Deployment memory deployment) {
        Config memory config = _loadConfig();
        config.fresh = true;
        _validateEnvironment(config);

        uint256 firstNonce = vm.getNonce(config.deployer);
        vm.startBroadcast(config.deployer);
        deployment = _deploy(config, config.deployer, firstNonce);
        vm.stopBroadcast();

        uint256 checks = _verifyDeployment(deployment, config);
        (bool live,) = deployment.factory.ethUsdPrice();
        _check(live, "the ETH/USD feed is live: the creation fee follows it (K66)");
        checks = _checks;
        string memory outputPath = vm.envOr(
            "LAUNCHPAD_OUTPUT_PATH",
            string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/launchpad-deployment.json")
        );
        vm.writeJson(_deploymentJson(deployment, config, firstNonce, checks), outputPath);
        _log(deployment, config, checks, outputPath);
    }

    /// @notice Read-only: runs every check again, against the live chain,
    /// on the recorded deployment (`forge script … --sig "verifyRecorded()"`).
    function verifyRecorded() external returns (uint256 checks) {
        string memory json = vm.readFile(
            vm.envOr(
                "LAUNCHPAD_OUTPUT_PATH",
                string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/launchpad-deployment.json")
            )
        );
        Deployment memory d;
        d.factory = LaunchpadFactory(vm.parseJsonAddress(json, ".contracts.launchpadFactory"));
        d.miningImpl = MiningCampaign(payable(vm.parseJsonAddress(json, ".contracts.miningCampaignImplementation")));
        d.poolImpl = CampaignPool(payable(vm.parseJsonAddress(json, ".contracts.campaignPoolImplementation")));
        d.locker = PositionLocker(payable(vm.parseJsonAddress(json, ".contracts.positionLocker")));
        d.hook = LaunchpadHook(vm.parseJsonAddress(json, ".contracts.launchpadHook"));
        d.minerPool = MinerPool(payable(vm.parseJsonAddress(json, ".contracts.minerPool")));
        Config memory c;
        c.deployer = vm.parseJsonAddress(json, ".deployer");
        c.miner = vm.parseJsonAddress(json, ".dependencies.miner");
        c.minerPool = address(d.minerPool);
        c.platformTreasury = vm.parseJsonAddress(json, ".parameters.platformTreasury");
        c.guardian = vm.parseJsonAddress(json, ".parameters.guardian");
        c.ethUsdPriceCents = vm.parseJsonUint(json, ".parameters.ethUsdPriceCents");
        c.creationFeeWei = vm.parseJsonUint(json, ".parameters.creationFeeWei");
        c.ethUsdFeed = vm.keyExistsJson(json, ".dependencies.ethUsdFeed")
            ? vm.parseJsonAddress(json, ".dependencies.ethUsdFeed")
            : address(0);
        if (c.creationFeeWei != creationFeeFor(c.ethUsdPriceCents)) revert CheckFailed("recorded creation fee");
        c.directLaunchFdvWei = vm.parseJsonUint(json, ".parameters.directLaunchFdv.initialWei");
        if (c.directLaunchFdvWei != directLaunchFdvFor(c.ethUsdPriceCents)) revert CheckFailed("recorded opening FDV");
        checks = _verifyDeployment(d, c);
        console2.log("Launchpad: checks passed", checks);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice 3 USD at the given ETH price, rounded up to the wei (K6).
    function creationFeeFor(uint256 ethUsdPriceCents) public pure returns (uint256) {
        return (300e18 + ethUsdPriceCents - 1) / ethUsdPriceCents;
    }

    /// @notice 5,000 USD at the given ETH price, rounded down to the wei (K68).
    function directLaunchFdvFor(uint256 ethUsdPriceCents) public pure returns (uint256) {
        return 5_000e20 / ethUsdPriceCents;
    }

    /// @notice The record folder and `network` field: `base` or `base-sepolia`.
    function _networkName() internal view returns (string memory) {
        if (block.chainid == BASE_CHAIN_ID) return "base";
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return "base-sepolia";
        revert UnsupportedChain(block.chainid);
    }

    /// @notice Uniswap's V4 PoolManager on this chain (`MinerPool` pins the same two).
    function _poolManager() internal view returns (address) {
        if (block.chainid == BASE_CHAIN_ID) return BASE_POOL_MANAGER;
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_POOL_MANAGER;
        revert UnsupportedChain(block.chainid);
    }

    function _defaultEthUsdFeed() internal view returns (address) {
        if (block.chainid == BASE_CHAIN_ID) return BASE_ETH_USD_FEED;
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_ETH_USD_FEED;
        revert UnsupportedChain(block.chainid);
    }

    function _loadConfig() internal view returns (Config memory config) {
        string memory inputs = vm.readFile(
            vm.envOr(
                "PUBLIC_INPUTS_PATH",
                string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/public-inputs.json")
            )
        );
        // MINER and its pool come from this network's B20MINER genesis record
        string memory genesis = vm.readFile(
            vm.envOr(
                "GENESIS_RECORD_PATH",
                string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/launch-flow-deployment.json")
            )
        );
        config.miner = vm.parseJsonAddress(genesis, ".contracts.b20Token");
        config.minerPool = vm.parseJsonAddress(genesis, ".contracts.minerPool");
        config.deployer = vm.parseJsonAddress(inputs, ".addresses.deployer");
        config.platformTreasury =
            vm.envOr("PLATFORM_TREASURY", vm.parseJsonAddress(inputs, ".addresses.operationsTreasury"));
        // the ecosystem manager also plays the guardian multisig unless set
        config.guardian = vm.envOr("LAUNCHPAD_GUARDIAN", vm.parseJsonAddress(inputs, ".addresses.ecosystemManager"));
        config.ethUsdPriceCents = vm.envUint("ETH_USD_PRICE_CENTS");
        config.creationFeeWei = creationFeeFor(config.ethUsdPriceCents);
        config.directLaunchFdvWei = directLaunchFdvFor(config.ethUsdPriceCents);
        config.ethUsdFeed = vm.envOr("ETH_USD_FEED", _defaultEthUsdFeed());
    }

    function _validateEnvironment(Config memory config) internal view {
        address poolManager = _poolManager(); // reverts on any other chain
        if (config.deployer == address(0)) revert ZeroConfigAddress("deployer");
        if (config.miner == address(0)) revert ZeroConfigAddress("MINER (genesis record)");
        if (config.minerPool == address(0)) revert ZeroConfigAddress("minerPool (genesis record)");
        if (config.platformTreasury == address(0)) revert ZeroConfigAddress("PLATFORM_TREASURY");
        if (config.guardian == address(0)) revert ZeroConfigAddress("LAUNCHPAD_GUARDIAN");
        if (config.ethUsdPriceCents < 50_000 || config.ethUsdPriceCents > 2_000_000) {
            revert EthUsdPriceOutOfRange(config.ethUsdPriceCents);
        }
        _requireCode(poolManager);
        _requireCode(config.minerPool);
        _requireCode(config.ethUsdFeed);
        _requireCode(_create2Deployer());
        _requireNativeB20Factory(config.deployer);
    }

    /// @dev Native precompiles report no runtime bytecode, so a typed read
    /// tells the live B20 factory from an empty account (plain Foundry sees
    /// the latter: run with `base-forge`). Every campaign token is a B20.
    function _requireNativeB20Factory(address creator) internal view {
        (bool ok, bytes memory result) = StdPrecompiles.B20_FACTORY_ADDRESS.staticcall(
            abi.encodeCall(IB20Factory.getB20Address, (IB20Factory.B20Variant.ASSET, creator, bytes32(0)))
        );
        if (!ok || result.length < 32 || abi.decode(result, (address)) == address(0)) {
            revert NativeB20FactoryUnavailable(StdPrecompiles.B20_FACTORY_ADDRESS);
        }
    }

    function _requireCode(address dependency) internal view {
        if (dependency.code.length == 0) revert MissingDependencyCode(dependency);
    }

    /// @dev Where `new LaunchpadHook{salt: …}` is created from: the
    /// deterministic CREATE2 deployer in a broadcast script.
    function _create2Deployer() internal view virtual returns (address) {
        return CREATE2_DEPLOYER;
    }

    /// @notice A salt whose CREATE2 hook address carries exactly the hook's
    /// permission bits (`HOOK_FLAGS`) and does not start with 0x91. Expected
    /// ~16,384 tries.
    function findHookSalt(address create2Deployer, address locker, address platformTreasury, address minerLiquidity)
        public
        view
        returns (bytes32 salt, address hook)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LaunchpadHook).creationCode, abi.encode(_poolManager(), locker, platformTreasury, minerLiquidity)
            )
        );
        for (uint256 i; i < HOOK_SALT_SEARCH; i++) {
            salt = bytes32(i);
            hook = vm.computeCreate2Address(salt, initHash, create2Deployer);
            // Uniswap's routing allowlist sends every 0x91… hook to manual review: skip them
            if (uint160(hook) & HOOK_MASK == HOOK_FLAGS && uint160(hook) >> 152 != 0x91 && hook.code.length == 0) {
                return (salt, hook);
            }
        }
        revert HookSaltNotFound();
    }

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    function _deploy(Config memory config, address deployer, uint256 firstNonce)
        internal
        returns (Deployment memory d)
    {
        d.minerPool = MinerPool(payable(config.minerPool));
        address predictedLocker = vm.computeCreateAddress(deployer, firstNonce + 2);
        address predictedFactory = vm.computeCreateAddress(deployer, firstNonce + 4);
        address predictedHook;
        (d.hookSalt, predictedHook) =
            findHookSalt(_create2Deployer(), predictedLocker, config.platformTreasury, config.minerPool);

        address poolManager = _poolManager();
        d.miningImpl = new MiningCampaign(); // +0
        d.poolImpl = new CampaignPool(); // +1
        d.locker = new PositionLocker(poolManager, predictedFactory, predictedHook); // +2
        _requirePredicted("PositionLocker", predictedLocker, address(d.locker));
        d.hook = new LaunchpadHook{salt: d.hookSalt}( // +3
        poolManager, predictedLocker, config.platformTreasury, config.minerPool);
        _requirePredicted("LaunchpadHook", predictedHook, address(d.hook));
        d.factory = new LaunchpadFactory(_factoryConfig(d, config)); // +4
        _requirePredicted("LaunchpadFactory", predictedFactory, address(d.factory));
    }

    function _factoryConfig(Deployment memory d, Config memory config)
        internal
        pure
        returns (LaunchpadFactory.Config memory)
    {
        return LaunchpadFactory.Config({
            miningImpl: address(d.miningImpl),
            poolImpl: address(d.poolImpl),
            locker: address(d.locker),
            feeRouter: address(d.minerPool), // v16: MINER's own V4 pool, as on mainnet
            platformTreasury: config.platformTreasury,
            guardian: config.guardian,
            creationFeeWei: config.creationFeeWei,
            ethUsdFeed: config.ethUsdFeed,
            directLaunchFdvWei: config.directLaunchFdvWei,
            proofFeeWei: PROOF_FEE_WEI,
            powTarget: POW_TARGET
        });
    }

    function _requirePredicted(string memory name, address predicted, address actual) internal pure {
        if (predicted != actual) revert PredictedAddressMismatch(name, predicted, actual);
    }

    // ------------------------------------------------------------------
    // Verification (every wire, read back from the chain)
    // ------------------------------------------------------------------

    function _check(bool ok, string memory what) internal {
        if (!ok) revert CheckFailed(what);
        _checks++;
    }

    function _verifyDeployment(Deployment memory d, Config memory config) internal returns (uint256) {
        _checks = 0;
        _verifyCode(d);
        _verifyHookAndLocker(d, config);
        _verifyFactory(d, config);
        _verifyPeriphery(d, config);
        return _checks;
    }

    function _verifyCode(Deployment memory d) internal {
        _check(address(d.minerPool).code.length > 0, "MINER pool code");
        _check(address(d.miningImpl).code.length > 0, "campaign implementation code");
        _check(address(d.poolImpl).code.length > 0, "pool implementation code");
        _check(address(d.locker).code.length > 0, "locker code");
        _check(address(d.hook).code.length > 0, "hook code");
        _check(address(d.factory).code.length > 0, "factory code");
        _check(d.factory.SUPPLY() == 1_000_000_000, "factory accepts only the 1 billion supply (K43)");
        // the implementations can never be initialized themselves
        _check(d.miningImpl.factory() == address(1), "campaign implementation sealed");
        _check(d.poolImpl.factory() == address(1), "pool implementation sealed");
        _check(
            d.poolImpl.OPENING_BUFFER_WEI() == 1.5 ether && d.factory.OPENING_BUFFER_WEI() == 1.5 ether,
            "opening buffer of 1.5 ETH, the same in the pool and the deposit cap (K53)"
        );
    }

    function _verifyHookAndLocker(Deployment memory d, Config memory config) internal {
        _check(uint160(address(d.hook)) & HOOK_MASK == HOOK_FLAGS, "hook address carries exactly its permissions");
        _check(address(d.hook.POOL_MANAGER()) == _poolManager(), "hook pool manager");
        _check(d.hook.LOCKER() == address(d.locker), "hook locker");
        _check(d.hook.PLATFORM_TREASURY() == config.platformTreasury, "hook platform share and surcharge go to the treasury");
        _check(d.hook.MINER_LIQUIDITY() == address(d.minerPool), "hook MINER liquidity = MINER's V4 pool (v16)");
        _check(
            d.hook.OPENING_TOTAL_FEE_BPS() == 9_900 && d.hook.ANTI_SNIPE_WINDOW() == 20,
            "anti-snipe 99% -> 1% over 20 s on pools that start from zero (K52)"
        );
        _check(
            d.hook.FEE_BPS() == 100 && d.locker.FEE() == 0,
            "trading fee 1% in ETH, taken by the hook; the pools have no LP fee (K69)"
        );
        _check(
            d.hook.CREATOR_BPS() == 5_000 && d.hook.PLATFORM_BPS() == 3_000 && d.hook.MINER_LIQUIDITY_BPS() == 2_000,
            "fee split on every swap: 50% creator / 30% platform / 20% MINER liquidity (K69)"
        );
        _check(address(d.locker.POOL_MANAGER()) == _poolManager(), "locker pool manager");
        _check(address(d.locker.REGISTRY()) == address(d.factory), "locker registry = factory");
        _check(d.locker.HOOK() == address(d.hook), "locker hook");
    }

    function _verifyFactory(Deployment memory d, Config memory config) internal {
        LaunchpadFactory f = d.factory;
        _check(f.MINING_IMPL() == address(d.miningImpl), "factory campaign implementation");
        _check(f.POOL_IMPL() == address(d.poolImpl), "factory pool implementation");
        _check(f.LOCKER() == address(d.locker), "factory locker");
        _check(address(f.FEE_ROUTER()) == address(d.minerPool), "factory: half the creation fee to MINER's V4 pool (v16)");
        _check(f.PLATFORM_TREASURY() == config.platformTreasury, "factory treasury");
        _check(f.GUARDIAN() == config.guardian, "factory guardian");
        _check(f.CREATION_FEE_WEI() == config.creationFeeWei, "fallback creation fee (3 USD on the deploy day)");
        _verifyOpeningFdv(f, config);
        _verifyCreationFee(f, config);
        _check(f.PROOF_FEE_WEI() == PROOF_FEE_WEI, "proof fee");
        _check(
            f.PRICE_PER_SUPPLY() == 10_000 && MiningCampaign(payable(f.MINING_IMPL())).PRICE_PER_SUPPLY() == 10_000
                && CampaignPool(payable(f.POOL_IMPL())).PRICE_PER_SUPPLY() == 10_000,
            "1 ETH = 100,000,000 tokens at 1 billion, the same in the factory, campaign and pool (K55)"
        );
        _check(
            f.MIN_WALLET_CAP() == 0.01 ether && f.MAX_WALLET_CAP() == 0.5 ether, "wallet cap 0.01 .. 0.5 ETH (K55)"
        );
        MiningCampaign m = MiningCampaign(payable(f.MINING_IMPL()));
        _check(
            m.PLATFORM_MIN_BPS() == 100 && m.PLATFORM_MAX_BPS() == 500 && m.PLATFORM_STEPS() == 5
                && m.PLATFORM_RAMP_BPS() == 2_000 && f.MAX_POOL_SHARE_BPS() == 9_541,
            "platform share 1% -> 5% in five steps over the first 20% mined; deposit cap at a 95.41% pool share (K56)"
        );
        _check(f.POW_TARGET() == POW_TARGET, "PoW target (24 bits)");
        _check(
            m.SHARES_PER_PROOF() == 16 && m.SHARE_SHIFT() == 4,
            "share mining: 16 shares at a 16x easier target earn one proof (K58)"
        );
        _check(
            f.MAX_NAME_BYTES() == 32 && f.MAX_SYMBOL_BYTES() == 10, "name at most 32 bytes, symbol at most 10 (v13)"
        );
        _check(!f.deprecated(), "factory open");
        _check(f.campaignCount() == 0, "no campaigns yet");
    }

    /// @notice MINER's V4 pool from the genesis (`B20_REVENUE_MODEL.md` §6):
    /// it may still be closed (it opens at B20MINER's finalize).
    function _verifyPeriphery(Deployment memory d, Config memory config) internal {
        MinerPool m = d.minerPool;
        _check(address(m.MINER()) == config.miner, "MINER pool token = MINER");
        _check(address(m.POOL_MANAGER()) == _poolManager(), "MINER pool manager");
        _check(address(m.BURNER().MINER()) == config.miner, "MINER pool fees burn through MINER's burner");
        _check(m.FINALIZER().code.length > 0, "MINER pool opens only by its contract (B20MINER finalizer; testnet: the tMINER launcher)");
        _check(
            m.FEE() == 3_000 && m.TICK_SPACING() == 60 && address(m.poolKey().hooks) == address(0),
            "hookless V4 pool, 0.30% fee, tick spacing 60"
        );
        _check(m.POOL_MINER_PER_ETH() == 6_000_000, "opens at 1 ETH = 6,000,000 MINER");
        _check(m.GRID() == 600 && m.BAND() == 6_960, "buy support on a 600-tick grid, bands of a price halving");
    }

    // ------------------------------------------------------------------
    // Record
    // ------------------------------------------------------------------

    function _deploymentJson(Deployment memory d, Config memory config, uint256 firstNonce, uint256 checks)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"schemaVersion":1,"network":"',
            _networkName(),
            '","chainId":',
            vm.toString(block.chainid),
            ',"product":"b20-miner-launchpad",',
            '"design":"docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md 1.68 (v16)",',
            '"deployer":"',
            vm.toString(config.deployer),
            '","firstNonce":',
            vm.toString(firstNonce),
            ',"checksPassed":',
            vm.toString(checks),
            ",",
            _contractsJson(d),
            ",",
            _dependenciesJson(config),
            ",",
            _parametersJson(d, config),
            ',"afterDeploy":["relay keeper: MinerPool.flush() after every hook sweep (no-op until B20MINER finalize opens the pool)"]}'
        );
    }

    function _contractsJson(Deployment memory d) internal pure returns (string memory) {
        return string.concat(
            '"contracts":{"launchpadFactory":"',
            vm.toString(address(d.factory)),
            '","miningCampaignImplementation":"',
            vm.toString(address(d.miningImpl)),
            '","campaignPoolImplementation":"',
            vm.toString(address(d.poolImpl)),
            '","positionLocker":"',
            vm.toString(address(d.locker)),
            '","launchpadHook":"',
            vm.toString(address(d.hook)),
            '","feeRouter":"',
            vm.toString(address(d.minerPool)),
            '","minerPool":"',
            vm.toString(address(d.minerPool)),
            '"}'
        );
    }

    function _dependenciesJson(Config memory config) internal view returns (string memory) {
        return string.concat(
            '"dependencies":{"miner":"',
            vm.toString(config.miner),
            '","ethUsdFeed":"',
            vm.toString(config.ethUsdFeed),
            '","uniswapV4PoolManager":"',
            vm.toString(_poolManager()),
            '","create2Deployer":"',
            vm.toString(CREATE2_DEPLOYER),
            '"}'
        );
    }

    /// @notice K66: the fee is 3 USD at Chainlink's ETH/USD, or the fallback.
    function _verifyCreationFee(LaunchpadFactory f, Config memory config) internal {
        IEthUsdFeed feed = IEthUsdFeed(config.ethUsdFeed);
        _check(address(f.ETH_USD_FEED()) == config.ethUsdFeed, "factory ETH/USD feed");
        _check(
            feed.decimals() == 8 && keccak256(bytes(IEthUsdFeedDescription(config.ethUsdFeed).description()))
                == keccak256("ETH / USD"),
            "Chainlink ETH / USD, 8 decimals"
        );
        _check(
            f.CREATION_FEE_USD_CENTS() == 300 && f.MAX_PRICE_AGE() == 6 hours && f.MIN_ETH_USD() == 500
                && f.MAX_ETH_USD() == 20_000,
            "creation fee 3 USD; feed answers up to 6 h old, 500..20,000 USD/ETH (K66)"
        );
        (bool live, uint256 price) = f.ethUsdPrice();
        uint256 expected = live ? (300e26 + price * 100 - 1) / (price * 100) : config.creationFeeWei;
        _check(f.creationFeeWei() == expected, "creation fee now = 3 USD at the feed (or the fallback)");
    }

    /// @notice K68: direct and instant launches open at a fixed ETH amount
    /// the guardian sets within 0.25..10 ETH; a fresh deployment still has
    /// the deploy day's 5,000 USD.
    function _verifyOpeningFdv(LaunchpadFactory f, Config memory config) internal {
        _check(
            f.MIN_DIRECT_LAUNCH_FDV_WEI() == 0.25 ether && f.MAX_DIRECT_LAUNCH_FDV_WEI() == 10 ether,
            "opening FDV: a fixed ETH amount the guardian sets within 0.25..10 ETH (K68)"
        );
        uint256 fdv = f.directLaunchFdvWei();
        if (config.fresh) {
            _check(fdv == config.directLaunchFdvWei, "opening FDV now = 5,000 USD at the deploy day's price");
        } else {
            _check(
                fdv >= f.MIN_DIRECT_LAUNCH_FDV_WEI() && fdv <= f.MAX_DIRECT_LAUNCH_FDV_WEI(),
                "opening FDV now within the guardian's range (refreshed since the deploy, or not)"
            );
        }
    }

    function _parametersJson(Deployment memory d, Config memory config) internal view returns (string memory) {
        return string.concat(
            '"parameters":{"platformTreasury":"',
            vm.toString(config.platformTreasury),
            '","guardian":"',
            vm.toString(config.guardian),
            '","ethUsdPriceCents":',
            vm.toString(config.ethUsdPriceCents),
            ',"creationFeeWei":"',
            vm.toString(config.creationFeeWei),
            '","creationFee":{"usdCents":300,"source":"Chainlink ETH/USD","maxPriceAgeSeconds":21600,"ethUsdRange":[500,20000],"fallbackWei":"',
            vm.toString(config.creationFeeWei),
            '"},"proofFeeWei":"',
            vm.toString(PROOF_FEE_WEI),
            '","powTarget":"',
            vm.toString(POW_TARGET),
            '","hookSalt":"',
            vm.toString(d.hookSalt),
            '","hookFlags":"0x20cc","antiSnipe":{"instantLaunch":"creator option","miningDirectLaunch":"always","minedPool":"never","openingTotalFeeBps":9900,"windowSeconds":20,"surchargeTo":"platformTreasury"},"tradingFee":{"bps":100,"currency":"ETH","takenBy":"hook","lpFee":0,"split":{"creatorBps":5000,"platformBps":3000,"minerLiquidityBps":2000},"splitPerSwap":true,"creatorClaim":"hook.claimCreatorFees","platformAndMinerPayout":"hook.sweep"},"directLaunchFdv":{"targetUsd":5000,"fixedInEth":true,"setBy":"guardian","setter":"setDirectLaunchFdvWei","minWei":"250000000000000000","maxWei":"10000000000000000000","initialWei":"',
            vm.toString(config.directLaunchFdvWei),
            '"},"tokensPerEthAtOneBillion":"100000000","tokensPerProof":"',
            vm.toString(PROOF_FEE_WEI * 100_000_000 / 1 ether),
            '","miningShareBps":{"twoX":6000,"oneX":4000},"walletCapWei":{"min":"10000000000000000","max":"500000000000000000","appDefault":"50000000000000000"},"openingBufferWei":"1500000000000000000","allowlist":false,"openingMultiples":[2,1],"defaultOpeningMultiple":2,"minimumPool":false,"instantLaunch":true,"platformShareBps":{"min":100,"max":500,"steps":5,"rampOfReserveBps":2000,"fullSellOutBps":460},"maxPoolShareBps":9541,"shareMining":{"sharesPerProof":16,"shareTargetBits":20,"partialBatch":false},"depositCapWei":{"twoX":"775400000000000000","oneX":"683600000000000000"},"instantCreatorBuy":{"limit":"none","antiSnipeSurcharge":false,"tradingFee":true},"nameMaxBytes":32,"symbolMaxBytes":10,"staking":false,"minerPool":{"openingMinerPerEth":6000000,"lpFeePips":3000,"tickSpacing":60,"hooks":"none","ethFees":"buy support","minerFees":"burned (MinerBurner)","minerShareAsBuySupport":true,"gridTicks":600,"bandTicks":6960,"opensAt":"',
            d.minerPool.opened() ? "open at deploy (testnet tMINER)" : "B20MINER finalize",
            '","flushBy":"anyone (relay keeper after sweep)"}}'
        );
    }

    function _log(Deployment memory d, Config memory config, uint256 checks, string memory outputPath) internal view {
        console2.log("B20 Miner Launchpad", _networkName());
        console2.log("  LaunchpadFactory     ", address(d.factory));
        console2.log("  MiningCampaign impl  ", address(d.miningImpl));
        console2.log("  CampaignPool impl    ", address(d.poolImpl));
        console2.log("  PositionLocker       ", address(d.locker));
        console2.log("  LaunchpadHook        ", address(d.hook));
        console2.log("  MinerPool (genesis)  ", address(d.minerPool));
        console2.log("  MINER                ", config.miner);
        console2.log("  creation fee now (wei)", d.factory.creationFeeWei());
        console2.log("  fallback fee (wei)   ", config.creationFeeWei);
        console2.log("  opening FDV (wei)    ", d.factory.directLaunchFdvWei());
        console2.log("  checks passed        ", checks);
        console2.log("  record               ", outputPath);
    }
}
