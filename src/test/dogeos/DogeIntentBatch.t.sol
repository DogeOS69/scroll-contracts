// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";

import {DogeSig} from "../../dogeos/DogeSig.sol";
import {DogeP2PKHVerifier} from "../../dogeos/DogeP2PKHVerifier.sol";
import {IDogeP2PKHVerifier} from "../../dogeos/IDogeP2PKHVerifier.sol";

// ---------------------------------------------------------------------------------------
// TEST/BENCHMARK-ONLY CONTRACTS - NOT FOR PRODUCTION.
//
// Minimal intent ledger used to measure the cost of Dogecoin-signature-authorized
// transfers in a batch, comparing:
//   A. internal-library verification (DogeSig inlined into the batch contract), vs
//   B. external per-op staticcalls to the DogeP2PKHVerifier predeploy.
//
// Packed op layout (193 bytes per op):
//   from(20) || to(20) || amount(16) || nonce(8) || header(1) || r(32) || s(32) || x(32) || y(32)
//
// The signed intent binds: chainid, ledger address, from, to, amount, nonce. Nonces give
// replay protection - signature bytes are never used as replay keys (signatures are
// malleable; see DogeSig).
// ---------------------------------------------------------------------------------------

abstract contract DogeIntentLedgerBase {
    uint256 internal constant OP_LENGTH = 193;

    mapping(bytes20 => uint256) public balances;
    mapping(bytes20 => uint64) public nonces;

    error ErrorInvalidBatchLength(uint256 length);
    error ErrorBadSignature(uint256 opIndex);
    error ErrorBadNonce(uint256 opIndex);
    error ErrorInsufficientBalance(uint256 opIndex);

    /// @dev Test-only balance setup.
    function creditForTest(bytes20 keyHash, uint256 amount) external {
        balances[keyHash] += amount;
    }

    function applyBatch(bytes calldata ops) external {
        if (ops.length == 0 || ops.length % OP_LENGTH != 0) {
            revert ErrorInvalidBatchLength(ops.length);
        }
        uint256 count = ops.length / OP_LENGTH;
        for (uint256 i = 0; i < count; i++) {
            bytes calldata op = ops[i * OP_LENGTH:(i + 1) * OP_LENGTH];

            bytes20 from = bytes20(op[0:20]);
            bytes20 to = bytes20(op[20:40]);
            uint128 amount = uint128(bytes16(op[40:56]));
            uint64 nonce = uint64(bytes8(op[56:64]));

            bytes32 msgHash = DogeSig.dogecoinMessageHash(
                abi.encodePacked(keccak256(abi.encodePacked(block.chainid, address(this), from, to, amount, nonce)))
            );

            if (
                !_verify(
                    from,
                    msgHash,
                    uint8(op[64]),
                    bytes32(op[65:97]),
                    bytes32(op[97:129]),
                    bytes32(op[129:161]),
                    bytes32(op[161:193])
                )
            ) {
                revert ErrorBadSignature(i);
            }
            if (nonces[from] != nonce) {
                revert ErrorBadNonce(i);
            }
            if (balances[from] < amount) {
                revert ErrorInsufficientBalance(i);
            }

            nonces[from] = nonce + 1;
            balances[from] -= amount;
            balances[to] += amount;
        }
    }

    function _verify(
        bytes20 from,
        bytes32 msgHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) internal view virtual returns (bool);
}

/// @dev Variant A: verification through the internal DogeSig library (no external call).
contract DogeIntentBatchInternal is DogeIntentLedgerBase {
    function _verify(
        bytes20 from,
        bytes32 msgHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) internal view override returns (bool) {
        return DogeSig.verifyP2PKH(from, msgHash, header, r, s, x, y);
    }
}

/// @dev Variant B: verification via a per-op staticcall to the DogeP2PKHVerifier predeploy.
contract DogeIntentBatchExternal is DogeIntentLedgerBase {
    IDogeP2PKHVerifier public immutable VERIFIER;

    constructor(IDogeP2PKHVerifier _verifier) {
        VERIFIER = _verifier;
    }

    function _verify(
        bytes20 from,
        bytes32 msgHash,
        uint8 header,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) internal view override returns (bool) {
        return VERIFIER.verifyP2PKHPacked(abi.encodePacked(from, msgHash, header, r, s, x, y));
    }
}

