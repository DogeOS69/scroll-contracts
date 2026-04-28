# preinstalls

Post-launch deploy of race-critical EVM ecosystem preinstalls (Multicall3,
CreateX) to their canonical addresses on a freshly launched L2 chain by
replaying publicly published presigned legacy unprotected transactions.

Both contracts' deployer EOAs hold real privkeys; if either ever leaks, an
attacker can land malicious bytecode at the canonical address before the
chain operator does. Running these deploys in the bootstrap window — before
the public RPC accepts external txs — closes that race forever by burning
nonce 0 on each deployer EOA. Multicall3's deployer key is publicly rumored
compromised; CreateX's is not, but the operational mitigation is identical.

## Usage

Setup (matches the rest of the scroll-contracts shell scripts):

```bash
cp .env.example .env       # then fill in L2_RPC_ENDPOINT and L2_DEPLOYER_PRIVATE_KEY
source .env
bash scripts/preinstalls/shell/deploy.sh
bash scripts/preinstalls/shell/verify.sh
```

Reuses the same env vars as `scripts/deterministic/shell/deploy.sh`. No new
env vars needed.

## Operational requirement

The L2 RPC must accept legacy unprotected (pre-EIP-155) transactions. On
scroll-geth that means starting the node with `--rpc.allow-unprotected-txs`
for the deploy window. The standard scroll-contracts deploys use `--legacy`
(EIP-155-protected) so they don't require the flag — these presigned txs do.

## Why bash + cast, not forge

These are presigned legacy unprotected txs from third parties (`mds1/multicall3`
and `pcaversaccio/createx`). The forge-equivalent cheatcode would be
`vm.broadcastRawTransaction`, but the version of `forge-std` pinned in this
repo (commit `978ac6fadb`, June 2024) predates that cheatcode and does not
expose it — Solidity calls fail to compile with `Member "broadcastRawTransaction" not found`. Bumping `forge-std` to bring it in
would expand the cheatcode surface for every existing script in the repo,
which is a much larger change than what this PR aims to do.

`cast publish` is the standard tool for "publish this exact pre-signed tx
as-is" and ships with `cast` (already required for Foundry).

## Layout

```
scripts/preinstalls/
├── README.md            (this file)
├── data/
│   ├── multicall3.bin   3,926 bytes — raw bytes of mds1's published presigned tx
│   └── createx.bin     12,140 bytes — raw bytes of pcaversaccio's published presigned tx
├── shell/
│   ├── deploy.sh        idempotent deploy + post-verify
│   └── verify.sh        codehash check against any RPC
└── test/
    └── genesis.test.json   minimal genesis (only Arachnid Proxy alloc'd) for local anvil testing
```

## Verification

### Bytecode authenticity

The `.bin` files are the raw bytes of the presigned legacy unprotected
deploy transactions, identical to what is published in the upstream repos:

- **Multicall3** — published in [mds1/multicall3 README](https://github.com/mds1/multicall3#new-deployments), under "Below is the signed transaction".
- **CreateX** — published in [pcaversaccio/createx](https://github.com/pcaversaccio/createx/blob/main/scripts/presigned-createx-deployment-transactions/signed_serialised_transaction_gaslimit_3000000_.json), 3M gas variant.

To verify the `.bin` matches upstream:

```bash
# Multicall3
diff <(xxd -p -c 0 scripts/preinstalls/data/multicall3.bin | sed 's/^/0x/') \
     <(curl -sL https://raw.githubusercontent.com/mds1/multicall3/main/README.md \
         | grep -oE "0xf90f53[a-fA-F0-9]+" | head -1)

# CreateX
diff <(xxd -p -c 0 scripts/preinstalls/data/createx.bin | sed 's/^/0x/') \
     <(curl -sL https://raw.githubusercontent.com/pcaversaccio/createx/main/scripts/presigned-createx-deployment-transactions/signed_serialised_transaction_gaslimit_3000000_.json \
         | tr -d '"\n\r ')
```

### Codehash anchored to mainnet

The codehashes baked into `deploy.sh` and `verify.sh` are computed from
the runtime bytecode of these contracts on Ethereum mainnet. To re-anchor:

```bash
L2_RPC_ENDPOINT=https://ethereum-rpc.publicnode.com bash scripts/preinstalls/shell/verify.sh
```

Both should report `[ok]`. Multicall3 and CreateX have no chainId-dependent
immutables, so the same codehash applies on every EVM-equivalent chain.

## Local end-to-end test

`test/genesis.test.json` is a minimal anvil genesis that pre-installs only the
Arachnid Proxy at `0x4e59...956C`, mirroring the relevant slice of an
EVM-equivalent chain. Anvil isn't wired to a Makefile target — just run:

```bash
anvil --init scripts/preinstalls/test/genesis.test.json --port 8545 &
L2_RPC_ENDPOINT=http://127.0.0.1:8545 \
L2_DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    bash scripts/preinstalls/shell/deploy.sh
L2_RPC_ENDPOINT=http://127.0.0.1:8545 bash scripts/preinstalls/shell/verify.sh
kill %1
```

Re-running `deploy.sh` after a successful deploy is a no-op (idempotent).

## Alternative considered: genesis preinstall

A separate PR adds Multicall3 and CreateX as genesis preinstalls in
`scripts/deterministic/GenerateGenesis.s.sol::generateGenesisAlloc`,
mirroring how the Arachnid Proxy is already preinstalled. That approach is
operationally cleaner (no funding, no EIP-155 window, no race) but expands
the genesis allocation, which is part of the chain's audit scope. The
present PR is the alternative that keeps audit scope narrow.
