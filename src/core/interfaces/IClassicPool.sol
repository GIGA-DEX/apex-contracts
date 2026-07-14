// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IClassicPool {
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function initialize(address token0, address token1, bool stable) external;

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    function skim(address to) external;

    function sync() external;

    function setFeeReceiver(address feeReceiver) external;

    function setProtocolFee(uint256 protocolFee) external;

    function setFee(uint256 fee) external;

    function mintFee() external;

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);

    function metadata()
        external
        view
        returns (
            uint256 decimals0,
            uint256 decimals1,
            uint256 reserve0,
            uint256 reserve1,
            bool stable,
            address token0,
            address token1
        );

    function protocolFee() external view returns (uint256);

    function fee() external view returns (uint256);

    function feeReceiver() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function stable() external view returns (bool);

    function kLast() external view returns (uint256);
}