/// @dev ERC-20 transfer baseline.
contract BenchERC20 is MockERC20 {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DogeIntentBatchTest is Test {
    uint256 internal constant SIGNER_COUNT = 8;

    DogeP2PKHVerifier internal _verifier;
    DogeIntentBatchInternal internal _internalLedger;
    DogeIntentBatchExternal internal _externalLedger;
    BenchERC20 internal _token;

    uint256[] internal _privateKeys;
    Vm.Wallet[] internal _wallets;
    bytes20[] internal _keyHashes;

    function setUp() public {
        _verifier = new DogeP2PKHVerifier();
        _internalLedger = new DogeIntentBatchInternal();
        _externalLedger = new DogeIntentBatchExternal(_verifier);
        _token = new BenchERC20();
        _token.initialize("Bench", "BNCH", 18);

        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            uint256 pk = 0xD09E + i;
            Vm.Wallet memory wallet = vm.createWallet(pk);
            _privateKeys.push(pk);
            _wallets.push(wallet);
            _keyHashes.push(DogeSig.p2pkhFromPubKey(bytes32(wallet.publicKeyX), bytes32(wallet.publicKeyY), true));
        }
    }

    // --- Op construction --- //

    function _signOp(
        address ledger,
        uint256 signerIdx,
        bytes20 to,
        uint128 amount,
        uint64 nonce
    ) internal returns (bytes memory op) {
        Vm.Wallet memory wallet = _wallets[signerIdx];
        bytes20 from = _keyHashes[signerIdx];

        bytes32 intentHash = keccak256(abi.encodePacked(block.chainid, ledger, from, to, amount, nonce));
        bytes32 msgHash = DogeSig.dogecoinMessageHash(abi.encodePacked(intentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKeys[signerIdx], msgHash);

        // v is 27/28; +4 marks the key as compressed.
        op = abi.encodePacked(
            from,
            to,
            amount,
            nonce,
            uint8(v + 4),
            r,
            s,
            bytes32(wallet.publicKeyX),
            bytes32(wallet.publicKeyY)
        );
    }

    /// @dev Builds a batch of `count` ops, cycling through the signers with per-signer
    ///      incrementing nonces starting at the ledger's current nonce. Note: ops are
    ///      signed for one specific ledger address (the intent binds address(this)), so
    ///      internal and external ledgers need separately built batches.
    function _buildBatch(DogeIntentLedgerBase ledger, uint256 count) internal returns (bytes memory ops) {
        bytes20 to = bytes20(uint160(0xBEEF));
        for (uint256 i = 0; i < count; i++) {
            uint256 signerIdx = i % SIGNER_COUNT;
            uint64 nonce = ledger.nonces(_keyHashes[signerIdx]) + uint64(i / SIGNER_COUNT);
            ops = bytes.concat(ops, _signOp(address(ledger), signerIdx, to, 1 ether, nonce));
        }
    }

    function _fund(DogeIntentLedgerBase ledger) internal {
        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            ledger.creditForTest(_keyHashes[i], 1_000_000 ether);
        }
    }

    // --- Correctness --- //

    function testApplyBatch_TransfersAndNonces() external {
        _fund(_internalLedger);
        _fund(_externalLedger);
        bytes20 to = bytes20(uint160(0xBEEF));

        _internalLedger.applyBatch(_buildBatch(_internalLedger, 10));
        _externalLedger.applyBatch(_buildBatch(_externalLedger, 10));

        assertEq(_internalLedger.balances(to), 10 ether);
        assertEq(_externalLedger.balances(to), 10 ether);
        assertEq(_internalLedger.nonces(_keyHashes[0]), 2); // 10 ops over 8 signers: signers 0/1 sent twice
        assertEq(_internalLedger.nonces(_keyHashes[2]), 1);
    }

    function testApplyBatch_RevertsOnReplay() external {
        _fund(_internalLedger);
        bytes memory ops = _buildBatch(_internalLedger, 1);
        _internalLedger.applyBatch(ops);
        vm.expectRevert(abi.encodeWithSelector(DogeIntentLedgerBase.ErrorBadNonce.selector, 0));
        _internalLedger.applyBatch(ops);
    }

    function testApplyBatch_RevertsOnTamperedAmount() external {
        _fund(_internalLedger);
        bytes memory ops = _buildBatch(_internalLedger, 1);
        // amount lives at bytes [40, 56); bump the low byte (offset 55).
        ops[55] = bytes1(uint8(ops[55]) ^ 1);
        vm.expectRevert(abi.encodeWithSelector(DogeIntentLedgerBase.ErrorBadSignature.selector, 0));
        _internalLedger.applyBatch(ops);
    }

    function testApplyBatch_RevertsOnWrongLedger() external {
        // Ops signed for the internal ledger must not verify on the external one:
        // the intent hash binds the ledger address.
        _fund(_externalLedger);
        bytes memory ops = _buildBatch(_internalLedger, 1);
        vm.expectRevert(abi.encodeWithSelector(DogeIntentLedgerBase.ErrorBadSignature.selector, 0));
        _externalLedger.applyBatch(ops);
    }

    function testApplyBatch_RevertsOnInsufficientBalance() external {
        bytes memory ops = _buildBatch(_internalLedger, 1);
        vm.expectRevert(abi.encodeWithSelector(DogeIntentLedgerBase.ErrorInsufficientBalance.selector, 0));
        _internalLedger.applyBatch(ops);
    }

    function testApplyBatch_RevertsOnBadLength() external {
        vm.expectRevert(abi.encodeWithSelector(DogeIntentLedgerBase.ErrorInvalidBatchLength.selector, 0));
        _internalLedger.applyBatch("");
        bytes memory ragged = new bytes(192);
        vm.expectRevert(abi.encodeWithSelector(DogeIntentLedgerBase.ErrorInvalidBatchLength.selector, 192));
        _internalLedger.applyBatch(ragged);
    }
}

