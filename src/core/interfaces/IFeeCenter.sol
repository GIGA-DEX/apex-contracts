// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFeeCenter {
    function apexController() external view returns (address);

    function vault() external view returns (address);

    function setReceiverImplementation(address _implementation) external;

    function addReceiver(address _outputToken) external returns (address receiver);

    function removeReceiver(address _outputToken) external returns (address receiver);

    function setSwapper(address _swapper, bool _status) external;

    function pushAndSplitFees(address[] calldata _tokens) external;

    function realizeClassicFees(address _pair) external returns (uint256 amount0, uint256 amount1);

    function executeReceiverSwap(
        address _receiver,
        address _tokenIn,
        address _target,
        uint256 _amount,
        uint256 _minAmountOut,
        bytes calldata _data
    ) external returns (uint256 spent, uint256 received);

    function notifyReceiverVault(address _receiver, uint256 _amount) external;

    function notifyReceiverVaultBalance(address _receiver) external returns (uint256 amount);

    function notifyReceiverVaultCompound(address _receiver, uint256 _amount) external;

    function notifyReceiverVaultCompoundBalance(address _receiver) external returns (uint256 amount);

    function rescueReceiverToken(address _receiver, address _token, address _to, uint256 _amount) external;

    function notifyVaultReward(address _token, uint256 _amount) external;

    function notifyVaultCompoundReward(uint256 _amount) external;

    function isSwapper(address _swapper) external view returns (bool);
}
