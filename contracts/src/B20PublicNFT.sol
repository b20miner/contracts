// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IB20MiningStatus} from "./interfaces/IB20MiningStatus.sol";

/// @notice NFT collection mintable by any address — no snapshot proof, no
/// eligibility attestation, no allowlist. Snapshot-eligible addresses may
/// mint this collection too, in addition to `B20EligibleNFT`.
///
/// Each NFT grants its minting wallet a fixed 10,000 MINER mining quota
/// (up to 5 NFTs = 50,000 MINER per wallet), permanently pinned to the
/// minting wallet exactly like `B20EligibleNFT`. There is no owner,
/// admin, pause, price/supply-change function of any kind.
///
/// Minting to a wallet closes for good once that wallet confirms its
/// final allocation in `B20Mining` (`mintingOpenFor`), and for everyone
/// once mining ends.
contract B20PublicNFT is ERC721, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MAX_PER_WALLET = 5;
    uint256 public constant MINT_PRICE = 1_020_000_000_000_000; // 0.00102 ETH
    uint256 public constant QUOTA_PER_NFT = 10_000 * 1e18;

    string private constant METADATA_DESCRIPTION =
        "An official B20MINER Public NFT available to any wallet. Each NFT provides the original minter with a mining quota of 10,000 MINER, up to five NFTs per wallet. Mining utility is permanently bound to the original minting wallet and does not transfer with the NFT. Transfers remain locked until the protocol mining period ends. This NFT does not guarantee a token price, profit, redemption value, or financial return.";
    string private constant METADATA_IMAGE = "ipfs://bafybeicai7nbpg3cd2cocccm7d43kqj2ussky3itslm5pci4xdpqi7ne7a";
    string private constant METADATA_EXTERNAL_URL = "https://app.b20miner.xyz";
    string private constant METADATA_ATTRIBUTES_JSON =
        '[{"trait_type":"Collection","value":"Public"},{"trait_type":"Network","value":"Base"},{"trait_type":"Access","value":"Public"},{"display_type":"number","trait_type":"Mining Quota","value":10000},{"trait_type":"Quota Unit","value":"MINER"},{"trait_type":"Maximum Mint Per Wallet","value":5},{"trait_type":"Utility Binding","value":"Original Minter"},{"trait_type":"Transfer Unlock","value":"Mining End"}]';

    address public immutable revenueVault;
    /// @notice The `B20Mining` contract whose `mintingOpenFor` gates
    /// every mint and whose `miningEnded` unlocks transfers. Deployed
    /// after this collection, at an address predicted by the deploy script.
    IB20MiningStatus public immutable mining;

    uint256 public totalMinted;

    mapping(address wallet => uint256 count) public mintedByWallet;
    mapping(uint256 tokenId => address owner) private _utilityOwner;

    error ZeroRevenueVault();
    error ZeroMining();
    error ZeroQuantity();
    error SupplyExceeded();
    error WalletLimitExceeded();
    error MintingClosed();
    error IncorrectPayment(uint256 sent, uint256 required);
    error TransferLocked();
    error RevenueTransferFailed();

    event PublicMinted(address indexed wallet, uint256 quantity, uint256 firstTokenId);

    constructor(string memory name_, string memory symbol_, address revenueVault_, address mining_)
        ERC721(name_, symbol_)
    {
        if (revenueVault_ == address(0)) revert ZeroRevenueVault();
        if (mining_ == address(0)) revert ZeroMining();

        revenueVault = revenueVault_;
        mining = IB20MiningStatus(mining_);
    }

    /// @notice Mints `quantity` Public NFTs to msg.sender. No eligibility
    /// check of any kind — anyone may call this.
    function mint(uint256 quantity) external payable nonReentrant {
        if (quantity == 0) revert ZeroQuantity();
        if (!mining.mintingOpenFor(msg.sender)) revert MintingClosed();
        if (totalMinted + quantity > MAX_SUPPLY) revert SupplyExceeded();
        if (mintedByWallet[msg.sender] + quantity > MAX_PER_WALLET) revert WalletLimitExceeded();

        uint256 required = quantity * MINT_PRICE;
        if (msg.value != required) revert IncorrectPayment(msg.value, required);

        uint256 firstTokenId = totalMinted;

        mintedByWallet[msg.sender] += quantity;
        totalMinted += quantity;
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = firstTokenId + i;
            _utilityOwner[tokenId] = msg.sender;
        }

        emit PublicMinted(msg.sender, quantity, firstTokenId);

        // `_mint`, not `_safeMint`: the minter is always `msg.sender`, who
        // chose to call this. `_safeMint` would call `onERC721Received` on
        // any minter with code — including an EOA carrying an EIP-7702
        // delegation — and revert when the delegate lacks that hook, locking
        // such wallets out of their mining quota. The quota is bound to the
        // minting wallet (`_utilityOwner`), not to token custody.
        for (uint256 i = 0; i < quantity; i++) {
            _mint(msg.sender, firstTokenId + i);
        }

        (bool success,) = revenueVault.call{value: msg.value}("");
        if (!success) revert RevenueTransferFailed();
    }

    /// @notice Total onchain mining quota (18-decimal MINER units) earned
    /// by `wallet` from all Public NFTs it has minted:
    /// `mintedByWallet[wallet] * 10,000e18`.
    function publicMiningQuota(address wallet) external view returns (uint256) {
        return mintedByWallet[wallet] * QUOTA_PER_NFT;
    }

    /// @notice The wallet whose mining quota `tokenId` counts toward —
    /// fixed permanently at mint time, unaffected by later transfers.
    function utilityOwnerOf(uint256 tokenId) external view returns (address) {
        return _utilityOwner[tokenId];
    }

    /// @notice Fully on-chain, deterministic ERC-721 metadata. Reverts with
    /// the standard ERC-721 "nonexistent token" error for any tokenId that
    /// has not been minted. No metadata is stored per token; every field
    /// besides the token's zero-padded number is a fixed compile-time
    /// constant, matching the off-chain V1 metadata package's content.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        bytes memory json = abi.encodePacked(
            '{"name":"',
            name(),
            " #",
            _zeroPadded(tokenId),
            '","description":"',
            METADATA_DESCRIPTION,
            '","image":"',
            METADATA_IMAGE,
            '","external_url":"',
            METADATA_EXTERNAL_URL,
            '","attributes":',
            METADATA_ATTRIBUTES_JSON,
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// @dev Zero-pads `tokenId` (0..9999) to exactly 5 digits, e.g. `7` -> `"00007"`.
    function _zeroPadded(uint256 tokenId) internal pure returns (string memory) {
        bytes memory raw = bytes(tokenId.toString());
        bytes memory padded = new bytes(5);
        uint256 offset = 5 - raw.length;
        for (uint256 i = 0; i < offset; i++) {
            padded[i] = bytes1("0");
        }
        for (uint256 i = 0; i < raw.length; i++) {
            padded[offset + i] = raw[i];
        }
        return string(padded);
    }

    /// @dev Blocks transfers (not mints) until mining has ended. Utility
    /// ownership (`_utilityOwner`) is intentionally never touched here.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && !mining.miningEnded()) revert TransferLocked();
        return super._update(to, tokenId, auth);
    }
}
