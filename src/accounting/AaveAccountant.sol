//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveManager} from "../core/aave/executors/AaveManager.sol";
import {AaveLedger} from "./AaveLedger.sol";
import {ILendingAccount} from "../interfaces/ILendingAccount.sol";
import {ISendraAddressProvider} from "../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {ISendraStorage} from "../interfaces/iSendraCore/ISendraStorage.sol";
import {IAaveOracle} from "../interfaces/aave/IAaveOracle.sol";
import {IAaveProtocolDataProvider} from "../interfaces/aave/IAaveProtocolDataProvider.sol";
import {AaveLib} from "../lib/aave/Aave.lib.sol";
import {SwapTypes} from "../lib/aave/SwapTypes.sol";
import {ISwapRouter} from "../lib/aave/SwapTypes.sol";

interface IAccountGate {
    function isProtocolAccount(address account) external view returns (bool);
}

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IUniV3Router {
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

/**
 * @title AaveAccountant
 * @notice One open Aave strategy per lending account. The account holds the aTokens, the debt and the LP.
 *
 * 5 supply   deposit the asset and keep the Aave supply yield
 * 6 loop     USDC -> asset -> collateral, then borrow USDC and buy more, up to 4 times
 * 7 short    USDC collateral -> borrow the asset -> sell it. Sale USDC can be released to the owner
 * 8 lp       buy the asset, post it, borrow USDC and leave it on the account for a Uniswap position
 *
 * Debt to repay is `variableDebtToken.balanceOf(account)`. That balance already includes the interest.
 */
contract AaveAccountant {
    using SafeERC20 for IERC20;

    address public constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    struct Book {
        uint256 positionId;
        uint8 kind;
        address asset;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 principalUsdc;
        uint256 proceeds;
        uint256 released;
        uint256 openedAt;
        uint256 uniTokenId;
        uint256 lpPositionId;
    }

    ISendraAddressProvider public immutable addressProvider;
    IAccountGate public immutable accounts;
    AaveManager public immutable aave;
    ISwapRouter public immutable swapRouter;
    ISendraStorage public immutable store;
    AaveLedger public immutable ledger;
    IAaveOracle public immutable oracle;
    IAaveProtocolDataProvider public immutable data;
    address public immutable usdc;

    uint256 private locked = 1;
    mapping(address => Book) public books;
    address private unwindAccount;
    address private unwindAsset;
    SwapTypes.SwapInput private unwindSwap;

    /// @dev Libros abiertos en accountants anteriores. `close` copia el primero que tenga posición.
    address public constant PREVIOUS_ACCOUNTANT = 0x554bD87eb8f823459A5eB6497271a09F029BC266;
    address public constant EARLIER_ACCOUNTANT = 0x933d6730a467694dBdE5720Ad35B1a2a87043639;

    constructor(address _addressProvider) {
        addressProvider = ISendraAddressProvider(_addressProvider);
        accounts = IAccountGate(addressProvider.getAddress("AccountAccessControl"));
        aave = AaveManager(addressProvider.getAddress("AaveManager"));
        swapRouter = ISwapRouter(addressProvider.getAddress("SwapRouter"));
        store = ISendraStorage(addressProvider.getAddress("SendraStorage"));
        ledger = new AaveLedger(_addressProvider, address(this));
        oracle = IAaveOracle(addressProvider.getAddress("AaveOracle"));
        data = IAaveProtocolDataProvider(addressProvider.getAddress("AaveProtocolDataProvider"));
        usdc = addressProvider.getAddress("USDC");
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

    function openSupply(address owner, address asset, uint256 usdcAmount, SwapTypes.SwapInput calldata swap)
        external
        onlyAccount
        nonReentrant
    {
        address account = _account(owner);
        _empty(account);
        if (usdcAmount == 0 || asset == address(0)) revert InvalidAmount();
        _take(usdc, usdcAmount);
        uint256 supplied = usdcAmount;
        if (asset != usdc) {
            _requireRoute(swap, usdc, asset, usdcAmount);
            supplied = _swap(swap, address(this));
        }
        _supply(asset, supplied, account);
        _open(owner, account, AaveLib.SUPPLY, asset, supplied, 0, usdcAmount, 0, 0);
    }

    function openLoop(
        address owner,
        address asset,
        uint256 usdcAmount,
        uint8 loops,
        uint16 borrowBps,
        SwapTypes.SwapInput calldata swap
    ) external onlyAccount nonReentrant {
        address account = _account(owner);
        _empty(account);
        _checkLoops(loops, borrowBps);
        _take(usdc, usdcAmount);
        _requireRoute(swap, usdc, asset, usdcAmount);
        uint256 bought = _swap(swap, address(this));
        _supply(asset, bought, account);
        _delegate(account, usdc);
        uint256 debt;
        for (uint8 i = 0; i < loops; i++) {
            uint256 tranche = _sized(account, usdc, borrowBps);
            if (tranche == 0) break;
            _borrow(usdc, tranche, account);
            debt += tranche;
            uint256 more = _swap(_scaled(swap, tranche), address(this));
            _supply(asset, more, account);
            bought += more;
        }
        _open(owner, account, AaveLib.LOOP, asset, bought, debt, usdcAmount, 0, 0);
    }

    function openShort(
        address owner,
        address asset,
        uint256 usdcAmount,
        uint8 loops,
        uint16 borrowBps,
        bool releaseToOwner,
        SwapTypes.SwapInput calldata sellAsset
    ) external onlyAccount nonReentrant {
        address account = _account(owner);
        _empty(account);
        _checkLoops(loops, borrowBps);
        _take(usdc, usdcAmount);
        _supply(usdc, usdcAmount, account);
        _delegate(account, asset);
        _requireRoute(sellAsset, asset, usdc, sellAsset.amountIn0);
        uint256 debt;
        uint256 proceeds;
        for (uint8 i = 0; i < loops; i++) {
            uint256 tranche = _sized(account, asset, borrowBps);
            if (tranche == 0) break;
            _borrow(asset, tranche, account);
            debt += tranche;
            uint256 sold = _swap(_scaled(sellAsset, tranche), address(this));
            bool last = i + 1 == loops;
            if (last) proceeds = sold;
            else _supply(usdc, sold, account);
        }
        if (proceeds > 0) IERC20(usdc).safeTransfer(account, proceeds);
        (address aToken,,) = data.getReserveTokensAddresses(usdc);
        _open(owner, account, AaveLib.SHORT, asset, IERC20(aToken).balanceOf(account), debt, usdcAmount, proceeds, 0);
        if (releaseToOwner && proceeds > 0) _release(account, proceeds);
    }

    function openLeveraged(
        address owner,
        address asset,
        uint256 usdcAmount,
        uint16 borrowBps,
        SwapTypes.SwapInput calldata buyAsset,
        bool collateralIsAsset
    ) external onlyAccount nonReentrant returns (uint256 positionId) {
        address account = _account(owner);
        _empty(account);
        if (borrowBps == 0 || borrowBps > AaveLib.MAX_BORROW_BPS) revert BorrowTooHigh();
        _take(usdc, usdcAmount);
        uint256 bought;
        address collateral = usdc;
        if (collateralIsAsset && asset != usdc) {
            _requireRoute(buyAsset, usdc, asset, usdcAmount);
            bought = _swap(buyAsset, address(this));
            collateral = asset;
        } else {
            bought = usdcAmount;
        }
        _supply(collateral, bought, account);
        _delegate(account, usdc);
        uint256 debt = _sized(account, usdc, borrowBps);
        if (debt == 0) revert InvalidAmount();
        _borrow(usdc, debt, account);
        IERC20(usdc).safeTransfer(account, debt);
        _open(owner, account, AaveLib.LEVERAGED_LP, collateral, bought, debt, usdcAmount, debt, 0);
        return books[account].positionId;
    }

    function sealLp(address owner, uint256 positionId, uint256 uniTokenId, uint256 lpPositionId)
        external
        onlyAccount
        nonReentrant
    {
        address account = _account(owner);
        Book storage book = books[account];
        if (book.positionId != positionId || book.kind != AaveLib.LEVERAGED_LP) revert PositionNotFound();
        book.uniTokenId = uniTokenId;
        book.lpPositionId = lpPositionId;
        ledger.recordUpdate(owner, account, _fields(book));
    }

    /// @dev USDC borrowed that the LP did not use. It went back to the owner, so it is not principal.
    function noteRefund(address owner, uint256 positionId, uint256 dust) external onlyAccount {
        address account = _account(owner);
        Book storage book = books[account];
        if (book.positionId != positionId) revert PositionNotFound();
        if (dust == 0) return;
        if (dust > book.principalUsdc) dust = book.principalUsdc;
        book.principalUsdc -= dust;
        ledger.recordUpdate(owner, account, _fields(book));
    }

    address private constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    /// @notice LP proceeds and any top-up are already on this contract. Repay, sell the collateral, return USDC.
    function settleLeveraged(address owner, uint256 positionId) external onlyAccount nonReentrant {
        address account = _account(owner);
        if (books[account].positionId == 0) _adopt(account);
        Book storage book = books[account];
        if (book.positionId != positionId || book.kind != AaveLib.LEVERAGED_LP) revert PositionNotFound();
        uint256 debt = debtOf(account, usdc);
        uint256 have = IERC20(usdc).balanceOf(address(this));
        if (have < debt) revert NotEnoughToRepay(debt, have);
        if (debt > 0) _repay(usdc, debt, account);
        uint256 assetOut = _withdrawAll(account, book.asset, address(this));
        if (assetOut > 0 && book.asset != usdc) _sellCollateral(book.asset, assetOut);
        uint256 left = IERC20(usdc).balanceOf(address(this));
        if (left > 0) IERC20(usdc).safeTransfer(owner, left);
        int256 pnl = int256(left) - int256(book.principalUsdc);
        ledger.recordClose(owner, account, _fields(book), left, pnl);
        delete books[account];
    }

    function release(address owner, uint256 positionId) external onlyAccount nonReentrant {
        address account = _account(owner);
        Book storage book = books[account];
        if (book.positionId != positionId || book.kind != AaveLib.SHORT) revert PositionNotFound();
        uint256 left = book.proceeds - book.released;
        if (left == 0) revert InvalidAmount();
        _release(account, left);
    }

    function close(address owner, uint256 positionId, SwapTypes.SwapInput calldata swap)
        external
        onlyAccount
        nonReentrant
    {
        address account = _account(owner);
        if (books[account].positionId == 0) _adopt(account);
        Book storage book = books[account];
        if (book.positionId != positionId) revert PositionNotFound();
        if (book.kind == AaveLib.LEVERAGED_LP) revert LeveragedNeedsUnwind();

        uint256 back;
        if (book.kind == AaveLib.SUPPLY) {
            back = _withdrawAll(account, book.asset, owner);
            back = aave.assetToUsdc(book.asset, back);
        } else if (book.kind == AaveLib.SHORT) {
            back = _closeShort(account, book, swap, owner) + book.released;
        } else {
            back = _closeLong(account, book, swap, owner);
        }

        int256 pnl = int256(back) - int256(book.principalUsdc);
        ledger.recordClose(owner, account, _fields(book), back, pnl);
        delete books[account];
    }

    /// @notice Live Aave debt, interest included. This is the amount `repay` must cover.
    function debtOf(address account, address asset) public view returns (uint256) {
        (,, address variableDebt) = data.getReserveTokensAddresses(asset);
        return IERC20(variableDebt).balanceOf(account);
    }

    /// @notice Isolated liquidation price in oracle units (8 decimals), plus the account health factor.
    /// @dev `liquidatesAbove` is true for a short: the asset rising is what liquidates it.
    function liquidation(address account)
        external
        view
        returns (uint256 price, bool liquidatesAbove, uint256 healthFactor)
    {
        Book storage book = books[account];
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

    function _closeShort(address account, Book storage book, SwapTypes.SwapInput calldata swap, address owner)
        internal
        returns (uint256 back)
    {
        uint256 debt = debtOf(account, book.asset);
        if (debt > 0) {
            if (swap.tokenIn != usdc || swap.tokenOut != book.asset || swap.swapInstructions.length == 0) {
                revert RouteTokenMismatch();
            }
            _take(usdc, swap.amountIn0);
            uint256 bought = _swap(swap, address(this));
            if (bought < debt) revert NotEnoughToRepay(debt, bought);
            _repay(book.asset, debt, account);
        }
        uint256 still = book.proceeds - book.released;
        if (still > 0) ILendingAccount(account).push(usdc, address(this), still);
        back = _withdrawAll(account, usdc, owner);
        uint256 idle = IERC20(usdc).balanceOf(address(this));
        if (idle > 0) IERC20(usdc).safeTransfer(owner, idle);
        return back + idle;
    }

    function _closeLong(address account, Book storage book, SwapTypes.SwapInput calldata swap, address owner)
        internal
        returns (uint256 back)
    {
        if (book.kind == AaveLib.LEVERAGED_LP && book.proceeds > book.released) {
            ILendingAccount(account).push(usdc, address(this), book.proceeds - book.released);
        }
        if (swap.tokenIn != book.asset || swap.tokenOut != usdc) revert RouteTokenMismatch();
        uint256 debt = debtOf(account, usdc);
        if (debt == 0) return _sellCollateral(account, book.asset, swap, owner);

        // Aave no deja transferir el aToken mientras la deuda sigue abierta.
        // El flash loan paga primero; el colateral vendido devuelve el préstamo.
        unwindAccount = account;
        unwindAsset = book.asset;
        unwindSwap = swap;
        aave.pool().flashLoanSimple(address(this), usdc, debt, "", 0);
        delete unwindSwap;
        unwindAccount = address(0);
        unwindAsset = address(0);
        back = IERC20(usdc).balanceOf(address(this));
        if (back > 0) IERC20(usdc).safeTransfer(owner, back);
    }

    /// @dev Callback de `flashLoanSimple`. Solo el pool, y solo mientras `close` está en curso.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata
    ) external returns (bool) {
        if (msg.sender != address(aave.pool()) || initiator != address(this) || locked != 2) revert NotAccount();
        if (unwindAccount == address(0) || asset != usdc) revert InvalidAmount();
        _repay(usdc, amount, unwindAccount);
        uint256 underlying = _withdrawAll(unwindAccount, unwindAsset, address(this));
        _swap(_scaled(unwindSwap, underlying), address(this));
        uint256 owed = amount + premium;
        uint256 have = IERC20(usdc).balanceOf(address(this));
        if (have < owed) revert NotEnoughToRepay(owed, have);
        IERC20(usdc).forceApprove(msg.sender, owed);
        return true;
    }

    function _sellCollateral(
        address account,
        address asset,
        SwapTypes.SwapInput calldata swap,
        address owner
    ) internal returns (uint256 back) {
        uint256 underlying = _withdrawAll(account, asset, address(this));
        _swap(_scaled(swap, underlying), address(this));
        back = IERC20(usdc).balanceOf(address(this));
        if (back > 0) IERC20(usdc).safeTransfer(owner, back);
    }

    function _adopt(address account) internal {
        _copyBook(PREVIOUS_ACCOUNTANT, account);
        if (books[account].positionId == 0) _copyBook(EARLIER_ACCOUNTANT, account);
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
        books[account] = Book({
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
    }

    function _release(address account, uint256 amount) internal {
        Book storage book = books[account];
        address owner = ILendingAccount(account).owner();
        ILendingAccount(account).push(usdc, owner, amount);
        book.released += amount;
        ledger.recordUpdate(owner, account, _fields(book));
    }

    function _open(
        address owner,
        address account,
        uint8 kind,
        address asset,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 principal,
        uint256 proceeds,
        uint256 uniTokenId
    ) internal {
        uint256 positionId = store.getUser(owner).totalPositions + 1;
        Book memory book = Book({
            positionId: positionId,
            kind: kind,
            asset: asset,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount,
            principalUsdc: principal,
            proceeds: proceeds,
            released: 0,
            openedAt: block.timestamp,
            uniTokenId: uniTokenId,
            lpPositionId: 0
        });
        books[account] = book;
        ledger.recordOpen(owner, account, _fields(books[account]));
        emit StrategyOpened(owner, account, kind, positionId, asset, principal);
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

    function _withdrawAll(address account, address asset, address to) internal returns (uint256 amount) {
        (address aToken,,) = data.getReserveTokensAddresses(asset);
        uint256 bal = IERC20(aToken).balanceOf(account);
        if (bal == 0) return 0;
        ILendingAccount(account).push(aToken, address(aave), bal);
        amount = aave.withdraw(asset, type(uint256).max, to);
    }

    function _supply(address asset, uint256 amount, address account) internal {
        IERC20(asset).forceApprove(address(aave), amount);
        aave.supply(asset, amount, account, 0);
    }

    function _borrow(address asset, uint256 amount, address account) internal {
        aave.borrow(asset, amount, AaveLib.VARIABLE_RATE, 0, account, address(this));
    }

    function _repay(address asset, uint256 amount, address account) internal {
        uint256 live = debtOf(account, asset);
        if (amount > live) amount = live;
        IERC20(asset).forceApprove(address(aave), amount);
        aave.repay(asset, amount, AaveLib.VARIABLE_RATE, account);
    }

    function _delegate(address account, address asset) internal {
        (,, address variableDebt) = data.getReserveTokensAddresses(asset);
        ILendingAccount(account).delegate(variableDebt, address(aave));
    }

    function _sized(address account, address asset, uint16 bps) internal view returns (uint256) {
        (,, uint256 available,,,) = aave.getAccountData(account);
        uint256 price = oracle.getAssetPrice(asset);
        if (price == 0 || available == 0) return 0;
        return available * (10 ** uint256(_decimals(asset))) / price * bps / AaveLib.BPS;
    }

    /// @dev Sells the withdrawn LP collateral for USDC inside `settleLeveraged`. The account
    ///      cannot forward a route, and a multicall cannot call `closeLeveraged` (`onlyOwner`).
    function _sellCollateral(address asset, uint256 amount) internal {
        uint256 price = oracle.getAssetPrice(asset);
        uint256 usdcPrice = oracle.getAssetPrice(usdc);
        if (price == 0 || usdcPrice == 0) revert InvalidAmount();
        uint256 minOut = amount * price * (10 ** uint256(_decimals(usdc))) / usdcPrice / (10 ** uint256(_decimals(asset)));
        minOut = minOut * 99 / 100;
        IERC20(asset).forceApprove(UNI_ROUTER, amount);
        uint24[3] memory fees = [uint24(500), 3000, 100];
        for (uint256 i = 0; i < fees.length; i++) {
            try IUniV3Router(UNI_ROUTER).exactInputSingle(
                IUniV3Router.ExactInputSingleParams({
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
                if (out > 0) return;
            } catch {}
        }
        revert InsufficientOutput();
    }

    function _swap(SwapTypes.SwapInput memory swap, address recipient) internal returns (uint256 amountOut) {
        _checkRoute(swap);
        swap.to = recipient;
        uint256 beforeBal = IERC20(swap.tokenOut).balanceOf(recipient);
        IERC20(swap.tokenIn).safeTransfer(address(swapRouter), swap.amountIn0);
        swapRouter.executeSwap(swap);
        amountOut = IERC20(swap.tokenOut).balanceOf(recipient) - beforeBal;
        if (amountOut == 0) revert InsufficientOutput();
    }

    function _scaled(SwapTypes.SwapInput memory swap, uint256 amount) internal pure returns (SwapTypes.SwapInput memory copy) {
        copy = swap;
        uint256 old = copy.amountIn0;
        if (old == 0) revert InvalidAmount();
        copy.amountIn0 = amount;
        uint256 rooted;
        uint256 first = type(uint256).max;
        for (uint256 i = 0; i < copy.swapInstructions.length; i++) {
            uint256 hopIn = copy.swapInstructions[i].amountIn;
            if (hopIn == 0) continue;
            if (first == type(uint256).max) first = i;
            copy.swapInstructions[i].amountIn = hopIn * amount / old;
            copy.swapInstructions[i].amountOut = copy.swapInstructions[i].amountOut * amount / old;
            rooted += copy.swapInstructions[i].amountIn;
        }
        if (first == type(uint256).max) revert EmptyRoute();
        if (rooted < amount) copy.swapInstructions[first].amountIn += amount - rooted;
    }

    function _requireRoute(SwapTypes.SwapInput calldata swap, address tokenIn, address tokenOut, uint256 amount) internal pure {
        if (swap.tokenIn != tokenIn || swap.tokenOut != tokenOut || swap.amountIn0 != amount) revert RouteTokenMismatch();
    }

    function _checkRoute(SwapTypes.SwapInput memory swap) internal pure {
        if (swap.swapInstructions.length == 0) revert EmptyRoute();
        uint256 rooted;
        for (uint256 i = 0; i < swap.swapInstructions.length; i++) {
            uint256 hopIn = swap.swapInstructions[i].amountIn;
            if (hopIn == 0) continue;
            if (swap.swapInstructions[i].tokenIn != swap.tokenIn) revert RouteTokenMismatch();
            rooted += hopIn;
        }
        if (rooted != swap.amountIn0) revert RouteAmountMismatch(rooted, swap.amountIn0);
    }

    function _take(address token, uint256 amount) internal view {
        if (IERC20(token).balanceOf(address(this)) < amount) revert InvalidAmount();
    }

    function _account(address owner) internal view returns (address account) {
        account = msg.sender;
        if (owner == address(0) || ILendingAccount(account).owner() != owner) revert OwnerMismatch();
    }

    function _empty(address account) internal view {
        if (books[account].positionId != 0) revert PositionOpen();
    }

    function _checkLoops(uint8 loops, uint16 borrowBps) internal pure {
        if (loops == 0 || loops > AaveLib.MAX_LOOPS) revert InvalidAmount();
        if (borrowBps == 0 || borrowBps > AaveLib.MAX_BORROW_BPS) revert BorrowTooHigh();
    }

    function _lpHeld(address account, uint256 tokenId) internal view returns (bool) {
        if (tokenId == 0) return false;
        try IERC721Owner(NPM).ownerOf(tokenId) returns (address who) {
            return who == account;
        } catch {
            return false;
        }
    }

    function _decimals(address asset) internal view returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }

    event StrategyOpened(
        address indexed owner,
        address indexed account,
        uint8 kind,
        uint256 positionId,
        address asset,
        uint256 principal
    );

    error NotAccount();
    error Reentrancy();
    error OwnerMismatch();
    error PositionOpen();
    error PositionNotFound();
    error InvalidAmount();
    error BorrowTooHigh();
    error EmptyRoute();
    error RouteTokenMismatch();
    error RouteAmountMismatch(uint256 rooted, uint256 amount);
    error InsufficientOutput();
    error NotEnoughToRepay(uint256 debt, uint256 have);
    error LeveragedNeedsUnwind();
}

interface IPreviousBooks {
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
        );
}
