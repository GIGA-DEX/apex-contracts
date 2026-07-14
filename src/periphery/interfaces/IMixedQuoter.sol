// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;
pragma abicoder v2;

interface IMixedQuoter {
    struct QuoteExactInputSingleCLParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactInputSingleClassicParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        bool stable;
    }

    function quoteExactInput(bytes memory _path, uint256 _amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    function quoteExactInput(bytes memory _path, uint256[] memory _flags, uint256 _amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    function quoteExactInputSingleCL(QuoteExactInputSingleCLParams memory _params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    function quoteExactInputSingleClassic(QuoteExactInputSingleClassicParams memory _params)
        external
        view
        returns (uint256 amountOut);
}
