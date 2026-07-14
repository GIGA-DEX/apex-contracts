// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;
pragma abicoder v2;

import {ICLNonfungiblePositionManager} from "./ICLNonfungiblePositionManager.sol";

interface ICLMasterChef {
    function apexController() external view returns (address);

    function addPool(address pool, uint256 allocPoint) external;

    function setPoolAllocPoint(address pool, uint256 allocPoint) external;

    function massUpdatePools() external;

    function updatePools(uint256[] calldata pids) external;

    function totalAllocPoint() external view returns (uint256);

    function nonfungiblePositionManager() external view returns (address);

    function setEmergency(bool emergency) external;

    function setMevResistanceWindow(uint32 window) external;

    function lmPoolDeployer() external view returns (address);

    function setLMPoolDeployer(address deployer) external;

    function setLmPoolDeployer(address deployer) external;

    function getLatestPeriodInfo(address pool) external view returns (uint256 rewardPerSecond, uint256 endTime);

    function forfeitReward(address pool, uint256 amount) external returns (uint256 forfeited);

    function increaseLiquidity(ICLNonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(ICLNonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(ICLNonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collectTo(ICLNonfungiblePositionManager.CollectParams calldata params, address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function unwrapWETH9(uint256 amountMinimum, address recipient) external;

    function sweepToken(address token, uint256 amountMinimum, address recipient) external;

    function burn(uint256 tokenId) external;

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
