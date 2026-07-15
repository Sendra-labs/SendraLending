//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveManager} from "../src/core/aave/executors/AaveManager.sol";
import {AaveOrchestrator} from "../src/core/aave/executors/AaveOrchestrator.sol";
import {AaveLib} from "../src/lib/aave/Aave.lib.sol";
import {SendraLib} from "../src/lib/Sendra.lib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDebtToken is ERC20 {
    mapping(address => mapping(address => uint256)) public borrowAllowances;

    constructor() ERC20("variableDebtWBTC", "vdWBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function approveDelegation(address delegatee, uint256 amount) external {
        borrowAllowances[msg.sender][delegatee] = amount;
    }
}

contract MockAToken is ERC20 {
    constructor() ERC20("aUSDC", "aUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockPool {
    MockERC20 public usdc;
    MockERC20 public wbtc;
    MockAToken public aUsdc;
    MockDebtToken public vdWbtc;

    constructor(MockERC20 usdc_, MockERC20 wbtc_, MockAToken aUsdc_, MockDebtToken vdWbtc_) {
        usdc = usdc_;
        wbtc = wbtc_;
        aUsdc = aUsdc_;
        vdWbtc = vdWbtc_;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(usdc), "asset");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aUsdc.mint(onBehalfOf, amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        require(asset == address(wbtc), "asset");
        require(vdWbtc.borrowAllowances(onBehalfOf, msg.sender) >= amount, "delegation");
        vdWbtc.mint(onBehalfOf, amount);
        wbtc.mint(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        require(asset == address(wbtc), "asset");
        uint256 debt = vdWbtc.balanceOf(onBehalfOf);
        uint256 pay = amount == type(uint256).max ? debt : amount;
        if (pay > debt) pay = debt;
        IERC20(asset).transferFrom(msg.sender, address(this), pay);
        vdWbtc.burn(onBehalfOf, pay);
        return pay;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(usdc), "asset");
        uint256 bal = aUsdc.balanceOf(msg.sender);
        uint256 burnAmount = amount == type(uint256).max ? bal : amount;
        aUsdc.burn(msg.sender, burnAmount);
        usdc.transfer(to, burnAmount);
        return burnAmount;
    }

    function getUserAccountData(address)
        external
        pure
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (1e8, 5e7, 5e7, 8000, 7500, 2e18);
    }
}

contract MockOracle {
    mapping(address => uint256) public prices;

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
}

contract MockDataProvider {
    address public aToken;
    address public vdToken;

    constructor(address aToken_, address vdToken_) {
        aToken = aToken_;
        vdToken = vdToken_;
    }

    function getReserveTokensAddresses(address) external view returns (address, address, address) {
        return (aToken, address(0), vdToken);
    }
}

contract MockAddressProvider {
    mapping(string => address) public addressMap;

    function setAddress(string calldata name, address addr) external {
        addressMap[name] = addr;
    }

    function getAddress(string calldata name) external view returns (address) {
        address addr = addressMap[name];
        require(addr != address(0), "AddressNotFound");
        return addr;
    }
}

/// @dev Minimal stand-in for protocol SendraStorage used only in unit tests.
contract MockSendraStorage {
    mapping(address => SendraLib.Position[]) internal positions;
    mapping(address => mapping(uint8 => int256)) public globalAcc;

    function getUser(address user) external view returns (SendraLib.UserInfoRead memory info) {
        info.totalPositions = positions[user].length;
    }

    function updateUserTransactionCount(address, uint256) external {}

    function addPositionToUser(address user, SendraLib.Position memory position) external {
        positions[user].push(position);
        // mimic 1-indexed ids used by protocol: overwrite id slot by pushing then fixing
        positions[user][positions[user].length - 1].id = positions[user].length;
    }

    function updateUserFullPosition(address user, uint256 positionId, SendraLib.Position memory position) external {
        positions[user][positionId - 1] = position;
    }

    function updateUserGlobalPnl(address, int256) external {}

    function decreaseGlobalPositionActivePositions(address) external {}

    function applyGlobalPulseDeltas(address user, uint8[] calldata fieldIds, int256[] calldata deltas) external {
        for (uint256 i = 0; i < fieldIds.length; i++) {
            globalAcc[user][fieldIds[i]] += deltas[i];
        }
    }

    function applySpecificPulseDeltas(address, uint64, uint8[] calldata, int256[] calldata) external {}

    function applyMetricDelta(address, uint64, uint256, int256) external {}

    function getUniqueGlobalAccumulator(uint8 fieldId, address user) external view returns (int256) {
        return globalAcc[user][fieldId];
    }

    function getUserPositionById(address user, uint256 positionId) external view returns (SendraLib.Position memory) {
        return positions[user][positionId - 1];
    }
}

