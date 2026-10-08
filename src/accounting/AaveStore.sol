//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapTypes} from "../lib/aave/SwapTypes.sol";

/// @dev Shared storage for `AaveAccountant` and `AaveDesk`. The desk is delegatecalled,
///      so these slots must stay in this order on both contracts.
abstract contract AaveStore {
    struct Book {
        uint256 positionId;
        uint8 kind;
        address asset;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 principalUsdc;
        uint256 proceeds;
        uint256 released;
        uint256 openedAt;
        uint256 uniTokenId;
        uint256 lpPositionId;
    }

    uint256 internal locked = 1;
    mapping(address => Book) internal stored;
    mapping(address => address[]) internal basketAsset;
    mapping(address => uint256[]) internal basketAmount;
    address internal unwindAccount;
    address internal unwindAsset;
    bool internal unwindBasket;
    SwapTypes.SwapInput internal unwindSwap;
}

interface IPreviousBooks {
    function books(address account)
        external
        view
        returns (
            uint256 positionId,
            uint8 kind,
            address asset,
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 principalUsdc,
            uint256 proceeds,
            uint256 released,
            uint256 openedAt,
            uint256 uniTokenId,
            uint256 lpPositionId
        );
}
