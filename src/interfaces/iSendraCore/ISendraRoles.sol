// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISendraRoles {
    function isProtocolContract(address _contract) external view returns (bool);

    function checkAdmin(address _admin) external view returns (bool);
}
