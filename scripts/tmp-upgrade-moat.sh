#!/usr/bin/env bash
# Temporary operator wrapper for UPGRADE_MOAT.md.
#
# This file deliberately orchestrates the existing upgrade scripts instead of
# duplicating their transaction logic.  It is safe to rerun after diagnosing a
# failed step: the underlying deployments are deterministic, state changes are
# idempotent, and every operation performs its own on-chain preflight checks.

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi

VOLUME_DIR="$REPO_ROOT/volume"
CONFIG="$VOLUME_DIR/config.toml"
CONFIG_CONTRACTS="$VOLUME_DIR/config-contracts.toml"
SHELL_DIR="$REPO_ROOT/scripts/deterministic/shell"

trap 'rc=$?; printf "\nERROR: tmp-upgrade-moat.sh stopped at line %s (exit %s).\n" "$LINENO" "$rc" >&2' ERR

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '\n==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_file() {
    [[ -f "$1" ]] || die "missing file: $1"
}

require_env() {
    local name=$1
    [[ -n "${!name:-}" ]] || die "$name is required"
}

resolve_deployer_private_key() {
    [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]] || return

    require_env OWNER_PRIVATE_KEY

    local deployer_addr owner_addr signer
    deployer_addr=$(extract_string DEPLOYER_ADDR "$CONFIG")
    owner_addr=$(extract_string OWNER_ADDR "$CONFIG")
    validate_address DEPLOYER_ADDR "$deployer_addr"
    validate_address OWNER_ADDR "$owner_addr"

    if [[ "$(lower "$deployer_addr")" != "$(lower "$owner_addr")" ]]; then
        die "DEPLOYER_ADDR and OWNER_ADDR differ; set DEPLOYER_PRIVATE_KEY separately"
    fi

    signer=$(cast wallet address --private-key "$OWNER_PRIVATE_KEY") ||
        die "failed to derive an address from OWNER_PRIVATE_KEY"
    assert_address_equal "owner/deployer signer" "$signer" "$deployer_addr"

    export DEPLOYER_PRIVATE_KEY="$OWNER_PRIVATE_KEY"
    printf '  [ok] reusing OWNER_PRIVATE_KEY for deterministic deployments\n'
}

extract_string() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | tail -n 1
}

extract_number() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*\([0-9_][0-9_]*\).*/\1/p" "$2" | tail -n 1 | tr -d '_'
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

first_word() {
    awk '{print $1}' <<<"$1"
}

assert_equal() {
    local label=$1 actual=$2 expected=$3
    [[ "$actual" == "$expected" ]] || die "$label mismatch: got $actual, expected $expected"
    printf '  [ok] %-28s %s\n' "$label" "$actual"
}

assert_address_equal() {
    local label=$1 actual=$2 expected=$3
    [[ "$(lower "$actual")" == "$(lower "$expected")" ]] ||
        die "$label mismatch: got $actual, expected $expected"
    printf '  [ok] %-28s %s\n' "$label" "$actual"
}

