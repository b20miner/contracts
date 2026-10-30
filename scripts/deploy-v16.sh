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
#   ACCOUNT=<keystore> [NETWORK=base-sepolia|base] [DRY_RUN=1] scripts/deploy-v16.sh genesis|open|launchpad|wallet
#
# DRY_RUN=1 simulates against the live chain and runs every check without
# sending anything; records go to *-dryrun.json files.
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
DIR="$ROOT/deployments/$NETWORK"
DEPLOYER=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).addresses.deployer)' "$DIR/public-inputs.json")
[[ "$(cast chain-id --rpc-url "$RPC")" == "$CHAIN" ]] || { echo "RPC is not chain $CHAIN"; exit 1; }
# The keystore check asks for the password, so a dry run (which signs
# nothing) skips it and simulates as the recorded deployer.
if [[ "${DRY_RUN:-0}" != "1" ]]; then
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
    dry && export DEPLOYMENT_OUTPUT_PATH="$DIR/launch-flow-dryrun.json"
    echo "TGE_TIMESTAMP $TGE_TIMESTAMP, MINING_OPEN_DEADLINE $MINING_OPEN_DEADLINE"
    forge_run script/DeployB20Genesis.s.sol:DeployB20Genesis
    ;;
  open)
    MINING=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).contracts.b20Mining)' "$DIR/launch-flow-deployment.json")
    echo "openMining() on B20Mining $MINING"
    if dry; then
      cast call "$MINING" "openMining()" --from "$DEPLOYER" --rpc-url "$RPC" && echo "would succeed"
    else
      cast send "$MINING" "openMining()" --account "$ACCOUNT" --from "$DEPLOYER" --rpc-url "$RPC"
    fi
    ;;
  launchpad)
    dry && export LAUNCHPAD_OUTPUT_PATH="$DIR/launchpad-v16-dryrun.json"
    forge_run script/DeployLaunchpad.s.sol:DeployLaunchpad
    ;;
  wallet)
    # The wallet factory trusts this genesis and the Launchpad just deployed.
    export LAUNCHPAD_FACTORY=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).contracts.launchpadFactory)' "$DIR/launchpad-deployment.json")
    [[ "$NETWORK" == "base-sepolia" ]] && export MINER_RELAY="${MINER_RELAY:-0xB486f2293C5D62A52CeD0D4481Eb7fd2eb64C165}"
    dry && export MINER_WALLET_OUTPUT_PATH="$DIR/miner-wallet-dryrun.json"
    echo "LAUNCHPAD_FACTORY $LAUNCHPAD_FACTORY, MINER_RELAY ${MINER_RELAY:-new}"
    forge_run script/DeployMinerWallet.s.sol:DeployMinerWallet
    ;;
  *)
    echo "usage: ACCOUNT=<keystore> [NETWORK=base-sepolia|base] [DRY_RUN=1] $0 genesis|open|launchpad|wallet"
    exit 1
    ;;
esac
