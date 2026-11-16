//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwapTypes} from "./SwapTypes.sol";
import {LpTypes, ILiquidityOrchestrator, INpmEnumerable} from "./LpTypes.sol";

library LpMount {
    using SafeERC20 for IERC20;

    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    function mount(
        address orchestrator,
        address usdc,
        bytes calldata encoded
    ) internal returns (uint256 uniId, uint256 lpPositionId) {
        LpTypes.ExecuteProvideLiquidityInput memory lp = abi.decode(encoded, (LpTypes.ExecuteProvideLiquidityInput));
        uint256 budget = IERC20(usdc).balanceOf(address(this));
        uint256 basis = lp.swapInput0.amountIn0 + lp.swapInput1.amountIn0;
        if (budget == 0 || basis == 0) revert EmptyLp();
        _fit(lp.swapInput0, budget, basis);
        _fit(lp.swapInput1, budget, basis);
        lp.provideLiquidityInput.amount0 = lp.provideLiquidityInput.amount0 * budget / basis;
        lp.provideLiquidityInput.amount1 = lp.provideLiquidityInput.amount1 * budget / basis;
        lp.provideLiquidityInput.recipient = address(this);
        lp.provideLiquidityInput.user = ICellOwner(address(this)).owner();

        IERC20(usdc).forceApprove(orchestrator, budget);
        (lpPositionId, uniId) = ILiquidityOrchestrator(orchestrator).provideLiquidity(lp);
    }

    function unwind(address orchestrator, uint256 uniId, uint256 lpPositionId, bytes calldata encoded)
        internal
        returns (uint256 usdcOut)
    {
        LpTypes.ExecuteWithdrawLiquidityAndCollectFees memory exit =
            abi.decode(encoded, (LpTypes.ExecuteWithdrawLiquidityAndCollectFees));
        exit.withdrawLiquidityInput.uniId = uint128(uniId);
        exit.withdrawLiquidityInput.positionId = lpPositionId;
        exit.withdrawLiquidityInput.user = ICellOwner(address(this)).owner();
        INpmEnumerable(NPM).approve(orchestrator, uniId);
        usdcOut = ILiquidityOrchestrator(orchestrator).withdrawLiquidityAndCollectFees(exit);
    }

    function _fit(SwapTypes.SwapInput memory swap, uint256 budget, uint256 basis) private pure {
        uint256 old = swap.amountIn0;
        if (old == 0) return;
        swap.amountIn0 = old * budget / basis;
        uint256 rooted;
        uint256 first = type(uint256).max;
        for (uint256 i = 0; i < swap.swapInstructions.length; i++) {
            uint256 hopIn = swap.swapInstructions[i].amountIn;
            if (hopIn != 0) {
                if (first == type(uint256).max) first = i;
                swap.swapInstructions[i].amountIn = hopIn * budget / basis;
                rooted += swap.swapInstructions[i].amountIn;
            }
            // The output floor sits on the last hop, whose amountIn is 0. It has to move with the borrow.
            uint256 hopOut = swap.swapInstructions[i].amountOut;
            if (hopOut != 0) swap.swapInstructions[i].amountOut = hopOut * budget / basis;
        }
        if (first != type(uint256).max && rooted < swap.amountIn0) {
            swap.swapInstructions[first].amountIn += swap.amountIn0 - rooted;
        }
    }

    error EmptyLp();
}

interface ICellOwner {
    function owner() external view returns (address);
}
