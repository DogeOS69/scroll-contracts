#!/bin/bash

export FOUNDRY_EVM_VERSION="cancun"
export FOUNDRY_BYTECODE_HASH="none"

# extract values from config file
config_file="./volume/config.toml"

# Check if config file exists
if [[ ! -f "$config_file" ]]; then
  echo "Error: Config file not found: $config_file" >&2
  exit 1
fi

# Helper function to remove quotes (single, double, or none)
remove_quotes() {
  local value="$1"
  # Remove leading and trailing whitespace first
  value=$(echo "$value" | sed 's/^[ \t]*//; s/[ \t]*$//')
  
  # Remove matching quotes (single or double) - only if they match at both ends
  if [[ "$value" =~ ^\".*\"$ ]]; then
    # Remove double quotes
    value="${value#\"}"
    value="${value%\"}"
  elif [[ "$value" =~ ^\'.*\'$ ]]; then
    # Remove single quotes
    value="${value#\'}"
    value="${value%\'}"
  fi
  
  echo "$value"
}

# Helper function to extract config values safely
extract_config_value() {
  local key="$1"
  local file="$2"
  # Match: optional whitespace (spaces and tabs), key name, optional whitespace, =, optional whitespace, value
  # Exclude commented lines (starting with #)
  local raw_value
  raw_value=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | \
    grep -v "^[[:space:]]*#" | \
    sed 's/^[[:space:]]*[^=]*[[:space:]]*=[[:space:]]*//' | \
    sed 's/[[:space:]]*$//' | \
    head -n1)
  
  # Remove quotes using the helper function
  remove_quotes "$raw_value"
}

#CHAIN_ID_L1=$(extract_config_value "CHAIN_ID_L1" "$config_file" | tr -d '_')
CHAIN_ID_L2=$(extract_config_value "CHAIN_ID_L2" "$config_file" | tr -d '_')
#RPC_URI_L1=$(extract_config_value "RPC_URI_L1" "$config_file")
RPC_URI_L2=$(extract_config_value "RPC_URI_L2" "$config_file")
VERIFIER_TYPE_L1=$(extract_config_value "VERIFIER_TYPE_L1" "$config_file")
VERIFIER_TYPE_L2=$(extract_config_value "VERIFIER_TYPE_L2" "$config_file")
EXPLORER_URI_L1=$(extract_config_value "EXPLORER_URI_L1" "$config_file")
EXPLORER_URI_L2=$(extract_config_value "EXPLORER_URI_L2" "$config_file")
EXPLORER_API_KEY_L1=$(extract_config_value "EXPLORER_API_KEY_L1" "$config_file")
EXPLORER_API_KEY_L2=$(extract_config_value "EXPLORER_API_KEY_L2" "$config_file")
ALTERNATIVE_GAS_TOKEN_ENABLED=$(extract_config_value "ALTERNATIVE_GAS_TOKEN_ENABLED" "$config_file")
TEST_ENV_MOCK_FINALIZE_ENABLED=$(extract_config_value "TEST_ENV_MOCK_FINALIZE_ENABLED" "$config_file")

# extract contract name and address
extract_contract_info() {
  # Validate input line format (key=value)
  # Allow spaces and tabs around the equals sign
  if [[ ! "$line" =~ ^[[:space:]]*[^=]+[[:space:]]*=[[:space:]]*[^[:space:]]+.*$ ]]; then
    echo "Invalid line format: $line" >&2
    contract_name=""
    contract_addr=""
    return 1
  fi
  
  # Extract key and value safely
  local key_part="${line%%=*}"
  local value_part="${line#*=}"
  
  # Clean up key and value using the helper function
  contract_name=$(remove_quotes "$key_part")
  contract_addr=$(remove_quotes "$value_part")
  
  # Validate contract address format (basic hex check)
  if [[ -n "$contract_addr" && ! "$contract_addr" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    echo "Warning: Invalid contract address format: $contract_addr" >&2
  fi
}

get_source_code_name() {
  # specially handle the case where alternative gas token is enabled
  if [[ "$ALTERNATIVE_GAS_TOKEN_ENABLED" == "true" && "$1" =~ ^(L1_SCROLL_MESSENGER_IMPLEMENTATION_ADDR|L2_TX_FEE_VAULT_ADDR)$ ]]; then
    case "$1" in
      L1_SCROLL_MESSENGER_IMPLEMENTATION_ADDR) echo L1ScrollMessengerNonETH ;;
      L2_TX_FEE_VAULT_ADDR) echo L2TxFeeVaultWithGasToken ;;
      *) 
    esac
  # specially handle the case where mock finalize is enabled
  elif [[ "$TEST_ENV_MOCK_FINALIZE_ENABLED" == "true" && "$1" =~ ^(L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR)$ ]]; then
    case "$1" in
      L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR) echo ScrollChainMockFinalize ;;
      *) 
    esac
  else
    case "$1" in
      # L1_SCROLL_CHAIN_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_SCROLL_MESSENGER_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_MULTIPLE_VERSION_ROLLUP_VERIFIER_ADDR ) echo MultipleVersionRollupVerifierSetOwner ;;
      L1_GAS_PRICE_ORACLE_ADDR) echo L1GasPriceOracle ;;
      # L1_MESSAGE_QUEUE_V2_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_MESSAGE_QUEUE_V2_IMPLEMENTATION_ADDR) echo L1MessageQueueV2 ;;
      # L1_SYSTEM_CONFIG_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_SYSTEM_CONFIG_IMPLEMENTATION_ADDR) echo SystemConfig ;;

      # Smart Contracts Verified on L2 Successfully
      L2_MESSAGE_QUEUE_ADDR) echo L2MessageQueue ;;
      L2_WHITELIST_ADDR) echo Whitelist ;;
      # L2_WETH_ADDR) echo WrappedEther ;;
      L2_WDOGE_ADDR) echo WrappedDoge ;;
      L2_TX_FEE_VAULT_ADDR) echo L2TxFeeVault ;;
      L2_PROXY_ADMIN_ADDR) echo ProxyAdminSetOwner ;;
      L2_DOGEOS_MESSENGER_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      L2_ETH_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      L2_WETH_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;


      # L1_WETH_ADDR) echo WrappedEther ;;
      # L1_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR) echo EmptyContract ;;
      # L1_PROXY_ADMIN_ADDR) echo ProxyAdminSetOwner ;;
      # L1_WHITELIST_ADDR) echo Whitelist ;;
      # L1_ENFORCED_TX_GATEWAY_IMPLEMENTATION_ADDR) echo EnforcedTxGateway ;;
      # L1_ENFORCED_TX_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_ZKEVM_VERIFIER_V2_ADDR) echo ZkEvmVerifierV2 ;;
      # L1_MESSAGE_QUEUE_V1_IMPLEMENTATION_ADDR) echo L1MessageQueueV1WithGasPriceOracle ;;
      # L1_MESSAGE_QUEUE_V1_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR) echo ScrollChain ;;
      # L1_GATEWAY_ROUTER_IMPLEMENTATION_ADDR) echo L1GatewayRouter ;;
      # L1_GATEWAY_ROUTER_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_ETH_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_WETH_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_STANDARD_ERC20_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_CUSTOM_ERC20_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_ERC721_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_ERC1155_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_GAS_TOKEN_GATEWAY_IMPLEMENTATION_ADDR) echo L1GasTokenGateway ;;
      # L1_GAS_TOKEN_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L1_WRAPPED_TOKEN_GATEWAY_ADDR) echo L1WrappedTokenGateway ;;
      L2_PROXY_IMPLEMENTATION_PLACEHOLDER_ADDR) echo EmptyContract ;;
      # L2_STANDARD_ERC20_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L2_CUSTOM_ERC20_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L2_ERC721_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L2_ERC1155_GATEWAY_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L2_SCROLL_STANDARD_ERC20_ADDR) echo ScrollStandardERC20 ;;
      # L2_SCROLL_STANDARD_ERC20_FACTORY_ADDR) echo ScrollStandardERC20FactorySetOwner ;;
      # L1_SCROLL_MESSENGER_IMPLEMENTATION_ADDR) echo L1ScrollMessenger ;;
      # L1_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR) echo L1StandardERC20Gateway ;;
      # L1_ETH_GATEWAY_IMPLEMENTATION_ADDR) echo L1ETHGateway ;;
      # L1_WETH_GATEWAY_IMPLEMENTATION_ADDR) echo L1WETHGateway ;;
      # L1_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR) echo L1CustomERC20Gateway ;;
      # L1_ERC721_GATEWAY_IMPLEMENTATION_ADDR) echo L1ERC721Gateway ;;
      # L1_ERC1155_GATEWAY_IMPLEMENTATION_ADDR ) echo L1ERC1155Gateway ;;
      L2_DOGEOS_MESSENGER_IMPLEMENTATION_ADDR) echo L2DogeOsMessenger ;;
      L2_GATEWAY_ROUTER_IMPLEMENTATION_ADDR) echo L2GatewayRouter ;;
      L2_GATEWAY_ROUTER_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      # L2_STANDARD_ERC20_GATEWAY_IMPLEMENTATION_ADDR) echo L2StandardERC20Gateway ;;
      L2_ETH_GATEWAY_IMPLEMENTATION_ADDR) echo L2ETHGateway ;;
      L2_WETH_GATEWAY_IMPLEMENTATION_ADDR) echo L2WETHGateway ;;
      # L2_CUSTOM_ERC20_GATEWAY_IMPLEMENTATION_ADDR) echo L2CustomERC20Gateway ;;
      # L2_ERC721_GATEWAY_IMPLEMENTATION_ADDR) echo L2ERC721Gateway ;;
      # L2_ERC1155_GATEWAY_IMPLEMENTATION_ADDR) echo L2ERC1155Gateway ;;
      L2_MOAT_IMPLEMENTATION_ADDR) echo Moat ;;
      L2_MOAT_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      L2_BASCULE_MOCK_VERIFIER_ADDR) echo BasculeMockVerifier ;;
      L2_SYSTEM_CONFIG_PROXY_ADDR) echo TransparentUpgradeableProxy ;;
      L2_SYSTEM_CONFIG_IMPLEMENTATION_ADDR) echo L2SystemConfig ;;
      
      *) echo "" ;; # default: return void string
    esac
  fi
}

