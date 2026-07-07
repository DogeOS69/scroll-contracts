// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {DogeOSPredeploy} from "../libraries/constants/DogeOSPredeploy.sol";
import {DogeSig} from "./DogeSig.sol";
import {IDogeDualToken} from "./IDogeDualToken.sol";
import {INativeDoge} from "./INativeDoge.sol";

/**
 * @title DogeDualToken
 * @notice Canonical native-DOGE token-duality predeploy (Celo model): native balance is
 *         the source of truth. `balanceOf(a) == a.balance`; there are NO storage balances.
 *         A Dogecoin P2PKH key hash `H` owns the native balance at `address(uint160(H))`
 *         and authorizes transfers with Dogecoin Core-compatible `signmessage` intents,
 *         verified internally via the DogeSig library.
 *
 * @dev Transfers move native balances through the restricted native-transfer precompile
 *      at {DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE}. That precompile is PROTOCOL-TBD:
 *      until it exists, every transfer path reverts loudly with
 *      {ErrorNativeTransferFailed} (views and approvals still work), so genesis-etching
 *      this contract before the protocol work lands is safe.
 *
 *      Transfers execute NO recipient code (the precompile moves balances without calls),
 *      so there are no ERC-777-style reentrancy hooks. ERC-20 zero-address handling is
 *      OZ-style strict — a deliberate deviation from the looser DualityDogeShim.
 *      Plain ERC-20 transfers do NOT apply the reserved-alias policy (EVM senders can
 *      already move native value anywhere); the P2PKH-authorized paths and
 *      {transferToP2PKH} do, because relayed Dogecoin users have no EVM context to
 *      recover funds sent into system contracts.
 *
 *      Signed payload: the Dogecoin user signs the raw 32-byte intent hash
 *      (`abi.encodePacked(intentHash)`) with `signmessage`. A deferred human-readable
 *      alternative ("DogeOS DOGE Transfer Authorization v1:0x<64 lowercase hex chars>")
 *      is specified here for future wallet UX work but deliberately not implemented.
 *
 *      Signature malleability: per DogeSig (Dogecoin Core parity, no low-s rule) each
 *      valid signature has a verifying twin. Replay protection is the sequential nonce
 *      only; signature bytes are never used as identifiers.
 */
