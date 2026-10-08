//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AaveManager} from "../core/aave/executors/AaveManager.sol";
import {AaveDesk} from "./AaveDesk.sol";
import {AaveLedger} from "./AaveLedger.sol";
import {AaveStore, IPreviousBooks} from "./AaveStore.sol";
import {ILendingAccount} from "../interfaces/ILendingAccount.sol";
import {ISendraAddressProvider} from "../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {IAaveOracle} from "../interfaces/aave/IAaveOracle.sol";
import {IAaveProtocolDataProvider} from "../interfaces/aave/IAaveProtocolDataProvider.sol";
import {AaveLib} from "../lib/aave/Aave.lib.sol";
import {SwapTypes} from "../lib/aave/SwapTypes.sol";

interface IAccountGate {
    function isProtocolAccount(address account) external view returns (bool);
}

/**
 * @title AaveAccountant
 * @notice One open Aave strategy per lending account. Opens and closes run in `AaveDesk`
 *         via delegatecall so this contract stays inside the 24KB limit.
 *
 * 5 supply   deposit the asset and keep the Aave supply yield
 * 6 loop     USDC -> asset -> collateral, then borrow USDC and buy more, up to 4 times
 * 7 short    USDC collateral -> borrow the asset -> sell it. Sale USDC can be released to the owner
 * 8 lp       buy the asset, post it, borrow USDC and leave it on the account for a Uniswap position
 * 9 basket   post one collateral, then borrow USDC and buy up to three other assets
 */