function is_predeploy_contract() {
  local contract_name="$1"

  if [[ "$contract_name" == "L2MessageQueue" || "$contract_name" == "L1GasPriceOracle" || "$contract_name" == "Whitelist" || "$contract_name" == "WrappedEther" || "$contract_name" == "L2TxFeeVault" ]]; then
    return 0  # True
  else
    return 1  # False
  fi
}

# read the file line by line
contracts_file="./volume/config-contracts.toml"

# Check if contracts file exists
if [[ ! -f "$contracts_file" ]]; then
  echo "Error: Contracts file not found: $contracts_file" >&2
  exit 1
fi

while IFS= read -r line; do
  # Skip empty lines and comments (lines starting with # possibly preceded by spaces/tabs)
  if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
    continue
  fi
  
  extract_contract_info "$line"
  
  # Skip if extraction failed
  if [[ -z "$contract_name" ]]; then
    continue
  fi

  # get contracts deployment layer
  if [[ "$contract_name" =~ ^L1(_|$) ]]; then
    layer="L1"
    # specially handle contract_name L1_GAS_PRICE_ORACLE_ADDR
    if [[ "$contract_name" == "L1_GAS_PRICE_ORACLE_ADDR" ]]; then
      layer="L2"
    fi
  elif [[ "$contract_name" =~ ^L2(_|$) ]]; then
    layer="L2"
  else
    echo "Error: Invalid contract name format (must start with L1_ or L2_): $contract_name" >&2
    continue
  fi

  source_code_name=$(get_source_code_name $contract_name)

  # skip if source_code_name or contract_addr is empty
  if [[ -z "$source_code_name" || -z "$contract_addr" ]]; then
    echo "Warning: Skipping contract ${contract_name} due to empty source_code_name '$source_code_name' or contract_addr '$contract_addr'" >&2
    continue
  fi

  # verify contract
  echo ""
  echo "verifing contract $contract_name with address $contract_addr on $layer"
  EXTRA_PARAMS=""
  if [[ "$layer" == "L1" ]]; then
    echo "skip L1 verification"
    if [[ "$VERIFIER_TYPE_L1" == "etherscan" ]]; then
      EXTRA_PARAMS="--api-key $EXPLORER_API_KEY_L1"
    elif [[ "$VERIFIER_TYPE_L1" == "blockscout" ]]; then
      EXTRA_PARAMS="--verifier-url ${EXPLORER_URI_L1}/api/ --verifier $VERIFIER_TYPE_L1"
    elif [[ "$VERIFIER_TYPE_L1" == "sourcify" ]]; then
      EXTRA_PARAMS="--api-key $EXPLORER_API_KEY_L1 --verifier-url $EXPLORER_URI_L1 --verifier $VERIFIER_TYPE_L1"
    fi