contract MockPositionInitializer {
    MockSendraStorage public sendraStorage;

    constructor(MockSendraStorage sendraStorage_) {
        sendraStorage = sendraStorage_;
    }

    function initializePosition(bytes[] memory data, uint128 positionType, address user) external {
        uint256 positionId = sendraStorage.getUser(user).totalPositions + 1;
        sendraStorage.addPositionToUser(
            user,
            SendraLib.Position({
                positionType: positionType,
                id: positionId,
                pnl: 0,
                isActive: true,
                positionData: data
            })
        );
    }
}

contract AaveOrchestratorTest is Test {
    MockAddressProvider addressProvider;
    MockSendraStorage sendraStorage;
    AaveOrchestrator orchestrator;
    AaveManager aaveManager;

    MockERC20 usdc;
    MockERC20 wbtc;
    MockAToken aUsdc;
    MockDebtToken vdWbtc;
    MockPool pool;
    MockOracle oracle;

    address user = address(0xB0);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        aUsdc = new MockAToken();
        vdWbtc = new MockDebtToken();
        pool = new MockPool(usdc, wbtc, aUsdc, vdWbtc);
        oracle = new MockOracle();
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wbtc), 100_000e8);

        MockDataProvider dataProvider = new MockDataProvider(address(aUsdc), address(vdWbtc));
        sendraStorage = new MockSendraStorage();
        MockPositionInitializer initializer = new MockPositionInitializer(sendraStorage);

        addressProvider = new MockAddressProvider();
        addressProvider.setAddress("AavePool", address(pool));
        addressProvider.setAddress("AaveOracle", address(oracle));
        addressProvider.setAddress("AaveProtocolDataProvider", address(dataProvider));
        addressProvider.setAddress("SendraStorage", address(sendraStorage));
        addressProvider.setAddress("PositionInitializer", address(initializer));

        aaveManager = new AaveManager(address(addressProvider));
        addressProvider.setAddress("AaveManager", address(aaveManager));

        orchestrator = new AaveOrchestrator(address(addressProvider));
        addressProvider.setAddress("AaveOrchestrator", address(orchestrator));

        usdc.mint(user, 10_000e6);
        usdc.mint(address(pool), 1_000_000e6);
    }

    function test_openSupplyAndBorrow_updatesGlobalPulse() public {
        uint256 supplyAmount = 1_000e6;
        uint256 borrowAmount = 0.005e8;

        vm.startPrank(user);
        vdWbtc.approveDelegation(address(aaveManager), type(uint256).max);
        usdc.approve(address(orchestrator), supplyAmount);

        orchestrator.openSupplyAndBorrow(
            AaveLib.OpenPositionInput({
                supply: AaveLib.SupplyInput({asset: address(usdc), amount: supplyAmount, referralCode: 0}),
                borrow: AaveLib.BorrowInput({
                    asset: address(wbtc),
                    amount: borrowAmount,
                    interestRateMode: AaveLib.VARIABLE_RATE,
                    referralCode: 0
                }),
                user: user
            })
        );
        vm.stopPrank();

        SendraLib.Position memory position = sendraStorage.getUserPositionById(user, 1);
        assertTrue(position.isActive);
        assertEq(position.positionType, AaveLib.POSITION_TYPE);
        assertEq(abi.decode(position.positionData[3], (uint256)), supplyAmount);
        assertEq(uint256(sendraStorage.getUniqueGlobalAccumulator(0, user)), 1_000e6);
        assertEq(uint256(sendraStorage.getUniqueGlobalAccumulator(9, user)), 1);
        assertEq(wbtc.balanceOf(user), borrowAmount);
    }

    function test_closePosition_realizesPnlPulse() public {
        uint256 supplyAmount = 1_000e6;
        uint256 borrowAmount = 0.005e8;

        vm.startPrank(user);
        vdWbtc.approveDelegation(address(aaveManager), type(uint256).max);
        usdc.approve(address(orchestrator), supplyAmount);
        orchestrator.openSupplyAndBorrow(
            AaveLib.OpenPositionInput({
                supply: AaveLib.SupplyInput({asset: address(usdc), amount: supplyAmount, referralCode: 0}),
                borrow: AaveLib.BorrowInput({
                    asset: address(wbtc),
                    amount: borrowAmount,
                    interestRateMode: AaveLib.VARIABLE_RATE,
                    referralCode: 0
                }),
                user: user
            })
        );

        wbtc.approve(address(orchestrator), type(uint256).max);
        aUsdc.approve(address(orchestrator), type(uint256).max);

        uint256 usdcOut = orchestrator.closePosition(
            AaveLib.ClosePositionInput({
                positionId: 1,
                user: user,
                collateralAsset: address(usdc),
                debtAsset: address(wbtc),
                interestRateMode: AaveLib.VARIABLE_RATE
            })
        );
        vm.stopPrank();

        SendraLib.Position memory position = sendraStorage.getUserPositionById(user, 1);
        assertFalse(position.isActive);
        assertEq(usdcOut, supplyAmount);
        assertEq(uint256(sendraStorage.getUniqueGlobalAccumulator(10, user)), 1);
        assertEq(uint256(sendraStorage.getUniqueGlobalAccumulator(3, user)), 0);
    }
}
