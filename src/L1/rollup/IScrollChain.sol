// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IScrollChain
/// @notice The interface for ScrollChain.
interface IScrollChain {
    /**********
     * Events *
     **********/

    /// @notice Emitted when a new batch is committed.
    /// @param batchIndex The index of the batch.
    /// @param batchHash The hash of the batch.
    event CommitBatch(uint256 indexed batchIndex, bytes32 indexed batchHash);

    /// @notice revert a pending batch.
    /// @param batchIndex The index of the batch.
    /// @param batchHash The hash of the batch
    event RevertBatch(uint256 indexed batchIndex, bytes32 indexed batchHash);

    /// @notice Emitted when a batch is verified by zk proof
    /// @param batchIndex The index of the batch.
    /// @param batchHash The hash of the batch
    /// @param stateRoot The state root on layer 2 after this batch.
    /// @param withdrawRoot The merkle root on layer2 after this batch.
    event VerifyBatchWithZkp(
        uint256 indexed batchIndex,
        bytes32 indexed batchHash,
        bytes32 stateRoot,
        bytes32 withdrawRoot
    );

    /// @notice Emitted when a batch is verified by tee proof
    /// @dev Tee proof always comes after zk proof. If they match, the state root and withdraw root are the same.
    ///      If they mismatch, we will emit `StateMismatch` instead. Therefore, the `stateRoot` and `withdrawRoot`
    ///      is not included in this event.
    /// @param batchIndex The index of the batch.
    event VerifyBatchWithTee(uint256 indexed batchIndex);

    /// @notice Emitted when a batch is finalized.
    /// @param batchIndex The index of the batch.
    /// @param batchHash The hash of the batch
    /// @param stateRoot The state root on layer 2 after this batch.
    /// @param withdrawRoot The merkle root on layer2 after this batch.
    event FinalizeBatch(uint256 indexed batchIndex, bytes32 indexed batchHash, bytes32 stateRoot, bytes32 withdrawRoot);

    /// @notice Emitted when state between zk proof and tee proof mismatch
    /// @param batchIndex The index of the batch.
    /// @param stateRoot The state root from tee proof.
    /// @param withdrawRoot The correct withdraw root from tee proof.
    event StateMismatch(uint256 indexed batchIndex, bytes32 stateRoot, bytes32 withdrawRoot);

    /// @notice Emitted when mismatched state is resolved.
    /// @param batchIndex The index of the batch.
    /// @param stateRoot The correct state root.
    /// @param withdrawRoot The correct withdraw root.
    event ResolveState(uint256 indexed batchIndex, bytes32 stateRoot, bytes32 withdrawRoot);

    /// @notice Emitted when owner updates the status of sequencer.
    /// @param account The address of account updated.
    /// @param status The status of the account updated.
    event UpdateSequencer(address indexed account, bool status);

    /// @notice Emitted when owner updates the status of prover.
    /// @param account The address of account updated.
    /// @param status The status of the account updated.
    event UpdateProver(address indexed account, bool status);

    /// @notice Emitted when the value of `maxNumTxInChunk` is updated.
    /// @param oldMaxNumTxInChunk The old value of `maxNumTxInChunk`.
    /// @param newMaxNumTxInChunk The new value of `maxNumTxInChunk`.
    event UpdateMaxNumTxInChunk(uint256 oldMaxNumTxInChunk, uint256 newMaxNumTxInChunk);

    /*************************
     * Public View Functions *
     *************************/

    /// @return The latest finalized batch index (both zkp and tee verified).
    function lastFinalizedBatchIndex() external view returns (uint256);

    /// @return The latest verified batch index by zkp proof.
    function lastZkpVerifiedBatchIndex() external view returns (uint256);

    /// @return The latest verified batch index by tee proof.
    function lastTeeVerifiedBatchIndex() external view returns (uint256);

    /// @param batchIndex The index of the batch.
    /// @return The batch hash of a committed batch.
    function committedBatches(uint256 batchIndex) external view returns (bytes32);

    /// @param batchIndex The index of the batch.
    /// @return The state root of a committed batch.
    function finalizedStateRoots(uint256 batchIndex) external view returns (bytes32);

    /// @param batchIndex The index of the batch.
    /// @return The message root of a committed batch.
    function withdrawRoots(uint256 batchIndex) external view returns (bytes32);

    /// @param batchIndex The index of the batch.
    /// @return Whether the batch is finalized by batch index.
    function isBatchFinalized(uint256 batchIndex) external view returns (bool);

