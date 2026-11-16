//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ISendraAddressProvider} from "../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {LendingCell} from "../execution/LendingCell.sol";

interface IAccountsManager {
    function accountByOwner(address owner) external view returns (address);
}

interface IAccountAccess {
    function setIsProtocolAccount(address account) external;
}

interface ILegacyLendingAccounts {
    function cellByOwner(address owner) external view returns (address);
    function cellsOf(address owner) external view returns (address[] memory);
}

interface IAaveBooks {
    function books(address account)
        external
        view
        returns (
            uint256 positionId,
            uint8 kind,
            address asset,
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 principalUsdc,
            uint256 proceeds,
            uint256 released,
            uint256 openedAt,
            uint256 uniTokenId,
            uint256 lpPositionId
        );
}

/**
 * @title LendingAccounts
 * @notice Aave strategies each get their own LendingCell. Spot and LP stay on SendraAccount.
 * @dev One implementation is deployed with this factory. Every `open` is an EIP-1167 clone.
 *      `legacy` keeps the cells of the factory this one replaced, so an open strategy can still be closed.
 *      A legacy cell that is the spot account is listed only while that strategy is open.
 */
contract LendingAccounts {
    uint256 public constant OPEN_MANY_MAX = 10;

    ISendraAddressProvider public immutable addressProvider;
    ILegacyLendingAccounts public immutable legacy;
    address public immutable implementation;
    mapping(address => address[]) private _cells;

    constructor(address _addressProvider, address _legacy) {
        addressProvider = ISendraAddressProvider(_addressProvider);
        legacy = ILegacyLendingAccounts(_legacy);
        implementation = address(new LendingCell(address(addressProvider), address(this)));
    }

    /// @notice Clone of the implementation. Does not touch the spot account.
    function open() external returns (address cell) {
        cell = _open(addressProvider.getAddress("AccountAccessControl"));
    }

    /// @notice Clone `n` cells for the caller in one transaction. `n` is from 1 to `OPEN_MANY_MAX`.
    function openMany(uint256 n) external returns (address[] memory cells) {
        if (n == 0) revert EmptyBatch();
        if (n > OPEN_MANY_MAX) revert BatchTooLarge();
        cells = new address[](n);
        address access = addressProvider.getAddress("AccountAccessControl");
        for (uint256 i; i < n; ++i) {
            cells[i] = _open(access);
        }
    }

    function _open(address access) internal returns (address cell) {
        cell = Clones.clone(implementation);
        LendingCell(cell).initialize(msg.sender);
        _cells[msg.sender].push(cell);
        IAccountAccess(access).setIsProtocolAccount(cell);
    }

    function cellsOf(address owner) external view returns (address[] memory cells) {
        address[] memory prior = _legacyCells(owner);
        address[] storage owned = _cells[owner];
        uint256 extra;
        for (uint256 i; i < prior.length; i++) {
            if (prior[i] != address(0) && !_contains(owned, prior[i])) extra++;
        }
        cells = new address[](owned.length + extra);
        uint256 n;
        for (uint256 i; i < prior.length; i++) {
            if (prior[i] == address(0) || _contains(owned, prior[i])) continue;
            cells[n++] = prior[i];
        }
        for (uint256 i; i < owned.length; i++) cells[n++] = owned[i];
    }

    /// @dev First cell. Callers that can hold several strategies should use `cellsOf`.
    function cellByOwner(address owner) external view returns (address) {
        address[] memory cells = this.cellsOf(owner);
        return cells.length == 0 ? address(0) : cells[0];
    }

    /// @dev The previous factory already merges its own legacy. Older factories only expose one cell.
    function _legacyCells(address owner) internal view returns (address[] memory cells) {
        if (address(legacy) == address(0)) return cells;
        try legacy.cellsOf(owner) returns (address[] memory found) {
            return found;
        } catch {
            address cell = _legacyCell(owner);
            if (cell == address(0)) return cells;
            cells = new address[](1);
            cells[0] = cell;
        }
    }

    function _legacyCell(address owner) internal view returns (address cell) {
        if (address(legacy) == address(0)) return address(0);
        cell = legacy.cellByOwner(owner);
        if (cell == address(0)) return address(0);
        address spot = _spot(owner);
        if (cell != spot) return cell;
        address accountant = addressProvider.getAddress("AaveAccountant");
        if (accountant == address(0)) return address(0);
        (uint256 positionId,,,,,,,,,,) = IAaveBooks(accountant).books(cell);
        return positionId == 0 ? address(0) : cell;
    }

    function _spot(address owner) internal view returns (address) {
        address manager = addressProvider.getAddress("AccountsManager");
        if (manager == address(0)) return address(0);
        return IAccountsManager(manager).accountByOwner(owner);
    }

    function _contains(address[] storage owned, address cell) internal view returns (bool) {
        for (uint256 i; i < owned.length; i++) {
            if (owned[i] == cell) return true;
        }
        return false;
    }

    error EmptyBatch();
    error BatchTooLarge();
}
