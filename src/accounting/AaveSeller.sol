//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAaveOracle} from "../interfaces/aave/IAaveOracle.sol";

interface ISellerUniRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @notice Sells rescued collateral for USDC. `AaveDesk` delegatecalls, so the tokens stay on the accountant.
contract AaveSeller {
    using SafeERC20 for IERC20;

    address public constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    IAaveOracle public immutable oracle;
    address public immutable usdc;

    constructor(address _oracle, address _usdc) {
        oracle = IAaveOracle(_oracle);
        usdc = _usdc;
    }

    /// @dev Tries 0.05%, 0.30% and 0.01% pools. A 1% floor under the Aave oracle. False if none fills.
    function sell(address asset, uint256 amount) external returns (bool) {
        uint256 price = oracle.getAssetPrice(asset);
        uint256 usdcPrice = oracle.getAssetPrice(usdc);
        if (price == 0 || usdcPrice == 0) return false;
        uint256 minOut = amount * price * (10 ** uint256(_decimals(usdc))) / usdcPrice / (10 ** uint256(_decimals(asset)));
        minOut = minOut * 99 / 100;
        IERC20(asset).forceApprove(UNI_ROUTER, amount);
        uint24[3] memory fees = [uint24(500), 3000, 100];
        for (uint256 i = 0; i < fees.length; i++) {
            try ISellerUniRouter(UNI_ROUTER).exactInputSingle(
                ISellerUniRouter.ExactInputSingleParams({
                    tokenIn: asset,
                    tokenOut: usdc,
                    fee: fees[i],
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 out) {
                if (out > 0) return true;
            } catch {}
        }
        return false;
    }

    function _decimals(address asset) internal view returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }
}
