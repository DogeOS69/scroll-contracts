// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

import {NativeDogeToken} from "../../dogeos/NativeDogeToken.sol";
import {DogeOSPredeploy} from "../../libraries/constants/DogeOSPredeploy.sol";
import {NativeTransferPrecompileMock} from "../mocks/NativeTransferPrecompileMock.sol";
import {GenerateGenesis} from "../../../scripts/deterministic/GenerateGenesis.s.sol";
import {NativeDogeSupplyConfig} from "../../../scripts/deterministic/NativeDogeSupplyConfig.sol";

contract HookReceiver {
    uint256 public receiveCount;
    uint256 public fallbackCount;

    receive() external payable {
        receiveCount++;
    }

    fallback() external payable {
        fallbackCount++;
    }
}

contract NativeTransferPrecompileCaller {
    function callNativeTransfer(bytes memory input) external returns (bool success, bytes memory ret) {
        return DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(input);
    }
}

contract RevertingNativeTransferPrecompileMock {
    error ErrorMockRevert();

    fallback() external {
        revert ErrorMockRevert();
    }
}

contract GenerateGenesisHarness is GenerateGenesis {
    function configure(
        uint256 maxNativeDogeSupply,
        uint256 deployerInitialBalance,
        address messenger,
        address deployer,
        string memory configToml
    ) external {
        L2_MAX_NATIVE_DOGE_SUPPLY = maxNativeDogeSupply;
        L2_DEPLOYER_INITIAL_BALANCE = deployerInitialBalance;
        L2_DOGEOS_MESSENGER_INITIAL_BALANCE = maxNativeDogeSupply - deployerInitialBalance;
        L2_DOGEOS_MESSENGER_PROXY_ADDR = messenger;
        DEPLOYER_ADDR = deployer;
        cfg = configToml;
    }

    function exposedSetL2NativeDogeToken() external {
        setL2NativeDogeToken();
    }

    function exposedSetL2DogeOsMessenger() external {
        setL2DogeOsMessenger();
    }

    function exposedSetL2Deployer() external {
        setL2Deployer();
    }

    function l2DogeOsMessengerInitialBalance() external view returns (uint256) {
        return L2_DOGEOS_MESSENGER_INITIAL_BALANCE;
    }
}

contract NativeDogeSupplyConfigHarness is NativeDogeSupplyConfig {
    function exposedReadL2MaxNativeDogeSupply(string memory configToml) external view returns (uint256) {
        return readL2MaxNativeDogeSupply(configToml);
    }
}

