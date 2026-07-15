/*
________________________________________________________________

  █████████                          █████
 ███▒▒▒▒▒███                        ▒▒███
▒███    ▒▒▒   ██████  ████████    ███████  ████████   ██████
▒▒█████████  ███▒▒███▒▒███▒▒███  ███▒▒███ ▒▒███▒▒███ ▒▒▒▒▒███
 ▒▒▒▒▒▒▒▒███▒███████  ▒███ ▒███ ▒███ ▒███  ▒███ ▒▒▒   ███████
 ███    ▒███▒███▒▒▒   ▒███ ▒███ ▒███ ▒███  ▒███      ███▒▒███
▒▒█████████ ▒▒██████  ████ █████▒▒████████ █████    ▒▒████████
 ▒▒▒▒▒▒▒▒▒   ▒▒▒▒▒▒  ▒▒▒▒ ▒▒▒▒▒  ▒▒▒▒▒▒▒▒ ▒▒▒▒▒      ▒▒▒▒▒▒▒▒

 █████                 █████
▒▒███                 ▒▒███
 ▒███         ██████   ▒███████   █████
 ▒███        ▒▒▒▒▒███  ▒███▒▒███ ███▒▒
 ▒███         ███████  ▒███ ▒███▒▒█████
 ▒███      █ ███▒▒███  ▒███ ▒███ ▒▒▒▒███
 ███████████▒▒████████ ████████  ██████
▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒▒▒ ▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒    Aave Orchestrator
________________________________________________________________
*/

//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AaveManager} from "./AaveManager.sol";
import {ISendraAddressProvider} from "../../../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {ISendraStorage} from "../../../interfaces/iSendraCore/ISendraStorage.sol";
import {IPositionInitializer} from "../../../interfaces/iSendraCore/IPositionInitializer.sol";
import {SendraLib} from "../../../lib/Sendra.lib.sol";
import {AaveLib} from "../../../lib/aave/Aave.lib.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";

/**
 * @title AaveOrchestrator
 * @notice Opens / closes Aave positions (supply collateral + borrow) and writes SendraPulse accounting
 *         against the existing protocol `SendraStorage` / `PositionInitializer` via AddressProvider.
 * @dev Position type = 4. Must be whitelisted as a protocol contract in Sendra `Roles`.
 *      User must credit-delegate variable debt to AaveManager before open,
 *      and approve aToken + debt asset to this orchestrator before close.
 *
 * positionData layout:
 * [0]  collateralAsset
 * [1]  debtAsset
 * [2]  openDate
 * [3]  supplyAmount
 * [4]  borrowAmount
 * [5]  interestRateMode
 * [6]  aToken
 * [7]  variableDebtToken
 * [8]  initialCollateralUsdcValue
 * [9]  initialDebtUsdcValue
 * [10] initialNetEquityUsdc
 * [11] healthFactorAtOpen
 * [12] finalUsdcValue
 * [13] finalDebtUsdcValue
 * [14] finalNetEquityUsdc
 * [15] initialPositionUsdcValue
 * [16] closeDate
 * [17] chainId
 * [18] collateralPriceAtOpen
 * [19] debtPriceAtOpen
 */
