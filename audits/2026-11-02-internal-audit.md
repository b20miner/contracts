# Internal audit — Base Sepolia v17 (2 November 2026)

**Internal audit — passed (2 Nov 2026).** This audit was done by the
B20MINER team. It is not a third-party audit, and no independent firm
reviewed this code. An audit lowers risk; it does not remove it.

**Result:** 21 of 21 contracts pass. One Medium finding (M-1, in
`MinerWallet`) was found and fixed the same day: a new `MinerWalletFactory`
(v13) and `MinerWallet` implementation are live on Base Sepolia. The other
items (one Medium about key management, three Low, six Info) are trust,
design or next-version notes, each listed below with how it is handled.

An earlier internal review on 31 October 2026 found a High issue in
`MinerPool` (a buyer could push the pool's bid range next to the price within
one transaction). It was fixed before the v17 deployment; the fix and its
tests are part of this code.

**Which deployment this covers.** The addresses in §3 are the v17 deployment
the audit was run on. The current Base Sepolia deployment (v20, 6 Nov 2026,
tag `sepolia-v20`, addresses in the [README](../README.md)) is built from the
same source with three changes, each reviewed below: the `B20Mining` opening
gate (Appendix A), the new test-network-only `TestMinerLauncher`
(Appendix B) and the `MiningCampaign` fix for Base's Denim upgrade
(Appendix C). Every other contract is unchanged; the v20 mining wallet runs
the fixed v13 wallet code, trusting the v20 Launchpad.

## 1. Scope

