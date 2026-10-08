//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveManager} from "../core/aave/executors/AaveManager.sol";
import {AaveLedger} from "./AaveLedger.sol";
import {AaveSeller} from "./AaveSeller.sol";
import {AaveStore} from "./AaveStore.sol";
import {ILendingAccount} from "../interfaces/ILendingAccount.sol";
import {ISendraStorage} from "../interfaces/iSendraCore/ISendraStorage.sol";
import {IAaveOracle} from "../interfaces/aave/IAaveOracle.sol";
import {IAaveProtocolDataProvider} from "../interfaces/aave/IAaveProtocolDataProvider.sol";
import {AaveLib} from "../lib/aave/Aave.lib.sol";
import {SwapTypes} from "../lib/aave/SwapTypes.sol";
import {ISwapRouter} from "../lib/aave/SwapTypes.sol";

interface IHost {
    function adopt(address account) external;
}

/// @notice Open, close and rescue for Aave strategies.
/// @dev `AaveAccountant` delegatecalls with the original calldata. Storage lives on the accountant.
contract AaveDesk is AaveStore {
    using SafeERC20 for IERC20;

    address public immutable accountant;
    AaveManager public immutable aave;
    ISwapRouter public immutable swapRouter;
    ISendraStorage public immutable store;
    AaveLedger public immutable ledger;
    IAaveOracle public immutable oracle;
    IAaveProtocolDataProvider public immutable data;
    address public immutable usdc;
    AaveSeller public immutable seller;

    constructor(
        address _accountant,
        address _aave,
        address _swapRouter,
        address _store,
        address _ledger,
        address _oracle,
        address _data,
        address _usdc
    ) {
        accountant = _accountant;
        aave = AaveManager(_aave);
        swapRouter = ISwapRouter(_swapRouter);
        store = ISendraStorage(_store);
        ledger = AaveLedger(_ledger);
        oracle = IAaveOracle(_oracle);
        data = IAaveProtocolDataProvider(_data);
        usdc = _usdc;
        seller = new AaveSeller(_oracle, _usdc);
    }

    function openSupply(address owner, address asset, uint256 usdcAmount, SwapTypes.SwapInput calldata swap) external {
        _host();
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
    ) external {
        _host();
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
    ) external {
        _host();
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
    ) external returns (uint256 positionId) {
        _host();
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
        return stored[account].positionId;
    }

    /// @notice Supply `collateral`, then borrow USDC and buy each leg. One debt, several aTokens.
    function openBasket(
        address owner,
        address collateral,
        uint256 usdcAmount,
        SwapTypes.SwapInput calldata buyCollateral,
        AaveLib.BasketBuy[] calldata buys
    ) external {
        _host();
        address account = _account(owner);
        _empty(account);
        if (buys.length == 0 || buys.length > 3) revert InvalidAmount();
        if (collateral == address(0) || collateral == usdc) revert InvalidAmount();
        _take(usdc, usdcAmount);
        _requireRoute(buyCollateral, usdc, collateral, usdcAmount);
        uint256 posted = _swap(buyCollateral, address(this));
        _supply(collateral, posted, account);
        _delegate(account, usdc);
        uint256 debt;
        for (uint256 i = 0; i < buys.length; i++) {
            address leg = buys[i].asset;
            if (leg == address(0) || leg == usdc || leg == collateral) revert InvalidAmount();
            for (uint256 j = 0; j < i; j++) {
                if (buys[j].asset == leg) revert InvalidAmount();
            }
            uint16 bps = buys[i].borrowBps;
            if (bps == 0 || bps > AaveLib.MAX_BORROW_BPS) revert BorrowTooHigh();
            uint256 tranche = _sized(account, usdc, bps);
            if (tranche == 0) revert InvalidAmount();
            if (
                buys[i].swap.tokenIn != usdc || buys[i].swap.tokenOut != leg
                    || buys[i].swap.swapInstructions.length == 0
            ) revert RouteTokenMismatch();
            _borrow(usdc, tranche, account);
            uint256 bought = _swap(_scaled(buys[i].swap, tranche), address(this));
            _supply(leg, bought, account);
            basketAsset[account].push(leg);
            basketAmount[account].push(bought);
            debt += tranche;
        }
        _open(owner, account, AaveLib.BASKET, collateral, posted, debt, usdcAmount, 0, 0);
    }

    function settleLeveraged(address owner, uint256 positionId) external {
        _host();
        address account = _account(owner);
        if (stored[account].positionId == 0) IHost(accountant).adopt(account);
        Book storage book = stored[account];
        if (book.positionId != positionId || book.kind != AaveLib.LEVERAGED_LP) revert PositionNotFound();
        uint256 debt = debtOf(account, usdc);
        bool soft = _seized(account, book, debt);
        uint256 have = IERC20(usdc).balanceOf(address(this));
        if (have < debt) revert NotEnoughToRepay(debt, have);
        if (debt > 0) _repay(usdc, debt, account);
        uint256 assetOut = _withdrawAll(account, book.asset, address(this));
        if (assetOut > 0 && book.asset != usdc) {
            if (!_sellOnUni(book.asset, assetOut)) {
                if (!soft) revert InsufficientOutput();
                IERC20(book.asset).safeTransfer(owner, assetOut);
            }
        }
        uint256 left = IERC20(usdc).balanceOf(address(this));
        if (left > 0) IERC20(usdc).safeTransfer(owner, left);
        int256 pnl = int256(left) - int256(book.principalUsdc);
        ledger.recordClose(owner, account, _fields(book), left, pnl);
        delete stored[account];
    }

    function close(address owner, uint256 positionId, SwapTypes.SwapInput calldata swap) external {
        _host();
        address account = _account(owner);
        if (stored[account].positionId == 0) IHost(accountant).adopt(account);
        Book storage book = stored[account];
        if (book.positionId != positionId) revert PositionNotFound();
        if (book.kind == AaveLib.LEVERAGED_LP) revert LeveragedNeedsUnwind();

        uint256 back;
        if (book.kind == AaveLib.SUPPLY) {
            if (book.asset == usdc) {
                back = _withdrawAll(account, usdc, owner);
            } else {
                if (swap.tokenIn != book.asset || swap.tokenOut != usdc) revert RouteTokenMismatch();
                back = _sellCollateral(account, book.asset, swap, owner);
            }
        } else if (book.kind == AaveLib.SHORT) {
            back = _closeShort(account, book, swap, owner) + book.released;
        } else if (book.kind == AaveLib.BASKET) {
            back = _closeBasket(account, book, owner);
        } else {
            back = _closeLong(account, book, swap, owner);
        }

        int256 pnl = int256(back) - int256(book.principalUsdc);
        ledger.recordClose(owner, account, _fields(book), back, pnl);
        delete stored[account];
    }

    /// @dev Aave calls the accountant. The accountant forwards the same calldata here.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        _host();
        if (msg.sender != address(aave.pool()) || initiator != address(this) || locked != 2) revert NotAccount();
        if (unwindAccount == address(0) || asset != usdc) revert InvalidAmount();
        _repay(usdc, amount, unwindAccount);
        if (unwindBasket) {
            Book storage book = stored[unwindAccount];
            _pullAndSell(unwindAccount, book.asset, false);
            uint256 n = basketAsset[unwindAccount].length;
            for (uint256 i = 0; i < n; i++) {
                _pullAndSell(unwindAccount, basketAsset[unwindAccount][i], false);
            }
        } else {
            uint256 underlying = _withdrawAll(unwindAccount, unwindAsset, address(this));
            _swap(_scaled(unwindSwap, underlying), address(this));
        }
        uint256 owed = amount + premium;
        uint256 have = IERC20(usdc).balanceOf(address(this));
        if (have < owed) revert NotEnoughToRepay(owed, have);
        IERC20(usdc).forceApprove(msg.sender, owed);
        return true;
    }

    function _host() internal view {
        if (address(this) != accountant) revert NotHost();
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
        uint256 liveDebt = debtOf(account, usdc);
        if (book.kind == AaveLib.LOOP && _seized(account, book, liveDebt)) {
            if (liveDebt > 0) {
                uint256 have = IERC20(usdc).balanceOf(address(this));
                if (have < liveDebt) revert NotEnoughToRepay(liveDebt, have);
                _repay(usdc, liveDebt, account);
            }
            uint256 left = _withdrawAll(account, book.asset, address(this));
            if (left > 0) {
                if (swap.tokenIn != book.asset || swap.tokenOut != usdc) revert RouteTokenMismatch();
                _swap(_scaled(swap, left), address(this));
            }
            back = IERC20(usdc).balanceOf(address(this));
            if (back > 0) IERC20(usdc).safeTransfer(owner, back);
            return back;
        }
        if (book.kind == AaveLib.LEVERAGED_LP && book.proceeds > book.released) {
            ILendingAccount(account).push(usdc, address(this), book.proceeds - book.released);
        }
        if (swap.tokenIn != book.asset || swap.tokenOut != usdc) revert RouteTokenMismatch();
        uint256 debt = debtOf(account, usdc);
        if (debt == 0) return _sellCollateral(account, book.asset, swap, owner);

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

    function _sellCollateral(address account, address asset, SwapTypes.SwapInput calldata swap, address owner)
        internal
        returns (uint256 back)
    {
        uint256 underlying = _withdrawAll(account, asset, address(this));
        _swap(_scaled(swap, underlying), address(this));
        back = IERC20(usdc).balanceOf(address(this));
        if (back > 0) IERC20(usdc).safeTransfer(owner, back);
    }

    function _closeBasket(address account, Book storage book, address owner) internal returns (uint256 back) {
        uint256 debt = debtOf(account, usdc);
        bool soft = _seized(account, book, debt);
        if (soft) {
            if (debt > 0) {
                uint256 have = IERC20(usdc).balanceOf(address(this));
                if (have < debt) revert NotEnoughToRepay(debt, have);
                _repay(usdc, debt, account);
            }
            _pullAndSell(account, book.asset, true);
            uint256 n = basketAsset[account].length;
            for (uint256 i = 0; i < n; i++) _pullAndSell(account, basketAsset[account][i], true);
            _returnUnsold(account, book, owner);
        } else if (debt > 0) {
            unwindAccount = account;
            unwindAsset = book.asset;
            unwindBasket = true;
            aave.pool().flashLoanSimple(address(this), usdc, debt, "", 0);
            unwindAccount = address(0);
            unwindAsset = address(0);
            unwindBasket = false;
        } else {
            _pullAndSell(account, book.asset, false);
            uint256 n = basketAsset[account].length;
            for (uint256 i = 0; i < n; i++) _pullAndSell(account, basketAsset[account][i], false);
        }
        delete basketAsset[account];
        delete basketAmount[account];
        back = IERC20(usdc).balanceOf(address(this));
        if (back > 0) IERC20(usdc).safeTransfer(owner, back);
    }

    function _pullAndSell(address account, address asset, bool soft) internal {
        uint256 got = _withdrawAll(account, asset, address(this));
        if (got == 0 || asset == usdc) return;
        if (_sellOnUni(asset, got)) return;
        if (!soft) revert InsufficientOutput();
    }

    function _returnUnsold(address account, Book storage book, address owner) internal {
        _sendDust(book.asset, owner);
        uint256 n = basketAsset[account].length;
        for (uint256 i = 0; i < n; i++) _sendDust(basketAsset[account][i], owner);
    }

    function _sendDust(address asset, address owner) internal {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal > 0) IERC20(asset).safeTransfer(owner, bal);
    }

    function _sellOnUni(address asset, uint256 amount) internal returns (bool sold) {
        (bool ok, bytes memory ret) = address(seller).delegatecall(abi.encodeCall(AaveSeller.sell, (asset, amount)));
        if (!ok || ret.length < 32) return false;
        sold = abi.decode(ret, (bool));
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

    /// @dev The output floor sits on the last hop and has to move with the size.
    function _scaled(SwapTypes.SwapInput memory swap, uint256 amount)
        internal
        pure
        returns (SwapTypes.SwapInput memory copy)
    {
        copy = swap;
        uint256 old = copy.amountIn0;
        if (old == 0) revert InvalidAmount();
        copy.amountIn0 = amount;
        uint256 rooted;
        uint256 first = type(uint256).max;
        for (uint256 i = 0; i < copy.swapInstructions.length; i++) {
            uint256 hopIn = copy.swapInstructions[i].amountIn;
            if (hopIn != 0) {
                if (first == type(uint256).max) first = i;
                copy.swapInstructions[i].amountIn = hopIn * amount / old;
                rooted += copy.swapInstructions[i].amountIn;
            }
            uint256 hopOut = copy.swapInstructions[i].amountOut;
            if (hopOut != 0) copy.swapInstructions[i].amountOut = hopOut * amount / old;
        }
        if (first == type(uint256).max) revert EmptyRoute();
        if (rooted < amount) copy.swapInstructions[first].amountIn += amount - rooted;
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

    function _requireRoute(SwapTypes.SwapInput calldata swap, address tokenIn, address tokenOut, uint256 amount)
        internal
        pure
    {
        if (swap.tokenIn != tokenIn || swap.tokenOut != tokenOut || swap.amountIn0 != amount) revert RouteTokenMismatch();
    }

    function _release(address account, uint256 amount) internal {
        Book storage book = stored[account];
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
        stored[account] = book;
        ledger.recordOpen(owner, account, _fields(stored[account]));
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

    function debtOf(address account, address asset) public view returns (uint256) {
        (,, address variableDebt) = data.getReserveTokensAddresses(asset);
        return IERC20(variableDebt).balanceOf(account);
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

    function _take(address token, uint256 amount) internal view {
        if (IERC20(token).balanceOf(address(this)) < amount) revert InvalidAmount();
    }

    function _account(address owner) internal view returns (address account) {
        account = msg.sender;
        if (owner == address(0) || ILendingAccount(account).owner() != owner) revert OwnerMismatch();
    }

    function _empty(address account) internal {
        if (stored[account].positionId == 0) IHost(accountant).adopt(account);
        if (stored[account].positionId != 0) revert PositionOpen();
    }

    function _checkLoops(uint8 loops, uint16 borrowBps) internal pure {
        if (loops == 0 || loops > AaveLib.MAX_LOOPS) revert InvalidAmount();
        if (borrowBps == 0 || borrowBps > AaveLib.MAX_BORROW_BPS) revert BorrowTooHigh();
    }

    function _decimals(address asset) internal view returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }

    event StrategyOpened(
        address indexed owner, address indexed account, uint8 kind, uint256 positionId, address asset, uint256 principal
    );

    error NotHost();
    error NotAccount();
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
