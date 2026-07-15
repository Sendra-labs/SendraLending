// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SendraLib} from "../../lib/Sendra.lib.sol";

/**
 * @title ISendraStorage
 * @notice External surface of protocol `SendraStorage`.
 */
interface ISendraStorage {
    function getUser(address user) external view returns (SendraLib.UserInfoRead memory);

    function updateUserTransactionCount(address user, uint256 transactionCount) external;

    function addPositionToUser(address user, SendraLib.Position memory position) external;

    function updateUserFullPosition(address user, uint256 positionId, SendraLib.Position memory position) external;

    function updateUserPositionData(address user, uint256 positionId, uint256 positionField, bytes memory value)
        external;

    function updateUserGlobalPnl(address user, int256 pnlChange) external;

    function decreaseGlobalPositionActivePositions(address user) external;

    function applyGlobalPulseDeltas(address user, uint8[] calldata fieldIds, int256[] calldata deltas) external;

    function applySpecificPulseDeltas(
        address user,
        uint64 specificKey,
        uint8[] calldata fieldIds,
        int256[] calldata deltas
    ) external;

    function applyMetricDelta(address user, uint64 specificKey, uint256 metricIndex, int256 delta) external;

    function getUniqueGlobalAccumulator(uint8 fieldId, address user) external view returns (int256);

    function getUserPositionById(address user, uint256 positionId) external view returns (SendraLib.Position memory);
}
