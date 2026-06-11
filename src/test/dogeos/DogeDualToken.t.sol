// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DogeSig} from "../../dogeos/DogeSig.sol";
import {DogeDualToken} from "../../dogeos/DogeDualToken.sol";
import {IDogeDualToken} from "../../dogeos/IDogeDualToken.sol";
import {INativeDoge} from "../../dogeos/INativeDoge.sol";
import {DogeOSPredeploy} from "../../libraries/constants/DogeOSPredeploy.sol";
import {NativeTransferPrecompileMock} from "../mocks/NativeTransferPrecompileMock.sol";

/// @dev Recipient whose receive() reverts: duality transfers execute no recipient code,
///      so transfers to it must still succeed.
contract RevertingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev Shared harness: token + precompile mock etched at their canonical addresses
///      (the genesis topology is what's under test), Dogecoin signers via vm.createWallet.
abstract contract DogeDualTokenTestBase is Test {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SIGNER_COUNT = 8;

    IDogeDualToken internal _token;

    uint256[] internal _privateKeys;
    Vm.Wallet[] internal _wallets;
    bytes20[] internal _keyHashes;

    address internal _alice = makeAddr("alice");
    address internal _bob = makeAddr("bob");
    address internal _relayer = makeAddr("relayer");

    function setUp() public virtual {
        // foundry.toml pins block.timestamp = 0; the validity window uses exclusive
        // bounds, so move to a realistic timestamp.
        vm.warp(1_700_000_000);

        DogeDualToken tokenImpl = new DogeDualToken();
        vm.etch(DogeOSPredeploy.L2_DOGE_DUAL_TOKEN, address(tokenImpl).code);
        _token = IDogeDualToken(DogeOSPredeploy.L2_DOGE_DUAL_TOKEN);

        NativeTransferPrecompileMock mockImpl = new NativeTransferPrecompileMock();
        vm.etch(DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE, address(mockImpl).code);

        for (uint256 i = 0; i < SIGNER_COUNT; i++) {
            uint256 pk = 0xD06E + i;
            Vm.Wallet memory wallet = vm.createWallet(pk);
            _privateKeys.push(pk);
            _wallets.push(wallet);
            bytes20 keyHash = DogeSig.p2pkhFromPubKey(bytes32(wallet.publicKeyX), bytes32(wallet.publicKeyY), true);
            _keyHashes.push(keyHash);
            vm.deal(address(keyHash), 1000 ether);
        }
        vm.deal(_alice, 1000 ether);
    }

    // --- Authorization helpers --- //

    function _defaultAuth(
        uint256 signerIdx,
        uint8 toKind,
        bytes20 to,
        uint128 amount
    ) internal view returns (IDogeDualToken.P2PKHTransferAuthorization memory auth) {
        auth = IDogeDualToken.P2PKHTransferAuthorization({
            fromKeyHash: _keyHashes[signerIdx],
            toKind: toKind,
            to: to,
            amount: amount,
            relayerFee: 0,
            relayerFeeRecipient: address(0),
            nonce: _token.nonceOfP2PKH(_keyHashes[signerIdx]),
            validAfter: 0,
            validBefore: type(uint64).max,
            contextHash: bytes32(0)
        });
    }

    function _intentHashOf(IDogeDualToken.P2PKHTransferAuthorization memory auth) internal view returns (bytes32) {
        return _intentHashFor(auth, address(_token));
    }

    function _intentHashFor(IDogeDualToken.P2PKHTransferAuthorization memory auth, address tokenAddress)
        internal
        view
        returns (bytes32)
    {
        // two-half encoding mirrors DogeDualToken._intentHash (byte-identical for
        // static types) and avoids stack-too-deep
        return
            keccak256(
                bytes.concat(
                    abi.encode(
                        DogeDualToken(DogeOSPredeploy.L2_DOGE_DUAL_TOKEN).P2PKH_TRANSFER_AUTHORIZATION_TYPEHASH(),
                        block.chainid,
                        tokenAddress,
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

    function _signAuth(uint256 signerIdx, IDogeDualToken.P2PKHTransferAuthorization memory auth)
        internal
        returns (IDogeDualToken.DogeSignature memory sig)
    {
        return _signIntentHash(signerIdx, _intentHashOf(auth));
    }

    function _signIntentHash(uint256 signerIdx, bytes32 intentHash)
        internal
        returns (IDogeDualToken.DogeSignature memory sig)
    {
        bytes32 msgHash = DogeSig.dogecoinMessageHash(abi.encodePacked(intentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKeys[signerIdx], msgHash);
        sig = IDogeDualToken.DogeSignature({
            header: v + 4, // compressed key
            r: r,
            s: s,
            x: bytes32(_wallets[signerIdx].publicKeyX),
            y: bytes32(_wallets[signerIdx].publicKeyY)
        });
    }
}

contract DogeDualTokenTest is DogeDualTokenTestBase {
    // --- ERC-20 / INativeDoge conformance --- //

    function testMetadata() external view {
        assertEq(_token.name(), "Dogecoin");
        assertEq(_token.symbol(), "DOGE");
        assertEq(_token.decimals(), 18);
        assertEq(_token.totalSupply(), 0);
    }

    function testFuzz_BalanceOfIsNativeBalance(address account, uint256 balance) external {
        vm.assume(account != address(0));
        balance = bound(balance, 0, type(uint128).max);
        vm.deal(account, balance);
        assertEq(_token.balanceOf(account), balance);
        assertEq(_token.balanceOf(account), account.balance);
    }

    function testTransfer() external {
        vm.prank(_alice);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(_alice, _bob, 30 ether);
        assertTrue(_token.transfer(_bob, 30 ether));
        assertEq(_alice.balance, 970 ether);
        assertEq(_bob.balance, 30 ether);
    }

    function testTransferDoesNotExecuteRecipientCode() external {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.prank(_alice);
        assertTrue(_token.transfer(address(receiver), 5 ether));
        assertEq(address(receiver).balance, 5 ether);
    }

    function testTransferToZeroReverts() external {
        vm.prank(_alice);
        vm.expectRevert(DogeDualToken.ErrorTransferToZeroAddress.selector);
        _token.transfer(address(0), 1 ether);

        vm.prank(_alice);
        vm.expectRevert(DogeDualToken.ErrorTransferToZeroAddress.selector);
        _token.transfer(address(0), 0);
    }

    function testTransferInsufficientBalanceReverts() external {
        vm.prank(_alice);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorNativeTransferFailed.selector, _alice, _bob, 1001 ether)
        );
        _token.transfer(_bob, 1001 ether);
    }

    function testApproveAndTransferFrom() external {
        vm.prank(_alice);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Approval(_alice, _bob, 25 ether);
        assertTrue(_token.approve(_bob, 25 ether));
        assertEq(_token.allowance(_alice, _bob), 25 ether);

        vm.prank(_bob);
        assertTrue(_token.transferFrom(_alice, _bob, 10 ether));
        assertEq(_alice.balance, 990 ether);
        assertEq(_bob.balance, 10 ether);
        assertEq(_token.allowance(_alice, _bob), 15 ether);
    }

    function testTransferFromInfiniteAllowanceNotDecremented() external {
        vm.prank(_alice);
        _token.approve(_bob, type(uint256).max);
        vm.prank(_bob);
        _token.transferFrom(_alice, _bob, 10 ether);
        assertEq(_token.allowance(_alice, _bob), type(uint256).max);
    }

    function testTransferFromInsufficientAllowanceReverts() external {
        vm.prank(_alice);
        _token.approve(_bob, 5 ether);
        vm.prank(_bob);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorInsufficientAllowance.selector, _alice, _bob, 5 ether, 6 ether)
        );
        _token.transferFrom(_alice, _bob, 6 ether);
    }

    function testZeroAddressPolicy() external {
        vm.startPrank(_alice);
        vm.expectRevert(DogeDualToken.ErrorApproveToZeroAddress.selector);
        _token.approve(address(0), 1 ether);

        _token.approve(_bob, 1 ether);
        vm.stopPrank();

        vm.startPrank(_bob);
        vm.expectRevert(DogeDualToken.ErrorTransferToZeroAddress.selector);
        _token.transferFrom(_alice, address(0), 1 ether);

        vm.expectRevert(DogeDualToken.ErrorTransferFromZeroAddress.selector);
        _token.transferFrom(address(0), _bob, 1 ether);

        // the from == 0 check fires even for zero amounts
        vm.expectRevert(DogeDualToken.ErrorTransferFromZeroAddress.selector);
        _token.transferFrom(address(0), _bob, 0);
        vm.stopPrank();
    }

    function testFuzz_TransferConservesTotal(uint256 amount) external {
        amount = bound(amount, 0, 1000 ether);
        uint256 totalBefore = _alice.balance + _bob.balance;
        vm.prank(_alice);
        _token.transfer(_bob, amount);
        assertEq(_alice.balance + _bob.balance, totalBefore);
    }

    // --- P2PKH views --- //

    function testFuzz_AliasEquality(bytes20 keyHash, uint256 balance) external {
        balance = bound(balance, 0, type(uint128).max);
        vm.assume(uint160(keyHash) != 0);
        vm.deal(address(keyHash), balance);
        assertEq(_token.evmAliasOfP2PKH(keyHash), address(keyHash));
        assertEq(_token.balanceOfP2PKH(keyHash), _token.balanceOf(_token.evmAliasOfP2PKH(keyHash)));
    }

    function testNonceLifecycle() external {
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 0);
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        _token.transferWithP2PKHAuthorization(auth, sig);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 1);
    }

    // --- transferToP2PKH --- //

    function testTransferToP2PKH() external {
        bytes20 toKeyHash = _keyHashes[1];
        uint256 before = address(toKeyHash).balance;
        vm.prank(_alice);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(_alice, address(toKeyHash), 7 ether);
        vm.expectEmit(true, true, false, true);
        emit IDogeDualToken.TransferToP2PKH(_alice, toKeyHash, address(toKeyHash), 7 ether);
        assertTrue(_token.transferToP2PKH(toKeyHash, 7 ether));
        assertEq(_token.balanceOfP2PKH(toKeyHash), before + 7 ether);
    }

    function testTransferToP2PKH_ReservedAliasReverts() external {
        bytes20[3] memory reserved = [
            bytes20(uint160(0x5300000000000000000000000000000000000004)), // WDOGE predeploy
            bytes20(uint160(0xfd)), // native-transfer precompile
            bytes20(0) // zero address
        ];
        for (uint256 i = 0; i < reserved.length; i++) {
            vm.prank(_alice);
            vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorReservedAlias.selector, address(reserved[i])));
            _token.transferToP2PKH(reserved[i], 1 ether);
        }
    }

    // --- Reserved-mask boundaries (probed via transferToP2PKH) --- //

    function testReservedMaskBoundaries() external {
        // reserved: low band upper edge, namespace lower and upper edges, token itself
        bytes20[4] memory reserved = [
            bytes20(uint160(0xffff)),
            bytes20(uint160(0x5300000000000000000000000000000000000000)),
            bytes20(uint160(0x530000000000000000000000000000000000fffF)),
            bytes20(DogeOSPredeploy.L2_DOGE_DUAL_TOKEN)
        ];
        for (uint256 i = 0; i < reserved.length; i++) {
            vm.prank(_alice);
            vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorReservedAlias.selector, address(reserved[i])));
            _token.transferToP2PKH(reserved[i], 1 ether);
        }

        // not reserved: just above the low band, just outside the namespace either side
        bytes20[3] memory open = [
            bytes20(uint160(0x10000)),
            bytes20(uint160(0x5300000000000000000000000000000000010000)),
            bytes20(uint160(0x52FFFffFffFfffFFFFffffFffffffFFffffFFffF))
        ];
        for (uint256 i = 0; i < open.length; i++) {
            vm.prank(_alice);
            assertTrue(_token.transferToP2PKH(open[i], 1 ether));
        }
    }

    // --- transferWithP2PKHAuthorization: positives --- //

    function testAuthorizedTransferToEVM() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 10 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        bytes32 intentHash = _intentHashOf(auth);

        vm.prank(_relayer);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(address(_keyHashes[0]), _bob, 10 ether);
        vm.expectEmit(true, true, false, true);
        emit IDogeDualToken.TransferFromP2PKHToAddress(_keyHashes[0], _bob, 10 ether, 0, _relayer);
        vm.expectEmit(true, false, false, true);
        emit IDogeDualToken.P2PKHAuthorizationUsed(_keyHashes[0], 0, intentHash);
        _token.transferWithP2PKHAuthorization(auth, sig);

        assertEq(_bob.balance, 10 ether);
        assertEq(_token.balanceOfP2PKH(_keyHashes[0]), 990 ether);
        assertEq(_token.nonceOfP2PKH(_keyHashes[0]), 1);
    }

    function testAuthorizedTransferToP2PKH() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 1, _keyHashes[1], 10 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);

        vm.expectEmit(true, true, false, true);
        emit IDogeDualToken.TransferFromP2PKHToP2PKH(_keyHashes[0], _keyHashes[1], 10 ether, 0, address(this));
        _token.transferWithP2PKHAuthorization(auth, sig);
        assertEq(_token.balanceOfP2PKH(_keyHashes[1]), 1010 ether);
    }

    function testAuthorizedTransferWithExplicitFeeRecipient() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 10 ether);
        auth.relayerFee = 1 ether;
        auth.relayerFeeRecipient = _relayer;
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);

        // both the amount and the fee moves emit ERC-20 Transfer logs
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(address(_keyHashes[0]), _bob, 10 ether);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(address(_keyHashes[0]), _relayer, 1 ether);
        _token.transferWithP2PKHAuthorization(auth, sig);
        assertEq(_bob.balance, 10 ether);
        assertEq(_relayer.balance, 1 ether);
        assertEq(_token.balanceOfP2PKH(_keyHashes[0]), 989 ether);
    }

    function testAuthorizedTransferFeeDefaultsToMsgSender() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 10 ether);
        auth.relayerFee = 1 ether;
        // relayerFeeRecipient stays address(0) => fee to msg.sender
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);

        vm.prank(_relayer);
        vm.expectEmit(true, true, false, true);
        emit INativeDoge.Transfer(address(_keyHashes[0]), _relayer, 1 ether);
        _token.transferWithP2PKHAuthorization(auth, sig);
        assertEq(_relayer.balance, 1 ether);
    }

    /// @dev Funds received at a P2PKH alias are spendable by that key with its own nonce.
    function testChainedP2PKHTransfers() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 1, _keyHashes[1], 10 ether);
        _token.transferWithP2PKHAuthorization(auth, _signAuth(0, auth));

        IDogeDualToken.P2PKHTransferAuthorization memory auth2 = _defaultAuth(1, 0, bytes20(_bob), 1005 ether);
        _token.transferWithP2PKHAuthorization(auth2, _signAuth(1, auth2));
        assertEq(_bob.balance, 1005 ether);
    }

    /// @dev Dogecoin Core parity: the malleated twin (n - s, flipped recId) verifies —
    ///      and the nonce blocks using it as a replay.
    function testMalleatedTwinAcceptedThenNonceBlocked() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);

        uint8 code = sig.header - 27;
        sig.s = bytes32(SECP256K1_N - uint256(sig.s));
        sig.header = 27 + ((code & 3) ^ 1) + (code >= 4 ? 4 : 0);

        _token.transferWithP2PKHAuthorization(auth, sig);
        assertEq(_bob.balance, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorInvalidNonce.selector, 1, 0));
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    // --- transferWithP2PKHAuthorization: negatives --- //

    function testRevertWrongNonce() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        auth.nonce = 5;
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorInvalidNonce.selector, 0, 5));
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertReplay() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        _token.transferWithP2PKHAuthorization(auth, sig);
        vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorInvalidNonce.selector, 1, 0));
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    /// @dev provided == uint64.max is rejected even when it equals the stored nonce
    ///      (the post-use increment would overflow).
    function testRevertMaxNonceGuard() external {
        bytes20 keyHash = _keyHashes[0];
        // _p2pkhNonces lives at slot 1; bytes20 keys are left-aligned in the hashed word
        bytes32 slot = keccak256(abi.encode(keyHash, uint256(1)));
        vm.store(DogeOSPredeploy.L2_DOGE_DUAL_TOKEN, slot, bytes32(uint256(type(uint64).max)));
        assertEq(_token.nonceOfP2PKH(keyHash), type(uint64).max);

        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        assertEq(auth.nonce, type(uint64).max);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorInvalidNonce.selector, type(uint64).max, type(uint64).max)
        );
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertExpired() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        auth.validBefore = uint64(block.timestamp); // exclusive bound
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(DogeDualToken.ErrorAuthorizationExpired.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertNotYetValid() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        auth.validAfter = uint64(block.timestamp); // exclusive bound
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(DogeDualToken.ErrorAuthorizationNotYetValid.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertInvalidToKind() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 2, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(abi.encodeWithSelector(DogeDualToken.ErrorInvalidToKind.selector, 2));
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertWrongChainDomain() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(DogeDualToken.ErrorInvalidSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertWrongTokenDomain() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        // sign an intent bound to a different token address
        IDogeDualToken.DogeSignature memory sig = _signIntentHash(0, _intentHashFor(auth, address(0xDEAD)));
        vm.expectRevert(DogeDualToken.ErrorInvalidSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertTamperedAmount() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        auth.amount = 2 ether;
        vm.expectRevert(DogeDualToken.ErrorInvalidSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertTamperedSignature() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        sig.s = bytes32(uint256(sig.s) ^ 1);
        vm.expectRevert(DogeDualToken.ErrorInvalidSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertWrongWitness() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        // another signer's valid on-curve pubkey
        sig.x = bytes32(_wallets[1].publicKeyX);
        sig.y = bytes32(_wallets[1].publicKeyY);
        vm.expectRevert(DogeDualToken.ErrorInvalidSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertMalformedHeader() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        sig.header = 26;
        vm.expectRevert(DogeDualToken.ErrorMalformedSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);

        sig.header = 29; // recId 2
        vm.expectRevert(DogeDualToken.ErrorMalformedSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertOffCurveWitness() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        sig.y = bytes32(uint256(sig.y) + 1);
        vm.expectRevert(DogeDualToken.ErrorMalformedSignature.selector);
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertReservedRecipient() external {
        // EVM-kind reserved recipient
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(
            0,
            0,
            bytes20(uint160(0x5300000000000000000000000000000000000004)),
            1 ether
        );
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(
            abi.encodeWithSelector(
                DogeDualToken.ErrorReservedAuthorizationTarget.selector,
                address(uint160(0x5300000000000000000000000000000000000004))
            )
        );
        _token.transferWithP2PKHAuthorization(auth, sig);

        // P2PKH-kind reserved recipient
        auth = _defaultAuth(0, 1, bytes20(uint160(0xfd)), 1 ether);
        sig = _signAuth(0, auth);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorReservedAuthorizationTarget.selector, address(uint160(0xfd)))
        );
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertReservedFeeRecipient() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1 ether);
        auth.relayerFee = 1 ether;
        auth.relayerFeeRecipient = address(uint160(0x5300000000000000000000000000000000000002));
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorReservedAuthorizationTarget.selector, auth.relayerFeeRecipient)
        );
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    function testRevertInsufficientBalanceWithFee() external {
        IDogeDualToken.P2PKHTransferAuthorization memory auth = _defaultAuth(0, 0, bytes20(_bob), 1000 ether);
        auth.relayerFee = 1 ether; // amount alone fits, amount + fee does not
        IDogeDualToken.DogeSignature memory sig = _signAuth(0, auth);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorInsufficientBalance.selector, 1000 ether, 1001 ether)
        );
        _token.transferWithP2PKHAuthorization(auth, sig);
    }

    // --- Environment failures --- //

    function testMockRejectsNonTokenCaller() external {
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(_alice, _bob, uint256(1 ether))
        );
        assertFalse(success);
        assertEq(bytes4(ret), NativeTransferPrecompileMock.ErrorUnauthorizedCaller.selector);
    }

    function testMissingPrecompileFailsLoudly() external {
        vm.etch(DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE, "");
        vm.prank(_alice);
        vm.expectRevert(
            abi.encodeWithSelector(DogeDualToken.ErrorNativeTransferFailed.selector, _alice, _bob, 1 ether)
        );
        _token.transfer(_bob, 1 ether);
    }
}
