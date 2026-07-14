// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFeeReceiver {
    function initialize(address _feeCenter, address _vault, address _outputToken) external;

    function notifyVault(uint256 amount) external;

    function notifyVaultCompound(uint256 amount) external;

    function outputToken() external view returns (address);
}
