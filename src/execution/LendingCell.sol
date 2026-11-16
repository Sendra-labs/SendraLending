//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreditDelegationToken} from "../interfaces/aave/ICreditDelegationToken.sol";
import {ISendraAddressProvider} from "../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {IAaveAccountant} from "../interfaces/IAaveAccountant.sol";
import {SwapTypes} from "../lib/aave/SwapTypes.sol";
import {LpMount} from "../lib/aave/LpMount.sol";
import {AaveLib} from "../lib/aave/Aave.lib.sol";

/**
 * @title LendingCell
 * @notice Holds Aave collateral, debt and a Uniswap LP for one owner.
 * @dev A SendraAccount deployed before lending cannot learn new functions.
 *      This cell is that owner's lending account. A later account with `aaveEnabled` is used instead.
 */
contract LendingCell {
    using SafeERC20 for IERC20;

    ISendraAddressProvider public immutable addressProvider;
    /// @dev Set to the factory that deployed the implementation. Clones read this from that bytecode.
    address public immutable factory;
    address public owner;
    uint256 private locked = 1;

    constructor(address _addressProvider, address _owner) {
        if (_owner == address(0)) revert ZeroOwner();
        addressProvider = ISendraAddressProvider(_addressProvider);
        factory = msg.sender;
        owner = _owner;
    }

    /// @notice Owner of a clone. The implementation is constructed with an owner, so this reverts there.
    /// @dev A clone does not run the constructor, so `locked` would stay 0 and every call would revert.
    function initialize(address _owner) external {
        if (msg.sender != factory) revert NotFactory();
        if (owner != address(0)) revert AlreadyInitialized();
        if (_owner == address(0)) revert ZeroOwner();
        owner = _owner;
        locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAccountant() {
        if (msg.sender != addressProvider.getAddress("AaveAccountant")) revert NotAccountant();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    function aaveEnabled() external pure returns (bool) {
        return true;
    }

    function basketEnabled() external pure returns (bool) {
        return true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function push(address token, address to, uint256 amount) external {
        address orchestrator = addressProvider.getAddress("LiquidityOrchestrator");
        if (msg.sender != address(_accountant()) && msg.sender != orchestrator) revert NotAccountant();
        IERC20(token).safeTransfer(to, amount);
    }

    function delegate(address debtToken, address delegatee) external onlyAccountant {
        ICreditDelegationToken(debtToken).approveDelegation(delegatee, type(uint256).max);
    }

    function approveToken(address token, address spender, uint256 amount) external onlyAccountant {
        IERC20(token).forceApprove(spender, amount);
    }

    function callOrchestrator(bytes calldata data) external onlyOwner nonReentrant {
        address orchestrator = addressProvider.getAddress("LiquidityOrchestrator");
        (bool ok, bytes memory reason) = orchestrator.call(data);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function openBasket(
        address collateral,
        uint256 usdcAmount,
        SwapTypes.SwapInput calldata buyCollateral,
        AaveLib.BasketBuy[] calldata buys
    ) external onlyOwner nonReentrant {
        _fund(addressProvider.getAddress("USDC"), usdcAmount);
        _accountant().openBasket(owner, collateral, usdcAmount, buyCollateral, buys);
    }

    function openSupply(address asset, uint256 usdcAmount, SwapTypes.SwapInput calldata swap) external onlyOwner nonReentrant {
        _fund(addressProvider.getAddress("USDC"), usdcAmount);
        _accountant().openSupply(owner, asset, usdcAmount, swap);
    }

    function openLoop(
        address asset,
        uint256 usdcAmount,
        uint8 loops,
        uint16 borrowBps,
        SwapTypes.SwapInput calldata swap
    ) external onlyOwner nonReentrant {
        address usdc = addressProvider.getAddress("USDC");
        _fund(usdc, usdcAmount);
        _accountant().openLoop(owner, asset, usdcAmount, loops, borrowBps, swap);
    }

    function openShort(
        address asset,
        uint256 usdcAmount,
        uint8 loops,
        uint16 borrowBps,
        bool releaseToOwner,
        SwapTypes.SwapInput calldata sellAsset
    ) external onlyOwner nonReentrant {
        address usdc = addressProvider.getAddress("USDC");
        _fund(usdc, usdcAmount);
        _accountant().openShort(owner, asset, usdcAmount, loops, borrowBps, releaseToOwner, sellAsset);
    }

    function openLeveraged(
        address asset,
        uint256 usdcAmount,
        uint16 borrowBps,
        SwapTypes.SwapInput calldata buyAsset,
        bool collateralIsAsset,
        bytes calldata lpData
    ) external onlyOwner nonReentrant {
        address usdc = addressProvider.getAddress("USDC");
        _fund(usdc, usdcAmount);
        uint256 positionId = _accountant().openLeveraged(owner, asset, usdcAmount, borrowBps, buyAsset, collateralIsAsset);
        _approvePositions();
        (uint256 uniId, uint256 lpId) = LpMount.mount(
            addressProvider.getAddress("LiquidityOrchestrator"),
            usdc,
            lpData
        );
        _accountant().sealLp(owner, positionId, uniId, lpId);
    }

    function closeLeveraged(uint256 positionId, uint256 fundAmount, uint256 uniId, uint256 lpPositionId, bytes calldata exitData)
        external
        onlyOwner
        nonReentrant
    {
        address usdc = addressProvider.getAddress("USDC");
        address accountant = address(_accountant());
        if (fundAmount > 0) {
            IERC20(usdc).safeTransferFrom(owner, address(this), fundAmount);
            IERC20(usdc).safeTransfer(accountant, fundAmount);
        }
        _approvePositions();
        LpMount.unwind(addressProvider.getAddress("LiquidityOrchestrator"), uniId, lpPositionId, exitData);
        uint256 got = IERC20(usdc).balanceOf(address(this));
        if (got > 0) IERC20(usdc).safeTransfer(accountant, got);
        _accountant().settleLeveraged(owner, positionId);
    }

    function release(uint256 positionId) external onlyOwner nonReentrant {
        _accountant().release(owner, positionId);
    }

    function close(uint256 positionId, uint256 fundAmount, SwapTypes.SwapInput calldata swap)
        external
        onlyOwner
        nonReentrant
    {
        if (fundAmount > 0) _fund(swap.tokenIn, fundAmount);
        _accountant().close(owner, positionId, swap);
    }

    function _fund(address token, uint256 amount) internal {
        IERC20(token).safeTransferFrom(owner, address(this), amount);
        IERC20(token).safeTransfer(address(_accountant()), amount);
    }

    function _approvePositions() internal {
        IERC721(addressProvider.getAddress("UniswapNFTPositionManager")).setApprovalForAll(
            addressProvider.getAddress("LiquidityManager"), true
        );
        IERC721(addressProvider.getAddress("UniswapV4PositionManager")).setApprovalForAll(
            addressProvider.getAddress("LiquidityManagerV4"), true
        );
    }

    function _accountant() internal view returns (IAaveAccountant) {
        return IAaveAccountant(addressProvider.getAddress("AaveAccountant"));
    }

    error NotOwner();
    error NotAccountant();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroOwner();
    error Reentrancy();
}
