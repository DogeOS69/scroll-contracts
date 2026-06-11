// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

library DogeOSPredeploy {
    /// @notice Canonical address of the DogeP2PKHVerifier predeploy.
    address internal constant L2_DOGE_P2PKH_VERIFIER = 0x5300000000000000000000000000000000000006;

    /// @notice Canonical address of the DogeDualToken predeploy (native-DOGE token duality).
    address internal constant L2_DOGE_DUAL_TOKEN = 0x5300000000000000000000000000000000000007;

    /// @notice PROTOCOL-TBD: restricted native-transfer precompile (Celo transfer-precompile
    ///         model). Does NOT exist in DogeOS l2geth/revm/prover yet; this address is a
    ///         proposal pending protocol-team ratification. Chosen to match Celo's transfer
    ///         precompile at 0x...fd: outside the 0x5300 predeploy namespace, inside the
    ///         always-reserved low address band, and far above the EIP precompile range.
    ///
    ///         Required precompile contract (see DogeDualToken._nativeTransfer):
    ///         - callable ONLY by L2_DOGE_DUAL_TOKEN; revert for any other caller
    ///         - input: 96 bytes, abi.encode(address from, address to, uint256 amount)
    ///         - effect: debit native balance[from], credit native balance[to]
    ///         - revert if balance[from] < amount
    ///         - MUST NOT execute recipient code (no receive()/fallback hooks)
    ///         - return exactly 32 bytes: abi.encode(uint256(1))
    ///         - deterministic gas (Celo reference: 9,000)
    address internal constant NATIVE_TRANSFER_PRECOMPILE = 0x00000000000000000000000000000000000000fd;
}
