// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "../core/interfaces/ICLPool.sol";
import "../core/interfaces/callback/IPancakeV3SwapCallback.sol";
import "../core/libraries/cl/SafeCast.sol";
import "../core/libraries/cl/TickMath.sol";

import "./base/PeripheryImmutableState.sol";
import "./interfaces/IClassicFactoryMinimal.sol";
import "./interfaces/IClassicPoolMinimal.sol";
import "./interfaces/IMixedQuoter.sol";
import "./libraries/MixedRoute.sol";
import "./libraries/CallbackValidation.sol";
import "./libraries/Path.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/PoolTicksCounter.sol";

/// @title Apex mixed-route quoter
/// @notice Quotes exact-input paths that can include Apex Classic stable/volatile pairs and Apex CL pools.
contract MixedQuoter is IMixedQuoter, IPancakeV3SwapCallback, PeripheryImmutableState {
    using Path for bytes;
    using PoolTicksCounter for ICLPool;
    using SafeCast for uint256;

    address public immutable classicFactory;

    constructor(address _deployer, address _factory, address _classicFactory, address _WETH9)
        PeripheryImmutableState(_deployer, _factory, _WETH9)
    {
        classicFactory = _classicFactory;
    }

    function getPool(address _tokenA, address _tokenB, uint24 _fee) private view returns (ICLPool) {
        return ICLPool(PoolAddress.computeAddress(deployer, PoolAddress.getPoolKey(_tokenA, _tokenB, _fee)));
    }

    function getClassicPair(address _tokenIn, address _tokenOut, bool _stable) private view returns (address pair) {
        pair = IClassicFactoryMinimal(classicFactory).getPair(_tokenIn, _tokenOut, _stable);
        require(pair != address(0), "Classic pair missing");
    }

    /// @inheritdoc IPancakeV3SwapCallback
    function pancakeV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data)
        external
        view
        override
    {
        require(_amount0Delta > 0 || _amount1Delta > 0);

        bytes memory path = _data;
        (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();
        CallbackValidation.verifyCallback(deployer, tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountReceived) = _amount0Delta > 0
            ? (tokenIn < tokenOut, uint256(-_amount1Delta))
            : (tokenOut < tokenIn, uint256(-_amount0Delta));

        ICLPool pool = getPool(tokenIn, tokenOut, fee);
        (uint160 sqrtPriceX96After, int24 tickAfter,,,,,) = pool.slot0();

        if (isExactInput) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountReceived)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        }

        revert("Exact output quote not supported");
    }

    function parseRevertReason(bytes memory _reason)
        private
        pure
        returns (uint256 amount, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (_reason.length != 96) {
            if (_reason.length < 68) revert("Unexpected error");
            assembly {
                _reason := add(_reason, 0x04)
            }
            revert(abi.decode(_reason, (string)));
        }
        return abi.decode(_reason, (uint256, uint160, int24));
    }

    function handleCLRevert(bytes memory _reason, ICLPool _pool, uint256 _gasEstimate)
        private
        view
        returns (uint256 amount, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256)
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore,,,,,) = _pool.slot0();
        (amount, sqrtPriceX96After, tickAfter) = parseRevertReason(_reason);
        initializedTicksCrossed = _pool.countInitializedTicksCrossed(tickBefore, tickAfter);
        return (amount, sqrtPriceX96After, initializedTicksCrossed, _gasEstimate);
    }

    function quoteExactInputSingleCL(QuoteExactInputSingleCLParams memory _params)
        public
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        bool zeroForOne = _params.tokenIn < _params.tokenOut;
        ICLPool pool = getPool(_params.tokenIn, _params.tokenOut, _params.fee);

        uint256 gasBefore = gasleft();
        try pool.swap(
            address(this),
            zeroForOne,
            _params.amountIn.toInt256(),
            _params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : _params.sqrtPriceLimitX96,
            abi.encodePacked(_params.tokenIn, _params.fee, _params.tokenOut)
        ) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            return handleCLRevert(reason, pool, gasEstimate);
        }
    }

    function quoteExactInputSingleClassic(QuoteExactInputSingleClassicParams memory _params)
        public
        view
        override
        returns (uint256 amountOut)
    {
        amountOut = IClassicPoolMinimal(getClassicPair(_params.tokenIn, _params.tokenOut, _params.stable))
            .getAmountOut(_params.amountIn, _params.tokenIn);
    }

    function quoteExactInput(bytes memory _path, uint256 _amountIn)
        public
        override
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        uint256[] memory flags = new uint256[](0);
        return _quoteExactInput(_path, flags, _amountIn);
    }

    /// @notice Pancake SmartRouter-compatible overload. Flags are consumed only for Classic hops.
    function quoteExactInput(bytes memory _path, uint256[] memory _flags, uint256 _amountIn)
        public
        override
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        return _quoteExactInput(_path, _flags, _amountIn);
    }

    function _quoteExactInput(bytes memory _path, uint256[] memory _flags, uint256 _amountIn)
        private
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        sqrtPriceX96AfterList = new uint160[](_path.numPools());
        initializedTicksCrossedList = new uint32[](_path.numPools());

        uint256 i;
        uint256 flagIndex;
        while (true) {
            (address tokenIn, address tokenOut, uint24 action) = _path.decodeFirstPool();
            if (MixedRoute.hasClassicFlag(action)) {
                bool stable = flagIndex < _flags.length
                    ? MixedRoute.stableFromPancakeFlag(_flags[flagIndex++])
                    : MixedRoute.stableFromAction(action);
                _amountIn = quoteExactInputSingleClassic(
                    QuoteExactInputSingleClassicParams({
                        tokenIn: tokenIn, tokenOut: tokenOut, amountIn: _amountIn, stable: stable
                    })
                );
            } else {
                uint256 clGasEstimate;
                (_amountIn, sqrtPriceX96AfterList[i], initializedTicksCrossedList[i], clGasEstimate) =
                    quoteExactInputSingleCL(
                        QuoteExactInputSingleCLParams({
                            tokenIn: tokenIn, tokenOut: tokenOut, fee: action, amountIn: _amountIn, sqrtPriceLimitX96: 0
                        })
                    );
                gasEstimate += clGasEstimate;
            }
            i++;

            if (_path.hasMultiplePools()) {
                _path = _path.skipToken();
            } else {
                require(flagIndex == _flags.length, "Flag length mismatch");
                return (_amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate);
            }
        }
    }
}
