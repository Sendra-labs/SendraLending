//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { LendingAccounts } from "../src/storage/LendingAccounts.sol";
import { LendingCell } from "../src/execution/LendingCell.sol";

contract MockAccess {
    function setIsProtocolAccount(address) external {}
}

contract MockProvider {
    address public access;

    constructor(address _access) {
        access = _access;
    }

    function getAddress(string calldata name) external view returns (address) {
        if (keccak256(bytes(name)) == keccak256("AccountAccessControl")) return access;
        return address(0);
    }
}

/// @dev Previous factory shape: one cell, no `cellsOf`.
contract OneCellLegacy {
    address public cell;

    constructor(address _cell) {
        cell = _cell;
    }

    function cellByOwner(address) external view returns (address) {
        return cell;
    }
}

contract LendingAccountsTest is Test {
    MockProvider internal provider;
    LendingAccounts internal accounts;
    address internal alice = makeAddr("alice");

    function setUp() public {
        provider = new MockProvider(address(new MockAccess()));
        accounts = new LendingAccounts(address(provider), address(0));
    }

    function test_openIsACloneOwnedByTheCaller() public {
        vm.prank(alice);
        address cell = accounts.open();

        assertEq(cell.code.length, 45);
        assertGt(accounts.implementation().code.length, 1000);
        assertEq(LendingCell(cell).owner(), alice);
        assertEq(LendingCell(cell).factory(), address(accounts));
        assertEq(address(LendingCell(cell).addressProvider()), address(provider));
        assertEq(uint256(vm.load(cell, bytes32(uint256(1)))), 1);
        assertTrue(LendingCell(cell).aaveEnabled());

        address[] memory cells = accounts.cellsOf(alice);
        assertEq(cells.length, 1);
        assertEq(cells[0], cell);
    }

    function test_openManyMintsAPoolOwnedByTheCaller() public {
        vm.prank(alice);
        address[] memory minted = accounts.openMany(10);

        assertEq(minted.length, 10);
        address[] memory cells = accounts.cellsOf(alice);
        assertEq(cells.length, 10);
        for (uint256 i; i < 10; ++i) {
            assertEq(cells[i], minted[i]);
            assertEq(minted[i].code.length, 45);
            assertEq(LendingCell(minted[i]).owner(), alice);
            assertEq(LendingCell(minted[i]).factory(), address(accounts));
            for (uint256 j; j < i; ++j) {
                assertTrue(minted[i] != minted[j]);
            }
        }
    }

    function test_openManyRejectsAnEmptyOrOversizedBatch() public {
        vm.prank(alice);
        vm.expectRevert(LendingAccounts.EmptyBatch.selector);
        accounts.openMany(0);

        vm.prank(alice);
        vm.expectRevert(LendingAccounts.BatchTooLarge.selector);
        accounts.openMany(11);
    }

    function test_secondOpenIsAlsoAClone() public {
        vm.prank(alice);
        address first = accounts.open();
        vm.prank(alice);
        address second = accounts.open();

        assertEq(first.code.length, 45);
        assertEq(second.code.length, 45);
        assertTrue(first != second);
        assertEq(accounts.cellsOf(alice).length, 2);
    }

    function test_initializeIsFactoryOnly() public {
        address raw = Clones.clone(accounts.implementation());

        vm.prank(alice);
        vm.expectRevert(LendingCell.NotFactory.selector);
        LendingCell(raw).initialize(alice);

        vm.prank(address(accounts));
        vm.expectRevert(LendingCell.ZeroOwner.selector);
        LendingCell(raw).initialize(address(0));

        vm.prank(address(accounts));
        LendingCell(raw).initialize(alice);
        assertEq(LendingCell(raw).owner(), alice);

        vm.prank(address(accounts));
        vm.expectRevert(LendingCell.AlreadyInitialized.selector);
        LendingCell(raw).initialize(alice);
    }

    function test_legacyCellsStayListed() public {
        vm.prank(alice);
        address oldCell = accounts.open();

        LendingAccounts next = new LendingAccounts(address(provider), address(accounts));
        address[] memory listed = next.cellsOf(alice);
        assertEq(listed.length, 1);
        assertEq(listed[0], oldCell);

        vm.prank(alice);
        address fresh = next.open();
        listed = next.cellsOf(alice);
        assertEq(listed.length, 2);
        assertEq(listed[0], oldCell);
        assertEq(listed[1], fresh);
        assertEq(fresh.code.length, 45);
    }

    function test_oneCellLegacyIsStillListed() public {
        address oldCell = makeAddr("old");
        LendingAccounts next = new LendingAccounts(address(provider), address(new OneCellLegacy(oldCell)));
        address[] memory listed = next.cellsOf(alice);
        assertEq(listed.length, 1);
        assertEq(listed[0], oldCell);
    }
}
