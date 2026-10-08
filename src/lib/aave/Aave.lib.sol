//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapTypes} from "./SwapTypes.sol";

library AaveLib {
    /// @notice Legacy supply+borrow bundle. Spot already uses type 4, so this stays unused.
    uint128 constant POSITION_TYPE = 4;

    uint8 constant SUPPLY = 5;
    uint8 constant LOOP = 6;
    uint8 constant SHORT = 7;
    uint8 constant LEVERAGED_LP = 8;
    /// @notice One USDC debt, several supplied assets. The first is the collateral that opens the borrow.
    uint8 constant BASKET = 9;

    struct BasketBuy {
        address asset;
        uint16 borrowBps;
        SwapTypes.SwapInput swap;
    }

    uint256 constant BPS = 10_000;
    uint8 constant MAX_LOOPS = 4;
    uint16 constant MAX_BORROW_BPS = 7_500;

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

    /// @notice Price, in Aave oracle units (8 decimals), at which this position's health factor hits 1.
    /// @dev `debtIsQuoted` means the debt asset is the one whose price we solve for (a short).
    ///      Otherwise the collateral asset is the one that can fall into liquidation (a loop).
    function liquidationPrice(
        bool debtIsQuoted,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint8 collateralDecimals,
        uint8 debtDecimals,
        uint256 liquidationThresholdBps,
        uint256 usdcPrice
    ) internal pure returns (uint256 price) {
        if (collateralAmount == 0 || debtAmount == 0 || liquidationThresholdBps == 0 || usdcPrice == 0) return 0;
        if (debtIsQuoted) {
            uint256 collateralBase = collateralAmount * usdcPrice / (10 ** uint256(collateralDecimals));
            return collateralBase * liquidationThresholdBps * (10 ** uint256(debtDecimals)) / (BPS * debtAmount);
        }
        uint256 debtBase = debtAmount * usdcPrice / (10 ** uint256(debtDecimals));
        return debtBase * BPS * (10 ** uint256(collateralDecimals)) / (collateralAmount * liquidationThresholdBps);
    }
}
