// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console } from "forge-std/Script.sol";
import { LendingAccounts } from "../src/storage/LendingAccounts.sol";
import { AdminQuorum, IQuorumProvider, IQuorumRoles } from "./AdminQuorum.sol";

/**
 * @notice Replaces LendingAccounts only. AddressProvider, Roles and the rest of
 *         the core stay where they are. The new factory deploys one LendingCell
 *         implementation and every later open() is a 45-byte clone. The previous
 *         factory stays as `legacy`, so cells already deployed are still listed.
 *
 *         WSL, from SendraLending/:
 *           forge script script/RedeployLendingAccounts.s.sol --rpc-url arbitrum
 *           forge script script/RedeployLendingAccounts.s.sol --rpc-url arbitrum --broadcast
 *
 *         Then put the logged address in web-frontend LENDING_ACCOUNTS_ADDRESS.
 */
contract RedeployLendingAccounts is AdminQuorum {
    function run() public {
        if (block.chainid != 42161) revert WrongChain();
        IQuorumProvider provider = _provider();
        IQuorumRoles roles = IQuorumRoles(provider.getAddress("Roles"));
        address previous = provider.getAddress("LendingAccounts");

        vm.startBroadcast(_keys()[0]);
        LendingAccounts accounts = new LendingAccounts(address(provider), previous);
        vm.stopBroadcast();

        _register(provider, roles, "LendingAccounts", address(accounts), true);
        console.log("LendingAccounts", address(accounts));
        console.log("implementation", accounts.implementation());
        console.log("previous", previous);
    }

    error WrongChain();
}
