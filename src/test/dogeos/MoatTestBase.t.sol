// SPDX-License-Identifier: MIT

pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Moat} from "../../dogeos/Moat.sol";
import {EmptyContract} from "../../misc/EmptyContract.sol";

/// @notice Deploys Moats behind proxies, the way DeployScroll does: an empty proxy first (so
///         other contracts can bind its address), then the implementation installed and
///         initialized with its owner, then configured through the owner setters. The
///         implementation disables its own initializers, so a Moat only works behind a proxy.
abstract contract MoatTestBase is Test {
    bytes1 internal constant MAINNET_P2PKH_PREFIX = bytes1(0x1e);
    bytes1 internal constant MAINNET_P2SH_PREFIX = bytes1(0x16);

    struct MoatConfig {
        address owner;
        address feeRecipient;
        uint256 withdrawalFee;
        uint256 depositFee;
        uint256 minWithdrawal;
        address feeExemptCaller;
    }

    /// @dev An empty proxy administered by a fresh ProxyAdmin (owned by this test).
    function _deployEmptyProxy() internal returns (ProxyAdmin admin, address proxy) {
        admin = new ProxyAdmin();
        proxy = address(new TransparentUpgradeableProxy(address(new EmptyContract()), address(admin), new bytes(0)));
    }

    function _initializeCall(MoatConfig memory cfg) internal pure returns (bytes memory) {
        return abi.encodeCall(Moat.initialize, (cfg.owner));
    }

    function _callInitialize(Moat moat, MoatConfig memory cfg) internal {
        moat.initialize(cfg.owner);
    }

    /// @dev Applies `cfg` through the owner setters. A zero fee recipient or fee-exempt caller
    ///      means none.
    function _configure(Moat moat, MoatConfig memory cfg) internal {
        vm.startPrank(cfg.owner);
        if (cfg.feeRecipient != address(0)) {
            moat.setFeeRecipient(cfg.feeRecipient);
        }
        moat.setWithdrawalFee(cfg.withdrawalFee);
        moat.setDepositFee(cfg.depositFee);
        moat.setMinWithdrawal(cfg.minWithdrawal);
        if (cfg.feeExemptCaller != address(0)) {
            moat.setFeeExempt(cfg.feeExemptCaller, true);
        }
        vm.stopPrank();
    }

    /// @dev Installs a mainnet-prefix Moat bound to `messenger` into `proxy`, initialized with
    ///      `cfg.owner` and configured with the rest of `cfg`.
    function _installMoat(
        ProxyAdmin admin,
        address proxy,
        address messenger,
        MoatConfig memory cfg
    ) internal returns (Moat moat) {
        Moat impl = new Moat(MAINNET_P2PKH_PREFIX, MAINNET_P2SH_PREFIX, messenger);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(impl), _initializeCall(cfg));
        moat = Moat(proxy);
        _configure(moat, cfg);
    }

    function _deployMoat(address messenger, MoatConfig memory cfg) internal returns (Moat) {
        (ProxyAdmin admin, address proxy) = _deployEmptyProxy();
        return _installMoat(admin, proxy, messenger, cfg);
    }
}
