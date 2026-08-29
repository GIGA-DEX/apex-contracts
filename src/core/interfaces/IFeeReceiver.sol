// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFeeReceiver {
    function initialize(address _feeCenter, address _vault, address _outputToken) external;

    function executeSwap(
        address _tokenIn,
        address _target,
        uint256 _amount,
        uint256 _minAmountOut,
        bytes calldata _data
    ) external returns (uint256 spent, uint256 received);

    function notifyVault(uint256 amount) external;

    function notifyVaultCompound(uint256 amount) external;

    function outputToken() external view returns (address);
}
