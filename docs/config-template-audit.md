# Shared config template audit

验证日期：2026-09-11。完整复跑已成功，证据目录为
`/tmp/contracts-config-audit-hiy673zr/evidence`，机器可读结论见其中的
`summary.json`；CLI 全量结果见 `cli-tests.log`。

本次审计针对 `docker/templates/config.toml`，同时覆盖本地合约脚本和
`scroll-sdk-cli` 对根配置的消费。基线是提交
`56a4cacda6046c9445af023aefee15a42fda2fdd` 中的完整模板；执行的是当前工作区
的脚本，包括已经取消旧 coordinator 生成步骤的 `gen-configs.sh`。

模板从 **94 个字段调整为 50 个字段**：删除 46 项，补入 2 项有效 ingress 配置。默认账户和数据库仍为占位输入，
必须按启用组件补齐；Reth 节点身份单独写入 doge-config。
测试只使用公开测试私钥和临时本地链，没有读取实际部署目录中的私钥。

DogeOS 的真实 L1 是 Dogecoin。部署流程里的 Ethereum/Scroll L1 合约用于模拟和
地址推导，并不部署到 Dogecoin。删除 `[rollup]` 的依据是这套 L1 架构以及参数没有
进入 L2 合约，与 L2 选择 Reth 或 Geth 无关。下文的 Reth 节点身份清理是另一项
独立改造。保留的旧 Ethereum/Scroll L1 初始化能力使用独立环境变量，不属于正常
DogeOS 部署流程。

## 可以删除的 46 项

| 节                       | 删除字段                                                                                                                                                        | 依据与限制                                                                                                                                         |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `general`                | `DA_PUBLISHER_ENDPOINT`, `BEACON_RPC_ENDPOINT`                                                                                                                  | 当前合约入口和 CLI 无消费；Ethereum DA 的运行配置在 doge-config 中。                                                                               |
| `general`                | `L1_RPC_ENDPOINT_WEBSOCKET`                                                                                                                                     | 当前 `setup domains` 固定输出空字符串，不读取模板值；命令以后可能重新写入空字段。                                                                  |
| `general`                | `VERIFIER_DIGEST_1`, `VERIFIER_DIGEST_2`                                                                                                                        | 确定性部署使用代码中的 `VERIFIER_DIGEST`；旧 standalone Foundry 脚本读取同名环境变量，不读取这两个 TOML 项。                                       |
| `db`                     | `ADMIN_SYSTEM_DB_CONNECTION_STRING`                                                                                                                             | CLI 无此名称的消费。旧 admin 映射实际使用 `ADMIN_SYSTEM_BACKEND_DB_CONNECTION_STRING`。                                                            |
| `gas-token`              | `GAS_ORACLE_INCORPORATE_TOKEN_EXCHANGE_RATE_ENANBLED`, `EXCHANGE_RATE_UPDATE_MODE`, `FIXED_EXCHANGE_RATE`, `TOKEN_SYMBOL_PAIR`, `ALTERNATIVE_GAS_TOKEN_ENABLED` | 当前合约不消费这些字段；删除整个节及 CLI 自动投影。旧 CLI 辅助命令的可选兼容读取在字段缺失时按 false 处理。                                        |
| `rollup`                 | `MAX_BLOCK_IN_CHUNK`, `MAX_BATCH_IN_BUNDLE`                                                                                                                     | 当前 `Configuration.sol` 已取消读取，CLI 自动投影同步删除。                                                                                        |
| `rollup`                 | `MAX_TX_IN_CHUNK`                                                                                                                                               | `ScrollChain.initialize` 只写入废弃且无读取的 `__maxNumTxInChunk` 存储槽。移除配置读取及 CLI 投影，部署脚本对兼容 ABI 参数传入 0，不改变存储布局。 |
| `rollup`                 | `TEST_ENV_MOCK_FINALIZE_TIMEOUT_SEC`                                                                                                                            | 当前合约脚本不读；删除 CLI 中无用途的 mock 开关／超时读取，以及 doge-config 和 spec 投影。                                                         |
| `rollup`                 | `MAX_L1_MESSAGE_GAS_LIMIT`, `FINALIZE_BATCH_DEADLINE_SEC`, `RELAY_MESSAGE_DEADLINE_SEC`                                                                         | 只用于 L1 `SystemConfig` 初始化，没有进入 L2。移除公共 loader 的读取；显式调用旧 L1 初始化时改为读取同名环境变量，与 standalone L1 脚本一致。      |
| `rollup`                 | `TEST_ENV_MOCK_FINALIZE_ENABLED`                                                                                                                                | 只选择 L1 ScrollChain 实现；移除分支，固定使用正式实现，等同旧模板默认 false。整个 `[rollup]` 节删除。                                             |
| `ingress`                | `ROLLUP_EXPLORER_API_HOST`, `COORDINATOR_API_HOST`, `ADMIN_SYSTEM_DASHBOARD_HOST`, `L1_EXPLORER_HOST`                                                           | 旧服务域名，删除 CLI 提示、投影、TLS 和旧 values 处理入口；保留外部 Dogecoin 浏览器链接。                                                          |
| `ingress`                | `BLOCKSCOUT_BACKEND_HOST`                                                                                                                                       | 无有效消费；当前 Blockscout UI 与 API 都使用 `BLOCKSCOUT_HOST`，分别路由 `/` 和 `/api`。                                                           |
| `frontend`               | `BASE_CHAIN`                                                                                                                                                    | 合约和 CLI 前端输出均从 `general.CHAIN_NAME_L1` 得到 base chain。                                                                                  |
| `genesis`                | `L2_MAX_ETH_SUPPLY`                                                                                                                                             | 保留规范字段 `L2_MAX_NATIVE_DOGE_SUPPLY`；合约支持旧别名，但不要求两份配置。                                                                       |
| `contracts.verification` | `VERIFIER_TYPE_L1`, `EXPLORER_URI_L1`, `RPC_URI_L1`, `EXPLORER_API_KEY_L1`                                                                                      | 当前验证入口只验证 L2。`setup domains` 可能重新投影 L1 URL，但不依赖模板中的旧值。                                                                 |
| `coordinator`            | `CHUNK_COLLECTION_TIME_SEC`, `BATCH_COLLECTION_TIME_SEC`, `BUNDLE_COLLECTION_TIME_SEC`                                                                          | 当前 Docker 入口不再执行旧 `GenerateCoordinatorConfig`。手动运行该 standalone 旧生成器仍需自行提供这些字段。                                       |

