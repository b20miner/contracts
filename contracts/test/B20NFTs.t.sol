// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {B20NFTRevenueVault} from "../src/B20NFTRevenueVault.sol";
import {B20EligibleNFT} from "../src/B20EligibleNFT.sol";
import {B20PublicNFT} from "../src/B20PublicNFT.sol";
import {IB20MiningStatus} from "../src/interfaces/IB20MiningStatus.sol";

/// @notice A contract with no receive/fallback, used to make a vault
/// recipient transfer fail on purpose.
contract RejectingRecipient {}

/// @notice A minter contract with no `onERC721Received` — like an EOA whose
/// EIP-7702 delegate lacks the ERC-721 receiver hook.
contract NoReceiverMinter {
    function mintPublic(B20PublicNFT nft) external payable {
        nft.mint{value: msg.value}(1);
    }
}

/// @notice Stand-in for `B20Mining`'s two NFT-gate reads: mining "ends" at
/// a settable timestamp, and wallets can be marked as having confirmed
/// their allocation.
contract MockMiningStatus is IB20MiningStatus {
    uint256 public endsAt;
    mapping(address wallet => bool confirmed) public confirmed;

    function setEndsAt(uint256 value) external {
        endsAt = value;
    }

    function setConfirmed(address wallet) external {
        confirmed[wallet] = true;
    }

    function miningEnded() public view returns (bool) {
        return endsAt != 0 && block.timestamp >= endsAt;
    }

    function mintingOpenFor(address wallet) external view returns (bool) {
        return !confirmed[wallet] && !miningEnded();
    }
}

