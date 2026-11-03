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
| `contracts/src/launchpad` | `LaunchpadFactory`, `MiningCampaign`, `CampaignPool`, `LaunchpadHook`, `PositionLocker`, `LaunchpadSwapRouter`, `TestMinerLauncher` (test network only) |
| `contracts/src/wallet` | `MinerWalletFactory`, `MinerWallet`, `MinerRelay` |
| `contracts/test` | Unit, integration, invariant and fork tests |
| `contracts/script` | The deploy scripts used on Base Sepolia |
| `deployments/base-sepolia` | Deployed addresses and deploy records |
| `audits` | Security audit reports |
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
the public RPCs. They place mock B20 code at the native B20 address, which
`base-forge` refuses, so run them with stock Foundry:
`forge test --match-path "test/**/*.fork.t.sol"`.

## Base Sepolia deployment

Test network deployment of 3 November 2026. On Base Sepolia the mining and
claim windows are 1 day each; on Base they are 15 days.

MINER genesis (mined on Base mainnet at launch; this copy is the test
network rehearsal):

| Contract | Address |
| --- | --- |
| MINER | `0xb200000000000000000000f05e939E87Fc68e8e5` |
| B20Mining | `0x1d94eE4CfdA776CeeD4625583E17104592D5e2B0` |
| B20WalletBinding | `0x90c4696A23fc4F01af54ff373F4E62c28270F44b` |
| B20EligibleNFT | `0xE2fD2054df2e1A85A76F6E15F6d74520eC143211` |
| B20PublicNFT | `0x667107bB2B053a58156Ac54297ED6403B9dC81B0` |
| B20NFTRevenueVault | `0xfB1d72976923ddF41dD4A47E2b94b6a58105460c` |
| B20ClaimVault | `0x34018C4b59903946746d5FdDA4443826957d5bC9` |
| B20LiquidityFinalizer | `0x4feCC1E4d020dDa069662161E369cB2cb47f9CA8` |
| MinerPool | `0xF07aebdda0088DbA21Fb7d162835d306d60cad3f` |
| MinerBurner | `0xd946b2867A9615766F76A921309254613209dF2f` |
| B20TeamVesting | `0xb02aBaf1E6eb55DD8D018A41938258A982d354B2` |
| B20EcosystemVault | `0x7d7D55073A6608031751e77713f137b984154fcb` |
| B20CommunityVault | `0xB1fC9d3Df02AAF8f10d5eC9aC9C7Ad687283d7A9` |

tMINER, the test network token the Launchpad pays its MINER share into.
`TestMinerLauncher` creates it and opens a pool built from the same
`MinerPool` and `MinerBurner` code as MINER:

| Contract | Address |
| --- | --- |
| tMINER | `0xb2000000000000000000003c123A342354B84588` |
| MinerPool (tMINER) | `0xD5C1Ebbe65c7478e1353ED8FDAE796331f357eEE` |
| MinerBurner (tMINER) | `0x6c42852c173456c0a1aF4790fD0a7F1420E2D106` |
| TestMinerLauncher | `0x40FFD8f1C061fe555578599C138b64cC2b1B10A1` |

Launchpad and mining wallet:

| Contract | Address |
| --- | --- |
| LaunchpadFactory | `0x95814C2FF4005FcA3545c0a9d9aA20DA92f7644a` |
| MiningCampaign (implementation) | `0x34b8f8184aA6E966Ff9fdb91F7d5B1E48bBDc863` |
| CampaignPool (implementation) | `0x22def2894055DFD2A72A5bc62a956ad20f323918` |
| PositionLocker | `0x95dEdc31De8Ce15447d663db6232436b694F711c` |
| LaunchpadHook | `0x6789bC7845e85B3d49fB01f102b1768dF079A0Cc` |
| LaunchpadSwapRouter | `0xb817581D358D6F12a5A789b25CE263694C04eaC3` |
| MinerWalletFactory | `0x3b4Ed45Df443Ca1714B7F584538C4dF8b8472984` |
| MinerWallet (implementation) | `0xe204a4E0E3Ee7697d3c52614C6e52E6e9CC35d8D` |
| MinerRelay | `0xB486f2293C5D62A52CeD0D4481Eb7fd2eb64C165` |

The source of these contracts is verified on [Sourcify](https://sourcify.dev).
The tag `sepolia-v19` marks the commit they were deployed from. The swap
router and the relay contract are unchanged from earlier deployments and
were reused. Earlier mining wallet factories, including
`0xe1939bc8B7c96Ec7aDc37c1472c02f09792bAE5C` and
`0xfbFF0386BbC2E1099c691BeBd8Fb56b1Df0d66D5`, stay on chain; the apps let
their wallets withdraw only.

To rebuild the deployed bytecode (metadata hash included), compile the
contracts alone with solc 0.8.35. A full `base-forge build` also compiles the
tests, which pull in Uniswap's `=0.8.26` files and move some contracts to that
compiler.

```bash
base-forge build --use 0.8.35 --skip test --skip script
```

## Security

Internal audit — passed (2 Nov 2026): [report](audits/2026-11-02-internal-audit.md).
The audit was done by the B20MINER team, not by an independent firm. To
report a security problem, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
