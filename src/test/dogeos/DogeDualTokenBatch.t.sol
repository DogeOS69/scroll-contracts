// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {console2} from "forge-std/console2.sol";

import {DogeSig} from "../../dogeos/DogeSig.sol";
import {DogeDualToken} from "../../dogeos/DogeDualToken.sol";
import {IDogeDualToken} from "../../dogeos/IDogeDualToken.sol";
import {DogeOSPredeploy} from "../../libraries/constants/DogeOSPredeploy.sol";
import {DogeDualTokenTestBase} from "./DogeDualToken.t.sol";

contract DogeDualTokenBatchTest is DogeDualTokenTestBase {
    function _packOp(IDogeDualToken.P2PKHTransferAuthorization memory auth, IDogeDualToken.DogeSignature memory sig)
        internal
        pure
        returns (bytes memory)
    {
        // split to avoid stack-too-deep; concatenation matches the 278-byte op layout
        return
            bytes.concat(
                abi.encodePacked(
                    auth.fromKeyHash,
                    auth.toKind,
                    auth.to,
                    auth.amount,
                    auth.relayerFee,
                    auth.relayerFeeRecipient
                ),
                abi.encodePacked(auth.nonce, auth.validAfter, auth.validBefore, auth.contextHash),
                abi.encodePacked(sig.header, sig.r, sig.s, sig.x, sig.y)
            );
    }

    /// @dev Builds a batch of `count` ops to `_bob`, cycling signers with per-signer
    ///      sequential nonces starting from the current on-chain nonce.
    function _buildBatch(uint256 count, uint128 amount) internal returns (bytes memory ops) {
        uint64[] memory nonceOffsets = new uint64[](SIGNER_COUNT);
        for (uint256 i = 0; i < count; i++) {
            uint256 signerIdx = i % SIGNER_COUNT;
            IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(signerIdx, 0, bytes20(_bob), amount);
            auth.nonce += nonceOffsets[signerIdx];
            nonceOffsets[signerIdx]++;
            ops = bytes.concat(ops, _packOp(auth, _signAuth(signerIdx, auth)));
        }
    }

    // --- Correctness --- //

    function testPackedOpLength() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        bytes memory op = _packOp(auth, _signAuth(0, auth));
        assertEq(op.length, DogeDualToken(DogeOSPredeploy.L2_DOGE_DUAL_TOKEN).OP_LENGTH());
        assertEq(op.length, 278);
    }

    function testBatchSingleOp() external {
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(_buildBatch(1, 1 ether));
        assertEq(count, 1);
        assertEq(_bob.balance, 1 ether);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 1);
    }

    function testBatchTenOps() external {
        // 10 ops over 8 signers: signers 0 and 1 send twice with sequential nonces
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(_buildBatch(10, 1 ether));
        assertEq(count, 10);
        assertEq(_bob.balance, 10 ether);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 2);
        assertEq(_token.nonceOfP2PKH(_keyHashes[1]), 2);
        assertEq(_token.nonceOfP2PKH(_keyHashes[2]), 1);
    }

    function testBatchSameSenderSequentialNonces() external {
        bytes memory ops;
        for (uint64 i = 0; i < 3; i++) {
            IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
            auth.nonce = i;
            ops = bytes.concat(ops, _packOp(auth, _signAuth(0, auth)));
        }
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 3);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 3);
    }

    // --- Skip semantics --- //

    function testBatchSkipsTamperedOp() external {
        bytes memory ops = _buildBatch(5, 1 ether);
        // tamper op 2's amount field (offset 2*278 + 41, high byte of uint128)
        ops[2 * 278 + 41] = bytes1(uint8(ops[2 * 278 + 41]) ^ 1);

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(2, 7); // invalid signature
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);

        assertEq(count, 4);
        assertEq(_bob.balance, 4 ether);
        assertEq(_token.nonceOfP2PKH(_keyHashes[2]), 0, "skipped signer's nonce unchanged");
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 1);
    }

    function testBatchSkipsStaleNonce() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        // consume the nonce first
        _token.transferWithP2PKHAuthorization(auth, sig);

        bytes memory ops = bytes.concat(_packOp(auth, sig), _buildBatch(1, 1 ether));
        // _buildBatch built signer 0's op with the fresh nonce (1)

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(0, 5); // bad nonce
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 1);
        assertEq(_bob.balance, 2 ether);
    }

    function testBatchSkipsExpiredOp() external {
        IDogeDualToken.P2PKHTransferAuthorization memory expired = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        expired.validBefore = uint64(block.timestamp);
        IDogeDualToken.P2PKHTransferAuthorization memory good = _defaultAuth(1, 0, bytes20(_bob), 1 ether);

        bytes memory ops = bytes.concat(_packOp(expired, _signAuth(0, expired)), _packOp(good, _signAuth(1, good)));

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(0, 3); // expired
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 1);
        assertEq(_bob.balance, 1 ether);
    }

    function testBatchSkipsInsufficientBalance() external {
        bytes memory ops = _buildBatch(2, 1 ether);
        // drain signer 0's alias after signing
        vm.deal(address(_keyHashes[0]), 0.5 ether);

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(0, 8); // insufficient balance
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 1);
        assertEq(_bob.balance, 1 ether);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 0);
    }

    function testBatchSkipsMalformedSignature() external {
        bytes memory ops = _buildBatch(2, 1 ether);
        // corrupt op 0's header byte (offset 149) to 26 - outside the valid range,
        // which DogeSig would revert on; the batch pre-check must skip instead
        ops[149] = bytes1(uint8(26));

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(0, 6); // malformed signature
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 1);
        assertEq(_bob.balance, 1 ether);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 0);
    }

    function testBatchSkipsOffCurveWitness() external {
        bytes memory ops = _buildBatch(2, 1 ether);
        // corrupt op 0's y witness (offsets 246..278): y+1 is off-curve
        uint256 yOffset = 246;
        ops[yOffset + 31] = bytes1(uint8(ops[yOffset + 31]) ^ 1);

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(0, 6); // malformed signature
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 1);
    }

    function testBatchCrossBatchReplaySkipped() external {
        bytes memory ops = _buildBatch(1, 1 ether);
        assertEq(_token.transferBatchWithP2PKHAuthorizations(ops), 1);

        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHOpSkipped(0, 5); // bad nonce
        assertEq(_token.transferBatchWithP2PKHAuthorizations(ops), 0);
        assertEq(_bob.balance, 1 ether);
    }

    function testBatchWithFees() external {
        bytes memory ops;
        for (uint256 i = 0; i < 3; i++) {
            IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(i, 0, bytes20(_bob), 1 ether);
            auth.relayerFee = 0.1 ether;
            auth.relayerFeeRecipient = _relayer;
            ops = bytes.concat(ops, _packOp(auth, _signAuth(i, auth)));
        }
        uint256 count = _token.transferBatchWithP2PKHAuthorizations(ops);
        assertEq(count, 3);
        assertEq(_bob.balance, 3 ether);
        assertEq(_relayer.balance, 0.3 ether);
    }

    function testBatchInvalidEnvelopeReverts() external {
        vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorInvalidBatchLength.selector, 0));
        _token.transferBatchWithP2PKHAuthorizations("");

        bytes memory ragged = new bytes(277);
        vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorInvalidBatchLength.selector, 277));
        _token.transferBatchWithP2PKHAuthorizations(ragged);
    }
}

