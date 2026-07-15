// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPositionInitializer {
    function initializePosition(bytes[] memory _newPositionData, uint128 _positionType, address _user) external;
}
