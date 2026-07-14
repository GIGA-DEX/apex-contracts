// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFeeSwapper {
    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut, address _recipient)
        external
        returns (uint256 amountOut);
}