contract AaveOrchestrator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable addressProvider;
    AaveManager public immutable aaveManager;
    ISendraStorage public immutable sendraStorage;
    IAaveOracle public immutable oracle;

    error InvalidUser();
    error InvalidAmount();
    error InvalidRateMode();
    error PositionInactive();
    error PositionTypeMismatch();

    constructor(address _addressProvider) {
        addressProvider = _addressProvider;
        ISendraAddressProvider ap = ISendraAddressProvider(_addressProvider);
        aaveManager = AaveManager(ap.getAddress("AaveManager"));
        sendraStorage = ISendraStorage(ap.getAddress("SendraStorage"));
        oracle = IAaveOracle(ap.getAddress("AaveOracle"));
    }

    /**
     * @notice Supplies collateral and borrows against it, then registers a Sendra position type 4.
     * @param _input Supply + borrow parameters. `_input.user` must equal `msg.sender`.
     */
    function openSupplyAndBorrow(AaveLib.OpenPositionInput calldata _input) external nonReentrant {
        if (_input.user != msg.sender) revert InvalidUser();
        if (_input.supply.amount == 0 || _input.borrow.amount == 0) revert InvalidAmount();
        if (_input.borrow.interestRateMode != AaveLib.VARIABLE_RATE) revert InvalidRateMode();

        address user = _input.user;
        address collateral = _input.supply.asset;
        address debtAsset = _input.borrow.asset;

        IERC20(collateral).safeTransferFrom(user, address(this), _input.supply.amount);
        IERC20(collateral).forceApprove(address(aaveManager), _input.supply.amount);
        aaveManager.supply(collateral, _input.supply.amount, user, _input.supply.referralCode);

        aaveManager.borrow(
            debtAsset,
            _input.borrow.amount,
            _input.borrow.interestRateMode,
            _input.borrow.referralCode,
            user,
            user
        );

        (address aToken,,) = aaveManager.getReserveTokens(collateral);
        (,, address variableDebtToken) = aaveManager.getReserveTokens(debtAsset);

        uint256 collateralUsdc = aaveManager.assetToUsdc(collateral, _input.supply.amount);
        uint256 debtUsdc = aaveManager.assetToUsdc(debtAsset, _input.borrow.amount);
        uint256 netEquity = collateralUsdc > debtUsdc ? collateralUsdc - debtUsdc : 0;

        (,,,,, uint256 healthFactor) = aaveManager.getAccountData(user);

        bytes[] memory positionData = new bytes[](20);
        positionData[0] = abi.encode(collateral);
        positionData[1] = abi.encode(debtAsset);
        positionData[2] = abi.encode(block.timestamp);
        positionData[3] = abi.encode(_input.supply.amount);
        positionData[4] = abi.encode(_input.borrow.amount);
        positionData[5] = abi.encode(_input.borrow.interestRateMode);
        positionData[6] = abi.encode(aToken);
        positionData[7] = abi.encode(variableDebtToken);
        positionData[8] = abi.encode(collateralUsdc);
        positionData[9] = abi.encode(debtUsdc);
        positionData[10] = abi.encode(netEquity);
        positionData[11] = abi.encode(healthFactor);
        positionData[12] = abi.encode(uint256(0));
        positionData[13] = abi.encode(uint256(0));
        positionData[14] = abi.encode(uint256(0));
        positionData[15] = abi.encode(collateralUsdc);
        positionData[16] = abi.encode(uint256(0));
        positionData[17] = abi.encode(block.chainid);
        positionData[18] = abi.encode(oracle.getAssetPrice(collateral));
        positionData[19] = abi.encode(oracle.getAssetPrice(debtAsset));

        IPositionInitializer(ISendraAddressProvider(addressProvider).getAddress("PositionInitializer")).initializePosition(
            positionData, AaveLib.POSITION_TYPE, user
        );

        _applyOpenPulse(user, collateralUsdc);
    }

    /**
     * @notice Repays debt, withdraws collateral and closes the Sendra position with pulse PnL.
     * @dev User must approve debt asset and aToken to this contract beforehand.
     */
    function closePosition(AaveLib.ClosePositionInput calldata _input) external nonReentrant returns (uint256 usdcOut) {
        if (_input.user != msg.sender) revert InvalidUser();

        SendraLib.Position memory position = sendraStorage.getUserPositionById(_input.user, _input.positionId);
        if (!position.isActive) revert PositionInactive();
        if (position.positionType != AaveLib.POSITION_TYPE) revert PositionTypeMismatch();

        address collateral = abi.decode(position.positionData[0], (address));
        address debtAsset = abi.decode(position.positionData[1], (address));
        uint256 rateMode = abi.decode(position.positionData[5], (uint256));
        address aToken = abi.decode(position.positionData[6], (address));
        address variableDebtToken = abi.decode(position.positionData[7], (address));
        uint256 initialUsdc = abi.decode(position.positionData[15], (uint256));

        if (
            collateral != _input.collateralAsset || debtAsset != _input.debtAsset
                || rateMode != _input.interestRateMode
        ) {
            revert PositionTypeMismatch();
        }

        AaveLib.PositionSnapshot memory beforeClose =
            aaveManager.snapshot(_input.user, collateral, debtAsset, variableDebtToken);

        uint256 debtAmount = IERC20(variableDebtToken).balanceOf(_input.user);
        if (debtAmount > 0) {
            IERC20(debtAsset).safeTransferFrom(_input.user, address(this), debtAmount);
            IERC20(debtAsset).forceApprove(address(aaveManager), debtAmount);
            aaveManager.repay(debtAsset, type(uint256).max, rateMode, _input.user);
        }

        uint256 aTokenBalance = IERC20(aToken).balanceOf(_input.user);
        IERC20(aToken).safeTransferFrom(_input.user, address(aaveManager), aTokenBalance);
        usdcOut = aaveManager.withdraw(collateral, type(uint256).max, _input.user);

        position.isActive = false;
        position.pnl = int256(usdcOut) - int256(initialUsdc);
        position.positionData[12] = abi.encode(usdcOut);
        position.positionData[13] = abi.encode(beforeClose.debtUsdcValue);
        position.positionData[14] =
            abi.encode(usdcOut > beforeClose.debtUsdcValue ? usdcOut - beforeClose.debtUsdcValue : uint256(0));
        position.positionData[16] = abi.encode(block.timestamp);

        sendraStorage.decreaseGlobalPositionActivePositions(_input.user);
        sendraStorage.updateUserFullPosition(_input.user, _input.positionId, position);
        sendraStorage.updateUserGlobalPnl(_input.user, position.pnl);

        _applyClosePulse(_input.user, position, usdcOut, initialUsdc);

        return usdcOut;
    }

    function _applyOpenPulse(address user, uint256 capitalUsdc) internal {
        uint8[] memory gFieldIds = new uint8[](5);
        int256[] memory gDeltas = new int256[](5);
        uint8[] memory sFieldIds = new uint8[](2);
        int256[] memory sDeltas = new int256[](2);

        uint256 peakExposure = uint256(sendraStorage.getUniqueGlobalAccumulator(2, user));
        uint256 currentExposure = uint256(sendraStorage.getUniqueGlobalAccumulator(3, user));
        uint256 lastActivityTimestamp = uint256(sendraStorage.getUniqueGlobalAccumulator(15, user));
        uint256 newExposure = currentExposure + capitalUsdc;

        gFieldIds[0] = 0;
        gDeltas[0] = int256(capitalUsdc);

        gFieldIds[1] = 2;
        gDeltas[1] = newExposure > peakExposure ? int256(newExposure - peakExposure) : int256(0);

        gFieldIds[2] = 3;
        gDeltas[2] = int256(capitalUsdc);

        gFieldIds[3] = 9;
        gDeltas[3] = 1;

        gFieldIds[4] = 15;
        gDeltas[4] = int256(block.timestamp - lastActivityTimestamp);

        sFieldIds[0] = 1;
        sDeltas[0] = int256(capitalUsdc);
        sFieldIds[1] = 5;
        sDeltas[1] = 1;

        _updateAccumulators(user, gFieldIds, gDeltas, sFieldIds, sDeltas);
    }

    function _applyClosePulse(
        address user,
        SendraLib.Position memory position,
        uint256 capitalOut,
        uint256 initialUsdc
    ) internal {
        uint8[] memory gFieldIds = new uint8[](14);
        int256[] memory gDeltas = new int256[](14);
        uint8[] memory sFieldIds = new uint8[](3);
        int256[] memory sDeltas = new int256[](3);

        int256 highWaterMark = sendraStorage.getUniqueGlobalAccumulator(7, user);
        int256 currentPnl = sendraStorage.getUniqueGlobalAccumulator(4, user);
        int256 newPnl = currentPnl + position.pnl;
        int256 maxDrawdown = sendraStorage.getUniqueGlobalAccumulator(8, user);
        int256 consecutiveLosses = sendraStorage.getUniqueGlobalAccumulator(17, user);
        int256 maxConsecutiveLosses = sendraStorage.getUniqueGlobalAccumulator(18, user);
        uint256 lastActivityTimestamp = uint256(sendraStorage.getUniqueGlobalAccumulator(15, user));
        uint256 openDate = abi.decode(position.positionData[2], (uint256));

        gFieldIds[0] = 1;
        gDeltas[0] = int256(capitalOut);

        gFieldIds[1] = 3;
        gDeltas[1] = -int256(initialUsdc);

        gFieldIds[2] = 4;
        gDeltas[2] = position.pnl;

        gFieldIds[4] = 7;
        gFieldIds[5] = 8;
        gFieldIds[6] = 10;
        gDeltas[6] = 1;
        gFieldIds[7] = 11;
        gFieldIds[8] = 12;

        if (position.pnl > 0) {
            gFieldIds[3] = 5;
            gDeltas[3] = position.pnl;
            gDeltas[4] = highWaterMark < newPnl ? int256(newPnl - highWaterMark) : int256(0);
            gDeltas[5] = 0;
            gDeltas[7] = 1;
            gDeltas[8] = 0;
        } else {
            gFieldIds[3] = 6;
            gDeltas[3] = -position.pnl;
            gDeltas[4] = int256(0);
            int256 drawdown = (newPnl < highWaterMark) ? int256(highWaterMark - newPnl) : int256(0);
            gDeltas[5] = maxDrawdown < drawdown ? drawdown - maxDrawdown : int256(0);
            gDeltas[7] = 0;
            gDeltas[8] = 1;
        }

        gFieldIds[9] = 13;
        gDeltas[9] = int256(block.timestamp - openDate);

        gFieldIds[10] = 15;
        gDeltas[10] = int256(block.timestamp - lastActivityTimestamp);

        gFieldIds[11] = 17;
        gFieldIds[12] = 18;
        gFieldIds[13] = 19;

        if (position.pnl < 0) {
            int256 newStreak = consecutiveLosses + 1;
            gDeltas[11] = int256(1);
            gDeltas[12] = newStreak > maxConsecutiveLosses ? int256(newStreak - maxConsecutiveLosses) : int256(0);
            gDeltas[13] = int256(initialUsdc);
        } else if (position.pnl > 0) {
            gDeltas[11] = consecutiveLosses > 0 ? -consecutiveLosses : int256(0);
            gDeltas[12] = int256(0);
            gDeltas[13] = int256(0);
        }

        sFieldIds[0] = 0;
        sDeltas[0] = position.pnl;
        sFieldIds[1] = 2;
        sDeltas[1] = int256(capitalOut);

        if (position.pnl > 0) {
            sFieldIds[2] = 3;
            sDeltas[2] = 1;
        } else {
            sFieldIds[2] = 4;
            sDeltas[2] = 1;
        }

        sendraStorage.applyMetricDelta(
            user, uint64(AaveLib.POSITION_TYPE), 0, int256(beforeCloseInterestPaid(initialUsdc, capitalOut))
        );
        sendraStorage.applyMetricDelta(user, uint64(AaveLib.POSITION_TYPE), 1, int256(block.timestamp - openDate));

        _updateAccumulators(user, gFieldIds, gDeltas, sFieldIds, sDeltas);
    }

    function beforeCloseInterestPaid(uint256 initialUsdc, uint256 capitalOut) internal pure returns (uint256) {
        return capitalOut < initialUsdc ? initialUsdc - capitalOut : 0;
    }

    function _updateAccumulators(
        address user,
        uint8[] memory gFieldIds,
        int256[] memory gDeltas,
        uint8[] memory sFieldIds,
        int256[] memory sDeltas
    ) internal {
        sendraStorage.applyGlobalPulseDeltas(user, gFieldIds, gDeltas);
        sendraStorage.applySpecificPulseDeltas(user, uint64(AaveLib.POSITION_TYPE), sFieldIds, sDeltas);
    }
}
