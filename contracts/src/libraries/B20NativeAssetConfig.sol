// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IB20} from "base-std/interfaces/IB20.sol";
import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {StdPrecompiles} from "base-std/StdPrecompiles.sol";

/// @notice Canonical, one-shot Base-native B20 Asset configuration for
/// B20MINER. This library deploys no token bytecode: the token is created by
/// Base's singleton B20 Factory precompile and executes through Base-native
/// B20 logic.
library B20NativeAssetConfig {
    string internal constant NAME = "B20MINER";
    string internal constant SYMBOL = "MINER";
    uint8 internal constant DECIMALS = 18;

    bytes32 internal constant CREATION_SALT = keccak256("B20MINER_NATIVE_B20_V1");

    /// @dev Distribution per `B20_REVENUE_MODEL.md` 1.36 (owner decision of
    /// 27 September 2026): snapshot 60B + NFT 1B (was 5B) in the claim
    /// vault, liquidity 25B, ecosystem 5B, team 1B (was 5B), community
    /// rewards 8B (new). Still 100B, minted once.
    uint256 internal constant BASE_AND_NFT_RESERVE = 61_000_000_000 * 1e18;
    uint256 internal constant LIQUIDITY_RESERVE = 25_000_000_000 * 1e18;
    uint256 internal constant ECOSYSTEM_RESERVE = 5_000_000_000 * 1e18;
    uint256 internal constant TEAM_RESERVE = 1_000_000_000 * 1e18;
    uint256 internal constant COMMUNITY_RESERVE = 8_000_000_000 * 1e18;
    uint256 internal constant TOTAL_SUPPLY = 100_000_000_000 * 1e18;

    /// @notice Where the fixed supply goes, and the only three holders of
    /// `BURN_ROLE`: the claim vault and the liquidity finalizer (their own
    /// reserves) and `burner` (`MinerBurner`, every later burn). The
    /// community vault burns its scaled-down excess through `burner`.
    struct Reserves {
        address claimVault;
        address liquidityFinalizer;
        address ecosystemVault;
        address teamVesting;
        address communityVault;
        address burner;
    }

    address internal constant FACTORY_ADDRESS = StdPrecompiles.B20_FACTORY_ADDRESS;

    error NativeB20AddressMismatch(address expected, address actual);
    error NativeB20NotInitialized(address token);
    error NativeB20IdentityOrSupplyMismatch();
    error NativeB20DistributionMismatch();
    error NativeB20RolesMismatch();
    error NativeB20PoliciesMismatch();
    /// @dev A Cobalt-only policy scope read reverted with something other
    /// than the official `IB20.UnsupportedPolicyType` selector, or returned
    /// a malformed (non-32-byte) success value. Never treated as "Cobalt is
    /// not active yet" — that reading is reserved for the one official
    /// revert shape checked in `_readPolicyIdIfSupported`.
    error NativeB20UnexpectedPolicyRevert(bytes32 policyScope, bytes returnData);

    function predictedToken(address creator) internal view returns (address) {
        return StdPrecompiles.B20_FACTORY.getB20Address(IB20Factory.B20Variant.ASSET, creator, CREATION_SALT);
    }

    function createParams() internal pure returns (bytes memory) {
        return B20FactoryLib.encodeAssetCreateParams(NAME, SYMBOL, address(0), DECIMALS);
    }

    /// @dev The new token starts admin-less. The Factory's temporary
    /// bootstrap window sets the exact cap, mints the entire fixed supply
    /// directly to the five reserve contracts, and grants BURN_ROLE only to
    /// the claim vault, the liquidity finalizer and the burner. `BURN_ROLE`
    /// can never be granted afterwards: the token has no admin.
    function initCalls(Reserves memory r) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](5);
        calls[0] = B20FactoryLib.encodeUpdateSupplyCap(TOTAL_SUPPLY);

        address[] memory recipients = new address[](5);
        recipients[0] = r.claimVault;
        recipients[1] = r.liquidityFinalizer;
        recipients[2] = r.ecosystemVault;
        recipients[3] = r.teamVesting;
        recipients[4] = r.communityVault;

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = BASE_AND_NFT_RESERVE;
        amounts[1] = LIQUIDITY_RESERVE;
        amounts[2] = ECOSYSTEM_RESERVE;
        amounts[3] = TEAM_RESERVE;
        amounts[4] = COMMUNITY_RESERVE;
        calls[1] = B20FactoryLib.encodeBatchMint(recipients, amounts);
        calls[2] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, r.claimVault);
        calls[3] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, r.liquidityFinalizer);
        calls[4] = B20FactoryLib.encodeGrantRole(B20Constants.BURN_ROLE, r.burner);
    }

    function create(address creator, Reserves memory r) internal returns (IB20Asset token) {
        address expected = predictedToken(creator);
        address created = StdPrecompiles.B20_FACTORY
            .createB20(IB20Factory.B20Variant.ASSET, CREATION_SALT, createParams(), initCalls(r));
        if (created != expected) revert NativeB20AddressMismatch(expected, created);
        token = IB20Asset(created);
    }

    function requireInitialized(address token) internal view {
        if (!StdPrecompiles.B20_FACTORY.isB20Initialized(token)) {
            revert NativeB20NotInitialized(token);
        }
    }

    /// @dev Reads `token.policyId(policyScope)` tolerating exactly one
    /// revert shape: the official `IB20.UnsupportedPolicyType` selector,
    /// which is what a pre-Cobalt precompile returns for a Cobalt policy
    /// scope such as `SEIZE_EXEMPT_POLICY`/`SEIZE_RECEIVER_POLICY`
    /// (changelog/02_Cobalt_B20_seize.md; Cobalt is live on Base Sepolia
    /// since 23 Sep 2026 and on Base mainnet since 30 Sep 2026) — there is
    /// no official src/-level "is Cobalt active" feature flag to check
    /// instead (base-std only ships a test-mock feature-ID list, which is
    /// not treated as authoritative here). `isSupported` is false only for
    /// that one accepted revert; any other revert, or a success return that
    /// isn't a clean 32-byte `uint64`, is a genuine failure and reverts with
    /// `NativeB20UnexpectedPolicyRevert` — never silently read as "not
    /// active yet".
    function _readPolicyIdIfSupported(IB20Asset token, bytes32 policyScope)
        internal
        view
        returns (bool isSupported, uint64 value)
    {
        (bool ok, bytes memory returnData) = address(token).staticcall(abi.encodeCall(IB20.policyId, (policyScope)));
        if (ok) {
            if (returnData.length != 32) revert NativeB20UnexpectedPolicyRevert(policyScope, returnData);
            return (true, abi.decode(returnData, (uint64)));
        }
        if (returnData.length >= 4 && bytes4(returnData) == IB20.UnsupportedPolicyType.selector) {
            return (false, 0);
        }
        revert NativeB20UnexpectedPolicyRevert(policyScope, returnData);
    }

    function verifyConfiguration(IB20Asset token, address creator, Reserves memory r) internal view {
        address tokenAddress = address(token);
        if (tokenAddress != predictedToken(creator)) {
            revert NativeB20AddressMismatch(predictedToken(creator), tokenAddress);
        }
        requireInitialized(tokenAddress);

        // `multiplier()` is the Beryl name and still canonical. Cobalt (Base
        // Sepolia 23 Sep 2026, Base mainnet 30 Sep 2026, 18:00 UTC) added the
        // ERC-8056 alias `uiMultiplier()` and the pending-schedule reads
        // `newUIMultiplier()`/`effectiveAt()`
        // (changelog/02_Cobalt_B20Asset_multiplier.md). They are not read
        // here: the local `base-forge`/`base-anvil` v1.1.0 used for tests and
        // deploy simulations still runs the Beryl precompile and reverts on
        // them. Nothing can be scheduled anyway (the token has no operator);
        // live Base Sepolia reads 1e18/1e18/0 (checked 30 Sep 2026). Add the
        // three reads once the local toolchain carries Cobalt.
        bool identityAndSupply = keccak256(bytes(token.name())) == keccak256(bytes(NAME))
            && keccak256(bytes(token.symbol())) == keccak256(bytes(SYMBOL)) && token.decimals() == DECIMALS
            && token.supplyCap() == TOTAL_SUPPLY && token.totalSupply() == TOTAL_SUPPLY && token.multiplier() == 1e18;

        bool distribution = token.balanceOf(r.claimVault) == BASE_AND_NFT_RESERVE
            && token.balanceOf(r.liquidityFinalizer) == LIQUIDITY_RESERVE
            && token.balanceOf(r.ecosystemVault) == ECOSYSTEM_RESERVE && token.balanceOf(r.teamVesting) == TEAM_RESERVE
            && token.balanceOf(r.communityVault) == COMMUNITY_RESERVE && token.balanceOf(r.burner) == 0
            && token.balanceOf(creator) == 0;

        // `SEIZE_ROLE` (like `seizeWithMemo` itself) came with Cobalt
        // (changelog/02_Cobalt_B20_seize.md). `hasRole` is a generic
        // membership check that never reverts. No participant address may
        // hold it; with no admin it can never be granted (confirmed on live
        // Base Sepolia after Cobalt, 30 Sep 2026).
        bool roles = !token.hasRole(B20Constants.DEFAULT_ADMIN_ROLE, creator)
            && !token.hasRole(B20Constants.MINT_ROLE, creator) && _burnRolesExact(token, creator, r)
            && !token.hasRole(B20Constants.BURN_BLOCKED_ROLE, creator)
            && !token.hasRole(B20Constants.PAUSE_ROLE, creator) && !token.hasRole(B20Constants.UNPAUSE_ROLE, creator)
            && !token.hasRole(B20Constants.METADATA_ROLE, creator)
            && !token.hasRole(B20Constants.OPERATOR_ROLE, creator) && _noSeizeRole(token, creator, r);

        // The four Beryl-era policy scopes are always dialable — a revert
        // here is a genuine failure, never tolerated.
        bool policies = token.policyId(B20Constants.TRANSFER_SENDER_POLICY) == 0
            && token.policyId(B20Constants.TRANSFER_RECEIVER_POLICY) == 0
            && token.policyId(B20Constants.TRANSFER_EXECUTOR_POLICY) == 0
            && token.policyId(B20Constants.MINT_RECEIVER_POLICY) == 0;

        // `SEIZE_EXEMPT_POLICY`/`SEIZE_RECEIVER_POLICY` came with Cobalt
        // (changelog/02_Cobalt_B20_seize.md), now live on both Base
        // networks: both must read exactly `0`, same as every other policy
        // slot (`SEIZE_EXEMPT_POLICY` 0 = every holder exempt, nobody
        // seizable). `_readPolicyIdIfSupported` still tolerates the official
        // pre-Cobalt `UnsupportedPolicyType` revert of the Beryl-only local
        // precompile (`base-forge` v1.1.0), where no seize surface exists.
        (bool seizeExemptSupported, uint64 seizeExemptPolicyId) =
            _readPolicyIdIfSupported(token, B20Constants.SEIZE_EXEMPT_POLICY);
        (bool seizeReceiverSupported, uint64 seizeReceiverPolicyId) =
            _readPolicyIdIfSupported(token, B20Constants.SEIZE_RECEIVER_POLICY);
        bool seizePolicies = (!seizeExemptSupported || seizeExemptPolicyId == 0)
            && (!seizeReceiverSupported || seizeReceiverPolicyId == 0);

        if (!identityAndSupply) revert NativeB20IdentityOrSupplyMismatch();
        if (!distribution) revert NativeB20DistributionMismatch();
        if (!roles) revert NativeB20RolesMismatch();
        if (!policies || !seizePolicies) revert NativeB20PoliciesMismatch();
    }

    /// @dev `BURN_ROLE` on exactly the claim vault, the liquidity finalizer
    /// and the burner — not the creator, the ecosystem vault, team vesting
    /// or the community vault.
    function _burnRolesExact(IB20Asset token, address creator, Reserves memory r) private view returns (bool) {
        return token.hasRole(B20Constants.BURN_ROLE, r.claimVault)
            && token.hasRole(B20Constants.BURN_ROLE, r.liquidityFinalizer) && token.hasRole(B20Constants.BURN_ROLE, r.burner)
            && !token.hasRole(B20Constants.BURN_ROLE, creator) && !token.hasRole(B20Constants.BURN_ROLE, r.ecosystemVault)
            && !token.hasRole(B20Constants.BURN_ROLE, r.teamVesting)
            && !token.hasRole(B20Constants.BURN_ROLE, r.communityVault);
    }

    /// @dev No participant holds `SEIZE_ROLE` (added by Cobalt).
    function _noSeizeRole(IB20Asset token, address creator, Reserves memory r) private view returns (bool) {
        return !token.hasRole(B20Constants.SEIZE_ROLE, creator) && !token.hasRole(B20Constants.SEIZE_ROLE, r.claimVault)
            && !token.hasRole(B20Constants.SEIZE_ROLE, r.liquidityFinalizer)
            && !token.hasRole(B20Constants.SEIZE_ROLE, r.ecosystemVault)
            && !token.hasRole(B20Constants.SEIZE_ROLE, r.teamVesting)
            && !token.hasRole(B20Constants.SEIZE_ROLE, r.communityVault)
            && !token.hasRole(B20Constants.SEIZE_ROLE, r.burner);
    }
}
