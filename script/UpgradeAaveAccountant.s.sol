// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AaveAccountant } from "../src/accounting/AaveAccountant.sol";

/**
 * Solo el accountant. El manager y las cuentas se quedan.
 * El cierre de un loop paga la deuda con flash loan antes de retirar el colateral.
 *
 * Desde SendraLending/ en WSL:
 *   forge script script/UpgradeAaveAccountant.s.sol --target-contract UpgradeAaveAccountant --rpc-url arbitrum --broadcast
 */
contract UpgradeAaveAccountant is Script {
    address constant ADDRESS_PROVIDER = 0xaF7A2feFBA6Acc09e62011d0359dC06e0e1245f5;

    function run() public {
        uint256 pk = vm.envUint("ADMIN1_PRIVATE_KEY");
        IProvider provider = IProvider(ADDRESS_PROVIDER);
        address roles = provider.getAddress("Roles");

        vm.startBroadcast(pk);
        AaveAccountant accountant = new AaveAccountant(ADDRESS_PROVIDER);
        provider.setAddress("AaveAccountant", address(accountant));
        IRoles(roles).allowContract(address(accountant), "AaveAccountant");
        IRoles(roles).allowContract(address(accountant.ledger()), "AaveLedger");
        vm.stopBroadcast();

        console.log("AaveAccountant:", address(accountant));
        console.log("AaveLedger:", address(accountant.ledger()));
    }
}

interface IProvider {
    function getAddress(string calldata name) external view returns (address);
    function setAddress(string calldata name, address addr) external;
}

interface IRoles {
    function allowContract(address c, string calldata name) external;
}
