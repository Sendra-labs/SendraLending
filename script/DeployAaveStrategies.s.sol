// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console } from "forge-std/Script.sol";
import { AaveManager } from "../src/core/aave/executors/AaveManager.sol";
import { AaveAccountant } from "../src/accounting/AaveAccountant.sol";
import { LendingAccounts } from "../src/storage/LendingAccounts.sol";
import { AdminQuorum, IQuorumProvider, IQuorumRoles } from "./AdminQuorum.sol";

/**
 * @notice Registers Aave V3 and deploys the manager, accountant and lending accounts.
 *         Pool, oracle and data provider are voted in before AaveManager, because
 *         its constructor reads them. AaveAccountant reads AaveManager the same way.
 *
 *         WSL, from SendraLending/, same shell as the core deploy:
 *           forge script script/DeployAaveStrategies.s.sol --rpc-url arbitrum
 *           forge script script/DeployAaveStrategies.s.sol --rpc-url arbitrum --broadcast
 */
contract DeployAaveStrategies is AdminQuorum {
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address constant AAVE_DATA = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;

    function run() public {
        if (block.chainid != 42161) revert WrongChain();
        IQuorumProvider provider = _provider();
        IQuorumRoles roles = IQuorumRoles(provider.getAddress("Roles"));
        provider.getAddress("AccountAccessControl");
        provider.getAddress("SwapRouter");
        provider.getAddress("SendraStorage");
        provider.getAddress("USDC");
        provider.getAddress("PositionInitializer");

        _propose(provider, "AavePool", AAVE_POOL);
        _propose(provider, "AaveOracle", AAVE_ORACLE);
        _propose(provider, "AaveProtocolDataProvider", AAVE_DATA);

        vm.startBroadcast(_keys()[0]);
        AaveManager manager = new AaveManager(address(provider));
        vm.stopBroadcast();
        _propose(provider, "AaveManager", address(manager));

        vm.startBroadcast(_keys()[0]);
        AaveAccountant accountant = new AaveAccountant(address(provider));
        LendingAccounts accounts = new LendingAccounts(address(provider), address(0));
        vm.stopBroadcast();

        _register(provider, roles, "AaveAccountant", address(accountant), true);
        _register(provider, roles, "AaveLedger", address(accountant.ledger()), true);
        _register(provider, roles, "LendingAccounts", address(accounts), true);

        console.log("AaveManager", address(manager));
        console.log("AaveAccountant", address(accountant));
        console.log("AaveLedger", address(accountant.ledger()));
        console.log("AaveDesk", address(accountant.desk()));
        console.log("LendingAccounts", address(accounts));
        console.log("accountant protocol", roles.isProtocolContract(address(accountant)));
        console.log("accounts protocol", roles.isProtocolContract(address(accounts)));
    }

    error WrongChain();
}