validate_address() {
    local label=$1 value=$2
    [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$label is not a 20-byte hex address: $value"
    [[ "$(lower "$value")" != "0x0000000000000000000000000000000000000000" ]] || die "$label must not be zero"
}

validate_config() {
    require_file "$CONFIG"
    require_file "$CONFIG_CONTRACTS"

    local key value expected
    for key in COMMIT_SCALAR BLOB_SCALAR SCALAR PENALTY_FACTOR FEE_VAULT_DOGE_RECIPIENT_ADDR; do
        grep -Eq "^${key}[[:space:]]*=" "$CONFIG" || die "$key is missing from $CONFIG"
    done

    for key in EXTERNAL_RPC_URI_L2 CHAIN_ID_L1; do
        grep -Eq "^${key}[[:space:]]*=" "$CONFIG" || die "$key is missing from $CONFIG"
    done

    for key in L2_PROXY_ADMIN_ADDR L2_MOAT_PROXY_ADDR L2_TX_FEE_VAULT_ADDR \
        L2_DOGEOS_MESSENGER_PROXY_ADDR L2_WHITELIST_ADDR L1_GAS_PRICE_ORACLE_ADDR; do
        value=$(extract_string "$key" "$CONFIG_CONTRACTS")
        [[ -n "$value" ]] || die "$key is missing or empty in $CONFIG_CONTRACTS"
        validate_address "$key" "$value"
    done

    while read -r key expected; do
        value=$(extract_number "$key" "$CONFIG")
        [[ "$value" == "$expected" ]] || die "$key is $value; UPGRADE_MOAT.md requires $expected"
    done <<'EOF'
COMMIT_SCALAR 38720000000
BLOB_SCALAR 8000000000
SCALAR 938846
PENALTY_FACTOR 10000
EOF

    value=$(extract_string FEE_VAULT_DOGE_RECIPIENT_ADDR "$CONFIG")
    validate_address FEE_VAULT_DOGE_RECIPIENT_ADDR "$value"

    if grep -n 'dogeos\.com' "$CONFIG"; then
        die "dogeos.com still appears in $CONFIG"
    fi

    printf '  [ok] configuration files and required Moat values\n'
}

prepare_config() {
    local config_dir=${1:-${CONFIG_DIR:-}}
    local staging_dir
    [[ -n "$config_dir" ]] || die "usage: $0 prepare /path/to/network-config"
    require_file "$config_dir/config.toml"
    require_file "$config_dir/config-contracts.toml"

    staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/scroll-contracts-moat-config.XXXXXX")
    cp "$config_dir/config.toml" "$staging_dir/config.toml"
    cp "$config_dir/config-contracts.toml" "$staging_dir/config-contracts.toml"
    perl -pi -e 's/testnet\.dogeos\.com/devnet.doge.xyz/g' "$staging_dir/config.toml"

    # Validate the staged copy before touching an existing volume.
    CONFIG="$staging_dir/config.toml" \
        CONFIG_CONTRACTS="$staging_dir/config-contracts.toml" \
        validate_config

    if [[ -e "$VOLUME_DIR" || -L "$VOLUME_DIR" ]]; then
        local backup_root backup_path
        backup_root=$(mktemp -d "${TMPDIR:-/tmp}/scroll-contracts-moat-volume.XXXXXX")
        backup_path="$backup_root/volume"
        mv "$VOLUME_DIR" "$backup_path"
        printf 'Existing volume moved to %s\n' "$backup_path"
    fi

    mv "$staging_dir" "$VOLUME_DIR"

    validate_config
    note "Local upgrade configuration is ready"
    ls -l "$CONFIG" "$CONFIG_CONTRACTS"
}

require_bridge_broadcast_inputs() {
    [[ "${BROADCAST:-0}" == "1" ]] || die "bridge sends transactions; set BROADCAST=1"
    require_env OWNER_PRIVATE_KEY
    resolve_deployer_private_key
}

run_bridge_preflight() {
    validate_config
    require_command cast
    require_command forge
    resolve_deployer_private_key

    note "Simulate Moat implementation deployment"
    BROADCAST=0 "$SHELL_DIR/deploy-moat-impl.sh"

    note "Simulate FeeVaultMoatAdapter deployment"
    BROADCAST=0 "$SHELL_DIR/deploy-fee-vault-moat-adapter.sh"

    note "Simulate L2DogeOsMessenger implementation deployment"
    BROADCAST=0 "$SHELL_DIR/deploy-dogeos-messenger-impl.sh"

    note "Deployment simulations passed"
    printf '%s\n' \
        'Proxy upgrades and the fee-vault rewire cannot all be preflighted before' \
        'their target bytecode exists. Run the guarded bridge command to continue.'
}

run_bridge() {
    validate_config
    require_command cast
    require_command forge
    require_bridge_broadcast_inputs

    local rpc proxy messenger_proxy
    local moat_messenger_before moat_withdrawal_fee_before moat_min_before
    local moat_deposit_fee_before moat_fee_recipient_before moat_owner_before
    local messenger_counterpart_before messenger_paused_before
    rpc=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")
    proxy=$(extract_string L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
    messenger_proxy=$(extract_string L2_DOGEOS_MESSENGER_PROXY_ADDR "$CONFIG_CONTRACTS")

    note "Capture storage values that the proxy upgrades must preserve"
    moat_messenger_before=$(cast call "$proxy" 'messenger()(address)' --rpc-url "$rpc")
    moat_withdrawal_fee_before=$(first_word "$(cast call "$proxy" 'withdrawalFee()(uint256)' --rpc-url "$rpc")")
    moat_min_before=$(first_word "$(cast call "$proxy" 'minWithdrawalAmount()(uint256)' --rpc-url "$rpc")")
    moat_deposit_fee_before=$(first_word "$(cast call "$proxy" 'depositFee()(uint256)' --rpc-url "$rpc")")
    moat_fee_recipient_before=$(cast call "$proxy" 'feeRecipient()(address)' --rpc-url "$rpc")
    moat_owner_before=$(cast call "$proxy" 'owner()(address)' --rpc-url "$rpc")
    messenger_counterpart_before=$(cast call "$messenger_proxy" 'counterpart()(address)' --rpc-url "$rpc")
    messenger_paused_before=$(first_word "$(cast call "$messenger_proxy" 'paused()(bool)' --rpc-url "$rpc")")

    note "1/6 Deploy Moat implementation (includes simulation)"
    BROADCAST=1 "$SHELL_DIR/deploy-moat-impl.sh"

    note "2/6 Upgrade Moat proxy"
    BROADCAST=1 OWNER_PRIVATE_KEY="$OWNER_PRIVATE_KEY" \
        "$SHELL_DIR/submit-moat-proxy-upgrade.sh"

    note "3/6 Deploy FeeVaultMoatAdapter (includes simulation)"
    BROADCAST=1 "$SHELL_DIR/deploy-fee-vault-moat-adapter.sh"

    note "4/6 Rewire fee vault through the adapter"
    BROADCAST=1 OWNER_PRIVATE_KEY="$OWNER_PRIVATE_KEY" \
        "$SHELL_DIR/submit-fee-vault-rewire.sh"

    note "5/6 Deploy L2DogeOsMessenger implementation (includes simulation)"
    BROADCAST=1 "$SHELL_DIR/deploy-dogeos-messenger-impl.sh"

    note "6/6 Upgrade L2DogeOsMessenger proxy"
    BROADCAST=1 OWNER_PRIVATE_KEY="$OWNER_PRIVATE_KEY" \
        "$SHELL_DIR/submit-dogeos-messenger-proxy-upgrade.sh"

    verify_bridge

    note "Verify proxy storage preservation"
    assert_address_equal "Moat messenger" \
        "$(cast call "$proxy" 'messenger()(address)' --rpc-url "$rpc")" "$moat_messenger_before"
    assert_equal "Moat withdrawalFee" \
        "$(first_word "$(cast call "$proxy" 'withdrawalFee()(uint256)' --rpc-url "$rpc")")" "$moat_withdrawal_fee_before"
    assert_equal "Moat minWithdrawalAmount" \
        "$(first_word "$(cast call "$proxy" 'minWithdrawalAmount()(uint256)' --rpc-url "$rpc")")" "$moat_min_before"
    assert_equal "Moat depositFee" \
        "$(first_word "$(cast call "$proxy" 'depositFee()(uint256)' --rpc-url "$rpc")")" "$moat_deposit_fee_before"
    assert_address_equal "Moat feeRecipient" \
        "$(cast call "$proxy" 'feeRecipient()(address)' --rpc-url "$rpc")" "$moat_fee_recipient_before"
    assert_address_equal "Moat owner" \
        "$(cast call "$proxy" 'owner()(address)' --rpc-url "$rpc")" "$moat_owner_before"
    assert_address_equal "messenger counterpart" \
        "$(cast call "$messenger_proxy" 'counterpart()(address)' --rpc-url "$rpc")" "$messenger_counterpart_before"
    assert_equal "messenger paused" \
        "$(first_word "$(cast call "$messenger_proxy" 'paused()(bool)' --rpc-url "$rpc")")" "$messenger_paused_before"

    note "Bridge phase completed and core state was read back"
    printf '%s\n' \
        'Still required before the fee migration:' \
        '  - complete the end-to-end P2PKH, P2SH, dust, and fee-vault withdrawals;' \
        '  - confirm the envelope-aware L1 withdrawal processor;' \
        '  - stop public transaction ingress and every fee-oracle writer.'
}

verify_bridge() {
    validate_config
    require_command cast

    local rpc chain_id p2pkh_expected p2sh_expected
    local proxy moat_impl messenger_proxy messenger_impl adapter vault recipient
    local actual moat_min vault_min required_min

    rpc=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")
    chain_id=$(extract_number CHAIN_ID_L1 "$CONFIG")
    proxy=$(extract_string L2_MOAT_PROXY_ADDR "$CONFIG_CONTRACTS")
    moat_impl=$(extract_string L2_MOAT_IMPLEMENTATION_ADDR "$CONFIG_CONTRACTS")
    messenger_proxy=$(extract_string L2_DOGEOS_MESSENGER_PROXY_ADDR "$CONFIG_CONTRACTS")
    messenger_impl=$(extract_string L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR "$CONFIG_CONTRACTS")
    adapter=$(extract_string L2_FEE_VAULT_MOAT_ADAPTER_ADDR "$CONFIG_CONTRACTS")
    vault=$(extract_string L2_TX_FEE_VAULT_ADDR "$CONFIG_CONTRACTS")
    recipient=$(extract_string FEE_VAULT_DOGE_RECIPIENT_ADDR "$CONFIG")

    for value in "$moat_impl" "$messenger_impl" "$adapter"; do
        [[ -n "$value" ]] || die "bridge deployment address is missing from $CONFIG_CONTRACTS"
        validate_address deployment_address "$value"
        actual=$(cast code "$value" --rpc-url "$rpc")
        [[ "$actual" != "0x" ]] || die "no deployed bytecode at $value"
    done

    case "$chain_id" in
        1)       p2pkh_expected=0x1e; p2sh_expected=0x16 ;;
        111111)  p2pkh_expected=0x71; p2sh_expected=0xc4 ;;
        5555555) p2pkh_expected=0x6f; p2sh_expected=0xc4 ;;
        *) die "unsupported CHAIN_ID_L1 for Dogecoin prefix verification: $chain_id" ;;
    esac

    note "Read back bridge state from $rpc"
    actual=$(cast implementation "$proxy" --rpc-url "$rpc")
    assert_address_equal "Moat implementation" "$actual" "$moat_impl"
    actual=$(cast implementation "$messenger_proxy" --rpc-url "$rpc")
    assert_address_equal "messenger implementation" "$actual" "$messenger_impl"

    actual=$(first_word "$(cast call "$proxy" 'P2PKH_PREFIX()(bytes1)' --rpc-url "$rpc")")
    assert_equal "P2PKH prefix" "$(lower "$actual")" "$p2pkh_expected"
    actual=$(first_word "$(cast call "$proxy" 'P2SH_PREFIX()(bytes1)' --rpc-url "$rpc")")
    assert_equal "P2SH prefix" "$(lower "$actual")" "$p2sh_expected"
    actual=$(first_word "$(cast call "$proxy" 'SATOSHI_TO_WEI()(uint256)' --rpc-url "$rpc")")
    assert_equal "SATOSHI_TO_WEI" "$actual" "10000000000"

    actual=$(cast call "$adapter" 'FEE_VAULT()(address)' --rpc-url "$rpc")
    assert_address_equal "adapter fee vault" "$actual" "$vault"
    actual=$(cast call "$adapter" 'MOAT()(address)' --rpc-url "$rpc")
    assert_address_equal "adapter Moat" "$actual" "$proxy"
    actual=$(first_word "$(cast call "$proxy" 'feeExemptCallers(address)(bool)' "$adapter" --rpc-url "$rpc")")
    assert_equal "adapter fee exemption" "$actual" "true"
    actual=$(cast call "$vault" 'messenger()(address)' --rpc-url "$rpc")
    assert_address_equal "fee-vault messenger" "$actual" "$adapter"
    actual=$(cast call "$vault" 'recipient()(address)' --rpc-url "$rpc")
    assert_address_equal "fee-vault recipient" "$actual" "$recipient"
    actual=$(cast call "$messenger_proxy" 'MOAT()(address)' --rpc-url "$rpc")
    assert_address_equal "messenger Moat" "$actual" "$proxy"

    require_command python3
    moat_min=$(first_word "$(cast call "$proxy" 'minWithdrawalAmount()(uint256)' --rpc-url "$rpc")")
    vault_min=$(first_word "$(cast call "$vault" 'minWithdrawAmount()(uint256)' --rpc-url "$rpc")")
    required_min=$(python3 -c 'import sys; print(int(sys.argv[1]) + 10_000_000_000)' "$moat_min")
    python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' \
        "$vault_min" "$required_min" ||
        die "fee-vault minWithdraw is $vault_min, below required $required_min"
    printf '  [ok] %-28s %s (required >= %s)\n' "fee-vault minWithdraw" "$vault_min" "$required_min"
}

