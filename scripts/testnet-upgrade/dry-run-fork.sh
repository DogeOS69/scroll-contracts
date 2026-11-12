#!/bin/sh
set -eu

# Dry run of the testnet L2 proxy upgrades on an anvil fork of testnet L2 state.
# One-off; see README.md next to this file.
#
#   CONFIG_CONTRACTS=/path/to/network/config-contracts.toml \
#     scripts/testnet-upgrade/dry-run-fork.sh
#
# Runs the real operator scripts in the README's order against the fork, with
# BROADCAST=1:
#   0. check the pause script refuses the messenger as deployed
#   1. deploy + upgrade the L2DogeOsMessenger implementation (before the window);
#      check a withdrawal through the old Moat is queued
#   2. pause the messenger; check a withdrawal reverts on the pause and a deposit
#      is credited
#   3. deploy + upgrade the Moat implementation (reopening)
#   4. unpause; check a Moat withdrawal and a fee vault withdrawal are queued, the
#      Moat holds the fee, a deposit is credited, and sweepFees pays the fees
# and checks after each upgrade that the proxy's storage and wiring are unchanged.
#
# Transactions go only to the fork. The scripts sign with anvil's well-known dev keys, so
# the fork first moves ownership of the ProxyAdmin, messenger and Moat to that key
# (impersonating the real owner) and funds it. volume/ is created for the run from
# docker/templates/config.toml and removed afterwards; the script refuses to run
# if volume/ already exists.
#
# Inputs:
#   CONFIG_CONTRACTS  the network's config-contracts.toml (addresses only; required)
#   FORK_URL          L2 RPC to fork (default https://rpc.testnet.dogeos.com)
#   CHAIN_ID_L1       selects the Dogecoin prefixes (default 111111, Dogecoin testnet)
#   ANVIL_PORT        default 8546

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
SHELL_DIR="$REPO_ROOT/scripts/deterministic/shell"
VOLUME="$REPO_ROOT/volume"

FORK_URL="${FORK_URL:-https://rpc.testnet.dogeos.com}"
CHAIN_ID_L1="${CHAIN_ID_L1:-111111}"
ANVIL_PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:$ANVIL_PORT"
CONFIG_CONTRACTS="${CONFIG_CONTRACTS:?set CONFIG_CONTRACTS to the network config-contracts.toml}"

# anvil dev accounts 0 (deployer + owner) and 1 (a user). Public test keys.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
USER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
P2PKH_TARGET=0x00000000000000000000000000000000000000aa
WITHDRAW_VALUE=10000000000000000000
DEPOSIT_VALUE=5000000000000000000

fail() {
    echo "DRY RUN FAILED: $1"
    exit 1
}

[ -f "$CONFIG_CONTRACTS" ] || fail "missing $CONFIG_CONTRACTS"
[ ! -e "$VOLUME" ] || fail "$VOLUME exists; move it away first (this run creates and deletes it)"
for c in anvil cast forge python3; do command -v "$c" >/dev/null || fail "missing command: $c"; done

# A second anvil on a busy port exits, and the readiness check below would then
# talk to whatever already listens there.
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
    fail "something already serves $RPC; stop it or set ANVIL_PORT"
fi
ANVIL_LOG=$(mktemp)
cleanup() {
    [ -z "${ANVIL_PID:-}" ] || kill "$ANVIL_PID" 2>/dev/null || true
    rm -rf "$VOLUME" "$ANVIL_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

anvil --fork-url "$FORK_URL" --port "$ANVIL_PORT" --silent >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
i=0
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do
    i=$((i + 1))
    kill -0 "$ANVIL_PID" 2>/dev/null || fail "anvil exited (port $ANVIL_PORT in use?): $(cat "$ANVIL_LOG")"
    [ "$i" -lt 60 ] || fail "anvil did not start: $(cat "$ANVIL_LOG")"
    sleep 1
done

get() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$CONFIG_CONTRACTS"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
call() { cast call "$@" --rpc-url "$RPC" || fail "cast call $*"; }
# A uint256 call result without cast's "[1e18]" annotation.
uint() {
    out=$(call "$@")
    echo "${out%% *}"
}
rpc() { cast rpc "$@" --rpc-url "$RPC" >/dev/null; }
math() { python3 -c "print($1)"; }
eq() {
    [ "$3" != "" ] || fail "$1: empty expected value"
    [ "$(lower "$2")" = "$(lower "$3")" ] || fail "$1: expected $3, got $2"
    echo "ok  $1"
}
# Sends $2... from the user and requires a revert whose output contains $1.
reverts() {
    reason=$1
    shift
    if out=$(cast send "$@" --private-key "$USER_KEY" --legacy --rpc-url "$RPC" 2>&1); then
        fail "expected a revert ($reason), but the transaction succeeded"
    fi
    case "$out" in
    *"$reason"*) ;;
    *) fail "expected a revert ($reason), got: $out" ;;
    esac
}

