//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library AaveLib {
    /// @notice Sendra positionType for Aave supply / borrow positions.
    uint128 constant POSITION_TYPE = 4;

    /// @notice Aave V3 variable rate mode.
    uint256 constant VARIABLE_RATE = 2;

    /// @notice Aave oracle quotes are BASE_CURRENCY with 8 decimals.
    uint256 constant ORACLE_BASE_UNIT = 1e8;

    struct SupplyInput {
        address asset;
        uint256 amount;
        uint16 referralCode;
    }

    struct BorrowInput {
        address asset;
        uint256 amount;
        uint256 interestRateMode;
        uint16 referralCode;
    }

    struct OpenPositionInput {
        SupplyInput supply;
        BorrowInput borrow;
        address user;
    }

    struct ClosePositionInput {
        uint256 positionId;
        address user;
        address collateralAsset;
        address debtAsset;
        uint256 interestRateMode;
    }

    struct PositionSnapshot {
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 collateralUsdcValue;
        uint256 debtUsdcValue;
        uint256 netEquityUsdc;
        uint256 healthFactor;
    }
}
