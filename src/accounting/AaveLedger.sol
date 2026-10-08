//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISendraAddressProvider} from "../interfaces/iSendraCore/ISendraAddressProvider.sol";
import {ISendraStorage} from "../interfaces/iSendraCore/ISendraStorage.sol";
import {IPositionInitializer} from "../interfaces/iSendraCore/IPositionInitializer.sol";
import {SendraLib} from "../lib/Sendra.lib.sol";

/// @notice Pulse and position records for Aave strategies. Split out so AaveAccountant fits in 24KB.
contract AaveLedger {
    struct Fields {
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

    address public immutable accountant;
    address public immutable registry;
    IPositionInitializer public immutable initializer;
    ISendraStorage public immutable store;

    constructor(address provider, address _accountant) {
        accountant = _accountant;
        registry = provider;
        ISendraAddressProvider addresses = ISendraAddressProvider(provider);
        initializer = IPositionInitializer(addresses.getAddress("PositionInitializer"));
        store = ISendraStorage(addresses.getAddress("SendraStorage"));
    }

    modifier onlyAccountant() {
        if (msg.sender != accountant) revert NotAccountant();
        _;
    }

    function recordOpen(address owner, address account, Fields calldata book) external onlyAccountant {
        _write(owner, account, book, false, 0, true);
        _accrueOpen(owner, book.kind, book.principalUsdc);
    }

    function recordUpdate(address owner, address account, Fields calldata book) external onlyAccountant {
        _write(owner, account, book, false, 0, false);
    }

    function recordClose(
        address owner,
        address account,
        Fields calldata book,
        uint256 capitalOut,
        int256 pnl
    ) external onlyAccountant {
        _accrueClose(owner, book.kind, book.principalUsdc, capitalOut, pnl, book.openedAt);
        _write(owner, account, book, true, pnl, false);
        store.decreaseGlobalPositionActivePositions(owner);
        store.updateUserGlobalPnl(_reputation(owner), pnl);
    }

    function _write(
        address owner,
        address account,
        Fields calldata book,
        bool closed,
        int256 pnl,
        bool first
    ) internal {
        bytes[] memory payload = new bytes[](13);
        payload[0] = abi.encode(book.asset);
        payload[1] = abi.encode(book.kind);
        payload[2] = abi.encode(book.openedAt);
        payload[3] = abi.encode(account);
        payload[4] = abi.encode(book.collateralAmount);
        payload[5] = abi.encode(book.debtAmount);
        payload[6] = abi.encode(book.principalUsdc);
        payload[7] = abi.encode(book.proceeds);
        payload[8] = abi.encode(book.released);
        payload[9] = abi.encode(closed ? block.timestamp : uint256(0));
        payload[10] = abi.encode(block.chainid);
        payload[11] = abi.encode(book.uniTokenId);
        payload[12] = abi.encode(book.lpPositionId);
        if (first) {
            initializer.initializePosition(payload, book.kind, owner);
            return;
        }
        store.updateUserFullPosition(
            owner,
            book.positionId,
            SendraLib.Position({
                positionType: book.kind,
                id: book.positionId,
                pnl: pnl,
                isActive: !closed,
                positionData: payload
            })
        );
    }

    function _accrueOpen(address owner, uint8 kind, uint256 capital) internal {
        address who = _reputation(owner);
        uint256 peak = uint256(store.getUniqueGlobalAccumulator(2, who));
        uint256 current = uint256(store.getUniqueGlobalAccumulator(3, who));
        uint256 last = uint256(store.getUniqueGlobalAccumulator(15, who));
        uint256 next = current + capital;
        uint8[] memory gIds = new uint8[](5);
        int256[] memory gDeltas = new int256[](5);
        gIds[0] = 0;
        gDeltas[0] = int256(capital);
        gIds[1] = 2;
        gDeltas[1] = next > peak ? int256(next - peak) : int256(0);
        gIds[2] = 3;
        gDeltas[2] = int256(capital);
        gIds[3] = 15;
        gDeltas[3] = int256(block.timestamp - last);
        gIds[4] = 9;
        gDeltas[4] = 1;
        uint8[] memory sIds = new uint8[](2);
        int256[] memory sDeltas = new int256[](2);
        sIds[0] = 1;
        sDeltas[0] = int256(capital);
        sIds[1] = 5;
        sDeltas[1] = 1;
        _pulse(who, kind, gIds, gDeltas, sIds, sDeltas);
    }

    function _accrueClose(
        address owner,
        uint8 kind,
        uint256 principal,
        uint256 capitalOut,
        int256 pnl,
        uint256 openedAt
    ) internal {
        address who = _reputation(owner);
        int256 highWaterMark = store.getUniqueGlobalAccumulator(7, who);
        int256 currentPnl = store.getUniqueGlobalAccumulator(4, who);
        int256 newPnl = currentPnl + pnl;
        int256 maxDrawdown = store.getUniqueGlobalAccumulator(8, who);
        int256 streak = store.getUniqueGlobalAccumulator(17, who);
        int256 maxStreak = store.getUniqueGlobalAccumulator(18, who);
        uint256 last = uint256(store.getUniqueGlobalAccumulator(15, who));
        uint8[] memory gIds = new uint8[](13);
        int256[] memory gDeltas = new int256[](13);
        gIds[0] = 1;
        gDeltas[0] = int256(capitalOut);
        gIds[1] = 3;
        gDeltas[1] = -int256(principal);
        gIds[2] = 4;
        gDeltas[2] = pnl;
        gIds[6] = 10;
        gDeltas[6] = 1;
        gIds[7] = 11;
        gIds[8] = 12;
        if (pnl > 0) {
            gIds[3] = 5;
            gDeltas[3] = pnl;
            gIds[4] = 7;
            gDeltas[4] = highWaterMark < newPnl ? newPnl - highWaterMark : int256(0);
            gIds[5] = 8;
            gDeltas[5] = 0;
            gDeltas[7] = 1;
        } else {
            gIds[3] = 6;
            gDeltas[3] = pnl < 0 ? -pnl : int256(0);
            gIds[4] = 7;
            gIds[5] = 8;
            int256 drawdown = newPnl < highWaterMark ? highWaterMark - newPnl : int256(0);
            gDeltas[5] = maxDrawdown < drawdown ? drawdown - maxDrawdown : int256(0);
            gDeltas[8] = pnl < 0 ? int256(1) : int256(0);
        }
        gIds[9] = 13;
        gDeltas[9] = int256(block.timestamp - openedAt);
        gIds[10] = 15;
        gDeltas[10] = int256(block.timestamp - last);
        gIds[11] = 17;
        gIds[12] = 18;
        if (pnl < 0) {
            int256 nextStreak = streak + 1;
            gDeltas[11] = 1;
            gDeltas[12] = nextStreak > maxStreak ? nextStreak - maxStreak : int256(0);
        } else if (pnl > 0 && streak > 0) {
            gDeltas[11] = -streak;
        }
        uint8[] memory sIds = new uint8[](3);
        int256[] memory sDeltas = new int256[](3);
        sIds[0] = 0;
        sDeltas[0] = pnl;
        sIds[1] = 2;
        sDeltas[1] = int256(capitalOut);
        sIds[2] = pnl > 0 ? 3 : 4;
        sDeltas[2] = pnl == 0 ? int256(0) : int256(1);
        _pulse(who, kind, gIds, gDeltas, sIds, sDeltas);
    }

    /// @dev Book stays on `owner`. Pulse moves to the enclave operator when EnclavePulse says so.
    function _reputation(address owner) internal view returns (address) {
        (bool ok, bytes memory data) = registry.staticcall(
            abi.encodeWithSignature("getAddress(string)", "EnclavePulse")
        );
        if (!ok || data.length < 32) return owner;
        address pulse = abi.decode(data, (address));
        if (pulse == address(0)) return owner;
        (bool okTo, bytes memory whoData) = pulse.staticcall(abi.encodeWithSignature("recipient(address)", owner));
        if (!okTo || whoData.length < 32) return owner;
        address who = abi.decode(whoData, (address));
        return who == address(0) ? owner : who;
    }

    function _pulse(
        address owner,
        uint8 kind,
        uint8[] memory gIds,
        int256[] memory gDeltas,
        uint8[] memory sIds,
        int256[] memory sDeltas
    ) internal {
        store.applyGlobalPulseDeltas(owner, gIds, gDeltas);
        store.applySpecificPulseDeltas(owner, kind, sIds, sDeltas);
    }

    error NotAccountant();
}
