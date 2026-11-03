#!/usr/bin/env bash
# The B20MINER genesis + Launchpad v16 + MinerWalletFactory, the same way on
# Base Sepolia and on Base (owner, 30 Oct 2026: the testnet runs what mainnet
# runs; only the windows differ, chosen by the contracts from the chain id:
# 1 day on Base Sepolia, 15 days on Base). Runbook:
# docs/B20_V16_GENESIS_DEPLOY_RUNBOOK.md.
#
# Run by the owner in their own terminal, one step at a time. Foundry asks
# for the keystore password itself; it is never passed on the command line.
# base-forge, not forge: MINER is created through Base's native B20 factory,
# which plain Foundry cannot execute.
#
#   ACCOUNT=<keystore> [NETWORK=base-sepolia|base] [DRY_RUN=1] scripts/deploy-v16.sh genesis|open|tminer|launchpad|wallet|router
#
# Base mainnet: genesis → wallet → router (no Launchpad; the router is the
# mining app's MINER swap, needed before the window ends).
# Base Sepolia Launchpad (owner, 3 Nov 2026: the real MINER mines on Base,
# the testnet Launchpad pays into tMINER): tminer → launchpad → wallet; the
# launchpad step reads tminer-deployment.json in place of the genesis record.
#
# DRY_RUN=1 simulates against the live chain and runs every check without
# sending anything; records go to *-dryrun.json files.
#
# Rehearsal only (mainnet readiness E1): FORK_RPC=http://127.0.0.1:<port>
# runs every step against a local base-anvil fork with the deployer unlocked
# there (no keystore), and DEPLOY_DIR=deployments/<scratch> keeps the
# records out of deployments/<network>/. FORK_RPC must be a loopback URL.
set -euo pipefail

STEP="${1:-}"
NETWORK="${NETWORK:-base-sepolia}"
: "${ACCOUNT:?set ACCOUNT to the deployer keystore name}"
case "$NETWORK" in
  base-sepolia) RPC=https://sepolia.base.org; FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1; CHAIN=84532 ;;
  base) RPC=https://mainnet.base.org; FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; CHAIN=8453 ;;
  *) echo "NETWORK must be base-sepolia or base"; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${DEPLOY_DIR:-$ROOT/deployments/$NETWORK}"
FORK="${FORK_RPC:-}"
if [[ -n "$FORK" ]]; then
  [[ "$FORK" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || { echo "FORK_RPC must be http://127.0.0.1:<port>"; exit 1; }
  RPC="$FORK"
fi
# Every script reads and writes this network's records in $DIR.
export PUBLIC_INPUTS_PATH="$DIR/public-inputs.json" GENESIS_RECORD_PATH="$DIR/launch-flow-deployment.json"
DEPLOYER=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).addresses.deployer)' "$DIR/public-inputs.json")
[[ "$(cast chain-id --rpc-url "$RPC")" == "$CHAIN" ]] || { echo "RPC is not chain $CHAIN"; exit 1; }
# The keystore check asks for the password, so a dry run (which signs
# nothing) skips it and simulates as the recorded deployer.
if [[ "${DRY_RUN:-0}" != "1" && -z "$FORK" ]]; then
  [[ "$(cast wallet address --account "$ACCOUNT")" == "$DEPLOYER" ]] || { echo "keystore $ACCOUNT is not the deployer $DEPLOYER in public-inputs.json"; exit 1; }
fi

answer=$(cast call "$FEED" "latestAnswer()(int256)" --rpc-url "$RPC" | awk '{print $1}')
export ETH_USD_PRICE_CENTS=$((answer / 1000000))
echo "Network $NETWORK, deployer $DEPLOYER, nonce $(cast nonce "$DEPLOYER" --rpc-url "$RPC"), balance $(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether) ETH, ETH/USD cents $ETH_USD_PRICE_CENTS"

dry() { [[ "${DRY_RUN:-0}" == "1" ]]; }
# --offline: forge otherwise looks up unknown selectors online and can hang
# there for minutes (seen on DeployLaunchpad, 30 Oct 2026); the RPC still works.
forge_run() {
  local script="$1"
  if dry; then
    base-forge script "$script" --rpc-url "$RPC" --sender "$DEPLOYER" --offline
  elif [[ -n "$FORK" ]]; then
    base-forge script "$script" --rpc-url "$RPC" --unlocked --sender "$DEPLOYER" --broadcast --slow --offline
  else
    base-forge script "$script" --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast --slow --offline
  fi
}

