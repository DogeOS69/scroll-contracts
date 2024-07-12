// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {IZkEvmVerifierV2} from "./IZkEvmVerifier.sol";

// solhint-disable no-inline-assembly

contract ZkEvmVerifierV2 is IZkEvmVerifierV2 {
    /**********
     * Errors *
     **********/

    /// @dev Thrown when bundle recursion zk proof verification is failed.
    error VerificationFailed();

    /*************
     * Constants *
     *************/

    /// @notice The address of highly optimized plonk verifier contract.
    address public immutable plonkVerifier;

    /// @notice A predetermined digest for the `plonkVerifier`.
    bytes32 public immutable verifierDigest;

    /***************
     * Constructor *
     ***************/

    constructor(address _verifier, bytes32 _verifierDigest) {
        plonkVerifier = _verifier;
        verifierDigest = _verifierDigest;
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IZkEvmVerifierV2
    ///
    /// @dev Encoding for `publicInput`
    /// ```text
    /// | layer2ChainId | numBatches | prevStateRoot | prevBatchHash | postStateRoot | batchHash | withdrawRoot |
    /// |    8 bytes    |  4  bytes  |   32  bytes   |   32  bytes   |   32  bytes   | 32  bytes |   32 bytes   |
    /// ```
    function verify(bytes calldata bundleProof, bytes calldata publicInput) external view override {
        address _verifier = plonkVerifier;
        bytes32 _verifierDigest = verifierDigest;
        bool success;

        // 1. the first 12 * 32 (0x180) bytes of `bundleProof` is `accumulator`
        // 2. the rest bytes of `bundleProof` is the actual `bundle_recursion_proof`
        // 3. Inserted between `accumulator` and `bundle_recursion_proof` are
        //    32 * 13 (0x1a0) bytes, such that:
        //    | start         | end           | field                   |
        //    |---------------|---------------|-------------------------|
        //    | 0x00          | 0x180         | bundleProof[0x00:0x180] |
        //    | 0x180         | 0x180 + 0x20  | verifierDigest          |
        //    | 0x180 + 0x20  | 0x180 + 0x40  | prevStateRoot_hi        |
        //    | 0x180 + 0x40  | 0x180 + 0x60  | prevStateRoot_lo        |
        //    | 0x180 + 0x60  | 0x180 + 0x80  | prevBatchHash_hi        |
        //    | 0x180 + 0x80  | 0x180 + 0xa0  | prevBatchHash_lo        |
        //    | 0x180 + 0xa0  | 0x180 + 0xc0  | postStateRoot_hi        |
        //    | 0x180 + 0xc0  | 0x180 + 0xe0  | postStateRoot_lo        |
        //    | 0x180 + 0xe0  | 0x180 + 0x100 | batchHash_hi            |
        //    | 0x180 + 0x100 | 0x180 + 0x120 | batchHash_lo            |
        //    | 0x180 + 0x120 | 0x180 + 0x140 | layer2ChainId           |
        //    | 0x180 + 0x140 | 0x180 + 0x160 | withdrawRoot_hi         |
        //    | 0x180 + 0x160 | 0x180 + 0x180 | withdrawRoot_lo         |
        //    | 0x180 + 0x180 | 0x180 + 0x1a0 | numBatches              |
        //    | 0x180 + 0x1a0 | dynamic       | bundleProof[0x180:]     |
        assembly {
            let p := mload(0x40)
            // 1. copy the accumulator's 0x180 bytes
            calldatacopy(p, bundleProof.offset, 0x180)
            // 2. insert the public input's 0x1a0 bytes
            mstore(add(p, 0x180), _verifierDigest) // verifierDigest
            let prevStateRoot := calldataload(add(publicInput.offset, 0xc))
            mstore(add(p, 0x1a0), shr(128, prevStateRoot)) // prevStateRoot_hi
            mstore(add(p, 0x1c0), and(prevStateRoot, 0xffffffffffffffffffffffffffffffff)) // prevStateRoot_lo
            let prevBatchHash := calldataload(add(publicInput.offset, 0x2c))
            mstore(add(p, 0x1e0), shr(128, prevBatchHash)) // prevBatchHash_hi
            mstore(add(p, 0x200), and(prevBatchHash, 0xffffffffffffffffffffffffffffffff)) // prevBatchHash_lo
            let postStateRoot := calldataload(add(publicInput.offset, 0x4c))
            mstore(add(p, 0x220), shr(128, postStateRoot)) // postStateRoot_hi
            mstore(add(p, 0x240), and(postStateRoot, 0xffffffffffffffffffffffffffffffff)) // postStateRoot_lo
            let batchHash := calldataload(add(publicInput.offset, 0x6c))
            mstore(add(p, 0x260), shr(128, batchHash)) // batchHash_hi
            mstore(add(p, 0x280), and(batchHash, 0xffffffffffffffffffffffffffffffff)) // batchHash_lo
            let layer2ChainId := shr(192, calldataload(publicInput.offset))
            mstore(add(p, 0x2a0), layer2ChainId) // layer2ChainId
            let withdrawRoot := calldataload(add(publicInput.offset, 0x8c))
            mstore(add(p, 0x2c0), shr(128, withdrawRoot)) // withdrawRoot_hi
            mstore(add(p, 0x2e0), and(withdrawRoot, 0xffffffffffffffffffffffffffffffff)) // withdrawRoot_lo
            let numBatches := shr(224, calldataload(add(publicInput.offset, 0x08)))
            mstore(add(p, 0x300), numBatches) // numBatches
            // 3. copy all remaining bytes from bundleProof
            calldatacopy(add(p, 0x320), add(bundleProof.offset, 0x180), sub(bundleProof.length, 0x180))
            // 4. call plonk verifier
            success := staticcall(gas(), _verifier, p, add(bundleProof.length, 0x1a0), 0x00, 0x00)
        }
        if (!success) {
            revert VerificationFailed();
        }
    }
}
