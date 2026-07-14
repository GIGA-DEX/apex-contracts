// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

contract SymbolicClassicPoolMathTest is Test {
    uint256 internal constant FEE_DENOM = 1_000_000;
    uint256 internal constant MAX_FEE = 500_000;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant MIN_VOLATILE_RESERVE = 1e6;
    uint256 internal constant MIN_STABLE_RESERVE = 1e18;
    uint256 internal constant MAX_VOLATILE_RESERVE = 1e30;
    uint256 internal constant MAX_STABLE_RESERVE = 1e24;

    function fuzzOnly_volatileSwapQuotePreservesAdjustedK(
        uint16 _reserveIn,
        uint16 _reserveOut,
        uint16 _amountIn,
        uint16 _fee
    ) public pure {
        if (_reserveIn == 0 || _reserveOut == 0 || _amountIn == 0) return;
        _volatileSwapQuotePreservesAdjustedKSmall(_reserveIn, _reserveOut, _amountIn, _fee);
    }

    function testFuzz_volatileSwapQuotePreservesAdjustedK(
        uint96 _reserveIn,
        uint96 _reserveOut,
        uint96 _amountIn,
        uint24 _fee
    ) public pure {
        _volatileSwapQuotePreservesAdjustedK(_reserveIn, _reserveOut, _amountIn, _fee);
    }

    function fuzzOnly_stableSwapQuotePreservesAdjustedK(
        uint96 _reserve0,
        uint96 _reserve1,
        uint96 _amountIn,
        uint24 _fee,
        bool _zeroForOne
    ) public pure {
        _stableSwapQuotePreservesAdjustedK(_reserve0, _reserve1, _amountIn, _fee, _zeroForOne);
    }

    function testFuzz_stableSwapQuotePreservesAdjustedK(
        uint96 _reserve0,
        uint96 _reserve1,
        uint96 _amountIn,
        uint24 _fee,
        bool _zeroForOne
    ) public pure {
        _stableSwapQuotePreservesAdjustedK(_reserve0, _reserve1, _amountIn, _fee, _zeroForOne);
    }

    function _volatileSwapQuotePreservesAdjustedKSmall(
        uint16 _reserveIn,
        uint16 _reserveOut,
        uint16 _amountIn,
        uint16 _fee
    ) internal pure {
        uint256 reserveIn = uint256(_reserveIn);
        uint256 reserveOut = uint256(_reserveOut);
        uint256 amountIn = uint256(_amountIn);
        uint256 fee = uint256(_fee);
        uint256 amountInAfterFee = amountIn - ((amountIn * fee) / FEE_DENOM);
        uint256 rawAmountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee);
        if (rawAmountOut == 0) return;

        uint256 amountOut = rawAmountOut - 1;
        uint256 balanceInAdjusted = reserveIn + amountInAfterFee;
        uint256 balanceOut = reserveOut - amountOut;

        assert(amountOut < reserveOut);
        assert(balanceInAdjusted * balanceOut >= reserveIn * reserveOut);
    }

    function _volatileSwapQuotePreservesAdjustedK(uint96 _reserveIn, uint96 _reserveOut, uint96 _amountIn, uint24 _fee)
        internal
        pure
    {
        uint256 reserveIn = _bounded(_reserveIn, MIN_VOLATILE_RESERVE, MAX_VOLATILE_RESERVE);
        uint256 reserveOut = _bounded(_reserveOut, MIN_VOLATILE_RESERVE, MAX_VOLATILE_RESERVE);
        uint256 amountIn = _bounded(_amountIn, 1, reserveIn);
        uint256 fee = uint256(_fee) % (MAX_FEE + 1);
        uint256 amountInAfterFee = amountIn - ((amountIn * fee) / FEE_DENOM);
        uint256 rawAmountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee);
        if (rawAmountOut == 0) return;

        uint256 amountOut = rawAmountOut - 1;
        uint256 balanceInAdjusted = reserveIn + amountInAfterFee;
        uint256 balanceOut = reserveOut - amountOut;

        assert(amountOut < reserveOut);
        assert(balanceInAdjusted * balanceOut >= reserveIn * reserveOut);
    }

    function _stableSwapQuotePreservesAdjustedK(
        uint96 _reserve0,
        uint96 _reserve1,
        uint96 _amountIn,
        uint24 _fee,
        bool _zeroForOne
    ) internal pure {
        uint256 reserve0 = _bounded(_reserve0, MIN_STABLE_RESERVE, MAX_STABLE_RESERVE);
        uint256 reserve1 = _bounded(_reserve1, MIN_STABLE_RESERVE, MAX_STABLE_RESERVE);
        uint256 reserveIn = _zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = _zeroForOne ? reserve1 : reserve0;
        uint256 amountIn = _bounded(_amountIn, 1, reserveIn);
        uint256 fee = uint256(_fee) % (MAX_FEE + 1);
        uint256 amountInAfterFee = amountIn - ((amountIn * fee) / FEE_DENOM);
        uint256 rawAmountOut = _stableAmountOut(reserve0, reserve1, amountInAfterFee, _zeroForOne);
        if (rawAmountOut == 0) return;

        uint256 amountOut = rawAmountOut - 1;

        assert(amountOut < reserveOut);
        _assertStableSwapPreservesK(reserve0, reserve1, amountInAfterFee, amountOut, _zeroForOne);
    }

    function _stableAmountOut(uint256 reserve0, uint256 reserve1, uint256 amountInAfterFee, bool zeroForOne)
        internal
        pure
        returns (uint256)
    {
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;
        uint256 scaledReserveIn = (reserveIn * 1e18) / DECIMALS;
        uint256 scaledReserveOut = (reserveOut * 1e18) / DECIMALS;
        uint256 scaledAmountIn = (amountInAfterFee * 1e18) / DECIMALS;
        uint256 y =
            scaledReserveOut - _getY(scaledAmountIn + scaledReserveIn, _stableK(reserve0, reserve1), scaledReserveOut);
        return (y * DECIMALS) / 1e18;
    }

    function _assertStableSwapPreservesK(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amountInAfterFee,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure {
        uint256 xy = _stableK(reserve0, reserve1);
        if (zeroForOne) {
            assert(_stableK(reserve0 + amountInAfterFee, reserve1 - amountOut) >= xy);
        } else {
            assert(_stableK(reserve0 - amountOut, reserve1 + amountInAfterFee) >= xy);
        }
    }

    function _stableK(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 scaledX = (x * 1e18) / DECIMALS;
        uint256 scaledY = (y * 1e18) / DECIMALS;
        uint256 a = (scaledX * scaledY) / 1e18;
        uint256 b = ((scaledX * scaledX) / 1e18) + ((scaledY * scaledY) / 1e18);
        return (a * b) / 1e18;
    }

    function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (x0 * ((((y * y) / 1e18) * y) / 1e18)) / 1e18 + (((((x0 * x0) / 1e18) * x0) / 1e18) * y) / 1e18;
    }

    function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (3 * x0 * ((y * y) / 1e18)) / 1e18 + ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    function _getY(uint256 x0, uint256 xy, uint256 y) internal pure returns (uint256) {
        for (uint256 i; i < 255; ++i) {
            uint256 yPrev = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > yPrev) {
                if (y - yPrev <= 1) return y;
            } else {
                if (yPrev - y <= 1) return y;
            }
        }
        return y;
    }

    function _bounded(uint256 value, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        return minValue + (value % (maxValue - minValue + 1));
    }
}