oracle_owner_key() {
    local value=${ORACLE_OWNER_PRIVATE_KEY:-${OWNER_PRIVATE_KEY:-}}
    [[ -n "$value" ]] || die "set ORACLE_OWNER_PRIVATE_KEY (or OWNER_PRIVATE_KEY)"
    printf '%s' "$value"
}

whitelist_owner_key() {
    local value=${WHITELIST_OWNER_PRIVATE_KEY:-${OWNER_PRIVATE_KEY:-}}
    [[ -n "$value" ]] || die "set WHITELIST_OWNER_PRIVATE_KEY (or OWNER_PRIVATE_KEY)"
    printf '%s' "$value"
}

run_fee_preflight() {
    validate_config
    note "L1GasPriceOracle fixed 1/1 and static-parameter read-only preflight"
    BROADCAST=0 "$SHELL_DIR/submit-l1-gas-price-oracle-config.sh"
}

run_fee_migration() {
    validate_config
    verify_bridge
    require_command cast
    [[ "${BROADCAST:-0}" == "1" ]] || die "fee-migrate sends transactions; set BROADCAST=1"

    local oracle_key whitelist_key rpc oracle owner_addr oracle_signer
    oracle_key=$(oracle_owner_key)
    whitelist_key=$(whitelist_owner_key)
    rpc=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")
    oracle=$(extract_string L1_GAS_PRICE_ORACLE_ADDR "$CONFIG_CONTRACTS")
    owner_addr=$(cast call "$oracle" 'owner()(address)' --rpc-url "$rpc")
    oracle_signer=$(cast wallet address --private-key "$oracle_key")
    assert_address_equal "oracle owner signer" "$oracle_signer" "$owner_addr"

    note "Temporarily whitelist the oracle owner for the fixed 1/1 dynamic write"
    BROADCAST=1 OWNER_PRIVATE_KEY="$whitelist_key" \
        "$SHELL_DIR/submit-l2-whitelist-sender.sh" "$owner_addr"

    note "Apply fixed 1/1, then three static fee parameters, with independent readbacks"
    BROADCAST=1 OWNER_PRIVATE_KEY="$oracle_key" \
        "$SHELL_DIR/submit-l1-gas-price-oracle-config.sh"

    note "Final fee-oracle state"
    "$SHELL_DIR/query-l1-gas-price-oracle-config.sh" "$rpc" "$oracle"

    note "Fixed-pair and static-parameter migration completed"
    printf '%s\n' \
        'KEEP INGRESS AND ALL FEE WRITERS STOPPED.' \
        'The oracle owner remains temporarily whitelisted for rollback.' \
        'Next, send and verify the private maintenance canary. Then use:' \
        "  NEW_FEE_ORACLE_SIGNER=0x... BROADCAST=1 $0 enable-signer"
}

