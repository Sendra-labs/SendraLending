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
▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒▒▒ ▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒    Aave Manager
________________________________________________________________
*/

//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";
import {IAaveProtocolDataProvider} from "../../../interfaces/aave/IAaveProtocolDataProvider.sol";
import {ISendraAddressProvider} from "../../../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {AaveLib} from "../../../lib/aave/Aave.lib.sol";

/**
 * @title AaveManager
 * @notice Thin adapter over Aave V3 Pool supply / borrow / repay / withdraw.
 * @dev Resolves Aave addresses from Sendra `AddressProvider`. Borrow-on-behalf requires
 *      the user to `approveDelegation` the variable debt token to this manager.
 */
contract AaveManager {
    using SafeERC20 for IERC20;

    address public immutable addressProvider;
    IPool public immutable pool;
    IAaveOracle public immutable oracle;
    IAaveProtocolDataProvider public immutable dataProvider;

    constructor(address _addressProvider) {
        addressProvider = _addressProvider;
        pool = IPool(ISendraAddressProvider(_addressProvider).getAddress("AavePool"));
        oracle = IAaveOracle(ISendraAddressProvider(_addressProvider).getAddress("AaveOracle"));
        dataProvider = IAaveProtocolDataProvider(
            ISendraAddressProvider(_addressProvider).getAddress("AaveProtocolDataProvider")
        );
    }

    /**
     * @notice Supplies `amount` of `asset` to Aave; aTokens are minted to `onBehalfOf`.
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        pool.supply(asset, amount, onBehalfOf, referralCode);
    }

    /**
     * @notice Borrows `amount` of `asset` onto `onBehalfOf` and forwards tokens to `recipient`.
     * @dev Requires credit delegation from `onBehalfOf` to this contract on the variable debt token.
     */
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf,
        address recipient
    ) external {
        pool.borrow(asset, amount, interestRateMode, referralCode, onBehalfOf);
        IERC20(asset).safeTransfer(recipient, amount);
    }

    /**
     * @notice Repays debt for `onBehalfOf`, pulling repayment tokens from the caller.
     */
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256 repaid)
    {
        uint256 pullAmount = amount;
        if (amount == type(uint256).max) {
            pullAmount = IERC20(asset).balanceOf(msg.sender);
        }
        IERC20(asset).safeTransferFrom(msg.sender, address(this), pullAmount);
        IERC20(asset).forceApprove(address(pool), pullAmount);
        repaid = pool.repay(asset, amount, interestRateMode, onBehalfOf);

        uint256 left = IERC20(asset).balanceOf(address(this));
        if (left > 0) {
            IERC20(asset).safeTransfer(msg.sender, left);
        }
    }

    /**
     * @notice Withdraws underlying using aTokens already held by this manager.
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        return pool.withdraw(asset, amount, to);
    }

    /**
     * @notice Returns aToken / debt token addresses for a reserve.
     */
    function getReserveTokens(address asset)
        external
        view
        returns (address aToken, address stableDebtToken, address variableDebtToken)
    {
        return dataProvider.getReserveTokensAddresses(asset);
    }

    /**
     * @notice Reads Aave account data for `user`.
     */
    function getAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return pool.getUserAccountData(user);
    }

    /**
     * @notice Converts `amount` of `asset` into USDC units (6 decimals) using Aave oracle.
     */
    function assetToUsdc(address asset, uint256 amount) public view returns (uint256) {
        uint8 decimals = IERC20Metadata(asset).decimals();
        uint256 price = oracle.getAssetPrice(asset);
        return (amount * price) / (10 ** uint256(decimals)) / 1e2;
    }

    /**
     * @notice Builds a USD/USDC mark-to-market snapshot for an Aave account.
     */
    function snapshot(address user, address collateralAsset, address debtAsset, address variableDebtToken)
        external
        view
        returns (AaveLib.PositionSnapshot memory snap)
    {
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        (address aToken,,) = dataProvider.getReserveTokensAddresses(collateralAsset);

        snap.collateralAmount = IERC20(aToken).balanceOf(user);
        snap.debtAmount = IERC20(variableDebtToken).balanceOf(user);
        snap.collateralUsdcValue = assetToUsdc(collateralAsset, snap.collateralAmount);
        snap.debtUsdcValue = assetToUsdc(debtAsset, snap.debtAmount);
        snap.netEquityUsdc =
            snap.collateralUsdcValue > snap.debtUsdcValue ? snap.collateralUsdcValue - snap.debtUsdcValue : 0;
        snap.healthFactor = healthFactor;
    }
}
