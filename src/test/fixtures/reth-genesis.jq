# Validate JSON types consumed by alloy-genesis, DogeOS ScrollChainConfig and
# rollup-node's NodeConfig::from_chainspec. Header quantities are hex strings;
# chain IDs and L1 counts are numbers. YAML wrapping happens after generation.
def uint: type == "number" and . >= 0 and floor == .;
def hex_string: type == "string" and test("^0x[0-9a-fA-F]+$");
def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");

(.config.chainId | uint) and
(.config.scroll | keys == ["feeVaultAddress", "l1Config", "l1DataFeeBufferCheck", "maxTxPayloadBytesPerBlock"]) and
(.config.scroll.feeVaultAddress | address) and
(.config.scroll.maxTxPayloadBytesPerBlock | uint) and
(.config.scroll.l1DataFeeBufferCheck | type == "boolean") and
(.config.scroll.l1Config |
    (keys == ["l1ChainId", "l1MessageQueueAddress", "l1MessageQueueV2Address", "l2SystemConfigAddress",
              "numL1MessagesPerBlock", "scrollChainAddress", "startL1Block", "systemContractAddress"]) and
    (.l1ChainId | uint) and
    (.numL1MessagesPerBlock | uint) and
    (.startL1Block | uint) and
    ([.l1MessageQueueAddress, .l1MessageQueueV2Address, .scrollChainAddress,
      .systemContractAddress, .l2SystemConfigAddress] | all(.[]; address))) and
(.config | has("clique") == false and has("systemContract") == false) and
([.nonce, .timestamp, .gasLimit, .difficulty, .baseFeePerGas] | all(.[]; hex_string)) and
(.extraData == "0x") and
(.alloc | type == "object") and
(.alloc | to_entries | all(.[];
    (.key | address) and
    (.value | (keys - ["balance", "code", "nonce", "storage"] == []) and
        (.balance | hex_string) and (.nonce | hex_string) and
        (.code | type == "string") and (.storage | type == "object"))))