contract DogeDualToken is IDogeDualToken {
    // --- Constants --- //

    /// @notice Typehash binding every signed authorization to this chain, this contract,
    ///         and all intent fields. EIP-712-flavored, but deliberately NOT EIP-712
    ///         (`\x19\x01`): the outer hash is a Dogecoin signmessage digest.
    bytes32 public constant P2PKH_TRANSFER_AUTHORIZATION_TYPEHASH =
        keccak256(
            "P2PKHTransferAuthorization(uint256 chainId,address token,bytes20 fromKeyHash,"
            "uint8 toKind,bytes20 to,uint128 amount,uint128 relayerFee,address relayerFeeRecipient,"
            "uint64 nonce,uint64 validAfter,uint64 validBefore,bytes32 contextHash)"
        );

    /// @notice Byte length of one packed batch op.
    uint256 public constant OP_LENGTH = 278;

    uint8 internal constant TO_KIND_EVM = 0;
    uint8 internal constant TO_KIND_P2PKH = 1;

    /// @dev Reserved low band: zero address, EVM precompiles, the native-transfer
    ///      precompile (0x...fd), and headroom.
    uint160 private constant RESERVED_LOW_MAX = 0xffff;
    /// @dev Top-18-byte mask: fixes everything but the low 2 bytes, reserving exactly
    ///      0x5300...0000 through 0x5300...ffff (the DogeOS/Scroll predeploy namespace).
    uint160 private constant DOGEOS_NAMESPACE_MASK = type(uint160).max ^ 0xffff;
    uint160 private constant DOGEOS_NAMESPACE_PREFIX = uint160(0x5300000000000000000000000000000000000000);

    // --- Validation reason codes (shared by revert mapping and batch skip events) --- //

    uint8 private constant REASON_OK = 0;
    uint8 private constant REASON_INVALID_TO_KIND = 1;
    uint8 private constant REASON_NOT_YET_VALID = 2;
    uint8 private constant REASON_EXPIRED = 3;
    uint8 private constant REASON_RESERVED_TARGET = 4;
    uint8 private constant REASON_BAD_NONCE = 5;
    uint8 private constant REASON_MALFORMED_SIGNATURE = 6;
    uint8 private constant REASON_INVALID_SIGNATURE = 7;
    uint8 private constant REASON_INSUFFICIENT_BALANCE = 8;

    // --- Errors --- //

    error ErrorTransferToZeroAddress();
    error ErrorTransferFromZeroAddress();
    error ErrorApproveToZeroAddress();
    error ErrorInsufficientAllowance(address owner, address spender, uint256 currentAllowance, uint256 amount);
    error ErrorNativeTransferFailed(address from, address to, uint256 amount);
    error ErrorReservedAlias(address aliasAddress);
    error ErrorInvalidBatchLength(uint256 length);

    error ErrorInvalidToKind(uint8 toKind);
    error ErrorAuthorizationNotYetValid();
    error ErrorAuthorizationExpired();
    error ErrorReservedAuthorizationTarget(address target);
    /// @dev `provided == type(uint64).max` is invalid even when it equals the stored
    ///      nonce: accepting it would overflow the post-use increment. Unreachable for
    ///      real signers (2^64 - 1 authorizations).
    error ErrorInvalidNonce(uint64 expected, uint64 provided);
    error ErrorMalformedSignature();
    error ErrorInvalidSignature();
    error ErrorInsufficientBalance(uint256 balance, uint256 needed);

    // --- Storage --- //

    // slot 0
    mapping(address => mapping(address => uint256)) private _allowances;
    // slot 1
    mapping(bytes20 => uint64) private _p2pkhNonces;

    // --- ERC-20 metadata --- //

    function name() external pure returns (string memory) {
        return "Dogecoin";
    }

    function symbol() external pure returns (string memory) {
        return "DOGE";
    }

    /// @notice 18 — native-wei semantics. The L2 native asset uses 18 decimals at the
    ///         EVM level; L1 Dogecoin's 8 decimals are a bridge-boundary concern.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Protocol-TBD placeholder. Native supply is not observable from the EVM;
    ///         a future protocol counter/system contract should back this. Matches the
    ///         INativeDoge shim convention.
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    // --- ERC-20 surface --- //

    /// @inheritdoc INativeDoge
    function balanceOf(address account) external view returns (uint256) {
        return account.balance;
    }

    /// @inheritdoc INativeDoge
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) {
            revert ErrorTransferToZeroAddress();
        }
        _nativeTransfer(msg.sender, to, amount);
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc INativeDoge
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc INativeDoge
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) {
            revert ErrorApproveToZeroAddress();
        }
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc INativeDoge
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (from == address(0)) {
            revert ErrorTransferFromZeroAddress();
        }
        if (to == address(0)) {
            revert ErrorTransferToZeroAddress();
        }
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) {
                revert ErrorInsufficientAllowance(from, msg.sender, allowed, amount);
            }
            _allowances[from][msg.sender] = allowed - amount;
        }
        _nativeTransfer(from, to, amount);
        emit Transfer(from, to, amount);
        return true;
    }

    // --- P2PKH views --- //

    /// @inheritdoc IDogeDualToken
    function evmAliasOfP2PKH(bytes20 keyHash) public pure returns (address) {
        return address(keyHash);
    }

    /// @inheritdoc IDogeDualToken
    function balanceOfP2PKH(bytes20 keyHash) external view returns (uint256) {
        return address(keyHash).balance;
    }

    /// @inheritdoc IDogeDualToken
    function nonceOfP2PKH(bytes20 keyHash) external view returns (uint64) {
        return _p2pkhNonces[keyHash];
    }

    // --- Transfers --- //

    /// @inheritdoc IDogeDualToken
    function transferToP2PKH(bytes20 toKeyHash, uint256 amount) external returns (bool) {
        address toAlias = address(toKeyHash);
        if (_isReserved(toAlias)) {
            revert ErrorReservedAlias(toAlias);
        }
        _nativeTransfer(msg.sender, toAlias, amount);
        emit Transfer(msg.sender, toAlias, amount);
        emit TransferToP2PKH(msg.sender, toKeyHash, toAlias, amount);
        return true;
    }

    /// @inheritdoc IDogeDualToken
    function transferWithP2PKHAuthorization(P2PKHTransferAuthorization calldata auth, DogeSignature calldata sig)
        external
    {
        P2PKHTransferAuthorization memory a = auth;
        DogeSignature memory s = sig;
        (address recipient, address feeTo, bytes32 intentHash, uint8 reason) = _validateAuthorization(a, s);
        if (reason != REASON_OK) {
            _revertWithReason(a, reason);
        }
        _executeAuthorizedTransfer(a, recipient, feeTo, intentHash);
    }

    /// @inheritdoc IDogeDualToken
    function transferBatchWithP2PKHAuthorizations(bytes calldata packedOps) external returns (uint256 successCount) {
        if (packedOps.length == 0 || packedOps.length % OP_LENGTH != 0) {
            revert ErrorInvalidBatchLength(packedOps.length);
        }
        uint256 opCount = packedOps.length / OP_LENGTH;
        for (uint256 i = 0; i < opCount; i++) {
            bytes calldata op = packedOps[i * OP_LENGTH:(i + 1) * OP_LENGTH];

            P2PKHTransferAuthorization memory a = P2PKHTransferAuthorization({
                fromKeyHash: bytes20(op[0:20]),
                toKind: uint8(op[20]),
                to: bytes20(op[21:41]),
                amount: uint128(bytes16(op[41:57])),
                relayerFee: uint128(bytes16(op[57:73])),
                relayerFeeRecipient: address(bytes20(op[73:93])),
                nonce: uint64(bytes8(op[93:101])),
                validAfter: uint64(bytes8(op[101:109])),
                validBefore: uint64(bytes8(op[109:117])),
                contextHash: bytes32(op[117:149])
            });
            DogeSignature memory s = DogeSignature({
                header: uint8(op[149]),
                r: bytes32(op[150:182]),
                s: bytes32(op[182:214]),
                x: bytes32(op[214:246]),
                y: bytes32(op[246:278])
            });

            (address recipient, address feeTo, bytes32 intentHash, uint8 reason) = _validateAuthorization(a, s);
            if (reason != REASON_OK) {
                // NOT a cancellation: see IDogeDualToken docs for replay, nonce-spend
                // cancellation, and reserved relayer fee-recipient implications.
                emit P2PKHOpSkipped(i, a.fromKeyHash, a.nonce, reason);
                continue;
            }
            _executeAuthorizedTransfer(a, recipient, feeTo, intentHash);
            successCount++;
        }
    }

    // --- Internal: validation and execution --- //

    /**
     * @dev Single validation path shared by the reverting single-op entrypoint and the
     *      skipping batch entrypoint. Performs NO state changes. Returns reason != 0 on
     *      any validation failure; cheap structural checks run before signature work.
     *
     *      The signature pre-checks (header range/recId, on-curve witness) make DogeSig's
     *      malformed-input reverts unreachable here, so the only revert that can escape
     *      in batch mode is RIPEMD-160-precompile absence — an environment failure that
     *      correctly aborts the whole batch (like native-transfer-precompile absence).
     */
    function _validateAuthorization(P2PKHTransferAuthorization memory auth, DogeSignature memory sig)
        private
        view
        returns (
            address recipient,
            address feeTo,
            bytes32 intentHash,
            uint8 reason
        )
    {
        if (auth.toKind > TO_KIND_P2PKH) {
            return (address(0), address(0), 0, REASON_INVALID_TO_KIND);
        }
        // EIP-3009 semantics: exclusive bounds.
        if (block.timestamp <= auth.validAfter) {
            return (address(0), address(0), 0, REASON_NOT_YET_VALID);
        }
        if (block.timestamp >= auth.validBefore) {
            return (address(0), address(0), 0, REASON_EXPIRED);
        }

        address fromAlias = address(auth.fromKeyHash);
        recipient = address(auth.to);
        feeTo = auth.relayerFeeRecipient == address(0) ? msg.sender : auth.relayerFeeRecipient;
        if (_isReserved(fromAlias) || _isReserved(recipient) || (auth.relayerFee > 0 && _isReserved(feeTo))) {
            return (recipient, feeTo, 0, REASON_RESERVED_TARGET);
        }

        // provided == uint64.max is rejected even if it matches storage: the post-use
        // increment would overflow and break batch skip semantics.
        if (_p2pkhNonces[auth.fromKeyHash] != auth.nonce || auth.nonce == type(uint64).max) {
            return (recipient, feeTo, 0, REASON_BAD_NONCE);
        }

        // Pre-checks for inputs DogeSig treats as malformed (it would revert).
        if (sig.header < 27 || sig.header > 34 || ((sig.header - 27) & 3) > 1 || !DogeSig.isOnCurve(sig.x, sig.y)) {
            return (recipient, feeTo, 0, REASON_MALFORMED_SIGNATURE);
        }

        intentHash = _intentHash(auth);
        bytes32 dogeMessageHash = DogeSig.dogecoinMessageHash(abi.encodePacked(intentHash));
        if (!DogeSig.verifyP2PKH(auth.fromKeyHash, dogeMessageHash, sig.header, sig.r, sig.s, sig.x, sig.y)) {
            return (recipient, feeTo, intentHash, REASON_INVALID_SIGNATURE);
        }

        // Balance pre-check so insufficient funds is a skippable reason, not a
        // native-transfer revert. uint128 + uint128 cannot overflow uint256.
        if (fromAlias.balance < uint256(auth.amount) + uint256(auth.relayerFee)) {
            return (recipient, feeTo, intentHash, REASON_INSUFFICIENT_BALANCE);
        }

        reason = REASON_OK;
    }

    /// @dev Effects + events for a validated authorization.
    function _executeAuthorizedTransfer(
        P2PKHTransferAuthorization memory auth,
        address recipient,
        address feeTo,
        bytes32 intentHash
    ) private {
        address fromAlias = address(auth.fromKeyHash);

        _p2pkhNonces[auth.fromKeyHash] = auth.nonce + 1;

        _nativeTransfer(fromAlias, recipient, auth.amount);
        emit Transfer(fromAlias, recipient, auth.amount);
        if (auth.relayerFee > 0) {
            _nativeTransfer(fromAlias, feeTo, auth.relayerFee);
            // the fee is a token move performed by this contract, so it gets an
            // ERC-20 Transfer log too (indexers must see every mediated move)
            emit Transfer(fromAlias, feeTo, auth.relayerFee);
        }
        if (auth.toKind == TO_KIND_EVM) {
            emit TransferFromP2PKHToAddress(auth.fromKeyHash, recipient, auth.amount, auth.relayerFee, feeTo);
        } else {
            emit TransferFromP2PKHToP2PKH(auth.fromKeyHash, auth.to, auth.amount, auth.relayerFee, feeTo);
        }
        emit P2PKHAuthorizationUsed(auth.fromKeyHash, auth.nonce, intentHash);
    }

    /// @dev Maps a validation reason to the rich revert used by the single-op entrypoint.
    function _revertWithReason(P2PKHTransferAuthorization memory auth, uint8 reason) private view {
        if (reason == REASON_INVALID_TO_KIND) revert ErrorInvalidToKind(auth.toKind);
        if (reason == REASON_NOT_YET_VALID) revert ErrorAuthorizationNotYetValid();
        if (reason == REASON_EXPIRED) revert ErrorAuthorizationExpired();
        if (reason == REASON_RESERVED_TARGET) {
            address fromAlias = address(auth.fromKeyHash);
            if (_isReserved(fromAlias)) revert ErrorReservedAuthorizationTarget(fromAlias);
            address recipient = address(auth.to);
            if (_isReserved(recipient)) revert ErrorReservedAuthorizationTarget(recipient);
            address feeTo = auth.relayerFeeRecipient == address(0) ? msg.sender : auth.relayerFeeRecipient;
            revert ErrorReservedAuthorizationTarget(feeTo);
        }
        if (reason == REASON_BAD_NONCE) revert ErrorInvalidNonce(_p2pkhNonces[auth.fromKeyHash], auth.nonce);
        if (reason == REASON_MALFORMED_SIGNATURE) revert ErrorMalformedSignature();
        if (reason == REASON_INVALID_SIGNATURE) revert ErrorInvalidSignature();
        if (reason == REASON_INSUFFICIENT_BALANCE) {
            revert ErrorInsufficientBalance(
                address(auth.fromKeyHash).balance,
                uint256(auth.amount) + uint256(auth.relayerFee)
            );
        }
        // unreachable: every non-OK reason code is mapped above
        assert(false);
    }

    /// @dev Domain-bound intent hash; see {P2PKH_TRANSFER_AUTHORIZATION_TYPEHASH}.
    ///      Encoded in two halves to stay within stack limits; all fields are static
    ///      types, so the concatenation is byte-identical to one abi.encode of all 13
    ///      values.
    function _intentHash(P2PKHTransferAuthorization memory auth) private view returns (bytes32) {
        return
            keccak256(
                bytes.concat(
                    abi.encode(
                        P2PKH_TRANSFER_AUTHORIZATION_TYPEHASH,
                        block.chainid,
                        address(this),
                        auth.fromKeyHash,
                        auth.toKind,
                        auth.to
                    ),
                    abi.encode(
                        auth.amount,
                        auth.relayerFee,
                        auth.relayerFeeRecipient,
                        auth.nonce,
                        auth.validAfter,
                        auth.validBefore,
                        auth.contextHash
                    )
                )
            );
    }

    // --- Internal: reserved aliases and native moves --- //

    /**
     * @dev Reserved addresses that P2PKH-authorized flows must never target:
     *      - the low band [0x0, 0xffff]: zero address, EVM precompiles, the
     *        native-transfer precompile (0x...fd), and headroom;
     *      - the DogeOS/Scroll predeploy namespace 0x5300...0000-0x5300...ffff;
     *      - this contract.
     *      Future predeploys placed outside these bands would be alias-targetable —
     *      keep predeploy address policy inside them.
     */
    function _isReserved(address a) private view returns (bool) {
        uint160 v = uint160(a);
        if (v <= RESERVED_LOW_MAX) {
            return true;
        }
        if ((v & DOGEOS_NAMESPACE_MASK) == DOGEOS_NAMESPACE_PREFIX) {
            return true;
        }
        return a == address(this);
    }

    /**
     * @dev Native balance move via the restricted native-transfer precompile. The
     *      return-word check makes a missing precompile fail LOUDLY: a CALL to an empty
     *      account "succeeds" with empty returndata (same failure class DogeSig._hash160
     *      defends against), so requiring the exact 32-byte success word converts that
     *      into {ErrorNativeTransferFailed}. See the precompile contract spec on
     *      {DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE}.
     */
    function _nativeTransfer(
        address from,
        address to,
        uint256 amount
    ) private {
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(from, to, amount)
        );
        if (!success || ret.length != 32 || abi.decode(ret, (uint256)) != 1) {
            revert ErrorNativeTransferFailed(from, to, amount);
        }
    }
}
