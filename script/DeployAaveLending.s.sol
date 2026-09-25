//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {AaveManager} from "../src/core/aave/executors/AaveManager.sol";
import {AaveOrchestrator} from "../src/core/aave/executors/AaveOrchestrator.sol";

interface IAddressProviderAdmin {
    function setAddress(string calldata contractName, address _address) external;
}

/**
 * @notice Registers Aave lending executors on an existing Sendra AddressProvider.
 * @dev Env: ADDRESS_PROVIDER, AAVE_POOL, AAVE_ORACLE, AAVE_DATA_PROVIDER
 *      Caller must be a Sendra admin. After deploy, whitelist both contracts in Roles.
 */
contract DeployAaveLending is Script {
    function run() external pure {
        revert("Usa script/DeployAaveStrategies.s.sol. Este deploy abre el tipo 4, que ya es spot.");
    }

    function runRetired() external {
        address addressProvider = vm.envAddress("ADDRESS_PROVIDER");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aaveOracle = vm.envAddress("AAVE_ORACLE");
        address aaveDataProvider = vm.envAddress("AAVE_DATA_PROVIDER");

        vm.startBroadcast();

        IAddressProviderAdmin(addressProvider).setAddress("AavePool", aavePool);
        IAddressProviderAdmin(addressProvider).setAddress("AaveOracle", aaveOracle);
        IAddressProviderAdmin(addressProvider).setAddress("AaveProtocolDataProvider", aaveDataProvider);

        AaveManager aaveManager = new AaveManager(addressProvider);
        IAddressProviderAdmin(addressProvider).setAddress("AaveManager", address(aaveManager));

        AaveOrchestrator aaveOrchestrator = new AaveOrchestrator(addressProvider);
        IAddressProviderAdmin(addressProvider).setAddress("AaveOrchestrator", address(aaveOrchestrator));

        // Admin must Roles.allowContract(AaveManager) + Roles.allowContract(AaveOrchestrator)
        // so they can write to the existing SendraStorage / PositionInitializer.

        vm.stopBroadcast();
    }
}