纯 Reth 清理另外删除原模板中的五项：

- `sequencer.L2GETH_KEYSTORE`、`sequencer.L2GETH_PASSWORD`、`sequencer.L2GETH_NODEKEY`。
- `bootnode.bootnode-0.L2GETH_NODEKEY`、`bootnode.bootnode-0.L2_GETH_STATIC_PEERS`。

整个 `[sequencer]` / `[bootnode.bootnode-0]` 区块均删除。配套 CLI 已取消旧节点
生成、secret 生成和 peer 回退，公网 P2P 命令也改为读取 Reth bootnode。
Reth signer / nodekey 保存在 `.data/doge-config.toml`，由专用 setup 命令管理。
`L2GETH_SIGNER_ADDRESS` 和 `L1_PLONK_VERIFIER_ADDR` 原本就不在这份基线模板中，
不计入这 46 项；当前合约生成不要求它们，CLI 也不再要求填写。

旧服务清理另外删除五项：

- `db.BRIDGE_HISTORY_DB_CONNECTION_STRING`、`db.CHAIN_MONITOR_DB_CONNECTION_STRING`、
  `db.L1_EXPLORER_DB_CONNECTION_STRING`：CLI 已取消这些数据库/用户的初始化、权限更新和 secret 映射。
- `frontend.BRIDGE_API_URI`、`ingress.BRIDGE_HISTORY_API_HOST`：同步取消 CLI 域名提示、
  旧服务 values 和前端配置投影；`Configuration.sol` 不再读取该前端字段，
  `GenerateConfigs.s.sol` 不再生成 `REACT_APP_BRIDGE_API_URI`。

Blockbook 不在基线模板字段中，不影响上述计数；配套 CLI 已移除其配置、提示、
secret/values 生成和网络回退。钱包 UTXO 同步使用 Electrs，桥初始化读取交易字节使用
Dogecoin RPC。完整操作说明见相邻 CLI 仓库的
[`docs/config-cleanup.md`](../../scroll-sdk-cli/docs/config-cleanup.md)。

数据库进一步收敛后，模板再删除 `GAS_ORACLE_DB_CONNECTION_STRING`、
`COORDINATOR_DB_CONNECTION_STRING`、`ROLLUP_NODE_DB_CONNECTION_STRING` 三项。
CLI 同步取消这些连接及 Scroll、Rollup Explorer、Admin System DSN 别名、secret
映射；旧数据库依赖 chart 不再自动生成。当前 `fee-oracle` 和 `proof-coordinator`
仍保留各自的原生服务配置。

## 特意保留的字段

- `general.L1_RPC_ENDPOINT`、`L2_RPC_ENDPOINT`：CLI 配置服务 RPC，不能因为
  合约 deploy 镜像使用环境变量就删除。
