// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

interface IClassicPoolMinimal {
    function getAmountOut(uint256 _amountIn, address _tokenIn) external view returns (uint256 _amountOut);

    function swap(uint256 _amount0Out, uint256 _amount1Out, address _to, bytes calldata _data) external;

    function token0() external view returns (address);
}
