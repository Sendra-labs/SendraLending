// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AaveManager } from "../src/core/aave/executors/AaveManager.sol";
import { AaveAccountant } from "../src/accounting/AaveAccountant.sol";
import { LendingAccounts } from "../src/storage/LendingAccounts.sol";

/**
 * Registra Aave V3 y despliega el executor, el accountant y el registro de cuentas de lending.
 *
 * Desde SendraLending/ en WSL, con ADMIN1_PRIVATE_KEY en .env:
 *   forge script script/DeployAaveStrategies.s.sol --target-contract DeployAaveStrategies --rpc-url arbitrum --broadcast
 */
contract DeployAaveStrategies is Script {
    address constant ADDRESS_PROVIDER = 0xaF7A2feFBA6Acc09e62011d0359dC06e0e1245f5;
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address constant AAVE_DATA = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;

    function run() public {
        uint256 pk = vm.envUint("ADMIN1_PRIVATE_KEY");
        IProvider provider = IProvider(ADDRESS_PROVIDER);
        address roles = provider.getAddress("Roles");

        vm.startBroadcast(pk);
        provider.setAddress("AavePool", AAVE_POOL);
        provider.setAddress("AaveOracle", AAVE_ORACLE);
        provider.setAddress("AaveProtocolDataProvider", AAVE_DATA);

        AaveManager manager = new AaveManager(ADDRESS_PROVIDER);
        provider.setAddress("AaveManager", address(manager));

        AaveAccountant accountant = new AaveAccountant(ADDRESS_PROVIDER);
        provider.setAddress("AaveAccountant", address(accountant));
        IRoles(roles).allowContract(address(accountant), "AaveAccountant");
        IRoles(roles).allowContract(address(accountant.ledger()), "AaveLedger");

        LendingAccounts accounts = new LendingAccounts(ADDRESS_PROVIDER);
        provider.setAddress("LendingAccounts", address(accounts));
        IRoles(roles).allowContract(address(accounts), "LendingAccounts");
        vm.stopBroadcast();

        console.log("AaveManager:", address(manager));
        console.log("AaveAccountant:", address(accountant));
        console.log("AaveLedger:", address(accountant.ledger()));
        console.log("LendingAccounts:", address(accounts));
        console.log("accountant protocolo:", IRoles(roles).isProtocolContract(address(accountant)));
        console.log("accounts protocolo:", IRoles(roles).isProtocolContract(address(accounts)));
    }
}

interface IProvider {
    function getAddress(string calldata name) external view returns (address);
    function setAddress(string calldata name, address addr) external;
}

interface IRoles {
    function allowContract(address c, string calldata name) external;
    function isProtocolContract(address c) external view returns (bool);
}
