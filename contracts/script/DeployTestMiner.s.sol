// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {MinerPool} from "../src/MinerPool.sol";
import {TestMinerLauncher} from "../src/launchpad/TestMinerLauncher.sol";

interface IB20RolesView {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Base Sepolia only (owner, 3 November 2026): tMINER and its pool
/// for the public testnet Launchpad, one transaction (`TestMinerLauncher`).
/// The pool is mainnet MINER's `MinerPool`, unchanged, opened at once with
/// `TMINER_OPENING_ETH` (default 0.02 ETH) and the matching tMINER at
/// 1 ETH = 6,000,000. `scripts/deploy-v16.sh tminer` runs it; the record it
/// writes (`tminer-deployment.json`) has the genesis record's keys
/// (`contracts.b20Token`, `contracts.minerPool`), so `DeployLaunchpad`
/// reads it in place of the genesis record.
/// @dev Run without `--broadcast` first, with `base-forge` (tMINER is created
/// through Base's native B20 factory). The broadcaster signs with its
/// encrypted Foundry keystore (`--account`); no private key is read here.
contract DeployTestMiner is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for *;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    uint256 internal _checks;

    error UnsupportedChain(uint256 chainId);

    function run() external returns (TestMinerLauncher launcher) {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert UnsupportedChain(block.chainid);
        uint256 openingEth = vm.envOr("TMINER_OPENING_ETH", uint256(0.02 ether));
        address deployer = vm.parseJsonAddress(vm.readFile(_inputsPath()), ".addresses.deployer");
        uint256 nonce = vm.getNonce(deployer);
        vm.startBroadcast(deployer);
        launcher = new TestMinerLauncher{value: openingEth}(POOL_MANAGER);
        vm.stopBroadcast();
        uint256 checks = _verify(launcher, openingEth);
        vm.writeJson(_json(launcher, deployer, nonce, openingEth, checks), _outputPath());
        console2.log("TestMinerLauncher", address(launcher));
        console2.log("tMINER           ", launcher.TOKEN());
        console2.log("MinerPool        ", address(launcher.POOL()));
        console2.log("MinerBurner      ", address(launcher.BURNER()));
        console2.log("opening ETH (wei)", openingEth);
        console2.log("checks passed    ", checks);
        console2.log("record           ", _outputPath());
    }

    /// @notice Re-runs every check against the recorded deployment.
    function verifyRecorded() external returns (uint256 checks) {
        string memory json = vm.readFile(_outputPath());
        TestMinerLauncher launcher = TestMinerLauncher(vm.parseJsonAddress(json, ".contracts.testMinerLauncher"));
        checks = _verify(launcher, vm.parseJsonUint(json, ".parameters.openingEthWei"));
        console2.log("tMINER: checks passed", checks);
    }

    function _check(bool ok, string memory what) internal {
        require(ok, what);
        _checks++;
    }

    function _verify(TestMinerLauncher launcher, uint256 openingEth) internal returns (uint256) {
        _checks = 0;
        MinerPool pool = launcher.POOL();
        IERC20Metadata token = IERC20Metadata(launcher.TOKEN());
        _check(address(launcher).code.length > 0 && address(pool).code.length > 0, "launcher and pool have code");
        _check(keccak256(bytes(token.symbol())) == keccak256("tMINER"), "token symbol tMINER");
        _check(keccak256(bytes(token.name())) == keccak256("B20MINER Test"), "token name B20MINER Test");
        _check(token.decimals() == 18, "18 decimals");
        _check(pool.opened(), "pool open");
        _check(pool.FINALIZER() == address(launcher), "the launcher is the pool's only opener");
        _check(address(pool.MINER()) == address(token), "pool token = tMINER");
        _check(address(pool.BURNER()) == address(launcher.BURNER()), "pool burner");
        _check(address(launcher.BURNER().MINER()) == address(token), "burner burns tMINER");
        _check(address(pool.POOL_MANAGER()) == POOL_MANAGER, "Uniswap's PoolManager on Base Sepolia");
        _check(pool.FEE() == 3_000 && pool.TICK_SPACING() == 60 && address(pool.poolKey().hooks) == address(0), "hookless V4 pool, 0.30%, spacing 60");
        (uint160 sqrtP,,,) = IPoolManager(POOL_MANAGER).getSlot0(pool.poolKey().toId());
        _check(sqrtP != 0, "pool initialized");
        _check(pool.openingEth() <= openingEth && pool.openingEth() > openingEth * 999 / 1000, "opening ETH in the full range");
        _check(token.totalSupply() <= openingEth * 6_000_000 && token.totalSupply() > openingEth * 6_000_000 * 999 / 1000, "supply = opening ETH x 6,000,000 (less burned dust)");
        _check(token.balanceOf(address(launcher)) == 0 && token.balanceOf(address(pool)) == 0, "no tMINER outside the pool");
        IB20RolesView roles = IB20RolesView(address(token));
        _check(roles.hasRole(B20Constants.BURN_ROLE, address(launcher.BURNER())), "burner holds BURN_ROLE");
        _check(!roles.hasRole(B20Constants.MINT_ROLE, address(launcher)) && !roles.hasRole(B20Constants.DEFAULT_ADMIN_ROLE, address(launcher)), "no minter, no admin");
        return _checks;
    }

    function _inputsPath() internal view returns (string memory) {
        return vm.envOr("PUBLIC_INPUTS_PATH", string.concat(vm.projectRoot(), "/../deployments/base-sepolia/public-inputs.json"));
    }

    function _outputPath() internal view returns (string memory) {
        return vm.envOr("TMINER_OUTPUT_PATH", string.concat(vm.projectRoot(), "/../deployments/base-sepolia/tminer-deployment.json"));
    }

    function _json(TestMinerLauncher launcher, address deployer, uint256 nonce, uint256 openingEth, uint256 checks)
        internal
        view
        returns (string memory)
    {
        string memory head = string.concat(
            '{"schemaVersion":1,"network":"base-sepolia","chainId":84532,"product":"tminer","design":"TestMinerLauncher: mainnet MinerPool code, opened at once (owner, 3 Nov 2026)","deployer":"',
            vm.toString(deployer),
            '","firstNonce":',
            vm.toString(nonce),
            ',"checksPassed":',
            vm.toString(checks)
        );
        return string.concat(head, _contractsJson(launcher), _parametersJson(launcher, openingEth));
    }

    function _contractsJson(TestMinerLauncher launcher) internal view returns (string memory) {
        return string.concat(
            ',"contracts":{"b20Token":"',
            vm.toString(launcher.TOKEN()),
            '","tMiner":"',
            vm.toString(launcher.TOKEN()),
            '","minerPool":"',
            vm.toString(address(launcher.POOL())),
            '","minerBurner":"',
            vm.toString(address(launcher.BURNER())),
            '","testMinerLauncher":"',
            vm.toString(address(launcher)),
            '"},"dependencies":{"uniswapV4PoolManager":"',
            vm.toString(POOL_MANAGER),
            '"}'
        );
    }

    function _parametersJson(TestMinerLauncher launcher, uint256 openingEth) internal view returns (string memory) {
        return string.concat(
            ',"parameters":{"name":"B20MINER Test","symbol":"tMINER","openingEthWei":"',
            vm.toString(openingEth),
            '","openingMinerPerEth":6000000,"openingLiquidity":"',
            vm.toString(uint256(launcher.OPENING_LIQUIDITY())),
            '","totalSupplyWei":"',
            vm.toString(IERC20Metadata(launcher.TOKEN()).totalSupply()),
            '","opensAt":"deploy"}}'
        );
    }
}
