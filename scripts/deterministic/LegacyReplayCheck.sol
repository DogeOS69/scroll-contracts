// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.24;

import {L2DogeOsMessenger} from "../../src/dogeos/L2DogeOsMessenger.sol";

/// @notice Derives L2DogeOsMessenger.LEGACY_REPLAY_CHECK for a new implementation from the live
///         messenger proxy, so it never depends on operator input.
library LegacyReplayCheck {
    /// @dev The value a new implementation for `proxy` must use.
    ///      - Not initialized: a fresh messenger has relayed nothing, so false.
    ///      - Current implementation predates the nonce bitmap (it has no LEGACY_REPLAY_CHECK
    ///        getter): its successes are only in the per-hash mapping, so true.
    ///      - Current implementation has the getter: keep its value. Once true it stays true.
    /// @param proxy The L2DogeOsMessenger proxy.
    /// @param initialized Whether the proxy has been initialized.
    function required(address proxy, bool initialized) internal view returns (bool) {
        if (!initialized) {
            return false;
        }
        try L2DogeOsMessenger(payable(proxy)).LEGACY_REPLAY_CHECK() returns (bool current) {
            return current;
        } catch {
            return true;
        }
    }

    /// @dev Reverts unless upgrading `proxy` to `newImpl` keeps replay protection intact.
    ///      Refuses to turn LEGACY_REPLAY_CHECK off, and to roll back from a bitmap implementation
    ///      to a pre-bitmap one, which would only check the per-hash mapping and so drop replay
    ///      protection for deposits relayed since the bitmap upgrade. `allowRollback` overrides the
    ///      latter only.
    function requireSafeUpgrade(
        address proxy,
        bool initialized,
        address newImpl,
        bool allowRollback
    ) internal view {
        bool mustCheckLegacy = required(proxy, initialized);
        try L2DogeOsMessenger(payable(newImpl)).LEGACY_REPLAY_CHECK() returns (bool provided) {
            require(provided || !mustCheckLegacy, "new L2DogeOsMessenger implementation must keep LEGACY_REPLAY_CHECK");
        } catch {
            bool currentIsBitmap = initialized && _hasGetter(proxy);
            require(
                !currentIsBitmap || allowRollback,
                "rollback to a pre-bitmap L2DogeOsMessenger drops replay protection for deposits relayed since the upgrade"
            );
        }
    }

    function _hasGetter(address proxy) private view returns (bool) {
        try L2DogeOsMessenger(payable(proxy)).LEGACY_REPLAY_CHECK() returns (bool) {
            return true;
        } catch {
            return false;
        }
    }
}
