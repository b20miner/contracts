// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @dev The two calls a mining target exposes (`B20Mining` and every
/// Launchpad `MiningCampaign` share them).
interface IMiningTarget {
    function quoteProof(address owner) external view returns (uint256 reward, uint256 fee);
    function submitProof(address owner, bytes32 expectedChallenge, uint256 nonce) external payable;
}

interface IShareTarget {
    function submitShares(address owner, bytes32 expectedChallenge, uint256[16] calldata nonces) external payable;
}

/// @dev What the wallet reads to recognise a Launchpad campaign.
interface ILaunchpadCampaign {
    function factory() external view returns (address);
    function token() external view returns (address);
}

/// @dev Base (OP Stack) GasPriceOracle predeploy, for the L1 data part of a
/// transaction's cost.
interface IGasPriceOracle {
    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256);
}

/// @notice K59–K62: an owner's mining wallet as a contract.
///
/// One per owner wallet (`MinerWalletFactory`, CREATE2 with the owner as
/// salt), created for gas only. It holds the owner's mining ETH and mines
/// for the owner and nobody else:
///
/// - Only `owner` (fixed at creation, never changes) withdraws, and always
///   the whole balance, to `owner`. There is no admin, no upgrade, no
///   pause, no other way out for the ETH.
/// - K62: a browser keeps a *permission key* that holds no ETH at all. It
///   only signs "mine this proof from my wallet" (EIP-712); anyone may carry
///   that signature to the chain (`relayProof` / `relayShares`), normally
///   B20MINER's relay server, and the wallet pays the sender's gas back in
///   the same call. Nothing is ever kept on a key, so a lost or cleared
///   browser loses nothing.
/// - A key is allowed by the owner's own signature (`KeyAuth`, no
///   transaction) and recorded on its first use. The owner revokes one key
///   or every key at once (`revokeKey`, `revokeAllKeys`).
/// - A signed mining order can only make this wallet submit proof-of-work
///   to a known mining contract (`B20_MINING`, or a campaign of
///   `LAUNCHPAD_FACTORY` or of a factory the owner added and that has
///   waited `FACTORY_DELAY`), always with `owner` as the reward owner. The
///   key signs the most it lets the wallet pay: the fee (`maxFee`) and the
///   gas price (`maxGasPrice`); the sender cannot exceed either. Each order
///   is used once (`opNonce`) and expires (`deadline`).
///
/// B20MINER's one-time activation (`B20WalletBinding.activate`) is still
/// paid by the owner wallet itself; once it is active, `B20Mining` accepts
/// proofs from any mining wallet, this one included. Launchpad campaigns
/// need no activation.
contract MinerWallet is EIP712 {
    /// @notice The contract that deploys and initialises every wallet.
    address public immutable FACTORY;
    /// @notice The B20MINER mining contract (proofs only), or zero.
    address public immutable B20_MINING;
    /// @notice The Launchpad factory whose campaigns are trusted, or zero.
    address public immutable LAUNCHPAD_FACTORY;

    /// @notice Gas a relayed call costs its sender that the measurement
    /// inside the call cannot see, besides calldata: a share of the
    /// transaction's base cost (relays are batched), the refund transfer
    /// and the event.
    uint256 public constant RELAY_OVERHEAD = 12_000;
    /// @notice Bytes added to the call's own data for the L1 data fee
    /// estimate (the transaction envelope and the batch encoding).
    uint256 public constant L1_ENVELOPE = 120;
    /// @notice Gas kept back for the work after the target call (the call's
    /// own value-transfer cost, the L1 fee read, the refund transfer and
    /// the `Relayed` event), so a target that burns all of `callGas` still
    /// leaves the order its refund (measured: 45k is not always enough).
    uint256 public constant FINISH_GAS = 60_000;
    /// @notice How long a factory the owner proposes waits before its
    /// campaigns are trusted (time to notice and cancel a wrong one).
    uint256 public constant FACTORY_DELAY = 48 hours;
    address internal constant GAS_PRICE_ORACLE = 0x420000000000000000000000000000000000000F;

    bytes32 public constant KEY_AUTH_TYPEHASH = keccak256("KeyAuth(address key,uint64 epoch)");
    bytes32 public constant MINE_PROOF_TYPEHASH = keccak256(
        "MineProof(address target,bytes32 challenge,uint256 nonce,uint256 maxFee,uint256 maxGasPrice,uint256 callGas,uint256 opNonce,uint64 deadline)"
    );
    bytes32 public constant MINE_SHARES_TYPEHASH = keccak256(
        "MineShares(address target,bytes32 challenge,uint256[16] nonces,uint256 maxFee,uint256 maxGasPrice,uint256 callGas,uint256 opNonce,uint64 deadline)"
    );

    /// @notice What a key signs besides the work itself.
    /// @param target `B20_MINING` or a trusted campaign.
    /// @param challenge The owner's current challenge at `target`.
    /// @param maxFee Most mining fee the wallet may pay for this order.
    /// @param maxGasPrice Most gas price the wallet pays back (the sender's
    ///        transaction must not be priced higher).
    /// @param callGas Gas the target call is given; the sender must supply
    ///        it, so it cannot make the call fail by starving it.
    /// @param opNonce Above every earlier order of the same key (used once).
    /// @param deadline Last second the order may land.
    struct Order {
        address target;
        bytes32 challenge;
        uint256 maxFee;
        uint256 maxGasPrice;
        uint256 callGas;
        uint256 opNonce;
        uint64 deadline;
    }

    address public owner;
    /// @notice Key generation; `revokeAllKeys` moves it on and so ends every key.
    uint64 public epoch;
    /// @dev `epoch + 1` for a key recorded in the current generation.
    mapping(address key => uint64) internal _keyEpoch;
    /// @dev `epoch + 1` for a key the owner revoked in the current generation.
    mapping(address key => uint64) internal _revokedEpoch;
    /// @notice The last order nonce each key used.
    mapping(address key => uint256) public lastOpNonce;
    /// @notice When a factory the owner proposed becomes trusted (0: never).
    mapping(address factory => uint256) public factoryTrustedFrom;

    bool private _busy;

    error NotFactory();
    error AlreadyInitialized();
    error NotOwner();
    error ZeroAddress();
    error UntrustedTarget(address target);
    error InsufficientBalance(uint256 balance, uint256 fee);
    error FeeAboveLimit(uint256 fee, uint256 maxFee);
    error GasPriceAboveLimit(uint256 gasPrice, uint256 maxGasPrice);
    error Expired(uint64 deadline);
    error UsedOrder(uint256 opNonce, uint256 lastOpNonce);
    error KeyNotAllowed(address key);
    error NotEnoughGas();
    error Busy();
    error TransferFailed();
    error FactoryAlreadyProposed(address factory);
    error UnknownFactory(address factory);

    event Initialized(address indexed owner);
    event Deposited(address indexed from, uint256 amount);
    event KeyAllowed(address indexed key, uint64 epoch);
    event KeyRevoked(address indexed key, uint64 epoch);
    event AllKeysRevoked(uint64 newEpoch);
    event FactoryProposed(address indexed factory, uint256 trustedFrom);
    event FactoryCancelled(address indexed factory);
    /// @notice One relayed order: `ok` false means the target refused it
    /// (no fee was paid); the sender's gas is paid back either way.
    event Relayed(address indexed key, address indexed target, bool ok, uint256 fee, uint256 refund, bytes4 reason);
    event Mined(address indexed target, uint256 fee);
    event Withdrawn(address indexed owner, uint256 amount);

    constructor(address b20Mining, address launchpadFactory) EIP712("B20 MinerWallet", "5") {
        FACTORY = msg.sender;
        B20_MINING = b20Mining;
        LAUNCHPAD_FACTORY = launchpadFactory;
        // The implementation itself is never usable.
        owner = address(0xdead);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier guarded() {
        if (_busy) revert Busy();
        _busy = true;
        _;
        _busy = false;
    }

    /// @notice Called once by the factory in the creation transaction.
    function initialize(address owner_) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit Initialized(owner_);
    }

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    /// @notice Plain ETH transfers are deposits (from anyone). Refunds of an
    /// overpaid mining fee arrive here too, during a mining call.
    receive() external payable {
        // Checked first, before any storage read: a sender that forwards
        // only the 2,300-gas stipend (`transfer`) still deposits.
        if (gasleft() < 5_000 || _busy) return;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Deposit from the app.
    function deposit() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    /// @notice Sends the whole balance to the owner.
    function withdraw() external onlyOwner guarded {
        uint256 amount = address(this).balance;
        emit Withdrawn(owner, amount);
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Allows `key` with a transaction instead of a signature (for
    /// an owner wallet that cannot sign typed data); also re-allows a key
    /// revoked in this generation.
    function allowKey(address key) external onlyOwner {
        if (key == address(0)) revert ZeroAddress();
        delete _revokedEpoch[key];
        _allow(key);
    }

    /// @notice Ends one key; its earlier `KeyAuth` signature no longer works.
    function revokeKey(address key) external onlyOwner {
        delete _keyEpoch[key];
        _revokedEpoch[key] = epoch + 1;
        emit KeyRevoked(key, epoch);
    }

    /// @notice Ends every key and every `KeyAuth` signed so far.
    function revokeAllKeys() external onlyOwner {
        emit AllKeysRevoked(++epoch);
    }

    /// @notice Starts trusting the campaigns of another Launchpad factory (a
    /// later Launchpad version) after `FACTORY_DELAY`.
    function proposeFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (factoryTrustedFrom[factory] != 0) revert FactoryAlreadyProposed(factory);
        uint256 from = block.timestamp + FACTORY_DELAY;
        factoryTrustedFrom[factory] = from;
        emit FactoryProposed(factory, from);
    }

    /// @notice Drops a proposed or trusted factory.
    function cancelFactory(address factory) external onlyOwner {
        if (factoryTrustedFrom[factory] == 0) revert UnknownFactory(factory);
        delete factoryTrustedFrom[factory];
        emit FactoryCancelled(factory);
    }

    /// @notice The owner mines directly from its own wallet (no key, no
    /// relay, no refund): the way to keep mining without any server.
    function mineProof(address target, bytes32 expectedChallenge, uint256 nonce) external onlyOwner guarded {
        if (target != B20_MINING && !isTrustedCampaign(target)) revert UntrustedTarget(target);
        uint256 fee = _fee(target);
        IMiningTarget(target).submitProof{value: fee}(owner, expectedChallenge, nonce);
        emit Mined(target, fee);
    }

    /// @notice As `mineProof`, for a batch of 16 shares to a campaign.
    function mineShares(address target, bytes32 expectedChallenge, uint256[16] calldata nonces)
        external
        onlyOwner
        guarded
    {
        if (!isTrustedCampaign(target)) revert UntrustedTarget(target);
        uint256 fee = _fee(target);
        IShareTarget(target).submitShares{value: fee}(owner, expectedChallenge, nonces);
        emit Mined(target, fee);
    }

    // ------------------------------------------------------------------
    // Relayed mining (anyone carries a key's signed order)
    // ------------------------------------------------------------------

    /// @notice Submits one proof the key signed. `ownerSig` (the owner's
    /// `KeyAuth` for the key) is needed only on the key's first use.
    function relayProof(Order calldata o, uint256 nonce, bytes calldata keySig, bytes calldata ownerSig)
        external
        guarded
    {
        uint256 startGas = gasleft();
        address key = _checkOrder(o, _orderHash(MINE_PROOF_TYPEHASH, o, bytes32(nonce)), keySig, ownerSig);
        if (o.target != B20_MINING && !isTrustedCampaign(o.target)) revert UntrustedTarget(o.target);
        uint256 fee = _orderFee(o);
        _ensureGas(o.callGas);
        (bool ok, bytes4 reason) = _submitProof(o, nonce, fee);
        _finish(key, o.target, ok, ok ? fee : 0, reason, startGas);
    }

    /// @notice Submits a batch of 16 shares the key signed (K58 campaigns).
    function relayShares(Order calldata o, uint256[16] calldata nonces, bytes calldata keySig, bytes calldata ownerSig)
        external
        guarded
    {
        uint256 startGas = gasleft();
        bytes32 work = keccak256(abi.encodePacked(nonces));
        address key = _checkOrder(o, _orderHash(MINE_SHARES_TYPEHASH, o, work), keySig, ownerSig);
        if (!isTrustedCampaign(o.target)) revert UntrustedTarget(o.target);
        uint256 fee = _orderFee(o);
        _ensureGas(o.callGas);
        (bool ok, bytes4 reason) = _submitShares(o, nonces, fee);
        _finish(key, o.target, ok, ok ? fee : 0, reason, startGas);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice True iff `key` may sign orders now (recorded in this
    /// generation and not revoked).
    function isKey(address key) external view returns (bool) {
        return _keyEpoch[key] == epoch + 1;
    }

    /// @notice True iff the owner revoked `key` in this generation: its
    /// `KeyAuth` no longer works until `revokeAllKeys` starts a new one.
    function isRevoked(address key) external view returns (bool) {
        return _revokedEpoch[key] == epoch + 1;
    }

    /// @notice EIP-712 digest of the owner's permission for `key` in the
    /// current generation (what the app asks the owner wallet to sign).
    function keyAuthDigest(address key) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(KEY_AUTH_TYPEHASH, key, epoch)));
    }

    /// @notice True iff `target` is a campaign that `LAUNCHPAD_FACTORY` or
    /// a factory the owner added (and that has waited `FACTORY_DELAY`)
    /// created — the factory's own registry says so, not the target.
    function isTrustedCampaign(address target) public view returns (bool) {
        if (target.code.length == 0) return false;
        address factory;
        address token;
        try ILaunchpadCampaign(target).factory() returns (address f) {
            factory = f;
        } catch {
            return false;
        }
        if (factory == address(0) || (factory != LAUNCHPAD_FACTORY && !_ownerFactoryActive(factory))) return false;
        try ILaunchpadCampaign(target).token() returns (address t) {
            token = t;
        } catch {
            return false;
        }
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSignature("campaignOf(address)", token));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (address)) == target;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _ownerFactoryActive(address factory) internal view returns (bool) {
        uint256 from = factoryTrustedFrom[factory];
        return from != 0 && block.timestamp >= from;
    }

    /// @dev The checks before anything is paid. A failing check reverts the
    /// whole call, so the sender pays its own gas (it can see these checks
    /// before sending).
    function _checkOrder(Order calldata o, bytes32 structHash, bytes calldata keySig, bytes calldata ownerSig)
        internal
        returns (address key)
    {
        if (block.timestamp > o.deadline) revert Expired(o.deadline);
        if (tx.gasprice > o.maxGasPrice) revert GasPriceAboveLimit(tx.gasprice, o.maxGasPrice);
        key = ECDSA.recover(_hashTypedDataV4(structHash), keySig);
        if (_keyEpoch[key] != epoch + 1) {
            // First use in this generation: the owner's permission.
            if (
                ownerSig.length == 0 || _revokedEpoch[key] == epoch + 1
                    || !SignatureChecker.isValidSignatureNow(owner, keyAuthDigest(key), ownerSig)
            ) revert KeyNotAllowed(key);
            _allow(key);
        }
        uint256 last = lastOpNonce[key];
        if (o.opNonce <= last) revert UsedOrder(o.opNonce, last);
        lastOpNonce[key] = o.opNonce;
    }

    /// @dev EIP-712 struct hash of an order; `work` is the proof nonce, or
    /// the hash of the 16 share nonces (`uint256[16]` encodes as the hash of
    /// its packed items). Encoded in two halves (same bytes as one
    /// `abi.encode`) to stay within the stack.
    function _orderHash(bytes32 typeHash, Order calldata o, bytes32 work) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(typeHash, o.target, o.challenge, work),
                abi.encode(o.maxFee, o.maxGasPrice, o.callGas, o.opNonce, o.deadline)
            )
        );
    }

    function _submitProof(Order calldata o, uint256 nonce, uint256 fee) internal returns (bool ok, bytes4 reason) {
        try IMiningTarget(o.target).submitProof{value: fee, gas: o.callGas}(owner, o.challenge, nonce) {
            ok = true;
        } catch (bytes memory err) {
            reason = _selector(err);
        }
    }

    function _submitShares(Order calldata o, uint256[16] calldata nonces, uint256 fee)
        internal
        returns (bool ok, bytes4 reason)
    {
        try IShareTarget(o.target).submitShares{value: fee, gas: o.callGas}(owner, o.challenge, nonces) {
            ok = true;
        } catch (bytes memory err) {
            reason = _selector(err);
        }
    }

    function _allow(address key) internal {
        _keyEpoch[key] = epoch + 1;
        emit KeyAllowed(key, epoch);
    }

    function _orderFee(Order calldata o) internal view returns (uint256 fee) {
        fee = _fee(o.target);
        if (fee > o.maxFee) revert FeeAboveLimit(fee, o.maxFee);
    }

    function _fee(address target) internal view returns (uint256 fee) {
        (, fee) = IMiningTarget(target).quoteProof(owner);
        if (fee > address(this).balance) revert InsufficientBalance(address(this).balance, fee);
    }

    /// @dev The target call must really get `callGas` (EIP-150 passes at
    /// most 63/64 of what is left), so a sender cannot starve it into a
    /// failure that still earns a refund.
    function _ensureGas(uint256 callGas) internal view {
        if (gasleft() < callGas + callGas / 63 + FINISH_GAS) revert NotEnoughGas();
    }

    /// @dev Pays the transaction's sender back what this order cost it: gas
    /// used so far plus `RELAY_OVERHEAD` and the calldata, at the
    /// transaction's gas price (capped by the key's `maxGasPrice`), plus the
    /// L1 data fee. Paid whether or not the target accepted the order (the
    /// order is used either way), never more than the balance; a sender
    /// that refuses the refund just goes without it.
    function _finish(address key, address target, bool ok, uint256 fee, bytes4 reason, uint256 startGas) internal {
        uint256 cost = (startGas - gasleft() + RELAY_OVERHEAD + 16 * msg.data.length) * tx.gasprice
            + _l1Fee(msg.data.length + L1_ENVELOPE);
        uint256 refund = cost < address(this).balance ? cost : address(this).balance;
        if (refund > 0) {
            // solhint-disable-next-line avoid-tx-origin
            (bool sent,) = tx.origin.call{value: refund}("");
            if (!sent) refund = 0;
        }
        emit Relayed(key, target, ok, fee, refund, reason);
    }

    function _selector(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) {
            assembly {
                s := mload(add(err, 32))
            }
        }
    }

    function _l1Fee(uint256 size) internal view returns (uint256) {
        if (GAS_PRICE_ORACLE.code.length == 0) return 0;
        try IGasPriceOracle(GAS_PRICE_ORACLE).getL1FeeUpperBound(size) returns (uint256 f) {
            return f;
        } catch {
            return 0;
        }
    }
}