/// @notice Gas benchmarks. Run with:
///         forge test --match-contract DogeIntentBatchBenchmark -vv
contract DogeIntentBatchBenchmarkTest is DogeIntentBatchTest {
    function _bench(
        DogeIntentLedgerBase ledger,
        string memory label,
        uint256 count
    ) internal {
        _fund(ledger);
        bytes memory ops = _buildBatch(ledger, count);
        uint256 gasBefore = gasleft();
        ledger.applyBatch(ops);
        uint256 used = gasBefore - gasleft();
        console2.log(label, count, used, used / count);
    }

    function testBench_InternalVsExternal() external {
        uint256[4] memory sizes = [uint256(1), 10, 50, 100];
        console2.log("label, batch size, total gas, gas per op");
        for (uint256 i = 0; i < sizes.length; i++) {
            _bench(new DogeIntentBatchInternal(), "internal", sizes[i]);
            _bench(new DogeIntentBatchExternal(_verifier), "external", sizes[i]);
        }
    }

    function testBench_LargeBatch500() external {
        _bench(new DogeIntentBatchInternal(), "internal", 500);
        _bench(new DogeIntentBatchExternal(_verifier), "external", 500);
    }

    function testBench_Baselines() external {
        // Single external packed verification (no ledger state transitions).
        Vm.Wallet memory wallet = _wallets[0];
        bytes32 msgHash = DogeSig.dogecoinMessageHash("baseline");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKeys[0], msgHash);
        bytes memory packed = abi.encodePacked(
            _keyHashes[0],
            msgHash,
            uint8(v + 4),
            r,
            s,
            bytes32(wallet.publicKeyX),
            bytes32(wallet.publicKeyY)
        );
        uint256 gasBefore = gasleft();
        bool ok = _verifier.verifyP2PKHPacked(packed);
        uint256 used = gasBefore - gasleft();
        assertTrue(ok);
        console2.log("single external verifyP2PKHPacked:", used);

        // ERC-20 transfer baseline (cold recipient).
        _token.mint(address(this), 100 ether);
        gasBefore = gasleft();
        _token.transfer(address(0xBEEF), 1 ether);
        used = gasBefore - gasleft();
        console2.log("ERC20 transfer (cold recipient):", used);

        // Warm recipient.
        gasBefore = gasleft();
        _token.transfer(address(0xBEEF), 1 ether);
        used = gasBefore - gasleft();
        console2.log("ERC20 transfer (warm recipient):", used);
    }

    /// @dev Raw verification cost with NO ledger storage involved: one fixed valid
    ///      signature measured through (a) the internal DogeSig library (inlined -
    ///      what a hot batch path pays), (b) the predeploy's field-level ABI
    ///      entrypoint, and (c) the predeploy's packed entrypoint. The verifier
    ///      account is warmed first so (b)/(c) show the steady-state external cost;
    ///      add 2,500 gas for the first (cold) call of a transaction.
    function testBench_RawVerificationCost() external {
        Vm.Wallet memory wallet = _wallets[0];
        bytes32 msgHash = DogeSig.dogecoinMessageHash("raw verification benchmark");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKeys[0], msgHash);
        uint8 header = v + 4;
        bytes32 x = bytes32(wallet.publicKeyX);
        bytes32 y = bytes32(wallet.publicKeyY);
        bytes20 keyHash = DogeSig.p2pkhFromPubKey(x, y, true);
        bytes memory packed = abi.encodePacked(keyHash, msgHash, header, r, s, x, y);

        // warm the verifier account
        _verifier.verifyP2PKHPacked(packed);

        uint256 gasBefore = gasleft();
        bool okInternal = DogeSig.verifyP2PKH(keyHash, msgHash, header, r, s, x, y);
        uint256 usedInternal = gasBefore - gasleft();

        gasBefore = gasleft();
        bool okExternal = _verifier.verifyP2PKH(keyHash, msgHash, header, r, s, x, y);
        uint256 usedExternal = gasBefore - gasleft();

        gasBefore = gasleft();
        bool okPacked = _verifier.verifyP2PKHPacked(packed);
        uint256 usedPacked = gasBefore - gasleft();

        assertTrue(okInternal && okExternal && okPacked);
        console2.log("raw verify, internal DogeSig (inlined):", usedInternal);
        console2.log("raw verify, external ABI (warm):", usedExternal);
        console2.log("raw verify, external packed (warm):", usedPacked);
        console2.log("external call overhead vs internal:", usedExternal - usedInternal);
    }

    /// @dev Puts the batch numbers next to ordinary ways of moving DOGE on the L2.
    ///
    ///      A batched intent op pays: its share of the 21,000 intrinsic tx gas, its
    ///      exact EIP-2028 calldata gas (193 bytes/op, 16 per nonzero / 4 per zero
    ///      byte), and its measured execution gas. A standalone alternative pays a
    ///      full 21,000 intrinsic per transfer: a native DOGE send is 21,000 total
    ///      (no execution), an ERC-20 transfer adds its execution on top. N native
    ///      sends cannot be batched by users themselves - each is its own signed
    ///      transaction - which is exactly the gap the intent ledger closes.
    ///
    ///      L1 data fees are out of scope here (chain-specific), but note each
    ///      standalone tx also posts ~110+ bytes to DA vs 193 bytes per batched op.
    function testBench_PerOpVsStandaloneTransfers() external {
        uint256 count = 100;
        DogeIntentBatchInternal ledger = new DogeIntentBatchInternal();
        _fund(ledger);
        bytes memory ops = _buildBatch(ledger, count);

        uint256 gasBefore = gasleft();
        ledger.applyBatch(ops);
        uint256 execPerOp = (gasBefore - gasleft()) / count;

        // exact EIP-2028 calldata gas for the op payload
        uint256 calldataGas = 0;
        for (uint256 i = 0; i < ops.length; i++) {
            calldataGas += ops[i] == 0 ? 4 : 16;
        }
        uint256 calldataPerOp = calldataGas / count;
        uint256 batchedPerOp = 21000 / count + calldataPerOp + execPerOp;

        // standalone ERC-20 transfer tx (cold recipient) for comparison
        _token.mint(address(this), 100 ether);
        gasBefore = gasleft();
        _token.transfer(address(0xCAFE), 1 ether);
        uint256 erc20Exec = gasBefore - gasleft();

        console2.log("batched intent op: execution", execPerOp);
        console2.log("batched intent op: calldata", calldataPerOp);
        console2.log("batched intent op: total incl amortized 21k intrinsic", batchedPerOp);
        console2.log("standalone native DOGE send tx (intrinsic only):", uint256(21000));
        console2.log("standalone ERC20 transfer tx (21k + cold transfer):", 21000 + erc20Exec);
    }
}