- `L1_CONTRACT_DEPLOYMENT_BLOCK`：CLI 仍有写回及兼容映射。
- 仅保留 `db.BLOCKSCOUT_DB_CONNECTION_STRING`：用于 Blockscout secret，`db-init` 也只初始化此数据库。
- `frontend.ETH_SYMBOL`、`CONNECT_WALLET_PROJECT_ID`：CLI 会将其写入前端输出。
- 有效 ingress 字段：保留 CLI 的域名和 chart 更新入口；新增 `TSO_HOST`、`PROOF_COORDINATOR_HOST`，对应端口 3000 和 7788。后者在 active proof 模式且显式配置 host 时由 native proof 流程启用 ingress；TLS 命令覆盖两者。
- `L1_FEE_VAULT_ADDR`：仍用于 genesis/bootstrap 初始化，并影响生成结果。
- `FEE_VAULT_DOGE_RECIPIENT_ADDR`：最终 fee vault Dogecoin P2PKH hash160；
  模板零值仅为占位，真实初始化必须设置为非零值。
- `L2_BRIDGE_FEE_RECIPIENT_ADDR`：零值表示使用 L2 fee vault 作为 Moat 的手续费接收者。
- `SCALAR`：虽然属于旧公式，配置读取和 `setScalar` 仍存在，不能只删除 TOML 项。
- 三个 genesis 参数和六个 predeploy overrides：仍由脚本读取或决定预部署结果。
- L2 verification 配置：当前验证命令的配置入口；API key 可为空。

`setup generate-from-spec` 已同步改为生成原生 Reth values，不再投影根配置的旧
Geth 节点字段。其他服务投影仍可能生成模板未预置的可选字段；删除模板占位项不
表示删除运行时服务自身的配置需求。

## 实际验证

| 检查                                                              | 结果                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 原模板和新模板执行当前 `docker/scripts/gen-configs.sh`            | 均成功                                                                                                                                                                                                                                                                                                                           |
| `config-contracts.toml`                                           | 逐字一致                                                                                                                                                                                                                                                                                                                         |
| `frontend-config.yaml`                                            | 逐字一致                                                                                                                                                                                                                                                                                                                         |
| genesis                                                           | 完整 JSON 比较一致，仅排除生成器使用当前时间生成的 `timestamp`                                                                                                                                                                                                                                                                   |
| 与改造前保存的产物及链上快照比较                                  | 合约地址、前端输出、genesis（排除 timestamp）、31 个运行时代码及 16 项状态一致                                                                                                                                                                                                                                                   |
| 两份 genesis 分别启动临时 Anvil，执行 `docker/scripts/deploy.sh`  | 均完成实际 L2 交易广播与初始化                                                                                                                                                                                                                                                                                                   |
| 部署后代码                                                        | 31 个 L2 合约／预部署地址的运行时代码一致                                                                                                                                                                                                                                                                                        |
| 部署后状态                                                        | 16 项读取一致：owner、fee vault recipient/messenger、Moat 费用与最小提现、oracle whitelist 与四个 fee 参数                                                                                                                                                                                                                       |
| CLI `setup gen-keystore`、`l2-sequencer-reth`、`l2-bootnode-reth` | 两份模板均完成账户与 Reth 节点身份配置；仅使用固定公开测试密钥                                                                                                                                                                                                                                                                   |
| CLI `setup gen-secrets -N --json`                                 | 两份模板均成功，11 个 secret 文件逐字一致；断言只有 Reth 节点 secret、没有旧 Geth 节点 secret                                                                                                                                                                                                                                    |
| CLI `setup prep-charts -N --json --skip-auth-check`               | 两份模板均成功，Reth 节点、contracts、Blockscout 和前端 values 保持一致；RPC trustedPeers 只有 Reth sequencer                                                                                                                                                                                                                    |
| CLI `setup domains -N --json --no-bootstrap-tls`                  | 两份模板均成功；六个命令运行后的 11 个 values 文件逐字一致，包含 TSO 和 Proof Coordinator 的 host/TLS 更新                                                                                                                                                                                                                       |
| CLI `setup gen-l2-artifacts --contracts-source`                   | 此前删除整个 `[rollup]` 后，用当时源码及 53 字段模板通过真实命令生成，约 48.2 秒（含编译）；地址和 genesis 与本次部署审计一致，源码 `volume/config.toml` 未改变；证据 `/tmp/rollup-cli-local-rpbvsfzk/summary.json`。此前两次运行验证缓存复用约 41.6 秒／2.6 秒，证据 `/tmp/scrollsdk-local-contracts-e2e-hf9dflud/summary.json` |
| CLI `setup gen-rpc-package`                                       | 完整命令回归通过；使用原生 Reth genesis，无旧 Geth values；kubectl 使用本地夹具                                                                                                                                                                                                                                                  |
| Reth values Helm 渲染                                             | sequencer、bootnode、内部 RPC、公网 RPC 四种 values 均通过本地 `l2-reth` chart 渲染                                                                                                                                                                                                                                              |
| 合约验证脚本测试                                                  | 10 项通过；其中检查模板足以构造 21 个 L2 验证调用                                                                                                                                                                                                                                                                                |
| Foundry genesis／fee-oracle 配置测试                              | 7 项通过                                                                                                                                                                                                                                                                                                                         |
| CLI `setup db-init`                                               | 隔离 PostgreSQL 客户端回归覆盖初始化、clean、权限更新和端口更新；即使输入旧数据库 DSN/开关，也只操作 Blockscout；未连接真实数据库                                                                                                                                                                                                |
| CLI `setup doge-config`                                           | 新建和旧配置迁移均通过真实命令入口回归，RPC 使用本地响应夹具，无 Blockbook 提示及字段                                                                                                                                                                                                                                            |
| CLI 全部测试                                                      | 560 项通过、13 项原有 pending；见 `cli-tests.log`，包含纯 Reth 清理回归                                                                                                                                                                                                                                                          |