enable_signer() {
    validate_config
    require_command cast
    require_env NEW_FEE_ORACLE_SIGNER
    validate_address NEW_FEE_ORACLE_SIGNER "$NEW_FEE_ORACLE_SIGNER"
    [[ "${BROADCAST:-0}" == "1" ]] || die "enable-signer sends a transaction; set BROADCAST=1"

    local whitelist_key
    whitelist_key=$(whitelist_owner_key)
    note "Whitelist the new fee-oracle signer ($NEW_FEE_ORACLE_SIGNER)"
    BROADCAST=1 OWNER_PRIVATE_KEY="$whitelist_key" \
        "$SHELL_DIR/submit-l2-whitelist-sender.sh" "$NEW_FEE_ORACLE_SIGNER"

    note "Signer is allowed; do not restore public ingress yet"
    printf '%s\n' \
        'Start the new fee-oracle and verify at least two consecutive successful' \
        'on-chain updates plus the production-fee canary. Then run cleanup.'
}

cleanup_owner_access() {
    validate_config
    require_command cast
    require_env NEW_FEE_ORACLE_SIGNER
    validate_address NEW_FEE_ORACLE_SIGNER "$NEW_FEE_ORACLE_SIGNER"
    [[ "${BROADCAST:-0}" == "1" ]] || die "cleanup removes owner permission; set BROADCAST=1"
    local owner_addr rpc oracle whitelist signer_allowed whitelist_key
    rpc=$(extract_string EXTERNAL_RPC_URI_L2 "$CONFIG")
    oracle=$(extract_string L1_GAS_PRICE_ORACLE_ADDR "$CONFIG_CONTRACTS")
    whitelist=$(extract_string L2_WHITELIST_ADDR "$CONFIG_CONTRACTS")
    owner_addr=$(cast call "$oracle" 'owner()(address)' --rpc-url "$rpc")
    whitelist_key=$(whitelist_owner_key)

    signer_allowed=$(first_word "$(cast call "$whitelist" 'isSenderAllowed(address)(bool)' \
        "$NEW_FEE_ORACLE_SIGNER" --rpc-url "$rpc")")
    assert_equal "new signer allowed" "$signer_allowed" "true"

    note "Remove the oracle owner's temporary dynamic-write permission"
    BROADCAST=1 OWNER_PRIVATE_KEY="$whitelist_key" \
        "$SHELL_DIR/submit-l2-whitelist-sender.sh" remove "$owner_addr"

    assert_equal "owner allowed" \
        "$(first_word "$(cast call "$whitelist" 'isSenderAllowed(address)(bool)' "$owner_addr" --rpc-url "$rpc")")" \
        "false"
    assert_equal "new signer allowed" \
        "$(first_word "$(cast call "$whitelist" 'isSenderAllowed(address)(bool)' "$NEW_FEE_ORACLE_SIGNER" --rpc-url "$rpc")")" \
        "true"

    note "Signer handoff verified"
    printf '%s\n' \
        'The on-chain upgrade workflow is complete. Restore public ingress only' \
        'after your external monitoring and rollback checks are ready.'
}

