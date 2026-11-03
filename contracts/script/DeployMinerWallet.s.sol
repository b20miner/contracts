// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MinerWallet} from "../src/wallet/MinerWallet.sol";
import {MinerWalletFactory} from "../src/wallet/MinerWalletFactory.sol";
import {MinerRelay} from "../src/wallet/MinerRelay.sol";

/// @notice K59–K62: the MinerWalletFactory, one script for both networks:
/// Base (8453) and Base Sepolia (84532) (owner, 30 October 2026). Both
/// contracts it trusts come from this network's records: B20MINER's
/// `B20Mining` from the genesis record (`launch-flow-deployment.json`) and
/// the Launchpad factory from `launchpad-deployment.json`. v11 (30 Oct 2026)
/// trusts the new testnet genesis and Launchpad v16; v12 (31 Oct 2026) the
/// H-1 genesis and Launchpad v17; v13 (2 Nov 2026) the same, with the
/// internal audit v17 M-1 refund fix. Before: the MinerWalletFactory on Base Sepolia
/// (`docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md` §26–§29; K62: keys hold no
/// ETH, they sign orders that anyone relays and the wallet pays the
/// relayer's gas back). Two transactions: the factory, which deploys its
/// fixed `MinerWallet` implementation in its constructor, and the stateless
/// `MinerRelay` batch sender. Nothing deployed has an owner, an admin or an
/// upgrade.
/// K64 (8 Oct 2026, MinerWalletFactory v6): a new factory whose wallets trust
/// Launchpad v11 from the start. `MINER_RELAY` reuses the deployed relay
/// (stateless, wallet-agnostic): then only the factory is sent.
/// The same script made v7 (Launchpad v12, 8 Oct 2026) and makes v8 for
/// Launchpad v13 (no staking, 22 Oct 2026), v9 for v14 (26 Oct 2026) and
/// v10 for v15 (tMINER, K70, 28 Oct 2026): it trusts whatever factory
/// `launchpad-deployment.json` records (or `LAUNCHPAD_FACTORY`).
/// @dev Run without `--broadcast` first. The broadcaster signs with its
/// encrypted Foundry keystore (`--account`); no private key is read here.
contract DeployMinerWallet is Script {
    uint256 internal constant BASE_CHAIN_ID = 8_453;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal _checks;

    error UnsupportedChain(uint256 chainId);

    function run() external returns (MinerWalletFactory factory, MinerRelay relay) {
        address launchpad = _launchpadFactory();
        address mining = _b20Mining();
        address reuse = vm.envOr("MINER_RELAY", address(0));
        vm.startBroadcast();
        factory = new MinerWalletFactory(mining, launchpad);
        relay = reuse != address(0) ? MinerRelay(reuse) : new MinerRelay();
        vm.stopBroadcast();
        uint256 checks = _verify(factory, relay, mining, launchpad);
        string memory out = _outputPath();
        vm.writeJson(_json(factory, relay, mining, launchpad, checks), out);
        console2.log("MinerWalletFactory", address(factory));
        console2.log("implementation      ", address(factory.IMPLEMENTATION()));
        console2.log("MinerRelay          ", address(relay));
        console2.log("checks passed       ", checks);
    }

    /// @notice Re-runs every check against the recorded deployment.
    function verifyRecorded() external returns (uint256 checks) {
        string memory json = vm.readFile(_outputPath());
        MinerWalletFactory factory = MinerWalletFactory(vm.parseJsonAddress(json, ".contracts.minerWalletFactory"));
        MinerRelay relay = MinerRelay(vm.parseJsonAddress(json, ".contracts.minerRelay"));
        checks = _verify(
            factory,
            relay,
            vm.parseJsonAddress(json, ".dependencies.b20Mining"),
            vm.parseJsonAddress(json, ".dependencies.launchpadFactory")
        );
        console2.log("MinerWallet: checks passed", checks);
    }

    /// @notice The record folder: `base` or `base-sepolia`.
    function _networkName() internal view returns (string memory) {
        if (block.chainid == BASE_CHAIN_ID) return "base";
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return "base-sepolia";
        revert UnsupportedChain(block.chainid);
    }

    /// @dev Base mainnet has no Launchpad (testnet-first, 12 Oct 2026): its
    /// wallets trust no campaign factory (zero) unless `LAUNCHPAD_FACTORY`
    /// names one; an owner can add one later (`proposeFactory`, 48 hours).
    /// Base Sepolia trusts the Launchpad its record names.
    function _launchpadFactory() internal view returns (address) {
        if (block.chainid == BASE_CHAIN_ID) return vm.envOr("LAUNCHPAD_FACTORY", address(0));
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/launchpad-deployment.json")
        );
        return vm.envOr("LAUNCHPAD_FACTORY", vm.parseJsonAddress(json, ".contracts.launchpadFactory"));
    }

    function _b20Mining() internal view returns (address) {
        string memory json = vm.readFile(
            vm.envOr(
                "GENESIS_RECORD_PATH",
                string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/launch-flow-deployment.json")
            )
        );
        return vm.envOr("B20_MINING", vm.parseJsonAddress(json, ".contracts.b20Mining"));
    }

    function _outputPath() internal view returns (string memory) {
        return vm.envOr(
            "MINER_WALLET_OUTPUT_PATH",
            string.concat(vm.projectRoot(), "/../deployments/", _networkName(), "/miner-wallet-deployment.json")
        );
    }

    function _check(bool ok, string memory what) internal {
        require(ok, what);
        _checks++;
    }

    function _verify(MinerWalletFactory factory, MinerRelay relay, address mining, address launchpad)
        internal
        returns (uint256)
    {
        _checks = 0;
        MinerWallet impl = factory.IMPLEMENTATION();
        _check(address(factory).code.length > 0 && address(impl).code.length > 0, "factory and implementation have code");
        _check(address(relay).code.length > 0, "MinerRelay has code");
        _check(impl.FACTORY() == address(factory), "implementation is initialised only by this factory");
        _check(impl.B20_MINING() == mining, "B20MINER mining contract (genesis record)");
        _check(mining.code.length > 0, "B20Mining has code");
        _check(
            impl.LAUNCHPAD_FACTORY() == launchpad
                && (launchpad.code.length > 0 || (launchpad == address(0) && block.chainid == BASE_CHAIN_ID)),
            "Launchpad factory (current; none on Base mainnet)"
        );
        _check(impl.owner() == address(0xdead) && impl.epoch() == 0, "implementation is unusable (owner 0xdead)");
        _check(impl.RELAY_OVERHEAD() == 12_000 && impl.L1_ENVELOPE() == 120, "relay overhead 12,000 gas, L1 envelope 120 bytes");
        _check(impl.FINISH_GAS() == 60_000, "60,000 gas kept for the refund after the target call");
        _check(impl.FACTORY_DELAY() == 48 hours, "a proposed factory waits 48 hours (K62)");
        _check(
            impl.MAX_REFUND_TIP() == 0.01 gwei && impl.MAX_OWNER_SIG() == 1024,
            "refund price capped at base fee + 0.01 gwei, owner signature at most 1,024 bytes (audit v17 M-1)"
        );
        (, string memory name, string memory version,,,,) = impl.eip712Domain();
        _check(
            keccak256(bytes(name)) == keccak256("B20 MinerWallet") && keccak256(bytes(version)) == keccak256("5"),
            "EIP-712 domain B20 MinerWallet / 5"
        );
        address probe = address(0xBEEF);
        _check(factory.walletOf(probe) == address(0) && factory.predict(probe) != address(0), "walletOf / predict");
        return _checks;
    }

    function _json(MinerWalletFactory factory, MinerRelay relay, address mining, address launchpad, uint256 checks)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"schemaVersion":1,"network":"', _networkName(), '","chainId":', vm.toString(block.chainid), ',"product":"b20-miner-wallet",',
            '"design":"docs/B20_MINER_LAUNCHPAD_CONTRACTS_V1.md 1.34 \\u00a729 (K59-K62), \\u00a731 (K64)",',
            '"deployer":"', vm.toString(msg.sender), '","checksPassed":', vm.toString(checks), ",",
            '"contracts":{"minerWalletFactory":"', vm.toString(address(factory)),
            '","minerWalletImplementation":"', vm.toString(address(factory.IMPLEMENTATION())),
            '","minerRelay":"', vm.toString(address(relay)), '"},',
            '"dependencies":{"b20Mining":"', vm.toString(mining), '","launchpadFactory":"', vm.toString(launchpad), '"},',
            '"parameters":{"model":"relayed-orders","relayOverheadGas":12000,"l1EnvelopeBytes":120,"finishGas":60000,"factoryDelaySeconds":172800,"maxRefundTipWei":"10000000","maxOwnerSigBytes":1024,"canonicalCalldata":true,',
            '"eip712":{"name":"B20 MinerWallet","version":"5"},"keyFloatWei":"0","admin":false,"upgradeable":false,"walletsPerOwner":1}}'
        );
    }
}
