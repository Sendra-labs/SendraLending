// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AaveAccountant } from "../src/accounting/AaveAccountant.sol";

/**
 * Accountant nuevo. El constructor despliega también el ledger, el desk y el seller.
 * Los libros abiertos siguen en las cuentas viejas. close() de esas cuentas
 * llama al accountant del provider, así que no hay que retirar nada antes.
 * Un supply de BTC o ETH se vende a USDC en el cierre. USDC sale en USDC.
 * Una cuenta ya desplegada no aprende openBasket: esa estrategia pide una cuenta nueva.
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
        console.log("AaveDesk:", address(accountant.desk()));
    }
}

interface IProvider {
    function getAddress(string calldata name) external view returns (address);
    function setAddress(string calldata name, address addr) external;
}

interface IRoles {
    function allowContract(address c, string calldata name) external;
}