/// @notice Gas benchmarks. Run with:
///         forge test --match-contract DogeDualTokenBenchmarkTest -vv
/// @dev CAVEAT: the native-transfer precompile mock moves balances via cheatcodes, so
///      these numbers EXCLUDE real precompile pricing. Celo's reference is 9,000 gas per
///      transfer — add 9k per op (18k with a relayer fee) for a Celo-priced estimate.
contract DogeDualTokenBenchmarkTest is DogeDualTokenBatchTest {
    function _calldataGas(bytes memory data) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < data.length; i++) {
            total += data[i] == 0 ? 4 : 16;
        }
    }

    function testBench_SingleAuthorizedTransfer() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        uint256 gasBefore = gasleft();
        _token.transferWithP2PKHAuthorization(auth, sig);
        uint256 used = gasBefore - gasleft();
        console2.log("single transferWithP2PKHAuthorization:", used);
    }

    function testBench_BatchSizes() external {
        uint256[4] memory sizes = [uint256(1), 10, 50, 100];
        console2.log("batch size, total gas, exec gas/op, all-in gas/op (cd + 21k amortized)");
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 n = sizes[i];
            bytes memory ops = _buildBatch(n, 1 ether);
            uint256 gasBefore = gasleft();
            _token.transferBatchWithP2PKHAuthorizations(ops);
            uint256 execTotal = gasBefore - gasleft();
            uint256 allIn = execTotal / n + _calldataGas(ops) / n + 21000 / n;
            console2.log(n, execTotal, execTotal / n, allIn);
        }
    }

    function testBench_SimpleTransfers() external {
        vm.startPrank(_alice);
        uint256 gasBefore = gasleft();
        _token.transferToP2PKH(_keyHashes[0], 1 ether);
        uint256 used = gasBefore - gasleft();
        console2.log("transferToP2PKH:", used);

        gasBefore = gasleft();
        _token.transfer(_bob, 1 ether);
        used = gasBefore - gasleft();
        console2.log("plain ERC20 transfer:", used);
        vm.stopPrank();
    }

    /// @dev Measures what the deferred human-readable message format (v2 spec in the
    ///      DogeDualToken NatSpec) would add per verification vs the raw 32-byte format.
    function testBench_MessageFormatDelta() external view {
        bytes32 intentHash = keccak256("bench");

        uint256 gasBefore = gasleft();
        DogeSig.dogecoinMessageHash(abi.encodePacked(intentHash));
        uint256 rawGas = gasBefore - gasleft();

        gasBefore = gasleft();
        bytes memory humanMessage = abi.encodePacked("DogeOS DOGE Transfer Authorization v1:0x", _toHex(intentHash));
        DogeSig.dogecoinMessageHash(humanMessage);
        uint256 humanGas = gasBefore - gasleft();

        console2.log("raw 32-byte message hash:", rawGas);
        console2.log("human-readable message hash (incl hex encode):", humanGas);
        console2.log("delta per verification:", humanGas - rawGas);
    }

    function _toHex(bytes32 value) private pure returns (bytes memory out) {
        bytes memory alphabet = "0123456789abcdef";
        out = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            out[i * 2] = alphabet[uint8(value[i]) >> 4];
            out[i * 2 + 1] = alphabet[uint8(value[i]) & 0x0f];
        }
    }
}
