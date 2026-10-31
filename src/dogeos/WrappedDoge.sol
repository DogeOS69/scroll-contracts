// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

// solhint-disable reason-string
// solhint-disable no-empty-blocks

/// @author Inspired by WETH9 (https://github.com/dapphub/ds-weth/blob/master/src/weth9.sol)
/// @dev Shares are minted only through deposit() (and receive(), which calls it).
///      DOGE credited to this contract any other way, such as a NativeDogeToken
///      transfer, which does not run receive(), mints nothing and stays locked
///      here, like force-sent ETH in WETH9. The contract's balance therefore
///      stays at or above totalSupply().
contract WrappedDoge is ERC20Permit {
    /// @notice Emitted when user deposits Doge to this contract.
    /// @param dst The address of depositor.
    /// @param wad The amount of Doge in wei deposited.
    event Deposit(address indexed dst, uint256 wad);

    /// @notice Emitted when user withdraws some Doge from this contract.
    /// @param src The address of caller.
    /// @param wad The amount of Doge in wei withdrawn.
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20Permit("Wrapped Doge") ERC20("Wrapped Doge", "WDOGE") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        address _sender = _msgSender();

        _mint(_sender, msg.value);

        emit Deposit(_sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        address _sender = _msgSender();

        _burn(_sender, wad);

        // slither-disable-next-line arbitrary-send-eth
        (bool success, ) = _sender.call{value: wad}("");
        require(success, "withdraw DOGE failed");

        emit Withdrawal(_sender, wad);
    }
}
