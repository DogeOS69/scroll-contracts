// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";

// Target contracts
import {FeeVaultMoatAdapter} from "../../dogeos/FeeVaultMoatAdapter.sol";
import {Moat} from "../../dogeos/Moat.sol";
import {L2TxFeeVault} from "../../L2/predeploys/L2TxFeeVault.sol";

// Mocks
import {MockScrollMessenger} from "./Moat.t.sol";

contract FeeVaultMoatAdapterTest is Test {
    Moat internal _moat;
    L2TxFeeVault internal _vault;
    FeeVaultMoatAdapter internal _adapter;
    MockScrollMessenger internal _mockMessenger;

    address internal _owner = address(0x1);
    address payable internal _feeRecipient = payable(address(0xfee));
    // The vault recipient, interpreted as a Dogecoin P2PKH hash160 payload.
    address internal _dogeRecipient = address(0xd09e);
    address internal _l1Counterpart = address(0xbeef);

    uint256 internal constant _MOAT_FEE = 0.01 ether;
    uint256 internal constant _MOAT_MIN_WITHDRAWAL = 0.1 ether;
    uint256 internal constant _VAULT_MIN_WITHDRAWAL = 1 ether;

    function setUp() public {
        _mockMessenger = new MockScrollMessenger(_l1Counterpart);

        _moat = new Moat(bytes1(0x1e), bytes1(0x16));
        _moat.initialize(_owner);

        _vault = new L2TxFeeVault(_owner, _dogeRecipient, _VAULT_MIN_WITHDRAWAL);
        _adapter = new FeeVaultMoatAdapter(address(_vault), address(_moat));

        vm.startPrank(_owner);
        _moat.updateMessenger(address(_mockMessenger));
        _moat.setFeeRecipient(_feeRecipient);
        _moat.setWithdrawalFee(_MOAT_FEE);
        _moat.setMinWithdrawal(_MOAT_MIN_WITHDRAWAL);
        _moat.setFeeExempt(address(_adapter), true);
        _vault.updateMessenger(address(_adapter));
        vm.stopPrank();
    }

    // --- Constructor --- //

    function testConstructor_Revert_ZeroAddress() external {
        vm.expectRevert(FeeVaultMoatAdapter.ErrorZeroAddress.selector);
        new FeeVaultMoatAdapter(address(0), address(_moat));

        vm.expectRevert(FeeVaultMoatAdapter.ErrorZeroAddress.selector);
        new FeeVaultMoatAdapter(address(_vault), address(0));
    }

    // --- End-to-end withdrawal routing --- //

    function testWithdraw_RoutesThroughMoat() external {
        uint256 amountAligned = 2 ether; // multiple of SATOSHI_TO_WEI
        uint256 dust = 12345; // sub-satoshi remainder
        vm.deal(address(_vault), amountAligned + dust);

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        _vault.withdraw();

        // The message reaching the messenger is a standard Moat withdrawal:
        // sent by the Moat, carrying the v1 P2PKH envelope, with a floored value.
        assertEq(_mockMessenger.lastSender(), address(_moat), "Message must be sent by the Moat");
        assertEq(_mockMessenger.lastTarget(), _dogeRecipient, "Target must be the vault recipient");
        assertEq(_mockMessenger.lastValue(), amountAligned, "Value must be floored to a satoshi multiple");
        assertEq(_mockMessenger.lastMsgValue(), amountAligned, "msg.value must match the floored value");
        assertEq(_mockMessenger.lastMessage().length, 2, "Envelope length should be 2");
        assertEq(_mockMessenger.lastMessage()[0], bytes1(uint8(1)), "Envelope version should be 1");
        assertEq(_mockMessenger.lastMessage()[1], bytes1(uint8(0)), "Envelope flags should be 0 (P2PKH)");

        // The adapter is fee-exempt: only the dust goes to the fee recipient.
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + dust, "Only dust should be collected as fee");
    }

    function testWithdraw_WithoutExemption_PaysBaseFee() external {
        vm.prank(_owner);
        _moat.setFeeExempt(address(_adapter), false);

        uint256 amount = 2 ether;
        vm.deal(address(_vault), amount);

        uint256 feeRecipBalanceBefore = _feeRecipient.balance;

        _vault.withdraw();

        assertEq(_mockMessenger.lastValue(), amount - _MOAT_FEE, "Value should be reduced by the base fee");
        assertEq(_feeRecipient.balance, feeRecipBalanceBefore + _MOAT_FEE, "Base fee should be collected");
    }

    function testWithdraw_Revert_BelowMoatMinimum() external {
        // A vault whose own minimum is below the Moat minimum: the vault check passes
        // but the Moat rejects the withdrawal, reverting the whole call.
        vm.startPrank(_owner);
        L2TxFeeVault laxVault = new L2TxFeeVault(_owner, _dogeRecipient, 0.01 ether);
        FeeVaultMoatAdapter laxAdapter = new FeeVaultMoatAdapter(address(laxVault), address(_moat));
        _moat.setFeeExempt(address(laxAdapter), true);
        laxVault.updateMessenger(address(laxAdapter));
        vm.stopPrank();

        vm.deal(address(laxVault), 0.05 ether); // >= vault min, < Moat min

        vm.expectRevert(Moat.ErrorBelowMinimumWithdrawal.selector);
        laxVault.withdraw();
    }

    // --- Adapter access control --- //

    function testSendMessage_Revert_NotFeeVault() external {
        address intruder = address(0xbad);
        vm.deal(intruder, 1 ether);

        vm.prank(intruder);
        vm.expectRevert(
            abi.encodeWithSelector(FeeVaultMoatAdapter.ErrorSenderNotFeeVault.selector, intruder, address(_vault))
        );
        _adapter.sendMessage{value: 1 ether}(_dogeRecipient, 1 ether, new bytes(0), 0);
    }

    function testSendMessage_Revert_ValueMismatch() external {
        // Called as the fee vault so the sender check passes first.
        vm.deal(address(_vault), 1 ether);

        vm.prank(address(_vault));
        vm.expectRevert(abi.encodeWithSelector(FeeVaultMoatAdapter.ErrorValueMismatch.selector, 2 ether, 1 ether));
        _adapter.sendMessage{value: 1 ether}(_dogeRecipient, 2 ether, new bytes(0), 0);
    }
}
