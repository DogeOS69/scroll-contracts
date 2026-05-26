#!/bin/bash
export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "missing required file: $1"
        exit 1
    fi
}

gen_config_contracts_toml() {
    forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --sig "run(string,string)" "none" "write-config" || exit 1
}

# format_config_file will add "scrollConfig: |" to the first line and indent the rest
format_config_file() {
    local file="$1"
    local config_scroll_key="scrollConfig: |"
    temp_file=$(mktemp)

    {
        echo $config_scroll_key
        while IFS= read -r line; do
            echo "  $line"
        done < <(grep "" "$file")
    } > "$temp_file"

    mv "$temp_file" "$file"
}

require_file "./volume/config.toml"

echo ""
echo "generating config-contracts.toml"
gen_config_contracts_toml

echo ""
echo "generating genesis.yaml"
forge script scripts/deterministic/GenerateGenesis.s.sol:GenerateGenesis --sig "run()" || exit 1
format_config_file "./volume/genesis.yaml"

echo ""
echo "generating coordinator-cron-config.yaml and coordinator-api-config.yaml"
forge script scripts/deterministic/GenerateConfigs.s.sol:GenerateCoordinatorConfig --sig "run()" || exit 1
format_config_file "./volume/coordinator-cron-config.yaml"
format_config_file "./volume/coordinator-api-config.yaml"

echo ""
echo "generating frontend-config.yaml"
forge script scripts/deterministic/GenerateConfigs.s.sol:GenerateFrontendConfig --sig "run()" || exit 1
format_config_file "./volume/frontend-config.yaml"
