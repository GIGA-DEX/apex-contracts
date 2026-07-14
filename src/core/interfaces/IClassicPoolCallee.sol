// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IClassicPoolCallee {
    function hook(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}