PROXY_ADMIN=$(get L2_PROXY_ADMIN_ADDR)
MESSENGER=$(get L2_DOGEOS_MESSENGER_PROXY_ADDR)
MOAT=$(get L2_MOAT_PROXY_ADDR)
QUEUE=$(get L2_MESSAGE_QUEUE_ADDR)
ADAPTER=$(get L2_FEE_VAULT_MOAT_ADAPTER_ADDR)
CHAIN_ID_L2=$(cast chain-id --rpc-url "$RPC")
echo "fork of $FORK_URL (chain $CHAIN_ID_L2) at block $(cast block-number --rpc-url "$RPC") on $RPC"

# The deployed-layout pins (deployed-layouts/) describe these exact implementations.
# A different implementation means testnet changed since they were pinned.
code_hash() { cast keccak "$(cast code "$(cast implementation "$1" --rpc-url "$RPC")" --rpc-url "$RPC")"; }
EXPECTED_MESSENGER_CODE=$(sed -n 's/^| L2DogeOsMessenger .*| `\(0x[0-9a-f]*\)` |$/\1/p' "$SCRIPT_DIR/README.md")
EXPECTED_MOAT_CODE=$(sed -n 's/^| Moat .*| `\(0x[0-9a-f]*\)` |$/\1/p' "$SCRIPT_DIR/README.md")
eq "messenger implementation is the pinned one" "$(code_hash "$MESSENGER")" "$EXPECTED_MESSENGER_CODE"
eq "Moat implementation is the pinned one" "$(code_hash "$MOAT")" "$EXPECTED_MOAT_CODE"
python3 "$SCRIPT_DIR/check-upgrade-layout.py"

# --- fork-only setup: hand ownership to the dev key ---------------------------
OWNER=$(call "$PROXY_ADMIN" 'owner()(address)')
rpc anvil_impersonateAccount "$OWNER"
rpc anvil_setBalance "$OWNER" 0x56BC75E2D63100000
for c in "$PROXY_ADMIN" "$MESSENGER" "$MOAT"; do
    cast send "$c" 'transferOwnership(address)' "$ADDR" --from "$OWNER" --unlocked --legacy --rpc-url "$RPC" >/dev/null
done
rpc anvil_stopImpersonatingAccount "$OWNER"
USER=$(cast wallet address --private-key "$USER_KEY")
for a in "$ADDR" "$USER"; do rpc anvil_setBalance "$a" 0x3635C9ADC5DEA00000; done

mkdir "$VOLUME"
cp "$CONFIG_CONTRACTS" "$VOLUME/config-contracts.toml"
sed -e "s|^CHAIN_ID_L1 = .*|CHAIN_ID_L1 = $CHAIN_ID_L1|" \
    -e "s|^CHAIN_ID_L2 = .*|CHAIN_ID_L2 = $CHAIN_ID_L2|" \
    -e "s|^EXTERNAL_RPC_URI_L2 = .*|EXTERNAL_RPC_URI_L2 = \"$RPC\"|" \
    -e "s|^DEPLOYER_ADDR = .*|DEPLOYER_ADDR = \"$ADDR\"|" \
    -e "s|^OWNER_ADDR = .*|OWNER_ADDR = \"$ADDR\"|" \
    -e "s|^L2_GAS_ORACLE_SENDER_ADDR = .*|L2_GAS_ORACLE_SENDER_ADDR = \"$ADDR\"|" \
    "$REPO_ROOT/docker/templates/config.toml" >"$VOLUME/config.toml"
