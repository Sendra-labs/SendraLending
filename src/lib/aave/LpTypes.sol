//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapTypes} from "./SwapTypes.sol";

/// @dev ABI-compatible with protocol `UniswapLib` liquidity inputs.
library LpTypes {
    struct ProvideLiquidityInput {
        SwapTypes.Protocol protocol;
        address token0;
        address token1;
        address recipient;
        address user;
        uint256 amount0;
        uint256 amount1;
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ExecuteProvideLiquidityInput {
        SwapTypes.SwapInput swapInput0;
        SwapTypes.SwapInput swapInput1;
        SwapTypes.SwapInput invertedSwapInput0;
        SwapTypes.SwapInput invertedSwapInput1;
        ProvideLiquidityInput provideLiquidityInput;
    }

    struct WithdrawLiquidityInput {
        uint128 uniId;
        uint256 positionId;
        address user;
    }

    struct ExecuteWithdrawLiquidityAndCollectFees {
        WithdrawLiquidityInput withdrawLiquidityInput;
        SwapTypes.SwapInput swapInput0;
        SwapTypes.SwapInput swapInput1;
    }
}

interface ILiquidityOrchestrator {
    function provideLiquidity(LpTypes.ExecuteProvideLiquidityInput calldata input)
        external
        returns (uint256 positionId, uint256 tokenId);

    function withdrawLiquidityAndCollectFees(LpTypes.ExecuteWithdrawLiquidityAndCollectFees calldata input)
        external
        returns (uint256);
}

interface INpmEnumerable {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function approve(address to, uint256 tokenId) external;
}

interface IUserCount {
    function getUser(address user)
        external
        view
        returns (
            uint256 id,
            int256 globalPnl,
            uint256 totalPositions,
            uint256 activePositions,
            uint256 transactionCount,
            bytes[] memory userData
        );
}
