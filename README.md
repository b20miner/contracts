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

Test network deployment of 31 October 2026. On Base Sepolia the mining and
claim windows are 1 day each; on Base they are 15 days.

| Contract | Address |
| --- | --- |
| MINER | `0xb200000000000000000000c9FEC3181Ce714dEa9` |
| B20Mining | `0x95442C94D2Ff303B115Ee029Ccd94D9B8C7Ca6A2` |
| B20WalletBinding | `0x9Ab79D1B5c0eC5Ba9f4C9B9C5e29F9F9dB6e8666` |
| B20EligibleNFT | `0x602EB357c534bFE4b0Fb345e00DC7dDD7f7249cE` |
| B20PublicNFT | `0x6262B87062D6A866a28DA1B8c94B0d39597Cb3a2` |
| B20NFTRevenueVault | `0xf53B2668c6335441b951FF270F4528c3A09e8b64` |
| B20ClaimVault | `0xeec4190f14F8F309d1E7FFC41080B72Bb6DEcb6e` |
| B20LiquidityFinalizer | `0xEA4fd0079A5B5b0824bc5576B1Bc26E3Baa15E5a` |
| MinerPool | `0x6d119d233A438c8322b305a24B843186b5409798` |
| MinerBurner | `0xef5A4DEA639E2c3f77F4BA0e63A97Eb5cd9dEc33` |
| B20TeamVesting | `0xD6A865D52Cb75c523E9F5521E4f22cE7343c252e` |
| B20EcosystemVault | `0x34Ef0be6c90fde87c3B4695469D1Ab74ca75961C` |
| B20CommunityVault | `0x4c16Df187437BcDa50a6a75Acb5ac0890B708726` |
| LaunchpadFactory | `0x7e8220d399eeA7EE2b5c00152C12F692de6eeF7A` |
| MiningCampaign (implementation) | `0x5E01251E46c2DC733e76F2ccB9E9375d61446222` |
| CampaignPool (implementation) | `0x7dcE57938be7a94eCf68950dc243aC7454db7dD3` |
| PositionLocker | `0xd579964df76f722dB7c480aE13D87180DCFA06ff` |
| LaunchpadHook | `0x372557A2E0da7cc11FB6d4788720540ee19420cC` |
| LaunchpadSwapRouter | `0xb817581D358D6F12a5A789b25CE263694C04eaC3` |
| MinerWalletFactory (v13, 2 Nov 2026) | `0xfbFF0386BbC2E1099c691BeBd8Fb56b1Df0d66D5` |
| MinerWallet (implementation, v13) | `0x6C1225717F2470B551A1e79560a2D65FB545fd45` |
| MinerRelay | `0xB486f2293C5D62A52CeD0D4481Eb7fd2eb64C165` |

The source of these contracts is verified on [Sourcify](https://sourcify.dev).
The tag `sepolia-v17` marks the commit they were deployed from. The mining
wallet factory was replaced on 2 November 2026 (v13) after our internal
audit (finding M-1: the relay gas refund now counts only the exact call
data and caps the gas price at the base fee plus 0.01 gwei). The v12 factory
`0xe9A014A76c3A44c3bcda1954521E81648aF00608` (implementation
`0x4e5bC558a9897C95346D219dB9F845e11aA92e93`) stays on chain; the apps let
its wallets withdraw only.

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