unset FORCE
export DEPLOYER_PRIVATE_KEY="$KEY" OWNER_PRIVATE_KEY="$KEY" BROADCAST=1

# Storage the upgrades must not touch: whole-slot reads of the deployed layout.
messenger_state() {
    for s in 0 51 101 151 201 202 203 204; do cast storage "$MESSENGER" "$s" --rpc-url "$RPC"; done
    call "$MESSENGER" 'counterpart()(address)'
    call "$MESSENGER" 'messageQueue()(address)'
    call "$MESSENGER" 'MOAT()(address)'
}
moat_state() {
    for s in 0 1 51 52 53 54 55 56; do cast storage "$MOAT" "$s" --rpc-url "$RPC"; done
    call "$MOAT" 'feeExemptCallers(address)(bool)' "$ADAPTER"
}
deposit() { # relays an L1 deposit of $2 wei to $1 through the messenger, as the sequencer would
    COUNTERPART=$(call "$MESSENGER" 'counterpart()(address)')
    ALIAS=$(python3 -c "import sys; print('0x%040x' % ((int(sys.argv[1], 16) + 0x1111000000000000000000000000000000001111) % 2**160))" "$COUNTERPART")
    rpc anvil_impersonateAccount "$ALIAS"
    rpc anvil_setBalance "$ALIAS" 0x56BC75E2D63100000
    cast send "$MESSENGER" 'relayMessage(address,address,uint256,uint256,bytes)' \
        "$1" "$MOAT" "$2" "$3" "$(cast calldata 'handleL1Message(address,bytes32)' "$1" 0x0000000000000000000000000000000000000000000000000000000000000000)" \
        --from "$ALIAS" --unlocked --legacy --rpc-url "$RPC" >/dev/null
    rpc anvil_stopImpersonatingAccount "$ALIAS"
}

# --- 1. messenger implementation (before the window) --------------------------
echo ""
echo "== step 0: the pause script refuses the deployed messenger"
if out=$("$SHELL_DIR/submit-dogeos-messenger-pause.sh" pause 2>&1); then
    fail "the pause script accepted the deployed messenger"
fi
case "$out" in
*"refuses deposit relays while paused"*) echo "ok  pause refused: deposits would stop relaying" ;;
*) fail "the pause script failed for another reason: $out" ;;
esac

echo ""
echo "== step 1: messenger implementation"
BEFORE=$(messenger_state)
"$SHELL_DIR/deploy-dogeos-messenger-impl.sh"
"$SHELL_DIR/submit-dogeos-messenger-proxy-upgrade.sh"
eq "messenger proxy points at the new implementation" "$(cast implementation "$MESSENGER" --rpc-url "$RPC")" "$(sed -n 's/^L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR *= *"\(.*\)".*/\1/p' "$VOLUME/config-contracts.toml")"
eq "messenger storage and wiring unchanged" "$(messenger_state)" "$BEFORE"
# Testnet stays longest in this state: old Moat, new messenger, not paused.
INDEX=$(uint "$QUEUE" 'nextMessageIndex()(uint256)')
cast send "$MOAT" 'withdrawToP2PKH(address)' "$P2PKH_TARGET" --value "$WITHDRAW_VALUE" \
    --private-key "$USER_KEY" --legacy --rpc-url "$RPC" >/dev/null
eq "old Moat + new messenger: withdrawal appended to the queue" "$(uint "$QUEUE" 'nextMessageIndex()(uint256)')" "$(math "$INDEX + 1")"

# --- 2. pause: withdrawals refused, deposits relay ----------------------------
echo ""
echo "== step 2: withdrawals-only pause"
"$SHELL_DIR/submit-dogeos-messenger-pause.sh" pause
reverts "Pausable: paused" "$MOAT" 'withdrawToP2PKH(address)' "$P2PKH_TARGET" --value "$WITHDRAW_VALUE"
echo "ok  withdrawal refused while paused"
DEPOSIT_TO=0x00000000000000000000000000000000000dE905
DEPOSIT_FEE=$(uint "$MOAT" 'depositFee()(uint256)')
deposit "$DEPOSIT_TO" "$DEPOSIT_VALUE" 4242424242
eq "deposit credited while paused" "$(cast balance "$DEPOSIT_TO" --rpc-url "$RPC")" "$(math "$DEPOSIT_VALUE - $DEPOSIT_FEE")"

