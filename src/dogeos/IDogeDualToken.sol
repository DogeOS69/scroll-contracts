// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {INativeDoge} from "./INativeDoge.sol";

/**
 * @title IDogeDualToken
 * @notice Native-DOGE token-duality predeploy with Dogecoin P2PKH authorization.
 *
 *         Account model: native balance is the source of truth. An EVM address holds its
 *         native balance; a Dogecoin P2PKH key hash `H` holds the native balance at its
 *         alias `address(uint160(H))`. P2PKH owners authorize transfers by signing typed
 *         intents with Dogecoin Core-compatible `signmessage`; any relayer can submit them.
 *
 * @dev Collision note: a 20-byte value is both a valid EVM address and a valid P2PKH key
 *      hash. Controlling both requires unrelated preimages (~2^-160 targeted) — inherent
 *      to the design and not mitigated. Typed functions/events distinguish the two
 *      interpretations; UIs must label Dogecoin-derived aliases explicitly.
 */
interface IDogeDualToken is INativeDoge {
    // --- Structs --- //

    /// @notice A Dogecoin-signed transfer intent.
    /// @dev `toKind`: 0 = `to` is an EVM address; 1 = `to` is a P2PKH key hash (recipient
    ///      is its alias). `relayerFeeRecipient == address(0)` pays the fee to msg.sender.
    ///      `validAfter`/`validBefore` are EXCLUSIVE bounds (EIP-3009 semantics); use
    ///      0 / type(uint64).max for "no window". `contextHash` is an app-defined binding
    ///      (0 for plain payments).
    struct P2PKHTransferAuthorization {
        bytes20 fromKeyHash;
        uint8 toKind;
        bytes20 to;
        uint128 amount;
        uint128 relayerFee;
        address relayerFeeRecipient;
        uint64 nonce;
        uint64 validAfter;
        uint64 validBefore;
        bytes32 contextHash;
    }

    /// @notice A Dogecoin compact signature plus the public key witness DogeSig requires.
    struct DogeSignature {
        uint8 header;
        bytes32 r;
        bytes32 s;
        bytes32 x;
        bytes32 y;
    }

    // --- Events --- //

    event TransferToP2PKH(address indexed from, bytes20 indexed toKeyHash, address toAlias, uint256 amount);

    event TransferFromP2PKHToAddress(
        bytes20 indexed fromKeyHash,
        address indexed to,
        uint256 amount,
        uint256 relayerFee,
        address relayerFeeRecipient
    );

    event TransferFromP2PKHToP2PKH(
        bytes20 indexed fromKeyHash,
        bytes20 indexed toKeyHash,
        uint256 amount,
        uint256 relayerFee,
        address relayerFeeRecipient
    );

    event P2PKHAuthorizationUsed(bytes20 indexed fromKeyHash, uint64 nonce, bytes32 intentHash);

    /// @notice Emitted by the batch entrypoint for each op that failed validation and was
    ///         skipped. `reason` values: 1 invalid toKind, 2 not yet valid, 3 expired,
    ///         4 reserved target, 5 bad nonce, 6 malformed signature, 7 invalid signature,
    ///         8 insufficient balance.
    /// @dev A skip is NOT a cancellation: the signed authorization remains valid and
    ///      replayable (by anyone holding it) until its nonce is consumed or its
    ///      validBefore passes. Signers who want an op dead must spend the nonce.
    event P2PKHOpSkipped(uint256 indexed opIndex, bytes20 indexed fromKeyHash, uint64 nonce, uint8 reason);

    // --- P2PKH views --- //

    /// @notice The EVM alias address controlled by a P2PKH key hash.
    function evmAliasOfP2PKH(bytes20 keyHash) external pure returns (address aliasAddress);

    /// @notice Native balance of a P2PKH key hash (== balanceOf(evmAliasOfP2PKH(keyHash))).
    function balanceOfP2PKH(bytes20 keyHash) external view returns (uint256);

    /// @notice Next sequential authorization nonce for a P2PKH key hash.
    function nonceOfP2PKH(bytes20 keyHash) external view returns (uint64);

    // --- Transfers --- //

    /// @notice Typed convenience transfer from msg.sender to a P2PKH key hash's alias.
    function transferToP2PKH(bytes20 toKeyHash, uint256 amount) external returns (bool);

    /// @notice Execute one Dogecoin-signed transfer intent. Reverts with a rich error on
    ///         any validation failure (see DogeDualToken error definitions).
    function transferWithP2PKHAuthorization(P2PKHTransferAuthorization calldata auth, DogeSignature calldata sig)
        external;

    /// @notice Execute a packed batch of Dogecoin-signed transfer intents. Ops that fail
    ///         validation are SKIPPED (emitting {P2PKHOpSkipped}); valid ops execute.
    /// @dev Packed op layout, 278 bytes:
    ///      fromKeyHash(20) || toKind(1) || to(20) || amount(16) || relayerFee(16) ||
    ///      relayerFeeRecipient(20) || nonce(8) || validAfter(8) || validBefore(8) ||
    ///      contextHash(32) || header(1) || r(32) || s(32) || x(32) || y(32).
    ///      Reverts only on a malformed envelope (length 0 or not a multiple of 278) or
    ///      on environment failure (missing native-transfer or RIPEMD-160 precompile).
    ///
    ///      A skipped op is not cancelled: emitting {P2PKHOpSkipped} leaves the signed
    ///      authorization live and replayable by anyone holding it until its nonce is
    ///      consumed or `validBefore` passes. There is no on-chain revocation primitive;
    ///      a signer who wants to cancel must spend the nonce, for example by signing and
    ///      executing a zero-amount self-transfer with the same nonce. An op that fails
    ///      now, such as for insufficient signer balance, with a distant `validBefore`
    ///      becomes executable as soon as the balance is topped up, with no further
    ///      signer action; wallets should default to tight `validBefore` windows.
    ///
    ///      If `relayerFee > 0` and `relayerFeeRecipient == address(0)`, the fee
    ///      recipient is `msg.sender`. Such ops are skipped with reason 4 (reserved
    ///      target) when submitted by a reserved-address caller, including the low band
    ///      or 0x5300... namespace. Signers who need unconditional fee routing should
    ///      set an explicit non-reserved `relayerFeeRecipient`.
    /// @return successCount The number of ops that executed.
    function transferBatchWithP2PKHAuthorizations(bytes calldata packedOps) external returns (uint256 successCount);
}
