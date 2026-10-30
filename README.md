# B20MINER contracts

Smart contracts for B20MINER on Base: the MINER token genesis (proof-of-work
mining, NFTs, claims, the MINER pool and burns), the Launchpad, and the mining
wallet.

- Website: [b20miner.xyz](https://b20miner.xyz)
- Docs: [docs.b20miner.xyz](https://docs.b20miner.xyz)

## Layout

| Path | What it holds |
| --- | --- |
| `contracts/src` | Genesis: `B20Mining`, `B20WalletBinding`, `B20EligibleNFT`, `B20PublicNFT`, `B20NFTRevenueVault`, `B20ClaimVault`, `B20LiquidityFinalizer`, `MinerPool`, `MinerBurner`, `B20TeamVesting`, `B20EcosystemVault`, `B20CommunityVault` |
| `contracts/src/launchpad` | `LaunchpadFactory`, `MiningCampaign`, `CampaignPool`, `LaunchpadHook`, `PositionLocker`, `LaunchpadSwapRouter` |
| `contracts/src/wallet` | `MinerWalletFactory`, `MinerWallet`, `MinerRelay` |
| `contracts/test` | Unit, integration, invariant and fork tests |
| `contracts/script` | The deploy scripts used on Base Sepolia |
| `deployments/base-sepolia` | Deployed addresses and deploy records |
| `scripts/deploy-v16.sh` | Runs the deploy scripts step by step |

MINER is a Base-native B20 asset created through Base's B20 factory, so the
project builds with Base's Foundry build (`base-forge`), not stock Foundry.

## Build and test

```bash
git clone --recurse-submodules https://github.com/b20miner/contracts.git
cd contracts/contracts
base-forge build
base-forge test --no-match-path "test/**/*.fork.t.sol"
```

The fork tests (`*.fork.t.sol`) read live Base Sepolia and Base state through
the public RPCs; run them with `base-forge test`.

## Base Sepolia deployment

Test network deployment of 30 October 2026. On Base Sepolia the mining and
claim windows are 1 day each; on Base they are 15 days.

| Contract | Address |
| --- | --- |
| MINER | `0xB200000000000000000000Efd99318fFEBD40415` |
| B20Mining | `0x1b057567530EA919B76854c39D0A57B05f7664aB` |
| B20WalletBinding | `0x122477CbCb82f966DF4E0E5d3FFBA40898E0f70A` |
| B20EligibleNFT | `0xa01960e8839B8fEA02B10f72B9C9F8138e6de682` |
| B20PublicNFT | `0x85b310d0f9181fdE6E834845cEdAD6A61FA8B865` |
| B20NFTRevenueVault | `0xb0aBDc5cfc0E662D76Af907321Db9eFeA485bf25` |
| B20ClaimVault | `0x7e59F588F7dF3d2886C4759b92eb3Aab6926baf5` |
| B20LiquidityFinalizer | `0x64edE020850d00c3B46eABE1c7eb2D6114Fe7Dc8` |
| MinerPool | `0xA5A17F89a601C743b1693C4F78B2FC5330d437D5` |
| MinerBurner | `0x487b73faADC9f2310f01Da757e139355C8A7d4Fb` |
| B20TeamVesting | `0xE0607B72a11b43e73656E96D84ce8A6e59630B24` |
| B20EcosystemVault | `0xCaA47Be4b3b5876552e212e4A83cBA8806AAdE9D` |
| B20CommunityVault | `0x614869D34AF2d7fe370050bC6653b92cD2d847Be` |
| LaunchpadFactory | `0x315Ce9b1a8473e3b2D10d4195F15470A66b7848d` |
| MiningCampaign (implementation) | `0x061c6b9C4Bac57F4A7d89B3541609EFBf99E526D` |
| CampaignPool (implementation) | `0x92b1391Ad19C937f7087156141401F930041E76D` |
| PositionLocker | `0x35F44EDABcc145F9BB46f98eBdc38d4828F73B4C` |
| LaunchpadHook | `0x08d1338ac4baf03dd47Ae94E04310b4819AD60Cc` |
| LaunchpadSwapRouter | `0xb817581D358D6F12a5A789b25CE263694C04eaC3` |
| MinerWalletFactory | `0xf4a2F99b482b23b37355fcAcA2398BE2eC97297e` |
| MinerWallet (implementation) | `0xEE840F9DF7eA288Ebd6658b90F64B36796060141` |
| MinerRelay | `0xB486f2293C5D62A52CeD0D4481Eb7fd2eb64C165` |

The source of these contracts is verified on [Sourcify](https://sourcify.dev).
The tag `sepolia-v16` marks the commit they were deployed from.

To rebuild the deployed bytecode (metadata hash included), compile the
contracts alone with solc 0.8.35. A full `base-forge build` also compiles the
tests, which pull in Uniswap's `=0.8.26` files and move some contracts to that
compiler.

```bash
base-forge build --use 0.8.35 --skip test --skip script
```

## Security

See [SECURITY.md](SECURITY.md). The contracts have not been audited yet.

## License

[MIT](LICENSE)