# --- 3. Moat implementation (reopening) ---------------------------------------
echo ""
echo "== step 3: Moat implementation"
BEFORE=$(moat_state)
# The Dogecoin prefixes are immutables, chosen from CHAIN_ID_L1 at deploy time.
PREFIXES=$(call "$MOAT" 'P2PKH_PREFIX()(bytes1)')$(call "$MOAT" 'P2SH_PREFIX()(bytes1)')
"$SHELL_DIR/deploy-moat-impl.sh"
"$SHELL_DIR/submit-moat-proxy-upgrade.sh"
eq "Moat proxy points at the new implementation" "$(cast implementation "$MOAT" --rpc-url "$RPC")" "$(sed -n 's/^L2_MOAT_IMPLEMENTATION_ADDR *= *"\(.*\)".*/\1/p' "$VOLUME/config-contracts.toml")"
eq "Moat storage unchanged" "$(moat_state)" "$BEFORE"
eq "Moat MESSENGER is the messenger proxy" "$(call "$MOAT" 'MESSENGER()(address)')" "$MESSENGER"
eq "Moat Dogecoin prefixes unchanged" "$(call "$MOAT" 'P2PKH_PREFIX()(bytes1)')$(call "$MOAT" 'P2SH_PREFIX()(bytes1)')" "$PREFIXES"

# --- 4. unpause: withdrawals resume, fees held then swept ---------------------
echo ""
echo "== step 4: unpause"
"$SHELL_DIR/submit-dogeos-messenger-pause.sh" unpause
INDEX=$(uint "$QUEUE" 'nextMessageIndex()(uint256)')
MOAT_BALANCE=$(cast balance "$MOAT" --rpc-url "$RPC")
WITHDRAWAL_FEE=$(uint "$MOAT" 'withdrawalFee()(uint256)')
cast send "$MOAT" 'withdrawToP2PKH(address)' "$P2PKH_TARGET" --value "$WITHDRAW_VALUE" \
    --private-key "$USER_KEY" --legacy --rpc-url "$RPC" >/dev/null
eq "withdrawal appended to the queue" "$(uint "$QUEUE" 'nextMessageIndex()(uint256)')" "$(math "$INDEX + 1")"
eq "withdrawal fee held by the Moat" "$(cast balance "$MOAT" --rpc-url "$RPC")" "$(math "$MOAT_BALANCE + $WITHDRAWAL_FEE")"
FEE_VAULT=$(get L2_TX_FEE_VAULT_ADDR)
cast send "$FEE_VAULT" 'withdraw(uint256)' "$(uint "$FEE_VAULT" 'minWithdrawAmount()(uint256)')" \
    --private-key "$USER_KEY" --legacy --rpc-url "$RPC" >/dev/null
eq "fee vault withdrawal through the adapter appended to the queue" "$(uint "$QUEUE" 'nextMessageIndex()(uint256)')" "$(math "$INDEX + 2")"
BALANCE=$(cast balance "$DEPOSIT_TO" --rpc-url "$RPC")
deposit "$DEPOSIT_TO" "$DEPOSIT_VALUE" 4242424243
eq "deposit credited by the new Moat" "$(cast balance "$DEPOSIT_TO" --rpc-url "$RPC")" "$(math "$BALANCE + $DEPOSIT_VALUE - $DEPOSIT_FEE")"
HELD=$(cast balance "$MOAT" --rpc-url "$RPC")
RECIPIENT=$(call "$MOAT" 'feeRecipient()(address)')
RECIPIENT_BEFORE=$(cast balance "$RECIPIENT" --rpc-url "$RPC")
cast send "$MOAT" 'sweepFees()' --private-key "$USER_KEY" --legacy --rpc-url "$RPC" >/dev/null
eq "sweepFees paid the held fees to feeRecipient" "$(cast balance "$RECIPIENT" --rpc-url "$RPC")" "$(math "$RECIPIENT_BEFORE + $HELD")"
eq "Moat holds nothing after the sweep" "$(cast balance "$MOAT" --rpc-url "$RPC")" 0

echo ""
echo "DRY RUN PASSED"
