// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import {SwapMath} from "../../src/core/libraries/cl/SwapMath.sol";
import {TickMath} from "../../src/core/libraries/cl/TickMath.sol";

contract SymbolicCLSwapMathTest {
    uint24 internal constant MAX_FEE_PIPS = 999_999;

    function fuzzOnly_exactInputSwapStepNeverOverConsumes(
        uint16 _liquidity,
        uint16 _amountRemaining,
        uint16 _feePips,
        bool _zeroForOne
    ) public pure {
        if (_liquidity == 0 || _amountRemaining == 0 || _feePips > MAX_FEE_PIPS) return;
        _exactInputSwapStepNeverOverConsumesSmall(_liquidity, _amountRemaining, _feePips, _zeroForOne);
    }

    function testFuzz_exactInputSwapStepNeverOverConsumes(
        uint160 _sqrtCurrent,
        uint160 _sqrtTargetSeed,
        uint96 _liquidity,
        uint96 _amountRemaining,
        uint24 _feePips,
        bool _zeroForOne
    ) public pure {
        _exactInputSwapStepNeverOverConsumes(
            _sqrtCurrent, _sqrtTargetSeed, _liquidity, _amountRemaining, _feePips, _zeroForOne
        );
    }

    function fuzzOnly_exactOutputSwapStepNeverOverDelivers(
        uint16 _liquidity,
        uint16 _amountOutRequested,
        uint16 _feePips,
        bool _zeroForOne
    ) public pure {
        if (_liquidity == 0 || _amountOutRequested == 0 || _feePips > MAX_FEE_PIPS) return;
        _exactOutputSwapStepNeverOverDeliversSmall(_liquidity, _amountOutRequested, _feePips, _zeroForOne);
    }

    function testFuzz_exactOutputSwapStepNeverOverDelivers(
        uint160 _sqrtCurrent,
        uint160 _sqrtTargetSeed,
        uint96 _liquidity,
        uint96 _amountOutRequested,
        uint24 _feePips,
        bool _zeroForOne
    ) public pure {
        _exactOutputSwapStepNeverOverDelivers(
            _sqrtCurrent, _sqrtTargetSeed, _liquidity, _amountOutRequested, _feePips, _zeroForOne
        );
    }

    function _exactInputSwapStepNeverOverConsumes(
        uint160 _sqrtCurrent,
        uint160 _sqrtTargetSeed,
        uint96 _liquidity,
        uint96 _amountRemaining,
        uint24 _feePips,
        bool _zeroForOne
    ) internal pure {
        uint160 sqrtCurrent = _boundedSqrt(_sqrtCurrent);
        uint160 sqrtTarget = _targetSqrt(sqrtCurrent, _sqrtTargetSeed, _zeroForOne);
        uint128 liquidity = uint128(1 + uint256(_liquidity));
        uint256 amountRemaining = 1 + uint256(_amountRemaining);
        uint24 feePips = uint24(uint256(_feePips) % (MAX_FEE_PIPS + 1));

        (uint160 sqrtNext, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtCurrent, sqrtTarget, liquidity, int256(amountRemaining), feePips);
        amountOut;

        assert(amountIn + feeAmount <= amountRemaining);
        _assertPriceWithinStep(sqrtCurrent, sqrtTarget, sqrtNext, _zeroForOne);
    }

    function _exactInputSwapStepNeverOverConsumesSmall(
        uint16 _liquidity,
        uint16 _amountRemaining,
        uint16 _feePips,
        bool _zeroForOne
    ) internal pure {
        uint160 sqrtCurrent = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtTarget = _zeroForOne ? TickMath.getSqrtRatioAtTick(-60) : TickMath.getSqrtRatioAtTick(60);

        (uint160 sqrtNext, uint256 amountIn,, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtCurrent, sqrtTarget, uint128(_liquidity), int256(_amountRemaining), _feePips);

        assert(amountIn + feeAmount <= uint256(_amountRemaining));
        _assertPriceWithinStep(sqrtCurrent, sqrtTarget, sqrtNext, _zeroForOne);
    }

    function _exactOutputSwapStepNeverOverDelivers(
        uint160 _sqrtCurrent,
        uint160 _sqrtTargetSeed,
        uint96 _liquidity,
        uint96 _amountOutRequested,
        uint24 _feePips,
        bool _zeroForOne
    ) internal pure {
        uint160 sqrtCurrent = _boundedSqrt(_sqrtCurrent);
        uint160 sqrtTarget = _targetSqrt(sqrtCurrent, _sqrtTargetSeed, _zeroForOne);
        uint128 liquidity = uint128(1 + uint256(_liquidity));
        uint256 amountOutRequested = 1 + uint256(_amountOutRequested);
        uint24 feePips = uint24(uint256(_feePips) % (MAX_FEE_PIPS + 1));

        (uint160 sqrtNext,, uint256 amountOut,) =
            SwapMath.computeSwapStep(sqrtCurrent, sqrtTarget, liquidity, -int256(amountOutRequested), feePips);

        assert(amountOut <= amountOutRequested);
        _assertPriceWithinStep(sqrtCurrent, sqrtTarget, sqrtNext, _zeroForOne);
    }

    function _exactOutputSwapStepNeverOverDeliversSmall(
        uint16 _liquidity,
        uint16 _amountOutRequested,
        uint16 _feePips,
        bool _zeroForOne
    ) internal pure {
        uint160 sqrtCurrent = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtTarget = _zeroForOne ? TickMath.getSqrtRatioAtTick(-60) : TickMath.getSqrtRatioAtTick(60);

        (uint160 sqrtNext,, uint256 amountOut,) = SwapMath.computeSwapStep(
            sqrtCurrent, sqrtTarget, uint128(_liquidity), -int256(_amountOutRequested), _feePips
        );

        assert(amountOut <= uint256(_amountOutRequested));
        _assertPriceWithinStep(sqrtCurrent, sqrtTarget, sqrtNext, _zeroForOne);
    }

    function _boundedSqrt(uint160 sqrtSeed) internal pure returns (uint160) {
        uint256 span = uint256(TickMath.MAX_SQRT_RATIO) - uint256(TickMath.MIN_SQRT_RATIO) - 2;
        return uint160(uint256(TickMath.MIN_SQRT_RATIO) + 1 + (uint256(sqrtSeed) % span));
    }

    function _targetSqrt(uint160 sqrtCurrent, uint160 sqrtTargetSeed, bool zeroForOne) internal pure returns (uint160) {
        if (zeroForOne) {
            uint256 belowSpan = uint256(sqrtCurrent) - uint256(TickMath.MIN_SQRT_RATIO);
            return uint160(uint256(sqrtCurrent) - (1 + (uint256(sqrtTargetSeed) % belowSpan)));
        }

        uint256 aboveSpan = uint256(TickMath.MAX_SQRT_RATIO) - uint256(sqrtCurrent);
        return uint160(uint256(sqrtCurrent) + (1 + (uint256(sqrtTargetSeed) % aboveSpan)));
    }

    function _assertPriceWithinStep(uint160 sqrtCurrent, uint160 sqrtTarget, uint160 sqrtNext, bool zeroForOne)
        internal
        pure
    {
        if (zeroForOne) {
            assert(sqrtTarget <= sqrtNext);
            assert(sqrtNext <= sqrtCurrent);
        } else {
            assert(sqrtCurrent <= sqrtNext);
            assert(sqrtNext <= sqrtTarget);
        }
    }
}
