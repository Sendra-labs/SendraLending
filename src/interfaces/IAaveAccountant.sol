//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapTypes} from "../lib/aave/SwapTypes.sol";

interface IAaveAccountant {
    function openSupply(address owner, address asset, uint256 usdcAmount, SwapTypes.SwapInput calldata swap) external;

    function openLoop(
        address owner,
        address asset,
        uint256 usdcAmount,
        uint8 loops,
        uint16 borrowBps,
        SwapTypes.SwapInput calldata swap
    ) external;

    function openShort(
        address owner,
        address asset,
        uint256 usdcAmount,
        uint8 loops,
        uint16 borrowBps,
        bool releaseToOwner,
        SwapTypes.SwapInput calldata sellAsset
    ) external;

    function openLeveraged(
        address owner,
        address asset,
        uint256 usdcAmount,
        uint16 borrowBps,
        SwapTypes.SwapInput calldata buyAsset,
        bool collateralIsAsset
    ) external returns (uint256 positionId);

    function sealLp(address owner, uint256 positionId, uint256 uniTokenId, uint256 lpPositionId) external;

    function settleLeveraged(address owner, uint256 positionId) external;

    function release(address owner, uint256 positionId) external;

    function close(address owner, uint256 positionId, SwapTypes.SwapInput calldata swap) external;

    function debtOf(address account, address asset) external view returns (uint256);
}
