//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { AaveLib } from "../src/lib/aave/Aave.lib.sol";

contract LiquidationPriceTest is Test {
    function test_loopLiquidatesWhenTheAssetFalls() public pure {
        // 1 WBTC collateral, 50_000 USDC debt, 80% threshold, USDC price 1e8.
        uint256 price = AaveLib.liquidationPrice(false, 1e8, 50_000e6, 8, 6, 8_000, 1e8);
        assertEq(price, 62_500e8);
    }

    function test_shortLiquidatesWhenTheAssetRises() public pure {
        // 50_000 USDC collateral, 1 WBTC debt, 80% threshold.
        uint256 price = AaveLib.liquidationPrice(true, 50_000e6, 1e8, 6, 8, 8_000, 1e8);
        assertEq(price, 40_000e8);
    }

    function test_supplyHasNoLiquidationPrice() public pure {
        assertEq(AaveLib.liquidationPrice(false, 1e8, 0, 8, 6, 8_000, 1e8), 0);
    }
}
