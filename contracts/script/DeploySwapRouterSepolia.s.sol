// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {LaunchpadSwapRouter} from "../src/launchpad/LaunchpadSwapRouter.sol";

/// @notice The Launchpad swap router on Base Sepolia (16 Oct 2026, web app
/// doc §4.6zp): a sale is a plain `approve` of the router once per token,
/// then the swap; no Permit2. One transaction. The router has no owner, no
/// admin, no upgrade and no storage; it uses the Uniswap V4 PoolManager the
/// Launchpad deployment records.
/// @dev Run without `--broadcast` first. The broadcaster signs with its
/// encrypted Foundry keystore (`--account`); no private key is read here.
contract DeploySwapRouterSepolia is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal _checks;

    function run() external returns (LaunchpadSwapRouter router) {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "Base Sepolia only");
        address poolManager = _poolManager();
        vm.startBroadcast();
        router = new LaunchpadSwapRouter(IPoolManager(poolManager));
        vm.stopBroadcast();
        uint256 checks = _verify(router, poolManager);
        vm.writeJson(_json(router, poolManager, checks), _outputPath());
        console2.log("LaunchpadSwapRouter", address(router));
        console2.log("PoolManager        ", poolManager);
        console2.log("checks passed      ", checks);
    }

    /// @notice Re-runs every check against the recorded deployment.
    function verifyRecorded() external returns (uint256 checks) {
        string memory json = vm.readFile(_outputPath());
        LaunchpadSwapRouter router = LaunchpadSwapRouter(payable(vm.parseJsonAddress(json, ".contracts.launchpadSwapRouter")));
        checks = _verify(router, vm.parseJsonAddress(json, ".dependencies.uniswapV4PoolManager"));
        console2.log("LaunchpadSwapRouter on Base Sepolia: checks passed", checks);
    }

    function _poolManager() internal view returns (address) {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/../deployments/base-sepolia/launchpad-deployment.json"));
        return vm.parseJsonAddress(json, ".dependencies.uniswapV4PoolManager");
    }

    function _outputPath() internal view returns (string memory) {
        return vm.envOr(
            "SWAP_ROUTER_OUTPUT_PATH",
            string.concat(vm.projectRoot(), "/../deployments/base-sepolia/swap-router-deployment.json")
        );
    }

    function _check(bool ok, string memory what) internal {
        require(ok, what);
        _checks++;
    }

    function _verify(LaunchpadSwapRouter router, address poolManager) internal returns (uint256) {
        _checks = 0;
        _check(address(router).code.length > 0, "router has code");
        _check(address(router.POOL_MANAGER()) == poolManager, "router uses the Launchpad's PoolManager");
        _check(poolManager.code.length > 0, "PoolManager has code");
        // Nothing to own: the callback answers only the PoolManager. (No balance
        // check: anyone can send ETH to an address before or after the deploy.)
        (bool ok, bytes memory ret) = address(router).call(abi.encodeCall(router.unlockCallback, ("")));
        _check(!ok && ret.length == 4 && bytes4(ret) == LaunchpadSwapRouter.NotPoolManager.selector, "callback refuses anyone but the PoolManager");
        return _checks;
    }

    function _json(LaunchpadSwapRouter router, address poolManager, uint256 checks)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"schemaVersion":1,"network":"base-sepolia","chainId":84532,"product":"b20-launchpad-swap-router",',
            '"design":"docs/B20_MINER_LAUNCHPAD_WEB_APP_V1.md \\u00a74.6zp (option A)",',
            '"deployer":"', vm.toString(msg.sender), '","checksPassed":', vm.toString(checks), ",",
            '"contracts":{"launchpadSwapRouter":"', vm.toString(address(router)), '"},',
            '"dependencies":{"uniswapV4PoolManager":"', vm.toString(poolManager), '"},',
            '"parameters":{"swap":"exact input, one V4 pool, caller pays and receives","permit2":false,',
            '"admin":false,"upgradeable":false,"storage":false}}'
        );
    }
}