#    forge verify-contract $contract_addr $source_code_name --rpc-url $RPC_URI_L1 --chain-id $CHAIN_ID_L1 --watch --guess-constructor-args --skip-is-verified-check $EXTRA_PARAMS
  elif [[ "$layer" == "L2" ]]; then
    if [[ "$VERIFIER_TYPE_L2" == "etherscan" ]]; then
      EXTRA_PARAMS="--api-key $EXPLORER_API_KEY_L2"
    elif [[ "$VERIFIER_TYPE_L2" == "blockscout" ]]; then
      EXTRA_PARAMS="--verifier-url ${EXPLORER_URI_L2}/api/ --verifier $VERIFIER_TYPE_L2"
    elif [[ "$VERIFIER_TYPE_L2" == "sourcify" ]]; then
      EXTRA_PARAMS="--api-key $EXPLORER_API_KEY_L2 --verifier-url $EXPLORER_URI_L2 --verifier $VERIFIER_TYPE_L2"
    fi
    
    # Add constructor args parameter for non-predeploy contracts
    if ! is_predeploy_contract "$source_code_name"; then
        EXTRA_PARAMS="$EXTRA_PARAMS --guess-constructor-args"
    fi
    
    cmd="forge verify-contract $contract_addr $source_code_name --rpc-url $RPC_URI_L2 --chain-id $CHAIN_ID_L2 --watch --skip-is-verified-check $EXTRA_PARAMS"
    echo "========================="
    echo "$cmd"
    echo "-------------------------"
    $cmd
    echo "========================="
  fi
done < "$contracts_file"