cd "$ROOT/contracts"
case "$STEP" in
  genesis)
    # The team vesting clock starts one day after the deploy; mining must be
    # opened (step `open`) within 7 days or anyone may open it.
    now=$(date +%s)
    export TGE_TIMESTAMP="${TGE_TIMESTAMP:-$((now + 86400))}"
    export MINING_OPEN_DEADLINE="${MINING_OPEN_DEADLINE:-$((now + 7 * 86400))}"
    if dry; then export DEPLOYMENT_OUTPUT_PATH="$DIR/launch-flow-dryrun.json"; else export DEPLOYMENT_OUTPUT_PATH="$DIR/launch-flow-deployment.json"; fi
    echo "TGE_TIMESTAMP $TGE_TIMESTAMP, MINING_OPEN_DEADLINE $MINING_OPEN_DEADLINE"
    forge_run script/DeployB20Genesis.s.sol:DeployB20Genesis
    ;;
  open)
    MINING=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).contracts.b20Mining)' "$DIR/launch-flow-deployment.json")
    echo "openMining() on B20Mining $MINING"
    if dry; then
      cast call "$MINING" "openMining()" --from "$DEPLOYER" --rpc-url "$RPC" && echo "would succeed"
    elif [[ -n "$FORK" ]]; then
      cast send "$MINING" "openMining()" --unlocked --from "$DEPLOYER" --rpc-url "$RPC"
    else
      cast send "$MINING" "openMining()" --account "$ACCOUNT" --from "$DEPLOYER" --rpc-url "$RPC"
    fi
    ;;
  tminer)
    # Base Sepolia only: tMINER on mainnet MINER's MinerPool code, opened at
    # once with TMINER_OPENING_ETH (default 0.02 ETH) and the matching tMINER.
    [[ "$NETWORK" == "base-sepolia" ]] || { echo "tminer is Base Sepolia only"; exit 1; }
    if dry; then export TMINER_OUTPUT_PATH="$DIR/tminer-dryrun.json"; else export TMINER_OUTPUT_PATH="$DIR/tminer-deployment.json"; fi
    echo "TMINER_OPENING_ETH ${TMINER_OPENING_ETH:-20000000000000000 (default)}"
    forge_run script/DeployTestMiner.s.sol:DeployTestMiner
    ;;
  launchpad)
    # Base Sepolia: the MINER-liquidity sink is tMINER's pool (tminer step).
    if [[ "$NETWORK" == "base-sepolia" ]]; then
      [[ -f "$DIR/tminer-deployment.json" ]] || { echo "run the tminer step first (no $DIR/tminer-deployment.json)"; exit 1; }
      export GENESIS_RECORD_PATH="$DIR/tminer-deployment.json"
    fi
    if dry; then export LAUNCHPAD_OUTPUT_PATH="$DIR/launchpad-v16-dryrun.json"; else export LAUNCHPAD_OUTPUT_PATH="$DIR/launchpad-deployment.json"; fi
    forge_run script/DeployLaunchpad.s.sol:DeployLaunchpad
    ;;
  wallet)
    # The wallet factory trusts this genesis and, on Base Sepolia, the
    # Launchpad just deployed. Base mainnet has no Launchpad: its wallets
    # trust no campaign factory (an owner may add one later, 48 h delay).
    if [[ "$NETWORK" == "base" ]]; then
      export LAUNCHPAD_FACTORY=0x0000000000000000000000000000000000000000
    else
      LAUNCHPAD_FACTORY=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).contracts.launchpadFactory)' "$DIR/launchpad-deployment.json")
      export LAUNCHPAD_FACTORY
    fi
    [[ "$NETWORK" == "base-sepolia" ]] && export MINER_RELAY="${MINER_RELAY:-0xB486f2293C5D62A52CeD0D4481Eb7fd2eb64C165}"
    if dry; then export MINER_WALLET_OUTPUT_PATH="$DIR/miner-wallet-dryrun.json"; else export MINER_WALLET_OUTPUT_PATH="$DIR/miner-wallet-deployment.json"; fi
    echo "LAUNCHPAD_FACTORY $LAUNCHPAD_FACTORY, MINER_RELAY ${MINER_RELAY:-new}"
    forge_run script/DeployMinerWallet.s.sol:DeployMinerWallet
    ;;
  router)
    # The swap router (any V4 pool, MINER's included). Base Sepolia has one
    # since 18 Oct 2026; Base mainnet gets its own (E5).
    if dry; then export SWAP_ROUTER_OUTPUT_PATH="$DIR/swap-router-dryrun.json"; else export SWAP_ROUTER_OUTPUT_PATH="$DIR/swap-router-deployment.json"; fi
    forge_run script/DeploySwapRouter.s.sol:DeploySwapRouter
    ;;
  *)
    echo "usage: ACCOUNT=<keystore> [NETWORK=base-sepolia|base] [DRY_RUN=1] $0 genesis|open|tminer|launchpad|wallet|router"
    exit 1
    ;;
esac