    /*****************************
     * Public Mutating Functions *
     *****************************/

    /// @notice Commit a batch of transactions on layer 1 with blob data proof.
    ///
    /// @dev Memory layout of `blobDataProof`:
    /// |    z    |    y    | kzg_commitment | kzg_proof |
    /// |---------|---------|----------------|-----------|
    /// | bytes32 | bytes32 |    bytes48     |  bytes48  |
    ///
    /// @param version The version of current batch.
    /// @param parentBatchHeader The header of parent batch, see the comments of `BatchHeaderV0Codec`.
    /// @param chunks The list of encoded chunks, see the comments of `ChunkCodec`.
    /// @param skippedL1MessageBitmap The bitmap indicates whether each L1 message is skipped or not.
    /// @param blobDataProof The proof for blob data.
    function commitBatchWithBlobProof(
        uint8 version,
        bytes calldata parentBatchHeader,
        bytes[] memory chunks,
        bytes calldata skippedL1MessageBitmap,
        bytes calldata blobDataProof
    ) external;

    /// @notice Commit a batch of transactions on layer 1 with blob data proof.
    ///
    /// @dev Memory layout of `blobDataProof`:
    /// |    z    |    y    | kzg_commitment | kzg_proof |
    /// |---------|---------|----------------|-----------|
    /// | bytes32 | bytes32 |    bytes48     |  bytes48  |
    ///
    /// @param version The version of current batch.
    /// @param parentBatchHeader The header of parent batch, see the comments of `BatchHeaderV0Codec`.
    /// @param chunks The list of encoded chunks, see the comments of `ChunkCodec`.
    /// @param blobDataProof The proof for blob data.
    function commitBatchWithBlobProof(
        uint8 version,
        bytes calldata parentBatchHeader,
        bytes[] memory chunks,
        bytes calldata blobDataProof
    ) external;

    /// @notice Finalize a list of committed batches (i.e. bundle) on layer 1.
    /// @param batchHeader The header of last batch in current bundle, see the encoding in comments of `commitBatch`.
    /// @param postStateRoot The state root after current bundle.
    /// @param withdrawRoot The withdraw trie root after current bundle.
    /// @param aggrProof The aggregation proof for current bundle.
    function finalizeBundleWithProof(
        bytes calldata batchHeader,
        bytes32 postStateRoot,
        bytes32 withdrawRoot,
        bytes calldata aggrProof
    ) external;

    /// @notice Finalize a list of committed batches (i.e. bundle) on layer 1 with TEE proof.
    /// @param batchHeader The header of last batch in current bundle, see the encoding in comments of `commitBatch`.
    /// @param postStateRoot The state root after current bundle.
    /// @param withdrawRoot The withdraw trie root after current bundle.
    /// @param teeProof The tee proof for current bundle.
    function finalizeBundleWithTeeProof(
        bytes calldata batchHeader,
        bytes32 postStateRoot,
        bytes32 withdrawRoot,
        bytes calldata teeProof
    ) external;

    /// @param The struct for batch committing.
    /// @param version The version of current batch.
    /// @param parentBatchHeader The header of parent batch, see the comments of `BatchHeaderV0Codec`.
    /// @param chunks The list of encoded chunks, see the comments of `ChunkCodec`.
    /// @param blobDataProof The proof for blob data.
    struct CommitStruct {
        uint8 version;
        bytes parentBatchHeader;
        bytes[] chunks;
        bytes blobDataProof;
    }

    /// @param The struct for batch finalization.
    /// @param batchHeader The header of current batch, see the encoding in comments of `commitBatch`.
    /// @param postStateRoot The state root after current batch.
    /// @param withdrawRoot The withdraw trie root after current batch.
    /// @param zkProof The zk proof for current batch (single-batch bundle).
    /// @param teeProof The tee proof for current batch (single-batch bundle).
    struct FinalizeStruct {
        bytes batchHeader;
        bytes32 postStateRoot;
        bytes32 withdrawRoot;
        bytes zkProof;
        bytes teeProof;
    }

    /// @notice Commit a batch of transactions on layer 1 with blob data proof and finalize it.
    /// @param commitStruct The data needed for commit.
    /// @param finalizeStruct The data needed for finalize.
    function commitAndFinalizeBatch(CommitStruct calldata commitStruct, FinalizeStruct calldata finalizeStruct)
        external;
}