contract AaveAccountant is AaveStore {
    ISendraAddressProvider public immutable addressProvider;
    IAccountGate public immutable accounts;
    AaveManager public immutable aave;
    IAaveOracle public immutable oracle;
    IAaveProtocolDataProvider public immutable data;
    AaveLedger public immutable ledger;
    AaveDesk public immutable desk;
    address public immutable usdc;

    /// @dev Books still sitting on the accountants this one replaces.
    address public constant PREVIOUS_ACCOUNTANT = 0x7F7F49fA9b935a9C1564FBBA0611E4C3D55c078B;
    address public constant EARLIER_ACCOUNTANT = 0xEb4a50a13EE9760e89f34cA17c42BfE4F57d74a3;

    constructor(address _addressProvider) {
        addressProvider = ISendraAddressProvider(_addressProvider);
        accounts = IAccountGate(addressProvider.getAddress("AccountAccessControl"));
        aave = AaveManager(addressProvider.getAddress("AaveManager"));
        oracle = IAaveOracle(addressProvider.getAddress("AaveOracle"));
        data = IAaveProtocolDataProvider(addressProvider.getAddress("AaveProtocolDataProvider"));
        usdc = addressProvider.getAddress("USDC");
        ledger = new AaveLedger(_addressProvider, address(this));
        desk = new AaveDesk(
            address(this),
            address(aave),
            addressProvider.getAddress("SwapRouter"),
            addressProvider.getAddress("SendraStorage"),
            address(ledger),
            address(oracle),
            address(data),
            usdc
        );
    }

    modifier onlyAccount() {
        if (!accounts.isProtocolAccount(msg.sender)) revert NotAccount();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    function openSupply(address, address, uint256, SwapTypes.SwapInput calldata) external onlyAccount nonReentrant {
        _callDesk();
    }

    function openLoop(address, address, uint256, uint8, uint16, SwapTypes.SwapInput calldata)
        external
        onlyAccount
        nonReentrant
    {
        _callDesk();
    }

    function openShort(address, address, uint256, uint8, uint16, bool, SwapTypes.SwapInput calldata)
        external
        onlyAccount
        nonReentrant
    {
        _callDesk();
    }

    function openLeveraged(address, address, uint256, uint16, SwapTypes.SwapInput calldata, bool)
        external
        onlyAccount
        nonReentrant
        returns (uint256 positionId)
    {
        positionId = abi.decode(_callDesk(), (uint256));
    }

    function openBasket(address, address, uint256, SwapTypes.SwapInput calldata, AaveLib.BasketBuy[] calldata)
        external
        onlyAccount
        nonReentrant
    {
        _callDesk();
    }

    function settleLeveraged(address, uint256) external onlyAccount nonReentrant {
        _callDesk();
    }

    function close(address, uint256, SwapTypes.SwapInput calldata) external onlyAccount nonReentrant {
        _callDesk();
    }

    /// @dev The pool calls here while `close` is still inside `nonReentrant`. Do not take the lock again.
    function executeOperation(address, uint256, uint256, address, bytes calldata) external returns (bool ok) {
        ok = abi.decode(_callDesk(), (bool));
    }

    function sealLp(address owner, uint256 positionId, uint256 uniTokenId, uint256 lpPositionId)
        external
        onlyAccount
        nonReentrant
    {
        address account = _account(owner);
        Book storage book = stored[account];
        if (book.positionId != positionId || book.kind != AaveLib.LEVERAGED_LP) revert PositionNotFound();
        book.uniTokenId = uniTokenId;
        book.lpPositionId = lpPositionId;
        ledger.recordUpdate(owner, account, _fields(book));
    }

    /// @dev USDC borrowed that the LP did not use. It went back to the owner, so it is not principal.
    function noteRefund(address owner, uint256 positionId, uint256 dust) external onlyAccount {
        address account = _account(owner);
        Book storage book = stored[account];
        if (book.positionId != positionId) revert PositionNotFound();
        if (dust == 0) return;
        if (dust > book.principalUsdc) dust = book.principalUsdc;
        book.principalUsdc -= dust;
        ledger.recordUpdate(owner, account, _fields(book));
    }

    function release(address owner, uint256 positionId) external onlyAccount nonReentrant {
        address account = _account(owner);
        Book storage book = stored[account];
        if (book.positionId != positionId || book.kind != AaveLib.SHORT) revert PositionNotFound();
        uint256 left = book.proceeds - book.released;
        if (left == 0) revert InvalidAmount();
        _release(account, left);
    }

    /// @notice Book on this accountant, or the one still stored on the accountant it replaced.
    function books(address account)
        external
        view
        returns (
            uint256 positionId,
            uint8 kind,
            address asset,
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 principalUsdc,
            uint256 proceeds,
            uint256 released,
            uint256 openedAt,
            uint256 uniTokenId,
            uint256 lpPositionId
        )
    {
        Book memory book = stored[account];
        if (book.positionId == 0) book = _previousBook(PREVIOUS_ACCOUNTANT, account);
        if (book.positionId == 0) book = _previousBook(EARLIER_ACCOUNTANT, account);
        return (
            book.positionId,
            book.kind,
            book.asset,
            book.collateralAmount,
            book.debtAmount,
            book.principalUsdc,
            book.proceeds,
            book.released,
            book.openedAt,
            book.uniTokenId,
            book.lpPositionId
        );
    }

    function basketLength(address account) external view returns (uint256) {
        return basketAsset[account].length;
    }

    function basketAt(address account, uint256 index) external view returns (address asset, uint256 amount) {
        return (basketAsset[account][index], basketAmount[account][index]);
    }

    /// @notice True when Aave has already taken collateral or repaid debt outside this book.
    function seized(address account) external view returns (bool liquidated, uint256 debtLeft, uint256 collateralLeft) {
        Book memory book = stored[account];
        if (book.positionId == 0) book = _previousBook(PREVIOUS_ACCOUNTANT, account);
        if (book.positionId == 0) book = _previousBook(EARLIER_ACCOUNTANT, account);
        if (book.positionId == 0 || book.kind == AaveLib.SUPPLY) return (false, 0, 0);
        address debtAsset = book.kind == AaveLib.SHORT ? book.asset : usdc;
        address collateralAsset = book.kind == AaveLib.SHORT ? usdc : book.asset;
        debtLeft = debtOf(account, debtAsset);
        collateralLeft = _aBalance(account, collateralAsset);
        liquidated = _seized(account, book, debtLeft);
    }

    /// @dev The desk calls this on itself while closing a book that still lives on an older accountant.
    function adopt(address account) external {
        if (msg.sender != address(this)) revert NotAccount();
        _copyBook(PREVIOUS_ACCOUNTANT, account);
        if (stored[account].positionId == 0) _copyBook(EARLIER_ACCOUNTANT, account);
    }

    function debtOf(address account, address asset) public view returns (uint256) {
        (,, address variableDebt) = data.getReserveTokensAddresses(asset);
        return IERC20(variableDebt).balanceOf(account);
    }

    function liquidation(address account)
        external
        view
        returns (uint256 price, bool liquidatesAbove, uint256 healthFactor)
    {
        Book storage book = stored[account];
        if (book.positionId == 0 || book.kind == AaveLib.SUPPLY) {
            (,,,,, healthFactor) = aave.getAccountData(account);
            return (0, false, healthFactor);
        }
        (address aToken,,) = data.getReserveTokensAddresses(book.kind == AaveLib.SHORT ? usdc : book.asset);
        address debtAsset = book.kind == AaveLib.SHORT ? book.asset : usdc;
        uint256 collateralAmount = IERC20(aToken).balanceOf(account);
        uint256 debtAmount = debtOf(account, debtAsset);
        (,, uint256 threshold,,,,,,,) = data.getReserveConfigurationData(book.kind == AaveLib.SHORT ? usdc : book.asset);
        liquidatesAbove = book.kind == AaveLib.SHORT;
        price = AaveLib.liquidationPrice(
            liquidatesAbove,
            collateralAmount,
            debtAmount,
            liquidatesAbove ? _decimals(usdc) : _decimals(book.asset),
            liquidatesAbove ? _decimals(book.asset) : _decimals(usdc),
            threshold,
            oracle.getAssetPrice(usdc)
        );
        (,,,,, healthFactor) = aave.getAccountData(account);
    }

    /// @dev Forwards the original calldata. Selectors match `AaveDesk`. The lock stays with the caller.
    function _callDesk() internal returns (bytes memory ret) {
        address target = address(desk);
        assembly {
            let args := mload(0x40)
            mstore(0x40, add(args, and(add(calldatasize(), 31), not(31))))
            calldatacopy(args, 0, calldatasize())
            let ok := delegatecall(gas(), target, args, calldatasize(), 0, 0)
            let size := returndatasize()
            ret := mload(0x40)
            mstore(ret, size)
            returndatacopy(add(ret, 0x20), 0, size)
            mstore(0x40, add(add(ret, 0x20), and(add(size, 31), not(31))))
            if iszero(ok) { revert(add(ret, 0x20), size) }
        }
    }

    function _release(address account, uint256 amount) internal {
        Book storage book = stored[account];
        address owner = ILendingAccount(account).owner();
        ILendingAccount(account).push(usdc, owner, amount);
        book.released += amount;
        ledger.recordUpdate(owner, account, _fields(book));
    }

    function _fields(Book storage book) internal view returns (AaveLedger.Fields memory fields) {
        fields = AaveLedger.Fields({
            positionId: book.positionId,
            kind: book.kind,
            asset: book.asset,
            collateralAmount: book.collateralAmount,
            debtAmount: book.debtAmount,
            principalUsdc: book.principalUsdc,
            proceeds: book.proceeds,
            released: book.released,
            openedAt: book.openedAt,
            uniTokenId: book.uniTokenId,
            lpPositionId: book.lpPositionId
        });
    }

    function _seized(address account, Book memory book, uint256 debtLeft) internal view returns (bool) {
        if (book.kind == AaveLib.SUPPLY || book.positionId == 0) return false;
        if (_shortOf(debtLeft, book.debtAmount)) return true;
        address collateralAsset = book.kind == AaveLib.SHORT ? usdc : book.asset;
        if (_shortOf(_aBalance(account, collateralAsset), book.collateralAmount)) return true;
        uint256 n = basketAmount[account].length;
        for (uint256 i = 0; i < n; i++) {
            if (_shortOf(_aBalance(account, basketAsset[account][i]), basketAmount[account][i])) return true;
        }
        return false;
    }

    function _shortOf(uint256 live, uint256 snapshot) internal pure returns (bool) {
        if (snapshot == 0) return false;
        return live * 100 < snapshot * 99;
    }

    function _aBalance(address account, address asset) internal view returns (uint256) {
        (address aToken,,) = data.getReserveTokensAddresses(asset);
        return IERC20(aToken).balanceOf(account);
    }

    function _account(address owner) internal view returns (address account) {
        account = msg.sender;
        if (owner == address(0) || ILendingAccount(account).owner() != owner) revert OwnerMismatch();
    }

    function _copyBook(address previous, address account) internal {
        (
            uint256 positionId,
            uint8 kind,
            address asset,
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 principalUsdc,
            uint256 proceeds,
            uint256 released,
            uint256 openedAt,
            uint256 uniTokenId,
            uint256 lpPositionId
        ) = IPreviousBooks(previous).books(account);
        if (positionId == 0) return;
        stored[account] = Book({
            positionId: positionId,
            kind: kind,
            asset: asset,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount,
            principalUsdc: principalUsdc,
            proceeds: proceeds,
            released: released,
            openedAt: openedAt,
            uniTokenId: uniTokenId,
            lpPositionId: lpPositionId
        });
        if (kind == AaveLib.BASKET) _adoptBasket(previous, account);
    }

    function _adoptBasket(address previous, address account) internal {
        (bool ok, bytes memory payload) = previous.staticcall(abi.encodeWithSignature("basketLength(address)", account));
        if (!ok || payload.length < 32) return;
        uint256 n = abi.decode(payload, (uint256));
        for (uint256 i = 0; i < n; i++) {
            (bool okAt, bytes memory row) =
                previous.staticcall(abi.encodeWithSignature("basketAt(address,uint256)", account, i));
            if (!okAt || row.length < 64) return;
            (address asset, uint256 amount) = abi.decode(row, (address, uint256));
            basketAsset[account].push(asset);
            basketAmount[account].push(amount);
        }
    }

    function _previousBook(address previous, address account) internal view returns (Book memory book) {
        if (previous == address(0)) return book;
        try IPreviousBooks(previous).books(account) returns (
            uint256 positionId,
            uint8 kind,
            address asset,
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 principalUsdc,
            uint256 proceeds,
            uint256 released,
            uint256 openedAt,
            uint256 uniTokenId,
            uint256 lpPositionId
        ) {
            book.positionId = positionId;
            book.kind = kind;
            book.asset = asset;
            book.collateralAmount = collateralAmount;
            book.debtAmount = debtAmount;
            book.principalUsdc = principalUsdc;
            book.proceeds = proceeds;
            book.released = released;
            book.openedAt = openedAt;
            book.uniTokenId = uniTokenId;
            book.lpPositionId = lpPositionId;
        } catch {}
    }

    function _decimals(address asset) internal view returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }

    error NotAccount();
    error Reentrancy();
    error OwnerMismatch();
    error PositionNotFound();
    error InvalidAmount();
}
