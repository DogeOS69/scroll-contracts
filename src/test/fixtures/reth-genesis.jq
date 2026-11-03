# Validate JSON types consumed by alloy-genesis, DogeOS ScrollChainConfig and
# rollup-node's NodeConfig::from_chainspec, and pin the fork schedule. Header
# quantities are hex strings; chain IDs and L1 counts are numbers. YAML wrapping
# happens after generation.
def uint: type == "number" and . >= 0 and floor == .;
def hex_string: type == "string" and test("^0x[0-9a-fA-F]+$");
def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");

(.config.chainId | uint) and
# dogeos-reth and dogeos-core reject tsukiTime without tsukiV2Time >= tsukiTime.
# The template activates every fork at genesis; adding a fork key needs an edit here.
(.config | keys == ["archimedesBlock", "berlinBlock", "bernoulliBlock", "byzantiumBlock", "chainId",
    "constantinopleBlock", "curieBlock", "darwinTime", "darwinV2Time", "eip150Block", "eip150Hash",
    "eip155Block", "eip158Block", "euclidTime", "euclidV2Time", "feynmanTime", "galileoTime",
    "galileoV2Time", "homesteadBlock", "istanbulBlock", "londonBlock", "petersburgBlock", "scroll",
    "shanghaiBlock", "tsukiTime", "tsukiV2Time"]) and
all(.config | to_entries[] | select(.key | test("(Block|Time)$")); .value | uint and . == 0) and
(.config.scroll | keys == ["feeVaultAddress", "l1Config", "maxTxPayloadBytesPerBlock"]) and
(.config.scroll.feeVaultAddress | address) and
(.config.scroll.maxTxPayloadBytesPerBlock | uint) and
(.config.scroll.l1Config |
    (keys == ["l1ChainId", "l1MessageQueueAddress", "l1MessageQueueV2Address", "l2SystemConfigAddress",
              "numL1MessagesPerBlock", "scrollChainAddress", "startL1Block", "systemContractAddress"]) and
    (.l1ChainId | uint) and
    (.numL1MessagesPerBlock | uint) and
    (.startL1Block | uint) and
    ([.l1MessageQueueAddress, .l1MessageQueueV2Address, .scrollChainAddress,
      .systemContractAddress, .l2SystemConfigAddress] | all(.[]; address))) and
([.nonce, .timestamp, .gasLimit, .difficulty, .baseFeePerGas] | all(.[]; hex_string)) and
(.extraData == "0x") and
(.alloc | type == "object") and
(.alloc | to_entries | all(.[];
    (.key | address) and
    (.value | (keys - ["balance", "code", "nonce", "storage"] == []) and
        (.balance | hex_string) and (.nonce | hex_string) and
        (.code | type == "string") and
        (.storage | type == "object" and all(.[]; hex_string and (test("^0[xX]0+$") | not))))))
