// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MiningCampaign} from "../../src/launchpad/MiningCampaign.sol";
import {B20PoW} from "../../src/B20PoW.sol";
import {MinerWallet} from "../../src/wallet/MinerWallet.sol";
import {MinerWalletFactory} from "../../src/wallet/MinerWalletFactory.sol";
import {MinerRelay} from "../../src/wallet/MinerRelay.sol";

contract WalletTestToken is ERC20 {
    constructor() ERC20("Kedi", "KEDI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// Stands in for `LaunchpadFactory`: initialises campaigns (so their
/// `factory()` is this contract) and keeps the `campaignOf` registry.
contract MockLaunchpadFactory {
    struct Campaign {
        address campaign;
        address pool;
        address creator;
        uint64 createdAt;
    }

    mapping(address token => Campaign) public campaignOf;

    function launch(address impl, MiningCampaign.InitParams memory p, bool register)
        external
        returns (MiningCampaign c)
    {
        c = MiningCampaign(payable(Clones.clone(impl)));
        c.initialize(p);
        WalletTestToken(p.token).mint(address(c), p.miningReserve);
        if (register) campaignOf[p.token] = Campaign(address(c), p.pool, msg.sender, uint64(block.timestamp));
    }
}

/// Stands in for `B20Mining`: same `quoteProof` / `submitProof` shape;
/// records the call and refunds any excess like the real contract.
contract MockB20Mining {
    uint256 public constant FEE = 26_041_666_666_667;
    address public lastOwner;
    address public lastMiner;
    uint256 public proofs;
    /// Burns every bit of gas it is given (a worst-case target).
    bool public burn;

    function setBurn(bool b) external {
        burn = b;
    }

    function quoteProof(address) external pure returns (uint256 reward, uint256 fee) {
        return (312.5e18, FEE);
    }

    function submitProof(address owner, bytes32, uint256) external payable {
        if (burn) {
            while (true) {}
        }
        require(msg.value >= FEE, "fee");
        lastOwner = owner;
        lastMiner = msg.sender;
        proofs++;
        if (msg.value > FEE) {
            (bool ok,) = msg.sender.call{value: msg.value - FEE}("");
            require(ok, "refund");
        }
    }
}

/// An owner wallet that is itself a contract (ERC-1271), e.g. a smart wallet.
contract Mock1271Owner {
    address public immutable signer;

    constructor(address s) {
        signer = s;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s_) = (uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64]));
        return ecrecover(hash, v, r, s_) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function create(MinerWalletFactory f) external returns (address) {
        return f.create();
    }
}