额外使用修改前的脚本做参数变化实验：把三个数值分别设为 `123456`、`123`、
`456`，并把 mock 开关设为 `true`，重新生成并实际部署 L2。相比修改前的默认值，
只有 `L1_SCROLL_CHAIN_IMPLEMENTATION_ADDR` 改变；全部 L2 地址、genesis
（排除 timestamp）、31 个运行时代码和 16 项状态不变。证据：
`/tmp/rollup-old-input-probe-wcm1hlu6/evidence/summary.json`。
因此这四项没有进入 L2，也没有通过 L1 实现选择间接改变 L2 部署结果。

补充 ingress 验证覆盖共享域名／独立域名下显式 TSO 和 Proof Coordinator host
保留、实际 TLS 命令（只读 kubectl 夹具）、Blockscout 单域名路由，以及 active proof
配置从关闭的 ingress 生成 host/TLS/7788 路由、worker URL 不一致时在编译前拒绝。
Proof Coordinator 配置回归使用编译器 bundle 夹具，不代表在真实集群运行 prover。
两者均使用相邻 SDK 仓库的实际 Helm chart 渲染成功：TSO 指向 Service
`tso-service:3000`，Proof Coordinator 指向 `proof-coordinator:7788`，host 和
TLS hosts 一致。common chart 的 ingress 后端端口必须是数字；配套配置关闭默认
继承的空 HTTP 端口并指定 prover 为主端口。渲染文件及检查摘要保存在本次证据目录
`ingress-render/`。

CLI 构建及本次修改文件 lint 通过。全仓库 lint 仍有 10 个原有错误，位于未修改的
`src/utils/kms-signer-provisioner.ts` 和 `test/utils/kms-signer-provisioner.test.ts`。

为了验证比较能够发现问题，另外执行了删除字段的负向测试：

- 删除 `L2_GAS_ORACLE_SENDER_ADDR`、`L2_NATIVE_DOGE_TOKEN`、`SCALAR` 或
  `GRAFANA_URI`，生成流程均失败，错误指向对应缺失字段。
- 删除 `general.L2_RPC_ENDPOINT`，CLI 仍可能返回成功，但
  `contracts-production.yaml` 的 RPC 未正确更新，输出比较检测到差异。
- 删除 `db.BLOCKSCOUT_DB_CONNECTION_STRING`，CLI 仍可能返回成功，但
  `blockscout-secret.env` 缺失，输出比较检测到差异。

这是本地的配置到产物、交易部署及状态验证。Anvil 不等同于完整 Dogecoin/Reth
网络；本次没有重跑 Bridge 创建、真实提款、KMS/IAM、数据库创建或 Kubernetes
安装。CLI 的这些外围能力由现有测试及配置消费核对覆盖，没有声称全部做过真实
外部系统端到端验证。Explorer 验证提交使用 mock，不向外部浏览器提交请求。
Docker 的实际 shell 入口在本地执行；没有构建、推送新的镜像。

## 复现

确保两个仓库依赖已安装，CLI 已构建，并有 Python 3.11+、Node.js、Foundry
(`forge` / `anvil` / `cast`) 和 `jq`：

```bash
python docker/scripts/test-config-template.py \
  --cli-repo ../scroll-sdk-cli
```

需要同时核对脚本修改前后的结果时，追加
`--previous-evidence /tmp/contracts-config-audit-7u_vsl7c/evidence`，指向修改前
成功审计保存的证据目录。此次完整验证包含该比较。

脚本复制当前合约工作区到临时目录，使用固定的旧模板作为基线。每条本地 Anvil
链使用随机 loopback 端口并在结束时关闭。日志、测试输入、输出和 `summary.json`
保存在输出的 `Evidence:` 目录中，可用 `--output` 指定一个尚不存在的新目录。

模板依赖的合约读取逻辑需要随模板一起发布并构建到新镜像；不能只替换模板后
继续使用尚未包含这些修改的旧镜像。
