//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISendraAddressProvider} from "../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {LendingCell} from "../execution/LendingCell.sol";

interface IAccountsManager {
    function accountByOwner(address owner) external view returns (address);
}

interface IAccountAccess {
    function setIsProtocolAccount(address account) external;
}

/**
 * @title LendingAccounts
 * @notice One lending account per owner. Uses the SendraAccount when it already implements `aaveEnabled`.
 *         Otherwise deploys a LendingCell. That cell is what holds the aTokens, the debt and the LP.
 */
contract LendingAccounts {
    ISendraAddressProvider public immutable addressProvider;
    mapping(address => address) public cellByOwner;

    constructor(address _addressProvider) {
        addressProvider = ISendraAddressProvider(_addressProvider);
    }

    function open() external returns (address cell) {
        cell = cellByOwner[msg.sender];
        if (cell != address(0)) return cell;

        address spot = IAccountsManager(addressProvider.getAddress("AccountsManager")).accountByOwner(msg.sender);
        if (_aaveEnabled(spot)) cell = spot;
        else cell = address(new LendingCell(address(addressProvider), msg.sender));

        cellByOwner[msg.sender] = cell;
        IAccountAccess(addressProvider.getAddress("AccountAccessControl")).setIsProtocolAccount(cell);
    }

    function _aaveEnabled(address spot) internal view returns (bool) {
        if (spot == address(0) || spot.code.length == 0) return false;
        (bool ok, bytes memory data) = spot.staticcall(abi.encodeWithSignature("aaveEnabled()"));
        return ok && data.length == 32 && abi.decode(data, (bool));
    }
}
