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

    /// @notice Pool types an authorized launcher caller may create.
    enum LauncherPermission {
        NONE,
        CLASSIC,
        CL,
        BOTH
    }

    struct EmissionWeight {
        PoolKind kind;
        address pool;
        uint256 allocPoint;
    }

    function registerClassicFarm(address pair) external;
    /// @dev External factories must implement the BrownFi V3 read and LP redemption ABI.
    function setExternalClassicFactory(address factory, bool allowed) external;
    function registerExternalClassicFarm(address factory, address pair) external;
    function isExternalClassicFactory(address factory) external view returns (bool);
    function externalClassicFarmFactory(address pair) external view returns (address);
    function requireExternalClassicFarmReady(address pair) external view;

    function activateClassicFarm(address pair, uint256 allocPoint) external;

    function deactivateClassicFarm(address pair) external;

    function registerCLFarm(address pool) external;

    function activateCLFarm(address pool, uint256 allocPoint) external;

    function deactivateCLFarm(address pool) external;

    function setCLGlobalProtocolFee(uint32 protocolFee) external;

    function clGlobalProtocolFee() external view returns (uint32);

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

    function collectLauncherCLProtocolFees(address pool) external returns (uint128 amount0, uint128 amount1);

    function collectLauncherClassicProtocolFees(address pair) external returns (uint256 amount0, uint256 amount1);

    /// @notice Configures and authorizes a launcher in one admin operation.
    /// @param veGigaFeeBps Base veGIGA share while ungauged; LPs receive the remaining gross-fee share.
    /// @param startGauged If true, creation registers the farm at zero emission weight and gives LPs zero swap fees.
    function configureLauncher(
        address launcher,
        address recipient,
        uint16 creatorFeeBps,
        uint16 veGigaFeeBps,
        bool startGauged,
        LauncherPermission permission,
        bool active
    ) external;

    /// @notice Assigns a share of gross swap fees to a recipient without granting launcher permissions.
    /// @dev Admin only. Settles old fees first. Zero bps requires a zero recipient and removes the creator share.
    ///      Preserves an existing base veGIGA share; first assignment on a gauged pool uses the global ungauged
    ///      protocol share as its base. Ungauged CL pools must have symmetric protocol fees.
    function assignCreatorFees(address pool, address recipient, uint16 creatorFeeBps) external;

    /// @notice Anyone may register an unused CL swap fee with a permanent global tick spacing.
    function enableCLFeeAmount(uint24 fee, int24 tickSpacing) external;

    /// @notice Settles existing fees, then updates a launcher's per-pool creator and base veGIGA split.
    function updateLauncherPoolFeeSplit(address pool, address recipient, uint16 creatorFeeBps, uint16 veGigaFeeBps)
        external;

    function createLauncherClassicPool(address tokenA, address tokenB, bool stable) external returns (address pair);

    function createLauncherCLPool(address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address pool);

    function launcherConfig(address launcher)
        external
        view
        returns (
            address recipient,
            uint16 creatorFeeBps,
            uint16 veGigaFeeBps,
            bool startGauged,
            LauncherPermission permission,
            bool active,
            bool configured
        );

    function launcherPoolConfig(address pool)
        external
        view
        returns (
            address launcher,
            address recipient,
            uint16 creatorFeeBps,
            uint16 veGigaFeeBps,
            PoolKind poolKind,
            bool gauged
        );

    function launchers(bool activeOnly) external view returns (address[] memory);

    function launcherPools() external view returns (address[] memory);

    function activeLauncherPools() external view returns (address[] memory);

    function launcherPoolsByLauncher(address launcher) external view returns (address[] memory);

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

    function pushAndSplitFeesWeighted(
        address[] calldata tokens,
        address[] calldata receivers,
        uint16[] calldata weightsBps
    ) external;

    function executeFeeReceiverSwap(
        address receiver,
        address tokenIn,
        address target,
        uint256 amount,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 spent, uint256 received);

    function notifyFeeReceiverVault(address receiver, uint256 amount) external;

    function notifyFeeReceiverVaultBalance(address receiver) external returns (uint256 amount);

    function notifyFeeReceiverVaultCompound(address receiver, uint256 amount) external;

    function notifyFeeReceiverVaultCompoundBalance(address receiver) external returns (uint256 amount);

    function notifyFeeReceiverVaultBalances(address[] calldata receivers, bool[] calldata isCompound)
        external
        returns (uint256[] memory amounts);

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
