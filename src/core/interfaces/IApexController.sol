// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IApexController {
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);

    struct InitParams {
        address admin;
        address treasury;
    }

    struct ProtocolParams {
        address rewardToken;
        address classicFactory;
        address clFactory;
        address classicChef;
        address clMasterChef;
        address apexVault;
        address feeCenter;
    }

    enum PoolKind {
        CLASSIC,
        CL
    }

    struct EmissionWeight {
        PoolKind kind;
        address pool;
        uint256 allocPoint;
    }

    function registerClassicFarm(address pair) external;

    function activateClassicFarm(address pair, uint256 allocPoint) external;

    function deactivateClassicFarm(address pair) external;

    function registerCLFarm(address pool) external;

    function activateCLFarm(address pool, uint256 allocPoint) external;

    function deactivateCLFarm(address pool) external;

    function setCLGlobalProtocolFee(uint32 protocolFee) external;

    function clGlobalProtocolFee() external view returns (uint32);

    function applyUngaugedProtocolFees(address[] calldata classicPairs, address[] calldata clPools) external;

    function setLmPoolDeployer(address lmPoolDeployer) external;

    function setCLMasterChefEmergency(bool emergency) external;

    function setCLMevResistanceWindow(uint32 window) external;

    function setEmissionCenter(address center) external;

    function stopAllEmissions() external;

    function rebalanceEmissions(uint256 amount, uint256 duration, EmissionWeight[] calldata weights) external;

    function releaseAndSplitEmissions() external;

    function payReward(address pool, address to, uint256 amount) external returns (uint256 paid);

    function forfeitReward(address pool, uint256 amount) external returns (uint256 forfeited);

    function getLatestPeriodInfo(address pool) external view returns (uint256 rewardPerSecond, uint256 endTime);

    function collectCLProtocolFees(address pool, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1);

    function collectClassicProtocolFees(address pair) external returns (uint256 amount0, uint256 amount1);

    function notifyVaultReward(address token, uint256 amount) external;

    function notifyVaultRewardFrom(address from, address token, uint256 amount) external;

    function notifyVaultCompoundReward(uint256 amount) external;

    function notifyVaultCompoundRewardFrom(address from, uint256 amount) external;

    function compoundVault(uint256 tokenId) external returns (uint256 amount);

    function compoundVaultMany(uint256[] calldata tokenIds) external returns (uint256 amount);

    function setFeeReceiverImplementation(address implementation) external;

    function addFeeReceiver(address outputToken) external returns (address receiver);

    function removeFeeReceiver(address outputToken) external returns (address receiver);

    function setFeeSwapper(address swapper, bool status) external;

    function pushAndSplitFees(address[] calldata tokens) external;

    function executeFeeReceiverSwap(
        address receiver,
        address tokenIn,
        address swapper,
        uint256 amount,
        uint256 minAmountOut
    ) external returns (uint256 spent, uint256 received);

    function notifyFeeReceiverVault(address receiver, uint256 amount) external;

    function notifyFeeReceiverVaultBalance(address receiver) external returns (uint256 amount);

    function notifyFeeReceiverVaultCompound(address receiver, uint256 amount) external;

    function notifyFeeReceiverVaultCompoundBalance(address receiver) external returns (uint256 amount);

    function rescueFeeReceiverToken(address receiver, address token, address to, uint256 amount) external;

    function isFarmRegistered(address pool) external view returns (bool);

    function isFarmActive(address pool) external view returns (bool);

    function registeredClassicFarmsLength() external view returns (uint256);

    function registeredCLFarmsLength() external view returns (uint256);

    function registeredClassicFarmAt(uint256 index) external view returns (address);

    function registeredCLFarmAt(uint256 index) external view returns (address);

    function setTreasury(address treasury) external;

    function treasury() external view returns (address);

    function rewardToken() external view returns (address);

    function feeCenter() external view returns (address);

    function emissionCenter() external view returns (address);
}
