# DogeOS Predeploy Deployment Notes

## Open Protocol Dependencies

- **RIPEMD-160 precompile prover support:** `DogeSig` depends on the RIPEMD-160
  precompile at `0x03` for HASH160. The contract performs a raw `staticcall`
  and reverts with `ErrorRipemd160PrecompileFailed` if the precompile is absent
  or returns malformed data, so unsupported networks fail loudly instead of
  returning an incorrect key hash. Prover support is pending confirmation from
  the zkvm-prover team.
- **Live-network predeploy deployment:** Existing networks cannot be re-genesis
  deployed. The deployment plan is to inject the pinned runtime bytecode at the
  fork block for the canonical DogeOS predeploy addresses, including
  `0x5300000000000000000000000000000000000006` for `DogeP2PKHVerifier`. Future
  networks include the same bytecode in genesis via `GenerateGenesis.s.sol`, so
  the predeploy address and runtime code match across live and fresh networks.
