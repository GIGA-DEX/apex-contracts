// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;
pragma abicoder v2;

import "../../core/interfaces/callback/IPancakeV3SwapCallback.sol";

interface ISmartRouter is IPancakeV3SwapCallback {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInputSingle(ExactInputSingleParams calldata _params) external payable returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata _params) external payable returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata _params) external payable returns (uint256 amountIn);

    function exactOutput(ExactOutputParams calldata _params) external payable returns (uint256 amountIn);

    function swapExactTokensForTokens(uint256 _amountIn, uint256 _amountOutMin, address[] calldata _path, address _to)
        external
        payable
        returns (uint256 amountOut);

    function exactInputStableSwap(
        address[] calldata _path,
        uint256[] calldata _flags,
        uint256 _amountIn,
        uint256 _amountOutMin,
        address _to
    ) external payable returns (uint256 amountOut);
}
