#!/bin/sh
set -eu

# Pauses or unpauses the L2DogeOsMessenger (ScrollMessengerBase.setPause) from its owner.
#
#   scripts/deterministic/shell/submit-dogeos-messenger-pause.sh pause|unpause
#
# A pause freezes withdrawals (sendMessage) only when the proxy runs an
# implementation from dogeos-v0.3.0-rc.5 (#71) or later; older implementations
# also refuse relayMessage, and a deposit the sequencer includes while they are
# paused is consumed without being credited (UPGRADE_MOAT.md section 1.8).
# Before pausing, this script therefore simulates a zero-value deposit relay to the
# Moat with the paused flag forced on (eth_call with a state override) and refuses
# to pause if that relay reverts. FORCE=1 skips that refusal.
#
# RPC from volume/config.toml (or RPC_URL); addresses from
# volume/config-contracts.toml.
# Inputs:
#   BROADCAST=1             send the transaction (otherwise preflight only)
#   OWNER_PRIVATE_KEY=0x... messenger owner key; required only when BROADCAST=1
#   FORCE=1                 pause even if deposits would stop relaying

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ "$REPO_ROOT" = "" ]; then
    REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
fi

VOLUME_PATH="$REPO_ROOT/volume"
CONFIG="$VOLUME_PATH/config.toml"
CONFIG_CONTRACTS="$VOLUME_PATH/config-contracts.toml"
OWNER_PRIVATE_KEY="${OWNER_PRIVATE_KEY:-}"

# ScrollMessengerBase storage: PausableUpgradeable._paused (storage-layouts/L2DogeOsMessenger.json).
PAUSED_SLOT=101
PROBE_ADDR=0x000000000000000000000000000000000000dEaD

extract() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$2"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

fail() {
    echo "$1"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

case "${1:-}" in
    pause) TARGET=true ;;
    unpause) TARGET=false ;;
    *) fail "usage: $0 pause|unpause" ;;
esac

[ -f "$CONFIG" ] || fail "missing file: $CONFIG"
[ -f "$CONFIG_CONTRACTS" ] || fail "missing file: $CONFIG_CONTRACTS"
require_command cast
require_command python3

RPC_URL="${RPC_URL:-$(extract EXTERNAL_RPC_URI_L2 "$CONFIG")}"
MESSENGER=$(extract L2_DOGEOS_MESSENGER_PROXY_ADDR "$CONFIG_CONTRACTS")
MOAT=$(extract L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
[ "$RPC_URL" != "" ] || fail "EXTERNAL_RPC_URI_L2 in $CONFIG or RPC_URL is not set"
[ "$MESSENGER" != "" ] || fail "L2_DOGEOS_MESSENGER_PROXY_ADDR in $CONFIG_CONTRACTS is not set"
[ "$MOAT" != "" ] || fail "L2_MOAT_PROXY_ADDR in $CONFIG_CONTRACTS is not set"
[ "$(cast code "$MESSENGER" --rpc-url "$RPC_URL")" != "0x" ] || fail "messenger proxy has no code at $MESSENGER"

# Simulates a zero-value deposit relay to the Moat while the messenger is paused
# (forced through a state override when $1 = override, as is otherwise). Prints
# "ok" when the relay would succeed, or the revert.
probe_relay() {
    COUNTERPART=$(cast call "$MESSENGER" 'counterpart()(address)' --rpc-url "$RPC_URL")
    # AddressAliasHelper.applyL1ToL2Alias: the L1 messenger's L2 alias is the only relayer.
    ALIAS=$(python3 -c "import sys; print('0x%040x' % ((int(sys.argv[1], 16) + 0x1111000000000000000000000000000000001111) % 2**160))" "$COUNTERPART")
    MESSAGE=$(cast calldata 'handleL1Message(address,bytes32)' "$PROBE_ADDR" 0x0000000000000000000000000000000000000000000000000000000000000000)
    if [ "$1" = "override" ]; then
        set -- --override-state-diff "$MESSENGER:$PAUSED_SLOT:1"
    else
        set --
    fi
    # The nonce is far above any real message, so the probe's hash is unused.
    if OUT=$(cast call "$MESSENGER" 'relayMessage(address,address,uint256,uint256,bytes)' \
        "$PROBE_ADDR" "$MOAT" 0 "$(cast max-uint)" "$MESSAGE" \
        --from "$ALIAS" "$@" --rpc-url "$RPC_URL" 2>&1); then
        echo ok
    else
        echo "$OUT" | tail -n 1
    fi
}

OWNER=$(cast call "$MESSENGER" 'owner()(address)' --rpc-url "$RPC_URL")
PAUSED=$(cast call "$MESSENGER" 'paused()(bool)' --rpc-url "$RPC_URL")
echo "RPC:             $RPC_URL"
echo "chain id:        $(cast chain-id --rpc-url "$RPC_URL")"
echo "messenger proxy: $MESSENGER"
echo "implementation:  $(cast implementation "$MESSENGER" --rpc-url "$RPC_URL")"
echo "messenger owner: $OWNER"
echo "paused:          $PAUSED -> $TARGET"

if [ "$TARGET" = "true" ]; then
    RELAY=$(probe_relay override)
    echo "deposit relay while paused (simulated): $RELAY"
    if [ "$RELAY" != "ok" ]; then
        echo ""
        echo "this messenger implementation refuses deposit relays while paused;"
        echo "pausing it would also stop deposits (upgrade it first, UPGRADE_MOAT.md 1.8)."
        [ "${FORCE:-0}" = "1" ] || exit 1
        echo "FORCE=1 set - continuing anyway"
    fi
fi

if [ "$PAUSED" = "$TARGET" ]; then
    echo "messenger is already in the requested state"
    exit 0
fi

if [ "${BROADCAST:-0}" != "1" ]; then
    echo ""
    echo "preflight only - set BROADCAST=1 to $1 the messenger"
    exit 0
fi

[ "$OWNER_PRIVATE_KEY" != "" ] || fail "OWNER_PRIVATE_KEY is not set for broadcast"
SIGNER=$(cast wallet address --private-key "$OWNER_PRIVATE_KEY")
[ "$(lower "$SIGNER")" = "$(lower "$OWNER")" ] || fail "OWNER_PRIVATE_KEY controls $SIGNER, but the messenger owner is $OWNER"

echo ""
echo "broadcasting setPause($TARGET)"
cast send "$MESSENGER" 'setPause(bool)' "$TARGET" \
    --rpc-url "$RPC_URL" \
    --private-key "$OWNER_PRIVATE_KEY" \
    --legacy >/dev/null

POST=$(cast call "$MESSENGER" 'paused()(bool)' --rpc-url "$RPC_URL")
echo "paused after:    $POST"
[ "$POST" = "$TARGET" ] || fail "post-check failed: paused() is $POST"
if [ "$TARGET" = "true" ]; then
    RELAY=$(probe_relay live)
    echo "deposit relay while paused (live state): $RELAY"
    [ "$RELAY" = "ok" ] || [ "${FORCE:-0}" = "1" ] || fail "post-check failed: deposits no longer relay"
fi
