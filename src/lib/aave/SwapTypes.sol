//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev ABI-compatible with protocol `UniswapLib.SwapInput`.
type Currency is address;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

library SwapTypes {
    enum Protocol {
        UniswapV2,
        UniswapV3,
        UniswapV4
    }

    struct SwapInstruction {
        Protocol protocol;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        address poolOrPair;
        uint24 fee;
        PoolKey poolKey;
    }

    struct SwapInput {
        address tokenIn;
        address tokenOut;
        SwapInstruction[] swapInstructions;
        uint256 amountIn0;
        address to;
    }
}

interface ISwapRouter {
    function executeSwap(SwapTypes.SwapInput calldata input) external;
}
