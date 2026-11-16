// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console } from "forge-std/Script.sol";
import { AaveAccountant } from "../src/accounting/AaveAccountant.sol";
import { AdminQuorum, IQuorumProvider, IQuorumRoles } from "./AdminQuorum.sol";

/**
 * @notice Replaces AaveAccountant after DeployAaveStrategies. Do not run this on a fresh deploy.
 *         The constructor also deploys the ledger and the desk, and the desk reads SwapRouter
 *         from the AddressProvider at that moment. Run this once the provider already points
 *         at the router that encodes minHopPriceX36. Open books stay on the previous
 *         accountant and are adopted on close.
 *         Then put the logged addresses in web-frontend AAVE_ACCOUNTANT_ADDRESS,
 *         AAVE_LEDGER_ADDRESS and AAVE_DESK_ADDRESS.
 *
 *         WSL:
 *           forge script script/UpgradeAaveAccountant.s.sol --rpc-url arbitrum --broadcast
 */
contract UpgradeAaveAccountant is AdminQuorum {
    function run() public {
        if (block.chainid != 42161) revert WrongChain();
        IQuorumProvider provider = _provider();
        IQuorumRoles roles = IQuorumRoles(provider.getAddress("Roles"));
        provider.getAddress("AaveManager");
        provider.getAddress("AaveOracle");
        provider.getAddress("AaveProtocolDataProvider");

        vm.startBroadcast(_keys()[0]);
        AaveAccountant accountant = new AaveAccountant(address(provider));
        vm.stopBroadcast();

        _register(provider, roles, "AaveAccountant", address(accountant), true);
        _register(provider, roles, "AaveLedger", address(accountant.ledger()), true);

        console.log("AaveAccountant", address(accountant));
        console.log("AaveLedger", address(accountant.ledger()));
        console.log("AaveDesk", address(accountant.desk()));
    }

    error WrongChain();
}