/// K62: the wallet pays the relayer back, keys hold no ETH.
contract MinerWalletTest is Test {
    uint256 constant PROOF_FEE = 100_000_000_000_000; // 0.0001 ETH
    uint256 constant OWNER_PK = 0xA11CE;
    uint256 constant KEY_PK = 0x4E1;
    uint256 constant KEY2_PK = 0x4E2;
    address constant OTHER = address(0xB0B);
    address constant TREASURY = address(0x7EA5);
    address constant RELAYER = address(0x7E1A);
    uint256 constant GAS_PRICE = 0.01 gwei;
    uint256 constant PROOF_GAS = 300_000;
    uint256 constant SHARES_GAS = 500_000;

    address OWNER;
    address KEY;
    address KEY2;

    MiningCampaign campaignImpl;
    MockLaunchpadFactory launchpad;
    MockB20Mining b20;
    MinerWalletFactory factory;
    MinerRelay relayer;
    WalletTestToken token;
    uint256 opNonce;

    receive() external payable {} // plays the CampaignPool

    function setUp() public {
        vm.warp(1_800_000_000);
        OWNER = vm.addr(OWNER_PK);
        KEY = vm.addr(KEY_PK);
        KEY2 = vm.addr(KEY2_PK);
        campaignImpl = new MiningCampaign();
        launchpad = new MockLaunchpadFactory();
        b20 = new MockB20Mining();
        factory = new MinerWalletFactory(address(b20), address(launchpad));
        relayer = new MinerRelay();
        vm.deal(OWNER, 10 ether);
        vm.deal(OTHER, 10 ether);
        vm.txGasPrice(GAS_PRICE);
    }

    // ---------------------------------------------------------------- helpers

    function _params() internal returns (MiningCampaign.InitParams memory p) {
        token = new WalletTestToken();
        p.token = address(token);
        p.pool = address(this);
        p.platformTreasury = TREASURY;
        p.powTarget = type(uint256).max >> 5; // share target: half of all hashes
        p.proofFee = PROOF_FEE;
        p.supplyWhole = 1_000_000_000;
        p.miningReserve = uint256(1_000_000_000e18) * 2 / 3;
        p.start = uint64(block.timestamp + 1 hours);
        p.durationDays = 7;
        p.walletCapWei = 1 ether;
    }

    function _campaign(MockLaunchpadFactory f, bool register) internal returns (MiningCampaign c) {
        MiningCampaign.InitParams memory p = _params();
        c = f.launch(address(campaignImpl), p, register);
        vm.warp(c.start());
        c.open();
    }

    function _wallet() internal returns (MinerWallet w) {
        vm.prank(OWNER);
        w = MinerWallet(payable(factory.create()));
    }

    function _funded(uint256 amount) internal returns (MinerWallet w) {
        w = _wallet();
        vm.prank(OWNER);
        w.deposit{value: amount}();
    }

    /// 16 shares found by `miner` (the wallet) for `owner`.
    function _shares(MiningCampaign c, address owner, address miner) internal view returns (uint256[16] memory n) {
        bytes32 ch = c.challengeOf(owner);
        uint256 target = c.shareTarget();
        uint256 k;
        for (uint256 nonce; k < 16; nonce++) {
            if (uint256(B20PoW.computeHash(block.chainid, address(c), owner, miner, ch, nonce)) <= target) n[k++] = nonce;
        }
    }

    function _digest(MinerWallet w, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("B20 MinerWallet"),
                keccak256("5"),
                block.chainid,
                address(w)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _auth(MinerWallet w, address key) internal view returns (bytes memory) {
        return _sign(OWNER_PK, w.keyAuthDigest(key));
    }

    function _order(address target, bytes32 ch, uint256 callGas) internal returns (MinerWallet.Order memory o) {
        o = MinerWallet.Order({
            target: target,
            challenge: ch,
            maxFee: PROOF_FEE,
            maxGasPrice: 1 gwei,
            callGas: callGas,
            opNonce: ++opNonce,
            deadline: uint64(block.timestamp + 120)
        });
    }

    function _proofSig(MinerWallet w, uint256 pk, MinerWallet.Order memory o, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            _digest(
                w,
                keccak256(
                    abi.encode(
                        w.MINE_PROOF_TYPEHASH(),
                        o.target,
                        o.challenge,
                        nonce,
                        o.maxFee,
                        o.maxGasPrice,
                        o.callGas,
                        o.opNonce,
                        o.deadline
                    )
                )
            )
        );
    }

    function _sharesSig(MinerWallet w, uint256 pk, MinerWallet.Order memory o, uint256[16] memory nonces)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            _digest(
                w,
                keccak256(
                    abi.encode(
                        w.MINE_SHARES_TYPEHASH(),
                        o.target,
                        o.challenge,
                        keccak256(abi.encodePacked(nonces)),
                        o.maxFee,
                        o.maxGasPrice,
                        o.callGas,
                        o.opNonce,
                        o.deadline
                    )
                )
            )
        );
    }

    /// The relayer sends a key's signed B20 proof (with the owner's permission).
    function _relayProof(MinerWallet w, uint256 pk, uint256 nonce, bytes memory ownerSig) internal {
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory sig = _proofSig(w, pk, o, nonce);
        vm.prank(RELAYER, RELAYER);
        w.relayProof(o, nonce, sig, ownerSig);
    }

    // ------------------------------------------------------------- creation

    function test_createOncePerOwnerAtThePredictedAddress() public {
        address predicted = factory.predict(OWNER);
        MinerWallet w = _wallet();
        assertEq(address(w), predicted);
        assertEq(factory.walletOf(OWNER), predicted);
        assertEq(w.owner(), OWNER);
        assertEq(w.epoch(), 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(MinerWalletFactory.AlreadyCreated.selector, predicted));
        factory.create();
    }

    function test_createCostsGasOnlyAndValueIsDeposited() public {
        uint256 before = OWNER.balance;
        _wallet();
        assertEq(OWNER.balance, before);
        vm.prank(OTHER);
        MinerWallet w = MinerWallet(payable(factory.create{value: 0.05 ether}()));
        assertEq(address(w).balance, 0.05 ether);
    }

    function test_implementationAndWalletCannotBeReinitialised() public {
        MinerWallet impl = factory.IMPLEMENTATION();
        vm.expectRevert(MinerWallet.NotFactory.selector);
        impl.initialize(OTHER);
        MinerWallet w = _wallet();
        vm.prank(address(factory));
        vm.expectRevert(MinerWallet.AlreadyInitialized.selector);
        w.initialize(OTHER);
    }

    // ------------------------------------------------------------- deposits

    function test_depositsFromAnyone() public {
        MinerWallet w = _funded(0.01 ether);
        vm.prank(OTHER);
        (bool ok,) = address(w).call{value: 0.02 ether}("");
        assertTrue(ok);
        vm.prank(OTHER);
        payable(address(w)).transfer(0.01 ether); // the 2,300-gas stipend still deposits
        assertEq(address(w).balance, 0.04 ether);
    }

    // ------------------------------------------------------------- relayed mining

    function test_relayedProofMinesForTheOwnerAndPaysTheRelayerBack() public {
        MinerWallet w = _funded(0.01 ether);
        _relayProof(w, KEY_PK, 1, _auth(w, KEY));
        assertEq(b20.proofs(), 1);
        assertEq(b20.lastOwner(), OWNER);
        assertEq(b20.lastMiner(), address(w));
        assertTrue(w.isKey(KEY));
        assertEq(KEY.balance, 0, "the key never holds ETH");
        uint256 refund = RELAYER.balance;
        assertGt(refund, 0);
        assertLt(refund, 200_000 * GAS_PRICE);
        assertEq(address(w).balance, 0.01 ether - b20.FEE() - refund);
        // Later orders need no owner signature.
        _relayProof(w, KEY_PK, 2, "");
        assertEq(b20.proofs(), 2);
    }

    function test_relayedSharesMineForTheOwner() public {
        MiningCampaign c = _campaign(launchpad, true);
        MinerWallet w = _funded(0.01 ether);
        uint256[16] memory nonces = _shares(c, OWNER, address(w));
        (uint256 reward,) = c.quoteProof(OWNER);
        MinerWallet.Order memory o = _order(address(c), c.challengeOf(OWNER), SHARES_GAS);
        bytes memory sig = _sharesSig(w, KEY_PK, o, nonces);
        bytes memory auth = _auth(w, KEY);
        vm.deal(RELAYER, 1 ether); // a working relayer is never an empty account
        vm.prank(RELAYER, RELAYER);
        uint256 g0 = gasleft();
        w.relayShares(o, nonces, sig, auth);
        uint256 used = g0 - gasleft();
        assertEq(c.minedOf(OWNER), reward);
        uint256 refund = RELAYER.balance - 1 ether;
        assertEq(address(w).balance, 0.01 ether - PROOF_FEE - refund);
        // The refund is the call's gas plus what a transaction adds around it
        // (calldata, a share of the base cost): close to the real cost, not a
        // margin for the relayer. Exact tuning: the fork measurement.
        emit log_named_uint("relayShares gas (measured by the test)", used);
        emit log_named_uint("refunded gas units", refund / GAS_PRICE);
        assertApproxEqAbs(refund / GAS_PRICE, used, 40_000);
    }

    function test_aKeyNeedsTheOwnersPermission() public {
        MinerWallet w = _funded(0.01 ether);
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory sig = _proofSig(w, KEY_PK, o, 1);
        vm.startPrank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.KeyNotAllowed.selector, KEY));
        w.relayProof(o, 1, sig, "");
        // A permission signed by someone else.
        bytes memory forged = _sign(KEY_PK, w.keyAuthDigest(KEY));
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.KeyNotAllowed.selector, KEY));
        w.relayProof(o, 1, sig, forged);
        // The owner's permission for another key.
        bytes memory other = _auth(w, KEY2);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.KeyNotAllowed.selector, KEY));
        w.relayProof(o, 1, sig, other);
        vm.stopPrank();
        assertEq(b20.proofs(), 0);
    }

    function test_anOrderIsUsedOnceAndInOrder() public {
        MinerWallet w = _funded(0.01 ether);
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory sig = _proofSig(w, KEY_PK, o, 1);
        bytes memory auth = _auth(w, KEY);
        vm.startPrank(RELAYER, RELAYER);
        w.relayProof(o, 1, sig, auth);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.UsedOrder.selector, o.opNonce, o.opNonce));
        w.relayProof(o, 1, sig, auth);
        vm.stopPrank();
        assertEq(w.lastOpNonce(KEY), o.opNonce);
    }

    function test_theKeysLimitsBindTheSender() public {
        MinerWallet w = _funded(0.01 ether);
        bytes memory auth = _auth(w, KEY);
        // Gas price above the signed limit.
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        o.maxGasPrice = GAS_PRICE - 1;
        bytes memory sig = _proofSig(w, KEY_PK, o, 1);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.GasPriceAboveLimit.selector, GAS_PRICE, GAS_PRICE - 1));
        w.relayProof(o, 1, sig, auth);
        // Fee above the signed limit.
        o = _order(address(b20), bytes32(0), PROOF_GAS);
        o.maxFee = b20.FEE() - 1;
        sig = _proofSig(w, KEY_PK, o, 1);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.FeeAboveLimit.selector, b20.FEE(), b20.FEE() - 1));
        w.relayProof(o, 1, sig, auth);
        // Expired.
        o = _order(address(b20), bytes32(0), PROOF_GAS);
        sig = _proofSig(w, KEY_PK, o, 1);
        vm.warp(o.deadline + 1);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.Expired.selector, o.deadline));
        w.relayProof(o, 1, sig, auth);
        // A changed field breaks the signature (another key, not allowed).
        o = _order(address(b20), bytes32(0), PROOF_GAS);
        sig = _proofSig(w, KEY_PK, o, 1);
        o.maxFee = 1 ether;
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert();
        w.relayProof(o, 1, sig, auth);
        assertEq(b20.proofs(), 0);
    }

    function test_untrustedTargetsAreRejected() public {
        MinerWallet w = _funded(0.01 ether);
        bytes memory auth = _auth(w, KEY);
        MiningCampaign fake = _campaign(launchpad, false); // factory() trusted, never registered
        uint256[16] memory nonces;
        MinerWallet.Order memory o = _order(address(fake), bytes32(0), SHARES_GAS);
        bytes memory sig = _sharesSig(w, KEY_PK, o, nonces);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.UntrustedTarget.selector, address(fake)));
        w.relayShares(o, nonces, sig, auth);
        o = _order(OTHER, bytes32(0), PROOF_GAS);
        sig = _proofSig(w, KEY_PK, o, 1);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.UntrustedTarget.selector, OTHER));
        w.relayProof(o, 1, sig, auth);
        o = _order(address(b20), bytes32(0), SHARES_GAS); // no shares at B20Mining
        sig = _sharesSig(w, KEY_PK, o, nonces);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.UntrustedTarget.selector, address(b20)));
        w.relayShares(o, nonces, sig, auth);
    }

    function test_miningNeedsTheFeeInTheWallet() public {
        MinerWallet w = _wallet();
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory sig = _proofSig(w, KEY_PK, o, 1);
        bytes memory auth = _auth(w, KEY);
        uint256 fee = b20.FEE();
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.InsufficientBalance.selector, 0, fee));
        w.relayProof(o, 1, sig, auth);
    }

    /// A refused order (stale challenge) pays no fee, uses the order and
    /// still pays the relayer back.
    function test_aRefusedOrderPaysNoFeeButRefundsTheRelayer() public {
        MiningCampaign c = _campaign(launchpad, true);
        MinerWallet w = _funded(0.01 ether);
        uint256[16] memory nonces = _shares(c, OWNER, address(w));
        MinerWallet.Order memory o = _order(address(c), bytes32(uint256(1)), SHARES_GAS); // stale
        bytes memory sig = _sharesSig(w, KEY_PK, o, nonces);
        bytes memory auth = _auth(w, KEY);
        vm.prank(RELAYER, RELAYER);
        w.relayShares(o, nonces, sig, auth);
        assertEq(c.minedOf(OWNER), 0);
        uint256 refund = RELAYER.balance;
        assertGt(refund, 0);
        assertEq(address(w).balance, 0.01 ether - refund, "no fee was paid");
        assertEq(w.lastOpNonce(KEY), o.opNonce);
    }

    /// The sender cannot starve the target call into a refunded failure.
    function test_theSenderMustGiveTheTargetItsGas() public {
        MinerWallet w = _funded(0.01 ether);
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory sig = _proofSig(w, KEY_PK, o, 1);
        bytes memory auth = _auth(w, KEY);
        vm.prank(RELAYER, RELAYER);
        (bool ok, bytes memory ret) =
            address(w).call{gas: 250_000}(abi.encodeCall(MinerWallet.relayProof, (o, 1, sig, auth)));
        assertFalse(ok);
        assertEq(bytes4(ret), MinerWallet.NotEnoughGas.selector);
        assertEq(b20.proofs(), 0);
    }

    /// K62: once the gas guard passes, the order always finishes and refunds
    /// its sender, even when the target burns all of `callGas` (the work
    /// after the call has `FINISH_GAS`).
    function test_aTargetThatBurnsItsGasStillLeavesTheRefund() public {
        MinerWallet w = _funded(0.01 ether);
        b20.setBurn(true);
        vm.txGasPrice(1 gwei);
        bytes memory auth = _auth(w, KEY);
        uint256 finished;
        for (uint256 g = PROOF_GAS; g < PROOF_GAS + 200_000; g += 2_000) {
            uint256 snap = vm.snapshotState();
            MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
            bytes memory sig = _proofSig(w, KEY_PK, o, 1);
            uint256 before = RELAYER.balance;
            vm.prank(RELAYER, RELAYER);
            (bool ok, bytes memory ret) = address(w).call{gas: g}(abi.encodeCall(MinerWallet.relayProof, (o, 1, sig, auth)));
            if (ok) {
                finished++;
                assertGt(RELAYER.balance, before, "refunded");
                assertEq(w.lastOpNonce(KEY), o.opNonce, "the order is used");
            } else {
                assertEq(bytes4(ret), MinerWallet.NotEnoughGas.selector, "only the guard may stop it");
            }
            vm.revertToState(snap);
        }
        assertGt(finished, 0);
    }

    /// A stolen key can only mine for the owner, at prices it signed, and
    /// the refund never exceeds the transaction's real cost.
    function test_aStolenKeyCannotDrainTheWallet() public {
        MinerWallet w = _funded(1 ether);
        bytes memory auth = _auth(w, KEY);
        uint256 before = address(w).balance;
        vm.txGasPrice(1 gwei); // the thief's own price, at the signed limit
        for (uint256 i; i < 5; ++i) {
            _relayProof(w, KEY_PK, i, i == 0 ? auth : bytes(""));
        }
        uint256 refunds = RELAYER.balance;
        assertEq(before - address(w).balance, 5 * b20.FEE() + refunds);
        assertLt(refunds, 5 * 200_000 * 1 gwei);
        assertEq(b20.lastOwner(), OWNER);
    }

    // ------------------------------------------------------------- keys

    function test_theOwnerRevokesOneKeyOrAll() public {
        MinerWallet w = _funded(0.1 ether);
        bytes memory auth = _auth(w, KEY);
        _relayProof(w, KEY_PK, 1, auth);
        vm.prank(OTHER);
        vm.expectRevert(MinerWallet.NotOwner.selector);
        w.revokeKey(KEY);
        vm.prank(OWNER);
        w.revokeKey(KEY);
        assertFalse(w.isKey(KEY));
        assertTrue(w.isRevoked(KEY));
        assertFalse(w.isRevoked(KEY2));
        // The old permission no longer works.
        MinerWallet.Order memory o = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory sig = _proofSig(w, KEY_PK, o, 2);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.KeyNotAllowed.selector, KEY));
        w.relayProof(o, 2, sig, auth);
        // The owner allows it again with a transaction.
        vm.prank(OWNER);
        w.allowKey(KEY);
        assertFalse(w.isRevoked(KEY));
        vm.prank(RELAYER, RELAYER);
        w.relayProof(o, 2, sig, "");
        assertEq(b20.proofs(), 2);

        // Revoke everything: every earlier permission ends.
        bytes memory auth2 = _auth(w, KEY2);
        _relayProof(w, KEY2_PK, 3, auth2);
        vm.prank(OWNER);
        w.revokeKey(KEY);
        vm.prank(OWNER);
        w.revokeAllKeys();
        assertEq(w.epoch(), 1);
        assertFalse(w.isRevoked(KEY), "a new generation starts with no revocations");
        assertFalse(w.isKey(KEY));
        assertFalse(w.isKey(KEY2));
        o = _order(address(b20), bytes32(0), PROOF_GAS);
        sig = _proofSig(w, KEY2_PK, o, 4);
        vm.prank(RELAYER, RELAYER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.KeyNotAllowed.selector, KEY2));
        w.relayProof(o, 4, sig, auth2);
        // A fresh permission for the new generation works.
        vm.prank(RELAYER, RELAYER);
        w.relayProof(o, 4, sig, _auth(w, KEY2));
        assertTrue(w.isKey(KEY2));
    }

    /// K60 still holds: the MINER app and the Launchpad (two keys) mine from one wallet.
    function test_twoKeysMineFromTheSameWallet() public {
        MiningCampaign c = _campaign(launchpad, true);
        MinerWallet w = _funded(0.05 ether);
        _relayProof(w, KEY_PK, 1, _auth(w, KEY));
        uint256[16] memory nonces = _shares(c, OWNER, address(w));
        MinerWallet.Order memory o = _order(address(c), c.challengeOf(OWNER), SHARES_GAS);
        bytes memory sig = _sharesSig(w, KEY2_PK, o, nonces);
        vm.prank(RELAYER, RELAYER);
        w.relayShares(o, nonces, sig, _auth(w, KEY2));
        assertEq(b20.lastMiner(), address(w));
        assertGt(c.minedOf(OWNER), 0);
        assertTrue(w.isKey(KEY) && w.isKey(KEY2));
    }

    function test_aSmartWalletOwnerAllowsKeysWithERC1271() public {
        Mock1271Owner smart = new Mock1271Owner(vm.addr(OWNER_PK));
        MinerWallet w = MinerWallet(payable(smart.create(factory)));
        vm.deal(address(w), 0.01 ether);
        bytes memory auth = _sign(OWNER_PK, w.keyAuthDigest(KEY));
        _relayProof(w, KEY_PK, 1, auth);
        assertEq(b20.lastOwner(), address(smart));
    }

    // ------------------------------------------------------------- owner

    function test_theOwnerMinesDirectlyWithoutAnyServer() public {
        MiningCampaign c = _campaign(launchpad, true);
        MinerWallet w = _funded(0.01 ether);
        vm.prank(OWNER);
        w.mineProof(address(b20), bytes32(0), 1);
        uint256[16] memory nonces = _shares(c, OWNER, address(w));
        bytes32 ch = c.challengeOf(OWNER);
        vm.prank(OWNER);
        w.mineShares(address(c), ch, nonces);
        assertEq(b20.proofs(), 1);
        assertGt(c.minedOf(OWNER), 0);
        vm.prank(KEY);
        vm.expectRevert(MinerWallet.NotOwner.selector);
        w.mineProof(address(b20), bytes32(0), 2);
    }

    /// K62: a later Launchpad factory is trusted only 48 hours after the
    /// owner proposes it, and the owner can cancel it any time.
    function test_aProposedFactoryWaits48Hours() public {
        MockLaunchpadFactory next = new MockLaunchpadFactory();
        MiningCampaign c = _campaign(next, true);
        MinerWallet w = _funded(0.01 ether);
        vm.prank(OTHER);
        vm.expectRevert(MinerWallet.NotOwner.selector);
        w.proposeFactory(address(next));
        vm.prank(OWNER);
        w.proposeFactory(address(next));
        assertFalse(w.isTrustedCampaign(address(c)));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.FactoryAlreadyProposed.selector, address(next)));
        w.proposeFactory(address(next));
        vm.warp(block.timestamp + 48 hours - 1);
        assertFalse(w.isTrustedCampaign(address(c)));
        vm.warp(block.timestamp + 1);
        assertTrue(w.isTrustedCampaign(address(c)));
        vm.prank(OWNER);
        w.cancelFactory(address(next));
        assertFalse(w.isTrustedCampaign(address(c)));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(MinerWallet.UnknownFactory.selector, address(next)));
        w.cancelFactory(address(next));
    }

    function test_withdrawReturnsEverythingToTheOwnerOnly() public {
        MinerWallet w = _funded(0.01 ether);
        _relayProof(w, KEY_PK, 1, _auth(w, KEY));
        vm.prank(OTHER);
        vm.expectRevert(MinerWallet.NotOwner.selector);
        w.withdraw();
        vm.prank(KEY);
        vm.expectRevert(MinerWallet.NotOwner.selector);
        w.withdraw();
        uint256 total = address(w).balance;
        uint256 ownerBefore = OWNER.balance;
        vm.prank(OWNER);
        w.withdraw();
        assertEq(address(w).balance, 0);
        assertEq(OWNER.balance, ownerBefore + total);
        assertEq(total, 0.01 ether - b20.FEE() - RELAYER.balance);
    }

    /// Whatever is deposited and mined, the owner gets back deposit − fees − refunds.
    function testFuzz_ownerGetsEverythingBack(uint96 a, uint96 b, uint8 proofs) public {
        uint256 da = bound(a, 0.001 ether, 5 ether);
        uint256 db = bound(b, 0, 5 ether);
        uint256 n = bound(proofs, 0, 8);
        MinerWallet w = _funded(da);
        vm.prank(OTHER);
        (bool ok,) = address(w).call{value: db}("");
        assertTrue(ok);
        uint256 mined;
        for (uint256 i; i < n; ++i) {
            if (address(w).balance < b20.FEE() + 0.0001 ether) break;
            _relayProof(w, KEY_PK, i, i == 0 ? _auth(w, KEY) : bytes(""));
            mined++;
        }
        uint256 ownerBefore = OWNER.balance;
        vm.prank(OWNER);
        w.withdraw();
        assertEq(OWNER.balance - ownerBefore + mined * b20.FEE() + RELAYER.balance, da + db);
        assertEq(KEY.balance, 0);
    }

    // ------------------------------------------------------------- batch relay

    /// One transaction carries several wallets' orders; a bad one is skipped,
    /// the others land, and every refund goes to the transaction's sender.
    function test_aBatchCarriesManyOrdersAndSkipsABadOne() public {
        MinerWallet w1 = _funded(0.01 ether);
        vm.deal(OTHER, 1 ether);
        address owner2 = vm.addr(0xB22);
        vm.deal(owner2, 1 ether);
        vm.prank(owner2);
        MinerWallet w2 = MinerWallet(payable(factory.create{value: 0.01 ether}()));

        MinerRelay.Call[] memory calls = new MinerRelay.Call[](3);
        MinerWallet.Order memory o1 = _order(address(b20), bytes32(0), PROOF_GAS);
        calls[0] = MinerRelay.Call(
            address(w1), abi.encodeCall(MinerWallet.relayProof, (o1, 1, _proofSig(w1, KEY_PK, o1, 1), _auth(w1, KEY)))
        );
        // No owner permission: fails its checks, skipped.
        MinerWallet.Order memory bad = _order(address(b20), bytes32(0), PROOF_GAS);
        calls[1] = MinerRelay.Call(
            address(w2), abi.encodeCall(MinerWallet.relayProof, (bad, 2, _proofSig(w2, KEY2_PK, bad, 2), bytes("")))
        );
        MinerWallet.Order memory o2 = _order(address(b20), bytes32(0), PROOF_GAS);
        bytes memory auth2 = _sign(0xB22, w2.keyAuthDigest(KEY2));
        calls[2] = MinerRelay.Call(
            address(w2), abi.encodeCall(MinerWallet.relayProof, (o2, 3, _proofSig(w2, KEY2_PK, o2, 3), auth2))
        );
        vm.expectEmit(true, true, false, false, address(relayer));
        emit MinerRelay.CallFailed(1, address(w2));
        vm.prank(RELAYER, RELAYER);
        relayer.relay(calls);
        assertEq(b20.proofs(), 2);
        assertEq(address(relayer).balance, 0, "the batch contract keeps nothing");
        assertGt(RELAYER.balance, 0);
    }

    /// The relayed path costs a bounded amount of gas over a direct submit.
    function test_gasOverheadOverADirectSubmit() public {
        MiningCampaign c = _campaign(launchpad, true);
        MinerWallet w = _funded(1 ether);
        bytes memory auth = _auth(w, KEY);
        _relayProof(w, KEY_PK, 0, auth); // the key's first use (records it)
        uint256 snap = vm.snapshotState();
        uint256[16] memory direct = _shares(c, OWNER, address(0xD1));
        bytes32 ch = c.challengeOf(OWNER);
        vm.deal(address(0xD1), 1 ether);
        vm.prank(address(0xD1), address(0xD1));
        uint256 g0 = gasleft();
        c.submitShares{value: PROOF_FEE}(OWNER, ch, direct);
        uint256 gDirect = g0 - gasleft();
        vm.revertToState(snap);
        uint256[16] memory viaWallet = _shares(c, OWNER, address(w));
        MinerWallet.Order memory o = _order(address(c), c.challengeOf(OWNER), SHARES_GAS);
        bytes memory sig = _sharesSig(w, KEY_PK, o, viaWallet);
        vm.prank(RELAYER, RELAYER);
        g0 = gasleft();
        w.relayShares(o, viaWallet, sig, "");
        uint256 gWallet = g0 - gasleft();
        emit log_named_uint("direct submitShares gas", gDirect);
        emit log_named_uint("relayed relayShares gas", gWallet);
        assertLt(gWallet - gDirect, 70_000);
    }
}
