//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILendingAccount {
    function owner() external view returns (address);

    function aaveEnabled() external view returns (bool);

    function push(address token, address to, uint256 amount) external;

    function delegate(address debtToken, address delegatee) external;

    function approveToken(address token, address spender, uint256 amount) external;

    function callOrchestrator(bytes calldata data) external;
}