- The 21 contracts of the Base Sepolia v17 deployment (addresses in §3),
  plus the libraries they use (`B20PoW`, `B20SnapshotMerkle`) and the MINER
  B20 token (Base's native B20 asset).
- Out of scope: OpenZeppelin, Uniswap v4-core and v4-periphery, base-std
  (pinned upstream releases), and code that is not deployed.
- Not covered: off-chain code (relay, indexer, apps), which had its own
  internal security review and is not part of this report.
- **Same code as on chain.** The runtime bytecode metadata hash (which hashes
  the exact source and compiler settings) of every local build equals the
  deployed code: 21/21 match. The two new wallet contracts (v13) match too.

## 2. Method

- **Manual review, line by line, of every contract.** Focus: access control
  and every privileged path, upgradeability, `delegatecall` and
  `selfdestruct`, reentrancy and call ordering, math and rounding, ETH
  accounting against forced sends, Uniswap v4 hook and unlock-callback flows,
  signatures (EIP-712, session keys, ERC-1271), gas refunds, loops over user
  lists, and how the real B20 precompile treats unusual receivers.
- **Tests.** `base-forge test --no-match-path "test/**/*.fork.t.sol"`: 411
  passed, 0 failed, including the Launchpad invariant suites. Added for this
  audit:
  - `test/audit/B20Receivers.fork.t.sol`: on a Base Sepolia fork with the real
    precompile, which receivers the B20 token refuses;
  - `test/audit/VaultMath.t.sol`: fuzzing (20,000 runs) of the community
    staking stream and the team vesting schedule;
  - four M-1 tests in `test/wallet/MinerWallet.t.sol` (below).
- **Static analysis.** Slither 0.11.4 on every contract with solc 0.8.35: 60
  results, each checked by hand (§5). None is a real issue.

## 3. Results

"Pass — role" means: not upgradeable, no bug found, but the contract keeps a
privileged role by design (§4).

| Contract | Address | Verdict |
| --- | --- | --- |
| MINER (B20) | `0xb200000000000000000000c9FEC3181Ce714dEa9` | Pass |
| B20Mining | `0x95442C94D2Ff303B115Ee029Ccd94D9B8C7Ca6A2` | Pass |
| B20WalletBinding | `0x9Ab79D1B5c0eC5Ba9f4C9B9C5e29F9F9dB6e8666` | Pass (I-1) |
| B20EligibleNFT | `0x602EB357c534bFE4b0Fb345e00DC7dDD7f7249cE` | Pass |
| B20PublicNFT | `0x6262B87062D6A866a28DA1B8c94B0d39597Cb3a2` | Pass |
| B20NFTRevenueVault | `0xf53B2668c6335441b951FF270F4528c3A09e8b64` | Pass (I-4) |
| B20ClaimVault | `0xeec4190f14F8F309d1E7FFC41080B72Bb6DEcb6e` | Pass |
| B20LiquidityFinalizer | `0xEA4fd0079A5B5b0824bc5576B1Bc26E3Baa15E5a` | Pass (I-2) |
| MinerPool | `0x6d119d233A438c8322b305a24B843186b5409798` | Pass (L-3) |
| MinerBurner | `0xef5A4DEA639E2c3f77F4BA0e63A97Eb5cd9dEc33` | Pass |
| B20TeamVesting | `0xD6A865D52Cb75c523E9F5521E4f22cE7343c252e` | Pass |
| B20EcosystemVault | `0x34Ef0be6c90fde87c3B4695469D1Ab74ca75961C` | Pass — role (M-2) |
| B20CommunityVault | `0x4c16Df187437BcDa50a6a75Acb5ac0890B708726` | Pass — role (M-2) |
| LaunchpadFactory | `0x7e8220d399eeA7EE2b5c00152C12F692de6eeF7A` | Pass — role (M-2, L-1, L-2) |
| MiningCampaign (implementation) | `0x5E01251E46c2DC733e76F2ccB9E9375d61446222` | Pass (I-5) |
| CampaignPool (implementation) | `0x7dcE57938be7a94eCf68950dc243aC7454db7dD3` | Pass (I-3) |
| PositionLocker | `0xd579964df76f722dB7c480aE13D87180DCFA06ff` | Pass |
| LaunchpadHook | `0x372557A2E0da7cc11FB6d4788720540ee19420cC` | Pass (I-6) |
| LaunchpadSwapRouter | `0xb817581D358D6F12a5A789b25CE263694C04eaC3` | Pass |
| MinerWalletFactory v13 | `0xfbFF0386BbC2E1099c691BeBd8Fb56b1Df0d66D5` | Pass |
| MinerWallet v13 (implementation) | `0x6C1225717F2470B551A1e79560a2D65FB545fd45` | Pass (M-1 fixed) |
| MinerRelay | `0xB486f2293C5D62A52CeD0D4481Eb7fd2eb64C165` | Pass |

The replaced v12 wallet contracts (`MinerWalletFactory`
`0xe9A014A76c3A44c3bcda1954521E81648aF00608`, implementation
`0x4e5bC558a9897C95346D219dB9F845e11aA92e93`) carry M-1. They stay on chain;
the apps let their wallets withdraw only.

No contract is upgradeable. The only `delegatecall` is in the fixed EIP-1167
clones (`MiningCampaign`, `CampaignPool`, `MinerWallet`). There is no
`selfdestruct`.

## 4. Privileged roles

- `LaunchpadFactory.GUARDIAN`: can deprecate the factory (no new tokens) and
  set the direct-launch price within 0.25–10 ETH.
- `B20EcosystemVault.MANAGER`: queues transfers, each public for 48 hours
  before it can run.
- `B20CommunityVault.MANAGER`: sets the staking recipient once and picks the
  airdrop Merkle roots (at most 50% of the airdrop pot per round, rounds at
  least 30 days apart, each public for 48 hours).
- `B20Mining.MINING_OPENER`: could open mining before a deadline; already
  used.
- Fee receivers, each token's creator fee recipient (two-step change), and
  each mining wallet's owner.

The relay and keeper servers hold no on-chain privilege. Every keeper call
(`flush`, `sweep`, `finalize`, `distribute`, `burnUnclaimed`, `settle`,
`startRound`, `closeRound`, `executeTransfer`) is open to anyone and can only
do its one fixed thing.

## 5. Findings

### M-1 — MinerWallet: padded calldata turned the gas refund into a profit (Medium) — fixed

The v12 wallet refunded the relayer
`(gas used + overhead + 16 × msg.data.length) × tx.gasprice` plus the L1
fee bound. The ABI decoder ignores bytes after the arguments, so a sender
could append zero bytes: each costs 4 gas (10 under the EIP-7623 floor) but
was refunded at 16 gas, and the gas price was bounded only by the order's
signed `maxGasPrice`.

- **Who:** someone holding a wallet's browser session key. The key holds no
  ETH, but it signs orders, including their `maxGasPrice`. The app caps that
  price, but a stolen key signs whatever the thief wants.
- **Proof of concept** on the v12 code: 120,000 zero bytes at 100 gwei gave a
  refund of 0.2093 ETH for a real cost of 0.1232 ETH, so +0.0861 ETH per
  order to the sender.
- **Impact:** a stolen session key could drain the mining wallet's ETH
  balance (mining wallets hold small amounts of gas money). Funds outside the
  mining wallet were never reachable.

**Fix (live on Base Sepolia, 2 Nov 2026, block 53533592):**

1. `relayProof` and `relayShares` revert with `NonCanonicalCalldata` unless
   `msg.data.length` is exactly the ABI length of the call. `keySig` must be
   65 bytes and `ownerSig` at most 1,024 bytes (`BadSignatureLength`).
2. Once a session key is recorded, a resent `ownerSig` is not refunded. The
   relay sends an empty `ownerSig` for recorded keys.
3. The refund gas price is `min(tx.gasprice, block.basefee + 0.01 gwei)`. A
   sender who pays a higher tip pays the difference itself.

Tests: `test_audit_paddedCalldataIsRefused` (the former proof of concept, now
expecting the revert), `test_audit_signatureLengthsAreBounded`,
`test_audit_refundPriceIsCappedAtBaseFeePlusTip`,
`test_audit_resentOwnerSigIsNotRefunded`. A local end-to-end run of the relay
on 300 orders showed refunds still cover the relay's gas.

What remains (accepted): a stolen key can still submit failing orders,
refunded at the capped price (about 0.0000016 ETH each at today's Base fees),
until the owner revokes the key. It never gains from them.

### M-2 — Privileged keys are single accounts, not multisigs (Medium, key management) — accepted

The roles in §4 are single accounts (no multisig), on the test network and,
as decided on 2 November 2026, on Base Mainnet too: there each role is a new
account used only for that role. A leaked
`B20CommunityVault.MANAGER` key could route the airdrop pot over two rounds
(about 62 days). Every round (`RoundQueued`) and every ecosystem transfer
(`TransferQueued`) is public on chain for 48 hours before it can run, so a
misuse can be seen before it happens. Accepted risk for the launch.

### L-1 — The guardian can move the direct-launch price (Low, trust)

Bounded to 0.25–10 ETH. A creator sees the price before launching.

### L-2 — The Chainlink ETH/USD read has no L2 sequencer-uptime check (Low)

`create(p, maxFeeWei)` caps what a creator pays, so a stale price cannot
charge more than the creator accepted.

### L-3 — MinerPool `flush` loops over every bid range made so far (Low)

One range is added per 600-tick price level reached; a 1,000× MINER price
rise adds about 115 ranges, and the whole tick range allows at most about
2,958. Gas grows with price history but stays within a block on any realistic
path. The next MinerPool should collect only ranges near the current tick.

### I-1 — Anyone can mine for an activated owner (Info)

Costly for the sender and harmless: the reward goes to the owner.

### I-2 — Genesis finalize needs some liquidity ETH (Info)

By design.

### I-3 — Launchpad pool deposits are not refundable (Info)

A creator's deposit joins the token's pool and stays locked with its
liquidity. The docs say so.

### I-4 — ETH sent to the NFT revenue vault after genesis finalize stays there (Info)

NFT minting closes at the end of mining, before finalize, and finalize
sweeps the vault. Only a donation or a forced send can be stuck; no user
money is involved.

### I-5 — One person can meet the "10 miners" opening condition (Info, economic)

Miners are counted by owner address, so one person can use ten. They still
pay the mining fees and do the work. The docs say "10 miner addresses", not
10 people.

### I-6 — Unofficial pools for a Launchpad token can exist (Info)

Only the locker can create pools with our hook, so nobody can front-run the
official pool. Anyone holding the token can still open a plain pool
elsewhere. The apps and the indexer use only the official pool.

### Checked and fine (selection)

- **B20 receivers:** the real precompile refuses only `address(0)`, so no
  miner address can block `MiningCampaign.distribute`.
- **Hook and router:** the hook bounds a router input to `amountIn`;
  `unlockCallback` only runs for the router's own `unlock`.
- **MinerPool bid anchor (earlier High):** the bid sits at least one grid step
  above `max(tick, anchor)`; pushes inside one transaction cannot move it
  closer.
- **Claim, community and finalizer vaults:** every amount comes from mining
  counters and fixed constants, never from `balanceOf`, so forced sends and
  donations change nothing. Each one-shot step has its own flag, and claims
  take no address parameter.
- **Rounding:** the staking stream never goes down and never overpays across
  year edges; team vesting releases nothing before TGE, then 1/48 steps, and
  the full 1B at period 60 (fuzzed).
- **NFTs:** `_mint` instead of `_safeMint` on purpose (EIP-7702 wallets),
  exact payment, transfers locked until mining ends.
- **Proof-of-work hash:** packed encoding of a literal followed by fixed-size
  fields only, so no ambiguity.

## 6. Static analysis (Slither, 60 results)

| Detector | Count | Verdict |
| --- | --- | --- |
| arbitrary-send-erc20 | 1 | False positive: the router pulls only from the caller of `swap` |
| arbitrary-send-eth | 4 | By design: swap output, creator fees, fixed fee targets, relay refund (its amount was M-1) |
| reentrancy-no-eth / -benign / -events | 16 | Calls only to the PoolManager and fixed contracts, inside `unlock` or behind guards |
| divide-before-multiply | 3 | Intended tick rounding; negative ticks round correctly |
| dangerous-strict-equalities | 8 | Zero checks on own counters |
| uninitialized-local | 7 | Accumulators that start at zero |
| unused-return | 9 | Values not needed (checked elsewhere or zero by construction) |
| calls-inside-a-loop | 4 | Bounded loops over trusted contracts (L-3 for MinerPool) |
| missing-zero-address | 4 | Constructors deployed with checked real addresses |

## 7. Before Base Mainnet

- Only the fixed wallet (v13 code) is deployed on Base Mainnet.
- The privileged roles in §4 are new single-purpose accounts (M-2).
- `TestMinerLauncher` and tMINER exist only on Base Sepolia; the launcher
  refuses any other chain.
- The Low and Info items are addressed in each contract's next version.

Report a security problem privately: see [SECURITY.md](../SECURITY.md).

## Appendix A — Change after the audit: opening gate (2 Nov 2026)

Owner decision (2 Nov 2026): NFT minting and allocation confirmation open
only with `openMining()`, not at deployment, so the published mainnet
addresses cannot be used (for example to mint all 10,000 Public NFTs)
before the launch. Change in `B20Mining` only:

- `mintingOpenFor(wallet)` is now `miningOpened && !allocationConfirmed[wallet] && !miningEnded()`.
- `confirmAllocation` reverts `MiningNotOpened` before `openMining()`.

Review: the change only narrows when two existing paths can run; no new
state, no new role, no new external call. `openMining()` keeps its rules
(`MINING_OPENER`, or anyone from `OPEN_DEADLINE`), so an absent opener
still cannot freeze minting or confirmation. Activation
(`B20WalletBinding`) is unchanged and works before the opening. Tests:
`test_beforeOpening_windowReadsFailClosed` (both closed before),
`test_openMining_opensMintingAndConfirmation` (both open after), the
integration and both rehearsal fork tests re-ordered to open first;
contract suite 497/498 (the one failure is `B20Receivers.fork`, which reads
a live v17 Sepolia holder and is environment-dependent, unrelated).
Verdict for `B20Mining`: PASS (unchanged).

## Appendix B — New for v19: `TestMinerLauncher` (3 Nov 2026)

Base Sepolia only. The test network Launchpad pays its MINER share into
tMINER, a test token, because the real MINER is mined on Base Mainnet.
`TestMinerLauncher` (`0x40FFD8f1C061fe555578599C138b64cC2b1B10A1`) sets
tMINER up in its constructor, in one transaction, and has no function
afterwards:

- reverts `WrongChain` on any chain but Base Sepolia (84532) and `ZeroAmount`
  without ETH;
- deploys `MinerBurner` and `MinerPool` unchanged (the audited code above)
  and is the pool's only `FINALIZER`;
- creates tMINER through Base's native B20 factory with no admin, the supply
  cap equal to the minted supply, the whole supply minted to the pool and
  `BURN_ROLE` to the burner only, so nobody can mint again;
- opens the pool once with the sent ETH at 1 ETH = 6,000,000 tMINER and
  checks that the created token address is the expected one.

Review (same team, 3 Nov 2026): no stored ETH, no owner, no callable
function, no `delegatecall`; the pool and burner code is the audited code,
and `open` cannot run a second time. Tests:
`test/launchpad/TestMinerLauncher.fork.t.sol` on a Base Sepolia fork, 6/6
passed (supply and price, only the burner burns and nobody mints, `open`
cannot run again, buys and sales with sale fees burned, Launchpad ETH as buy
support, chain and ETH checks). Verdict for `TestMinerLauncher`: PASS.

## Appendix C — Base Denim follow-up: Launchpad v20 (6 Nov 2026)

Base's Denim upgrade (Base Sepolia 21 Oct, Base Mainnet 5 Nov 2026) makes a
B20 token refuse a transfer to its own address with `InvalidReceiver`. The
2 Nov receiver check listed the token's own address as accepted; it is now
refused, and `test/audit/B20Receivers.fork.t.sol` checks that.

**Finding (Critical, fixed in v20).** `MiningCampaign.submitProof` and
`submitShares` accepted the token itself as an owner. Under Denim,
`CampaignPool.finalize` and `MiningCampaign.distribute` would then revert at
that owner every time, so the token's pool could never open. Shown on a
Base Sepolia fork with the native B20 token:
`test/audit/DenimTokenOwner.fork.t.sol`.

**Fix.**

- `submitProof` and `submitShares` revert `TokenOwner()` when the owner is
  the token.
- `distribute` skips an owner only when the token refuses the transfer with
  `InvalidReceiver`. It emits `DeliveryRefused`, leaves the share unclaimed
  (burned later by `burnUnclaimed`) and moves on. Any other failure, and a
  failure without revert data (what running out of gas looks like), still
  reverts, so the caller's gas cannot make an owner be skipped.

Tests: `test/launchpad/MiningCampaignDenim.t.sol` (token cannot be an owner;
a refused owner is skipped and its share burns; other failures revert; a
failure without data reverts; a gas sweep shows every served owner was
paid) and the fork test above. In this repository: 394/394 unit tests, and
the audit fork tests 27/27 on Base Sepolia.
The genesis contracts are not affected: they do not push tokens to a list
of owners. `MinerPool` accepts one bid per block, and blocks are now 0.2 s,
but its main limits (the 10-minute window and the drift bound) are measured
in time, so they are unchanged.

Verdict for `MiningCampaign` v20: PASS.