contract NativeDogeTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 2**247;
    uint256 internal constant ALICE_INITIAL_BALANCE = 100 ether;
    uint256 internal constant BOB_INITIAL_BALANCE = 5 ether;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);

    NativeDogeToken internal _token;

    function setUp() public {
        _token = _etchNativeDogeToken(SUPPLY);
        _etchNativeTransferPrecompile();

        vm.deal(ALICE, ALICE_INITIAL_BALANCE);
        vm.deal(BOB, BOB_INITIAL_BALANCE);
    }

    function test_metadata() external view {
        assertEq(_token.name(), "Dogecoin");
        assertEq(_token.symbol(), "DOGE");
        assertEq(_token.decimals(), 18);
    }

    function test_predeployAddressIsProtocolConstant() external pure {
        assertEq(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN, 0x530000000000000000000000000000000000d09e);
    }

    function test_totalSupply_returnsGenesisConfiguredSupply() external view {
        assertEq(_token.totalSupply(), SUPPLY);
    }

    function test_totalSupply_revertsIfGenesisSlotNotInitialized() external {
        vm.store(address(_token), bytes32(uint256(0)), bytes32(0));

        vm.expectRevert(NativeDogeToken.ErrorTotalSupplyUninitialized.selector);
        _token.totalSupply();
    }

    function test_constructorRejectsZeroSupply() external {
        vm.expectRevert(NativeDogeToken.ErrorTotalSupplyUninitialized.selector);
        new NativeDogeToken(0);
    }

    function test_balanceOfEqualsNativeBalance() external view {
        assertEq(_token.balanceOf(ALICE), ALICE.balance);
        assertEq(_token.balanceOf(BOB), BOB.balance);
    }

    function test_rawNativeTransferChangesBalanceOf() external {
        vm.prank(ALICE);
        (bool ok, ) = BOB.call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(_token.balanceOf(ALICE), ALICE.balance);
        assertEq(_token.balanceOf(BOB), BOB.balance);
    }

    function test_transferMovesNativeBalance() external {
        vm.prank(ALICE);
        bool ok = _token.transfer(BOB, 3 ether);

        assertTrue(ok);
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE - 3 ether);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE + 3 ether);
    }

    function test_transferEmitsTransferEvent() external {
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(ALICE, BOB, 4 ether);
        _token.transfer(BOB, 4 ether);
    }

    function test_transferReturnsTrue() external {
        vm.prank(ALICE);
        assertTrue(_token.transfer(BOB, 1 ether));
    }

    function test_transferZeroAmountIsNormalTransfer() external {
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(ALICE, BOB, 0);
        assertTrue(_token.transfer(BOB, 0));

        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE);
    }

    function test_transferToZeroAddressReverts() external {
        vm.prank(ALICE);
        vm.expectRevert(NativeDogeToken.ErrorTransferToZeroAddress.selector);
        _token.transfer(address(0), 1 ether);
    }

    function test_transferInsufficientBalanceReverts() external {
        vm.deal(ALICE, 1 ether);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(NativeDogeToken.ErrorInsufficientBalance.selector, ALICE, 1 ether, 2 ether)
        );
        _token.transfer(BOB, 2 ether);
    }

    function test_transferToContractDoesNotExecuteReceiveOrFallback() external {
        HookReceiver receiver = new HookReceiver();

        vm.prank(ALICE);
        _token.transfer(address(receiver), 2 ether);

        assertEq(address(receiver).balance, 2 ether);
        assertEq(receiver.receiveCount(), 0);
        assertEq(receiver.fallbackCount(), 0);
    }

    function test_transferToSameAddressNoNetBalanceChange() external {
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(ALICE, ALICE, 3 ether);
        _token.transfer(ALICE, 3 ether);

        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
    }

    function test_transferSucceedsOnEmptyPrecompileReturnData() external {
        vm.prank(ALICE);
        bool ok = _token.transfer(BOB, 1 ether);

        assertTrue(ok);
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE - 1 ether);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE + 1 ether);
    }

    function test_transferRevertsWhenPrecompileCallRevertsAndPreservesBalances() external {
        _etchPrecompile(address(new RevertingNativeTransferPrecompileMock()));

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(NativeDogeToken.ErrorNativeTransferFailed.selector, ALICE, BOB, 1 ether)
        );
        _token.transfer(BOB, 1 ether);

        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE);
    }

    function test_approveSetsAllowance() external {
        vm.prank(ALICE);
        assertTrue(_token.approve(SPENDER, 10 ether));

        assertEq(_token.allowance(ALICE, SPENDER), 10 ether);
    }

    function test_approveOverwritesAllowance() external {
        vm.startPrank(ALICE);
        _token.approve(SPENDER, 10 ether);
        _token.approve(SPENDER, 4 ether);
        vm.stopPrank();

        assertEq(_token.allowance(ALICE, SPENDER), 4 ether);
    }

    function test_approveEmitsApproval() external {
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Approval(ALICE, SPENDER, 7 ether);
        _token.approve(SPENDER, 7 ether);
    }

    function test_approveZeroSpenderReverts() external {
        vm.prank(ALICE);
        vm.expectRevert(NativeDogeToken.ErrorApproveToZeroAddress.selector);
        _token.approve(address(0), 1 ether);
    }

    function test_approveZeroAmountAllowedForNonzeroSpender() external {
        vm.prank(ALICE);
        assertTrue(_token.approve(SPENDER, 0));

        assertEq(_token.allowance(ALICE, SPENDER), 0);
    }

    function test_transferFromMovesNativeBalance() external {
        _approveAliceToSpender(10 ether);

        vm.prank(SPENDER);
        assertTrue(_token.transferFrom(ALICE, BOB, 3 ether));

        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE - 3 ether);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE + 3 ether);
    }

    function test_transferFromDecrementsFiniteAllowance() external {
        _approveAliceToSpender(10 ether);

        vm.prank(SPENDER);
        _token.transferFrom(ALICE, BOB, 3 ether);

        assertEq(_token.allowance(ALICE, SPENDER), 7 ether);
    }

    function test_transferFromDoesNotDecrementInfiniteAllowance() external {
        _approveAliceToSpender(type(uint256).max);

        vm.prank(SPENDER);
        _token.transferFrom(ALICE, BOB, 3 ether);

        assertEq(_token.allowance(ALICE, SPENDER), type(uint256).max);
    }

    function test_transferFromEmitsTransferEvent() external {
        _approveAliceToSpender(10 ether);

        vm.prank(SPENDER);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(ALICE, BOB, 3 ether);
        _token.transferFrom(ALICE, BOB, 3 ether);
    }

    function test_transferFromZeroAmountIsNormalTransfer() external {
        _approveAliceToSpender(0);

        vm.prank(SPENDER);
        vm.expectEmit(true, true, false, true, address(_token));
        emit Transfer(ALICE, BOB, 0);
        assertTrue(_token.transferFrom(ALICE, BOB, 0));

        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE);
    }

    function test_transferFromInsufficientAllowanceReverts() external {
        _approveAliceToSpender(1 ether);

        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                NativeDogeToken.ErrorInsufficientAllowance.selector,
                ALICE,
                SPENDER,
                1 ether,
                2 ether
            )
        );
        _token.transferFrom(ALICE, BOB, 2 ether);
    }

    function test_transferFromInsufficientBalanceReverts() external {
        vm.deal(ALICE, 1 ether);
        _approveAliceToSpender(3 ether);

        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(NativeDogeToken.ErrorInsufficientBalance.selector, ALICE, 1 ether, 2 ether)
        );
        _token.transferFrom(ALICE, BOB, 2 ether);

        assertEq(_token.allowance(ALICE, SPENDER), 3 ether);
    }

    function test_transferFromRevertsWhenPrecompileCallRevertsAndPreservesState() external {
        _approveAliceToSpender(3 ether);
        _etchPrecompile(address(new RevertingNativeTransferPrecompileMock()));

        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(NativeDogeToken.ErrorNativeTransferFailed.selector, ALICE, BOB, 1 ether)
        );
        _token.transferFrom(ALICE, BOB, 1 ether);

        assertEq(_token.allowance(ALICE, SPENDER), 3 ether);
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE);
    }

    function test_transferFromZeroFromReverts() external {
        vm.prank(SPENDER);
        vm.expectRevert(NativeDogeToken.ErrorTransferFromZeroAddress.selector);
        _token.transferFrom(address(0), BOB, 1 ether);
    }

    function test_transferFromZeroToReverts() external {
        _approveAliceToSpender(1 ether);

        vm.prank(SPENDER);
        vm.expectRevert(NativeDogeToken.ErrorTransferToZeroAddress.selector);
        _token.transferFrom(ALICE, address(0), 1 ether);
    }

    function test_transferFromToContractDoesNotExecuteReceiveOrFallback() external {
        HookReceiver receiver = new HookReceiver();
        _approveAliceToSpender(3 ether);

        vm.prank(SPENDER);
        _token.transferFrom(ALICE, address(receiver), 2 ether);

        assertEq(address(receiver).balance, 2 ether);
        assertEq(receiver.receiveCount(), 0);
        assertEq(receiver.fallbackCount(), 0);
    }

    function test_precompileDirectCallFromEOAReverts() external {
        vm.prank(ALICE);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(ALICE, BOB, 1 ether)
        );

        assertFalse(success);
        assertEq(bytes4(ret), NativeTransferPrecompileMock.ErrorUnauthorizedCaller.selector);
    }

    function test_precompileDirectCallFromArbitraryContractReverts() external {
        NativeTransferPrecompileCaller caller = new NativeTransferPrecompileCaller();

        (bool success, bytes memory ret) = caller.callNativeTransfer(abi.encode(ALICE, BOB, 1 ether));

        assertFalse(success);
        assertEq(bytes4(ret), NativeTransferPrecompileMock.ErrorUnauthorizedCaller.selector);
    }

    function test_precompileMalformedInputReverts() external {
        vm.prank(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(hex"01");

        assertFalse(success);
        assertEq(bytes4(ret), NativeTransferPrecompileMock.ErrorInvalidInputLength.selector);
    }

    function test_precompileInsufficientBalanceReverts() external {
        vm.deal(ALICE, 1 ether);

        vm.prank(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(ALICE, BOB, 2 ether)
        );

        assertFalse(success);
        assertEq(bytes4(ret), NativeTransferPrecompileMock.ErrorInsufficientBalance.selector);
        assertEq(ALICE.balance, 1 ether);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE);
    }

    function test_precompileReturnsEmptySuccessData() external {
        uint256 amount = 2 ether;

        vm.prank(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(ALICE, BOB, amount)
        );

        assertTrue(success);
        assertEq(ret, bytes(""));
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE - amount);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE + amount);
    }

    function test_precompileZeroAmountSucceedsWithNoBalanceChange() external {
        vm.prank(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(abi.encode(ALICE, BOB, 0));

        assertTrue(success);
        assertEq(ret, bytes(""));
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
        assertEq(BOB.balance, BOB_INITIAL_BALANCE);
    }

    function test_precompileFromToSameAddressSucceedsWithNoNetBalanceChange() external {
        vm.prank(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(ALICE, ALICE, 3 ether)
        );

        assertTrue(success);
        assertEq(ret, bytes(""));
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE);
    }

    function test_precompileToContractDoesNotExecuteReceiveOrFallback() external {
        HookReceiver receiver = new HookReceiver();

        vm.prank(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN);
        (bool success, bytes memory ret) = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE.call(
            abi.encode(ALICE, address(receiver), 2 ether)
        );

        assertTrue(success);
        assertEq(ret, bytes(""));
        assertEq(ALICE.balance, ALICE_INITIAL_BALANCE - 2 ether);
        assertEq(address(receiver).balance, 2 ether);
        assertEq(receiver.receiveCount(), 0);
        assertEq(receiver.fallbackCount(), 0);
    }

    function test_generateGenesisEtchesNativeDogeToken() external {
        GenerateGenesisHarness harness = _configuredGenesisHarness();

        vm.etch(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN, "");
        harness.exposedSetL2NativeDogeToken();

        assertGt(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN.code.length, 0);
    }

    function test_generateGenesisEtchesNativeDogeTokenRuntimeBytecode() external {
        GenerateGenesisHarness harness = _configuredGenesisHarness();
        NativeDogeToken impl = new NativeDogeToken(SUPPLY);
        bytes memory expectedRuntimeBytecode = address(impl).code;

        vm.etch(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN, "");
        harness.exposedSetL2NativeDogeToken();

        assertEq(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN.code, expectedRuntimeBytecode);
    }

    function test_generateGenesisSetsNativeDogeTotalSupplySlot() external {
        GenerateGenesisHarness harness = _configuredGenesisHarness();

        harness.exposedSetL2NativeDogeToken();

        assertEq(NativeDogeToken(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN).totalSupply(), SUPPLY);
        assertEq(vm.load(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN, bytes32(uint256(0))), bytes32(SUPPLY));
        assertEq(NativeDogeToken(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN).allowance(ALICE, SPENDER), 0);
    }

    function test_generateGenesisFundsMessengerWithMaxMinusPrefunds() external {
        GenerateGenesisHarness harness = _configuredGenesisHarness();
        address messenger = address(0x5300);

        harness.exposedSetL2DogeOsMessenger();

        assertEq(messenger.balance, SUPPLY - 1 ether);
        assertEq(messenger.balance, harness.l2DogeOsMessengerInitialBalance());
    }

    function test_generateGenesisFundsDeployer() external {
        GenerateGenesisHarness harness = _configuredGenesisHarness();
        address deployer = address(0xD390);

        harness.exposedSetL2Deployer();

        assertEq(deployer.balance, 1 ether);
    }

    function test_generateGenesisNativeSupplyInvariant() external {
        GenerateGenesisHarness harness = _configuredGenesisHarness();
        address messenger = address(0x5300);
        address deployer = address(0xD390);

        harness.exposedSetL2NativeDogeToken();
        harness.exposedSetL2DogeOsMessenger();
        harness.exposedSetL2Deployer();

        uint256 sum = messenger.balance + deployer.balance;
        assertEq(NativeDogeToken(DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN).totalSupply(), SUPPLY);
        assertEq(sum, SUPPLY);
    }

    function test_generateGenesisMissingNativeTokenOverrideReverts() external {
        GenerateGenesisHarness harness = new GenerateGenesisHarness();
        harness.configure(SUPPLY, 1 ether, address(0x5300), address(0xD390), "[contracts.overrides]\n");

        vm.expectRevert("L2_NATIVE_DOGE_TOKEN override missing from config.toml [contracts.overrides]");
        harness.exposedSetL2NativeDogeToken();
    }

    function test_generateGenesisWrongNativeTokenOverrideReverts() external {
        GenerateGenesisHarness harness = new GenerateGenesisHarness();
        harness.configure(
            SUPPLY,
            1 ether,
            address(0x5300),
            address(0xD390),
            string(
                abi.encodePacked(
                    "[contracts.overrides]\n",
                    'L2_NATIVE_DOGE_TOKEN = "0x530000000000000000000000000000000000d09f"\n'
                )
            )
        );

        vm.expectRevert("L2_NATIVE_DOGE_TOKEN override must match DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN");
        harness.exposedSetL2NativeDogeToken();
    }

    function test_readNativeDogeSupplyUsesNativeKey() external {
        NativeDogeSupplyConfigHarness harness = new NativeDogeSupplyConfigHarness();

        uint256 supply = harness.exposedReadL2MaxNativeDogeSupply('[genesis]\nL2_MAX_NATIVE_DOGE_SUPPLY = "12345"\n');

        assertEq(supply, 12345);
    }

    function test_readNativeDogeSupplyAllowsLegacyEthAlias() external {
        NativeDogeSupplyConfigHarness harness = new NativeDogeSupplyConfigHarness();

        uint256 supply = harness.exposedReadL2MaxNativeDogeSupply('[genesis]\nL2_MAX_ETH_SUPPLY = "12345"\n');

        assertEq(supply, 12345);
    }

    function test_readNativeDogeSupplyRejectsMismatchedLegacyEthAlias() external {
        NativeDogeSupplyConfigHarness harness = new NativeDogeSupplyConfigHarness();

        vm.expectRevert("L2_MAX_NATIVE_DOGE_SUPPLY must match L2_MAX_ETH_SUPPLY");
        harness.exposedReadL2MaxNativeDogeSupply(
            '[genesis]\nL2_MAX_NATIVE_DOGE_SUPPLY = "12345"\nL2_MAX_ETH_SUPPLY = "67890"\n'
        );
    }

    function test_nativeDogeTokenDoesNotExposeP2PKHSelectors() external view {
        bytes memory code = address(_token).code;
        bytes4[7] memory forbidden = [
            bytes4(keccak256("evmAliasOfP2PKH(bytes20)")),
            bytes4(keccak256("balanceOfP2PKH(bytes20)")),
            bytes4(keccak256("nonceOfP2PKH(bytes20)")),
            bytes4(keccak256("transferToP2PKH(bytes20,uint256)")),
            bytes4(keccak256("transferWithP2PKHAuthorization(bytes20,address,uint256,uint256,bytes)")),
            bytes4(keccak256("transferWithP2PKHAuthorization(bytes20,address,uint256,uint256,uint256,bytes)")),
            bytes4(keccak256("transferBatchWithP2PKHAuthorizations(bytes)"))
        ];

        for (uint256 i = 0; i < forbidden.length; i++) {
            assertFalse(_bytecodeContainsSelector(code, forbidden[i]));
        }
    }

    function _approveAliceToSpender(uint256 amount) internal {
        vm.prank(ALICE);
        _token.approve(SPENDER, amount);
    }

    function _etchNativeDogeToken(uint256 supply) internal returns (NativeDogeToken token) {
        NativeDogeToken impl = new NativeDogeToken(supply);

        address predeploy = DogeOSPredeploy.L2_NATIVE_DOGE_TOKEN;
        vm.etch(predeploy, address(impl).code);

        bytes32 totalSupplySlot = bytes32(uint256(0));
        vm.store(predeploy, totalSupplySlot, vm.load(address(impl), totalSupplySlot));

        vm.etch(address(impl), "");
        vm.resetNonce(address(impl));

        token = NativeDogeToken(predeploy);
    }

    function _etchNativeTransferPrecompile() internal {
        NativeTransferPrecompileMock mock = new NativeTransferPrecompileMock();

        address precompile = DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE;
        vm.etch(precompile, address(mock).code);

        vm.etch(address(mock), "");
        vm.resetNonce(address(mock));
    }

    function _etchPrecompile(address mock) internal {
        vm.etch(DogeOSPredeploy.NATIVE_TRANSFER_PRECOMPILE, mock.code);
        vm.etch(mock, "");
        vm.resetNonce(mock);
    }

    function _configuredGenesisHarness() internal returns (GenerateGenesisHarness harness) {
        harness = new GenerateGenesisHarness();
        harness.configure(
            SUPPLY,
            1 ether,
            address(0x5300),
            address(0xD390),
            string(
                abi.encodePacked(
                    "[contracts.overrides]\n",
                    'L2_NATIVE_DOGE_TOKEN = "0x530000000000000000000000000000000000d09e"\n'
                )
            )
        );
    }

    function _bytecodeContainsSelector(bytes memory code, bytes4 selector) internal pure returns (bool) {
        if (code.length < 4) {
            return false;
        }

        for (uint256 i = 0; i <= code.length - 4; i++) {
            bytes4 candidate;
            assembly {
                candidate := mload(add(add(code, 0x20), i))
            }
            if (candidate == selector) {
                return true;
            }
        }

        return false;
    }
}