show_usage() {
    cat <<EOF
Usage: $(basename "$0") COMMAND [arguments]

Commands:
  prepare DIR       Back up an existing volume and copy the network config.
  bridge-preflight  Validate config and simulate the three deployments only.
  bridge            Run bridge steps 1-6 and core on-chain readback.
  verify-bridge     Run the core bridge readback without sending transactions.
  fee-preflight     Read back current values plus fixed 1/1/static targets.
  fee-migrate       Apply fixed 1/1, then the three static parameters.
  enable-signer     Whitelist NEW_FEE_ORACLE_SIGNER after the maintenance canary.
  cleanup           Remove the owner's temporary whitelist permission.
  help              Show this help.

Bridge broadcast requirements:
  BROADCAST=1 OWNER_PRIVATE_KEY
  When DEPLOYER_ADDR equals OWNER_ADDR, the wrapper validates and reuses this
  key for deterministic deployments. Otherwise set DEPLOYER_PRIVATE_KEY too.

Fee migration requirements:
  BROADCAST=1
  ORACLE_OWNER_PRIVATE_KEY may be used when the oracle owner differs; it falls
  back to OWNER_PRIVATE_KEY. WHITELIST_OWNER_PRIVATE_KEY is used to temporarily
  allow the owner, enable the new signer, and clean up; it also falls back to
  OWNER_PRIVATE_KEY. On the current devnet both contracts have the same owner.

Cleanup broadcast requirements:
  BROADCAST=1 NEW_FEE_ORACLE_SIGNER=0x...

This wrapper never stops/starts infrastructure, submits canaries, verifies the
Dogecoin L1 withdrawal processor, or restores public ingress. Those are manual
maintenance gates in UPGRADE_MOAT.md.
EOF
}

cd "$REPO_ROOT"

case "${1:-help}" in
    prepare)
        shift
        prepare_config "${1:-}"
        ;;
    bridge-preflight)
        run_bridge_preflight
        ;;
    bridge)
        run_bridge
        ;;
    verify-bridge)
        verify_bridge
        ;;
    fee-preflight)
        run_fee_preflight
        ;;
    fee-migrate)
        run_fee_migration
        ;;
    enable-signer)
        enable_signer
        ;;
    cleanup)
        cleanup_owner_access
        ;;
    help|-h|--help)
        show_usage
        ;;
    *)
        show_usage >&2
        die "unknown command: $1"
        ;;
esac