/// @notice Critical targeted tests for B20NFTRevenueVault, B20EligibleNFT
/// and B20PublicNFT only. Not a full suite, not fuzz/invariant.
contract B20NFTsTest is Test {
    bytes32 internal constant SNAPSHOT_ROOT = 0xa5ebaa9d888946e87b9926ce7ed11e88169a7c9885c55d582f97de045f432e20;
    uint256 internal constant ELIGIBLE_PRICE = 340_000_000_000_000;
    uint256 internal constant PUBLIC_PRICE = 1_020_000_000_000_000;
    uint256 internal constant QUOTA_PER_NFT = 10_000 * 1e18;

    address internal liquidityRecipient = makeAddr("liquidityRecipient");
    address internal operationsRecipient = makeAddr("operationsRecipient");
    address internal stranger = makeAddr("stranger");
    address internal randomMinter = makeAddr("randomMinter");

    uint256 internal miningEnd;
    MockMiningStatus internal miningStatus;

    B20NFTRevenueVault internal vault;
    B20EligibleNFT internal eligible;
    B20PublicNFT internal publicNft;

    string internal fixturesJson;

    function setUp() public {
        vault = new B20NFTRevenueVault(liquidityRecipient, operationsRecipient);
        miningEnd = block.timestamp + 15 days;
        miningStatus = new MockMiningStatus();
        miningStatus.setEndsAt(miningEnd);
        eligible = new B20EligibleNFT("B20MINER Eligible", "B20E", SNAPSHOT_ROOT, address(vault), address(miningStatus));
        publicNft = new B20PublicNFT("B20MINER Public", "B20P", address(vault), address(miningStatus));

        fixturesJson = vm.readFile("test/fixtures/snapshot-v1-proofs.json");
    }

    function _loadFixture(uint256 index)
        internal
        view
        returns (address wallet, uint256 allocation, bytes32[] memory proof)
    {
        string memory base = string.concat(".[", vm.toString(index), "]");
        wallet = vm.parseJsonAddress(fixturesJson, string.concat(base, ".wallet"));
        allocation = vm.parseJsonUint(fixturesJson, string.concat(base, ".allocation_b20"));
        proof = vm.parseJsonBytes32Array(fixturesJson, string.concat(base, ".proof"));
    }

    // ---------------------------------------------------------------
    // B20NFTRevenueVault
    // ---------------------------------------------------------------

    function test_vault_ethAccumulates() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool success,) = address(vault).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_vault_permissionlessDistributeWorks() public {
        vm.deal(address(vault), 2 ether);
        vm.prank(stranger);
        vault.distribute();
        assertEq(liquidityRecipient.balance, 1 ether);
        assertEq(operationsRecipient.balance, 1 ether);
    }

    function test_vault_distributesExactly5050() public {
        vm.deal(address(vault), 10 ether);
        vault.distribute();
        assertEq(liquidityRecipient.balance, 5 ether);
        assertEq(operationsRecipient.balance, 5 ether);
        assertEq(vault.totalDistributedToLiquidity(), 5 ether);
        assertEq(vault.totalDistributedToOperations(), 5 ether);
    }

    function test_vault_oddWeiGoesToOperations() public {
        uint256 total = 1 ether + 1 wei;
        vm.deal(address(vault), total);
        vault.distribute();
        assertEq(liquidityRecipient.balance, total / 2);
        assertEq(operationsRecipient.balance, total - total / 2);
        assertEq(operationsRecipient.balance, liquidityRecipient.balance + 1 wei);
    }

    function test_vault_revertsOnZeroBalance() public {
        vm.expectRevert(B20NFTRevenueVault.NothingToDistribute.selector);
        vault.distribute();
    }

    function test_vault_revertsAllDistributionIfRecipientTransferFails() public {
        RejectingRecipient rejecting = new RejectingRecipient();
        B20NFTRevenueVault brokenVault = new B20NFTRevenueVault(address(rejecting), operationsRecipient);
        vm.deal(address(brokenVault), 1 ether);

        vm.expectRevert(B20NFTRevenueVault.TransferFailed.selector);
        brokenVault.distribute();

        assertEq(address(brokenVault).balance, 1 ether);
        assertEq(brokenVault.totalDistributedToLiquidity(), 0);
        assertEq(brokenVault.totalDistributedToOperations(), 0);
    }

    // ---------------------------------------------------------------
    // B20EligibleNFT
    // ---------------------------------------------------------------

    function test_eligible_mintSucceedsWithRealProductionProof() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        assertEq(eligible.ownerOf(0), wallet);
        assertEq(eligible.totalMinted(), 1);
        assertEq(eligible.eligibleBonus(wallet), (allocation * 1e18) / 20);
    }

    function test_eligible_rejectsWrongAddress() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(stranger, 1 ether);

        // stranger did not mint this proof's leaf; proof was for `wallet`.
        vm.prank(stranger);
        vm.expectRevert(B20EligibleNFT.InvalidSnapshotProof.selector);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
    }

    function test_eligible_rejectsWrongAllocation() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.InvalidSnapshotProof.selector);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation + 1, proof);
    }

    function test_eligible_rejectsWrongProof() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        proof[0] = proof[0] ^ bytes32(uint256(1));

        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.InvalidSnapshotProof.selector);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
    }

    function test_eligible_rejectsInsufficientPayment() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(B20EligibleNFT.IncorrectPayment.selector, ELIGIBLE_PRICE - 1, ELIGIBLE_PRICE)
        );
        eligible.mint{value: ELIGIBLE_PRICE - 1}(1, allocation, proof);
    }

    function test_eligible_rejectsExcessPayment() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(B20EligibleNFT.IncorrectPayment.selector, ELIGIBLE_PRICE + 1, ELIGIBLE_PRICE)
        );
        eligible.mint{value: ELIGIBLE_PRICE + 1}(1, allocation, proof);
    }

    function test_eligible_walletMintLimitIsFive() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE * 5}(5, allocation, proof);
        assertEq(eligible.mintedByWallet(wallet), 5);

        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.WalletLimitExceeded.selector);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
    }

    function test_eligible_bonusCorrectFor1To5NFTs() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
        assertEq(eligible.eligibleBonus(wallet), (allocation * 1e18 * 1) / 20);

        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE * 4}(4, allocation, proof);
        assertEq(eligible.eligibleBonus(wallet), (allocation * 1e18 * 5) / 20);
        // 5 NFTs = 25% of base allocation, in 18-decimal units.
        assertEq(eligible.eligibleBonus(wallet), (allocation * 1e18) / 4);
    }

    function test_eligible_mintingClosedAtMiningEnd() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        vm.warp(miningEnd);

        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.MintingClosed.selector);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
    }

    /// Once the wallet confirms its allocation in B20Mining, it can never
    /// mint again; other wallets are unaffected.
    function test_eligible_mintingClosedAfterAllocationConfirmed() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        miningStatus.setConfirmed(wallet);
        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.MintingClosed.selector);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
        assertEq(eligible.mintedByWallet(wallet), 1);
    }

    /// Before mining is opened (no end yet) minting is open and transfers
    /// stay locked.
    function test_eligible_beforeMiningOpened_mintOpenTransferLocked() public {
        miningStatus.setEndsAt(0);
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.TransferLocked.selector);
        eligible.transferFrom(wallet, stranger, 0);
    }

    function test_eligible_transferRejectedOneSecondBeforeMiningEnd() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        vm.warp(miningEnd - 1);
        vm.prank(wallet);
        vm.expectRevert(B20EligibleNFT.TransferLocked.selector);
        eligible.transferFrom(wallet, stranger, 0);
    }

    function test_eligible_transferOpensAtMiningEnd() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        vm.warp(miningEnd);
        vm.prank(wallet);
        eligible.transferFrom(wallet, stranger, 0);
        assertEq(eligible.ownerOf(0), stranger);
    }

    function test_eligible_transferDoesNotChangeUtilityOwnerOrBonus() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        uint256 bonusBefore = eligible.eligibleBonus(wallet);

        vm.warp(miningEnd);
        vm.prank(wallet);
        eligible.transferFrom(wallet, stranger, 0);

        assertEq(eligible.utilityOwnerOf(0), wallet);
        assertEq(eligible.eligibleBonus(wallet), bonusBefore);
        assertEq(eligible.eligibleBonus(stranger), 0);
    }

    function test_eligible_revenueGoesToVault() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);

        assertEq(address(vault).balance, ELIGIBLE_PRICE);
    }

    // ---------------------------------------------------------------
    // B20PublicNFT
    // ---------------------------------------------------------------

    function test_public_snapshotEligibleAddressCanMint() public {
        (address wallet,,) = _loadFixture(0);
        vm.deal(wallet, 1 ether);

        vm.prank(wallet);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        assertEq(publicNft.ownerOf(0), wallet);
    }

    function test_public_anyRandomAddressCanMint_noProofRequired() public {
        vm.deal(randomMinter, 1 ether);

        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        assertEq(publicNft.ownerOf(0), randomMinter);
    }

    function test_public_rejectsInsufficientAndExcessPayment() public {
        vm.deal(randomMinter, 1 ether);

        vm.prank(randomMinter);
        vm.expectRevert(abi.encodeWithSelector(B20PublicNFT.IncorrectPayment.selector, PUBLIC_PRICE - 1, PUBLIC_PRICE));
        publicNft.mint{value: PUBLIC_PRICE - 1}(1);

        vm.prank(randomMinter);
        vm.expectRevert(abi.encodeWithSelector(B20PublicNFT.IncorrectPayment.selector, PUBLIC_PRICE + 1, PUBLIC_PRICE));
        publicNft.mint{value: PUBLIC_PRICE + 1}(1);
    }

    function test_public_walletMintLimitIsFive() public {
        vm.deal(randomMinter, 1 ether);

        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE * 5}(5);
        assertEq(publicNft.mintedByWallet(randomMinter), 5);

        vm.prank(randomMinter);
        vm.expectRevert(B20PublicNFT.WalletLimitExceeded.selector);
        publicNft.mint{value: PUBLIC_PRICE}(1);
    }

    function test_public_fiveNFTsGiveExactly50000Quota() public {
        vm.deal(randomMinter, 1 ether);

        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE * 5}(5);

        assertEq(publicNft.publicMiningQuota(randomMinter), 5 * QUOTA_PER_NFT);
        assertEq(publicNft.publicMiningQuota(randomMinter), 50_000 * 1e18);
    }

    function test_public_miningEndBoundaries() public {
        vm.deal(randomMinter, 1 ether);

        vm.warp(miningEnd - 1);
        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        vm.warp(miningEnd);
        vm.prank(randomMinter);
        vm.expectRevert(B20PublicNFT.MintingClosed.selector);
        publicNft.mint{value: PUBLIC_PRICE}(1);
    }

    /// Confirming an allocation closes Public minting for that wallet only.
    function test_public_mintingClosedAfterAllocationConfirmed() public {
        vm.deal(randomMinter, 1 ether);
        vm.deal(stranger, 1 ether);
        miningStatus.setConfirmed(randomMinter);

        vm.prank(randomMinter);
        vm.expectRevert(B20PublicNFT.MintingClosed.selector);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        vm.prank(stranger);
        publicNft.mint{value: PUBLIC_PRICE}(1);
        assertEq(publicNft.publicMiningQuota(stranger), QUOTA_PER_NFT);
    }

    function test_public_constructorRejectsZeroMining() public {
        vm.expectRevert(B20PublicNFT.ZeroMining.selector);
        new B20PublicNFT("B20MINER Public", "B20P", address(vault), address(0));
    }

    function test_public_transferDoesNotChangeUtilityOwnerOrQuota() public {
        vm.deal(randomMinter, 1 ether);
        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        uint256 quotaBefore = publicNft.publicMiningQuota(randomMinter);

        vm.warp(miningEnd);
        vm.prank(randomMinter);
        publicNft.transferFrom(randomMinter, stranger, 0);

        assertEq(publicNft.utilityOwnerOf(0), randomMinter);
        assertEq(publicNft.publicMiningQuota(randomMinter), quotaBefore);
        assertEq(publicNft.publicMiningQuota(stranger), 0);
    }

    function test_public_revenueGoesToVault() public {
        vm.deal(randomMinter, 1 ether);

        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        assertEq(address(vault).balance, PUBLIC_PRICE);
    }

    // ---------------------------------------------------------------
    // On-chain metadata / tokenURI()
    // ---------------------------------------------------------------

    /// @dev Reads an existing V1 metadata file and re-encodes it exactly
    /// as the contract does, stripping the file's single trailing newline
    /// (a data URI has no such newline). Matching this re-encoded string
    /// against tokenURI()'s output is equivalent to decoding tokenURI()
    /// and comparing raw JSON, since Base64 encoding is deterministic and
    /// injective — OpenZeppelin's Base64 library (used by both the
    /// contract and this helper) has no decode function to invert it with.
    function _expectedDataUriFromFile(string memory path) internal view returns (string memory) {
        bytes memory raw = bytes(vm.readFile(path));
        require(raw.length > 0 && raw[raw.length - 1] == "\n", "fixture file missing trailing newline");
        bytes memory trimmed = new bytes(raw.length - 1);
        for (uint256 i = 0; i < trimmed.length; i++) {
            trimmed[i] = raw[i];
        }
        return string.concat("data:application/json;base64,", Base64.encode(trimmed));
    }

    function _mintEligible(address wallet, uint256 allocation, bytes32[] memory proof, uint256 quantity) internal {
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE * quantity}(quantity, allocation, proof);
    }

    function test_tokenURI_revertsForNonexistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        eligible.tokenURI(0);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        publicNft.tokenURI(0);
    }

    function test_eligible_tokenURI_startsWithDataUriPrefix() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        _mintEligible(wallet, allocation, proof, 1);

        string memory uri = eligible.tokenURI(0);
        assertEq(_slice(uri, 0, 29), "data:application/json;base64,");
    }

    function test_public_tokenURI_startsWithDataUriPrefix() public {
        vm.deal(randomMinter, 1 ether);
        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        string memory uri = publicNft.tokenURI(0);
        assertEq(_slice(uri, 0, 29), "data:application/json;base64,");
    }

    function _slice(string memory s, uint256 start, uint256 len) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function test_eligible_tokenURI_matchesOffChainMetadataFile() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        _mintEligible(wallet, allocation, proof, 1);

        string memory expected = _expectedDataUriFromFile("../artifacts/nft-metadata-v1/eligible/metadata/0");
        assertEq(eligible.tokenURI(0), expected);
    }

    function test_public_tokenURI_matchesOffChainMetadataFile() public {
        vm.deal(randomMinter, 1 ether);
        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        string memory expected = _expectedDataUriFromFile("../artifacts/nft-metadata-v1/public/metadata/0");
        assertEq(publicNft.tokenURI(0), expected);
    }

    /// Cross-checks the on-chain JSON's image/external_url/description/
    /// attributes against values transcribed directly from the task spec
    /// (independent of both the contract's own constants and the
    /// off-chain file), via `_eligibleExpectedUri`/`_publicExpectedUri`.
    function test_eligible_tokenURI_fieldsMatchSpec() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        _mintEligible(wallet, allocation, proof, 1);

        assertEq(eligible.tokenURI(0), _eligibleExpectedUri("00000"));
    }

    function test_public_tokenURI_fieldsMatchSpec() public {
        vm.deal(randomMinter, 1 ether);
        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        assertEq(publicNft.tokenURI(0), _publicExpectedUri("00000"));
    }

    /// @dev Builds the full expected Eligible data URI for a given
    /// already-zero-padded 5-digit token id string (e.g. "00004"),
    /// independent of the contract's own padding implementation.
    function _eligibleExpectedUri(string memory paddedId) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"B20MINER Eligible #',
            paddedId,
            '","description":"An official B20MINER Eligible NFT. Each NFT adds a mining bonus equal to 5% of the original minter',
            "'",
            's verified snapshot allocation, up to five NFTs per wallet. Mining utility is permanently bound to the original minting wallet and does not transfer with the NFT. Transfers remain locked until the protocol mining period ends. This NFT does not guarantee a token price, profit, redemption value, or financial return.","image":"ipfs://bafybeiffpyodwtv7kexhowwtkoyh3lpy7rdgovpgzbbtc2cyokgpvagoee","external_url":"https://app.b20miner.xyz","attributes":[{"trait_type":"Collection","value":"Eligible"},{"trait_type":"Network","value":"Base"},{"trait_type":"Utility","value":"Snapshot Mining Bonus"},{"trait_type":"Bonus Rate","value":"5%"},{"trait_type":"Maximum Mint Per Wallet","value":5},{"trait_type":"Utility Binding","value":"Original Minter"},{"trait_type":"Transfer Unlock","value":"Mining End"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Same as `_eligibleExpectedUri` but for the Public collection.
    function _publicExpectedUri(string memory paddedId) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"B20MINER Public #',
            paddedId,
            '","description":"An official B20MINER Public NFT available to any wallet. Each NFT provides the original minter with a mining quota of 10,000 MINER, up to five NFTs per wallet. Mining utility is permanently bound to the original minting wallet and does not transfer with the NFT. Transfers remain locked until the protocol mining period ends. This NFT does not guarantee a token price, profit, redemption value, or financial return.","image":"ipfs://bafybeicai7nbpg3cd2cocccm7d43kqj2ussky3itslm5pci4xdpqi7ne7a","external_url":"https://app.b20miner.xyz","attributes":[{"trait_type":"Collection","value":"Public"},{"trait_type":"Network","value":"Base"},{"trait_type":"Access","value":"Public"},{"display_type":"number","trait_type":"Mining Quota","value":10000},{"trait_type":"Quota Unit","value":"MINER"},{"trait_type":"Maximum Mint Per Wallet","value":5},{"trait_type":"Utility Binding","value":"Original Minter"},{"trait_type":"Transfer Unlock","value":"Mining End"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function test_tokenURI_numberingAndZeroPadding_for_0_4_10() public {
        // Eligible: mint tokenIds 0-4 from fixture wallet 0, 5-9 from
        // fixture wallet 1, and 10 from fixture wallet 2 (real proofs).
        (address walletA, uint256 allocA, bytes32[] memory proofA) = _loadFixture(0);
        _mintEligible(walletA, allocA, proofA, 5);
        (address walletB, uint256 allocB, bytes32[] memory proofB) = _loadFixture(1);
        _mintEligible(walletB, allocB, proofB, 5);
        (address walletC, uint256 allocC, bytes32[] memory proofC) = _loadFixture(2);
        _mintEligible(walletC, allocC, proofC, 1);

        assertEq(eligible.tokenURI(0), _eligibleExpectedUri("00000"));
        assertEq(eligible.tokenURI(4), _eligibleExpectedUri("00004"));
        assertEq(eligible.tokenURI(10), _eligibleExpectedUri("00010"));

        // Public: no proof needed, three separate wallets to respect the
        // 5-per-wallet mint limit while reaching tokenId 10.
        address minterA = makeAddr("publicNumberingA");
        address minterB = makeAddr("publicNumberingB");
        address minterC = makeAddr("publicNumberingC");
        vm.deal(minterA, 1 ether);
        vm.deal(minterB, 1 ether);
        vm.deal(minterC, 1 ether);
        vm.prank(minterA);
        publicNft.mint{value: PUBLIC_PRICE * 5}(5);
        vm.prank(minterB);
        publicNft.mint{value: PUBLIC_PRICE * 5}(5);
        vm.prank(minterC);
        publicNft.mint{value: PUBLIC_PRICE}(1);

        assertEq(publicNft.tokenURI(0), _publicExpectedUri("00000"));
        assertEq(publicNft.tokenURI(4), _publicExpectedUri("00004"));
        assertEq(publicNft.tokenURI(10), _publicExpectedUri("00010"));
    }

    // ---------------------------------------------------------------
    // Minters with code (EIP-7702 delegations, contract wallets)
    // ---------------------------------------------------------------

    /// An EOA whose code has no ERC-721 receiver hook (as with an EIP-7702
    /// delegation to such a delegate) can still mint: `_mint`, not `_safeMint`.
    function test_public_minterWithCodeButNoReceiverHookCanMint() public {
        vm.etch(randomMinter, address(new RejectingRecipient()).code);
        vm.deal(randomMinter, 1 ether);
        vm.prank(randomMinter);
        publicNft.mint{value: PUBLIC_PRICE}(1);
        assertEq(publicNft.ownerOf(0), randomMinter);
        assertEq(publicNft.publicMiningQuota(randomMinter), QUOTA_PER_NFT);
    }

    function test_eligible_minterWithCodeButNoReceiverHookCanMint() public {
        (address wallet, uint256 allocation, bytes32[] memory proof) = _loadFixture(0);
        vm.etch(wallet, address(new RejectingRecipient()).code);
        vm.deal(wallet, 1 ether);
        vm.prank(wallet);
        eligible.mint{value: ELIGIBLE_PRICE}(1, allocation, proof);
        assertEq(eligible.ownerOf(0), wallet);
        assertEq(eligible.eligibleBonus(wallet), (allocation * 1e18) / 20);
    }

    /// A contract minter without the receiver hook gets the NFT and the quota.
    function test_public_contractMinterWithoutReceiverHookCanMint() public {
        NoReceiverMinter minter = new NoReceiverMinter();
        minter.mintPublic{value: PUBLIC_PRICE}(publicNft);
        assertEq(publicNft.ownerOf(0), address(minter));
        assertEq(publicNft.publicMiningQuota(address(minter)), QUOTA_PER_NFT);
    }
}
