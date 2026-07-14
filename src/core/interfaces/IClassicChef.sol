// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IClassicChef {
    function rewardToken() external view returns (address);

    function apexController() external view returns (address);

    function add(uint256 allocPoint, IERC20 lpToken) external;

    function addPool(address lpToken, uint256 allocPoint) external;

    function set(uint256 pid, uint256 allocPoint) external;

    function setPoolAllocPoint(address lpToken, uint256 allocPoint) external;

    function depositFor(uint256 pid, uint256 amount, address account) external;

    function withdrawTo(uint256 pid, uint256 amount, address to) external;

    function withdrawToAndCall(uint256 pid, uint256 amount, address to, bytes calldata data) external;

    function massUpdatePools() external;

    function totalAllocPoint() external view returns (uint256);

    function pidOf(address lpToken) external view returns (uint256 pid);
}
