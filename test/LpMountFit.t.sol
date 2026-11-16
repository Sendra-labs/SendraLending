//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LpMount} from "../src/lib/aave/LpMount.sol";
import {LpTypes} from "../src/lib/aave/LpTypes.sol";
import {SwapTypes} from "../src/lib/aave/SwapTypes.sol";
import {Currency, PoolKey} from "../src/lib/aave/SwapTypes.sol";

contract MintUsdc is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RecordingOrchestrator {
    LpTypes.ExecuteProvideLiquidityInput internal last;

    function provideLiquidity(LpTypes.ExecuteProvideLiquidityInput calldata input)
        external
        returns (uint256, uint256)
    {
        last = input;
        return (7, 9);
    }

    function amountIn0(uint256 which) external view returns (uint256) {
        return which == 0 ? last.swapInput0.amountIn0 : last.swapInput1.amountIn0;
    }

    function hop(uint256 which, uint256 index) external view returns (uint256 amountIn, uint256 amountOut) {
        SwapTypes.SwapInstruction memory inst = which == 0
            ? last.swapInput0.swapInstructions[index]
            : last.swapInput1.swapInstructions[index];
        return (inst.amountIn, inst.amountOut);
    }

    function mintAmounts() external view returns (uint256 amount0, uint256 amount1) {
        return (last.provideLiquidityInput.amount0, last.provideLiquidityInput.amount1);
    }
}

contract CellHarness {
    function owner() external view returns (address) {
        return address(this);
    }

    function mount(address orchestrator, address usdc, bytes calldata encoded) external returns (uint256, uint256) {
        return LpMount.mount(orchestrator, usdc, encoded);
    }
}

/// @dev The borrow is smaller than the quoted route. A two-hop floor lives on the hop with amountIn 0.
contract LpMountFitTest is Test {
    MintUsdc internal usdc;
    RecordingOrchestrator internal orchestrator;
    CellHarness internal cell;

    function setUp() public {
        usdc = new MintUsdc();
        orchestrator = new RecordingOrchestrator();
        cell = new CellHarness();
        usdc.mint(address(cell), 50);
    }

    function test_scalesLastHopFloorWhenBorrowIsSmallerThanQuote() public {
        bytes memory encoded = abi.encode(_lp());

        (uint256 uniId, uint256 lpId) = cell.mount(address(orchestrator), address(usdc), encoded);

        assertEq(uniId, 9);
        assertEq(lpId, 7);
        assertEq(orchestrator.amountIn0(0), 30);
        (uint256 in0, uint256 out0) = orchestrator.hop(0, 0);
        assertEq(in0, 30);
        assertEq(out0, 0);
        (, uint256 floor) = orchestrator.hop(0, 1);
        assertEq(floor, 500);
        assertEq(orchestrator.amountIn0(1), 20);
        (uint256 in1, uint256 out1) = orchestrator.hop(1, 0);
        assertEq(in1, 20);
        assertEq(out1, 200);
        (uint256 amount0, uint256 amount1) = orchestrator.mintAmounts();
        assertEq(amount0, 10);
        assertEq(amount1, 20);
    }

    function _lp() internal view returns (LpTypes.ExecuteProvideLiquidityInput memory lp) {
        address weth = address(0xBEEF);
        SwapTypes.SwapInstruction[] memory hops = new SwapTypes.SwapInstruction[](2);
        hops[0] = _hop(address(usdc), weth, 60, 0);
        hops[1] = _hop(weth, address(0xAAEE), 0, 1000);
        lp.swapInput0 = SwapTypes.SwapInput({
            tokenIn: address(usdc),
            tokenOut: address(0xAAEE),
            swapInstructions: hops,
            amountIn0: 60,
            to: address(0)
        });

        SwapTypes.SwapInstruction[] memory direct = new SwapTypes.SwapInstruction[](1);
        direct[0] = _hop(address(usdc), weth, 40, 400);
        lp.swapInput1 = SwapTypes.SwapInput({
            tokenIn: address(usdc),
            tokenOut: weth,
            swapInstructions: direct,
            amountIn0: 40,
            to: address(0)
        });

        lp.provideLiquidityInput.amount0 = 20;
        lp.provideLiquidityInput.amount1 = 40;
    }

    function _hop(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (SwapTypes.SwapInstruction memory)
    {
        return SwapTypes.SwapInstruction({
            protocol: SwapTypes.Protocol.UniswapV3,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            poolOrPair: address(1),
            fee: 500,
            poolKey: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: address(0)
            })
        });
    }
}
