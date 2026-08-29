// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IApexController} from "./interfaces/IApexController.sol";
import {IClassicChef} from "./interfaces/IClassicChef.sol";
import {IClassicFactory} from "./interfaces/IClassicFactory.sol";
import {ICLFactory} from "./interfaces/ICLFactory.sol";
import {ICLMasterChef} from "./interfaces/ICLMasterChef.sol";
import {ICLMasterChefConfig} from "./interfaces/ICLMasterChefConfig.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {IFeeCenter} from "./interfaces/IFeeCenter.sol";
import {IApexVault} from "./interfaces/IApexVault.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";
import {ApexControllerFeePolicy} from "./libraries/ApexControllerFeePolicy.sol";
import {ApexControllerStorage} from "./storage/ApexControllerStorage.sol";

interface IEmissionCenter {
    function releaseVested(address token) external returns (uint256 released);
}

contract ApexController is IApexController, AccessControlEnumerableUpgradeable, ReentrancyGuardUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_PRECISION = 1e12;

    bytes32 public constant FEE_OPERATOR = keccak256("FEE_OPERATOR");
    bytes32 public constant EMISSION_OPERATOR = keccak256("EMISSION_OPERATOR");
    bytes32 public constant VAULT_OPERATOR = keccak256("VAULT_OPERATOR");

    event ControllerInitialized(address indexed admin, address indexed treasury);
    event ProtocolInitialized(
        address rewardToken,
        address classicFactory,
        address clFactory,
        address classicChef,
        address clMasterChef,
        address apexVault,
        address feeCenter
    );
    event ClassicFarmRegistered(address indexed pair);
    event ClassicFarmActivated(address indexed pair, uint256 allocPoint, address indexed feeReceiver);
    event ClassicFarmDeactivated(address indexed pair);
    event CLFarmRegistered(address indexed clFactory, address indexed pool);
    event CLFarmActivated(address indexed clFactory, address indexed pool, uint256 allocPoint);
    event CLFarmDeactivated(address indexed clFactory, address indexed pool);
    event RebalanceEmissions(uint256 amount, uint256 duration, uint256 rewardAmount, uint256 rewardPerSecond);
    event RewardPaid(address indexed pool, address indexed to, uint256 amount);
    event RewardForfeited(address indexed pool, uint256 amount);
    event EmissionCenterSet(address indexed center);
    event LauncherConfigured(
        address indexed launcher,
        address indexed recipient,
        uint16 creatorFeeBps,
        uint16 veGigaFeeBps,
        bool startGauged,
        LauncherPermission permission,
        bool active
    );
    event LauncherPoolCreated(
        address indexed launcher,
        address indexed pool,
        PoolKind indexed poolKind,
        address recipient,
        uint16 creatorFeeBps,
        uint16 veGigaFeeBps,
        bool gauged
    );
    event LauncherPoolFeeSplitSet(
        address indexed pool, address indexed recipient, uint16 creatorFeeBps, uint16 veGigaFeeBps
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata _params) external initializer {
        require(_params.admin != address(0) && _params.treasury != address(0), ApexErrors.ZERO_ADDRESS());
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();

        ApexControllerStorage.layout().treasury = _params.treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _params.admin);
        _grantRole(FEE_OPERATOR, _params.admin);
        _grantRole(EMISSION_OPERATOR, _params.admin);
        _grantRole(VAULT_OPERATOR, _params.admin);

        emit ControllerInitialized(_params.admin, _params.treasury);
    }

    function initializeProtocol(ProtocolParams calldata _params)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        reinitializer(2)
    {
        require(_params.rewardToken != address(0), ApexErrors.ZERO_ADDRESS());
        require(_params.classicFactory != address(0), ApexErrors.ZERO_ADDRESS());
        require(_params.clFactory != address(0), ApexErrors.ZERO_ADDRESS());
        require(_params.classicChef != address(0), ApexErrors.ZERO_ADDRESS());
        require(_params.clMasterChef != address(0), ApexErrors.ZERO_ADDRESS());
        require(_params.apexVault != address(0), ApexErrors.ZERO_ADDRESS());
        require(_params.feeCenter != address(0), ApexErrors.ZERO_ADDRESS());
        require(
            IClassicChef(_params.classicChef).rewardToken() == _params.rewardToken,
            ApexErrors.INVALID_POOL(_params.classicChef)
        );
        require(
            IClassicChef(_params.classicChef).apexController() == address(this),
            ApexErrors.NOT_AUTHORIZED(_params.classicChef)
        );
        require(
            address(ICLMasterChefConfig(_params.clMasterChef).rewardToken()) == _params.rewardToken,
            ApexErrors.INVALID_POOL(_params.clMasterChef)
        );
        require(
            ICLMasterChefConfig(_params.clMasterChef).apexController() == address(this),
            ApexErrors.NOT_AUTHORIZED(_params.clMasterChef)
        );
        require(
            IApexVault(_params.apexVault).apexController() == address(this),
            ApexErrors.NOT_AUTHORIZED(_params.apexVault)
        );
        require(ICLFactory(_params.clFactory).owner() == address(this), ApexErrors.NOT_AUTHORIZED(_params.clFactory));
        require(
            IFeeCenter(_params.feeCenter).apexController() == address(this),
            ApexErrors.NOT_AUTHORIZED(_params.feeCenter)
        );
        require(
            IFeeCenter(_params.feeCenter).vault() == _params.apexVault, ApexErrors.NOT_AUTHORIZED(_params.feeCenter)
        );

        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        $.rewardToken = IERC20(_params.rewardToken);
        $.classicFactory = IClassicFactory(_params.classicFactory);
        $.clFactory = ICLFactory(_params.clFactory);
        $.classicChef = IClassicChef(_params.classicChef);
        $.clMasterChef = ICLMasterChef(_params.clMasterChef);
        $.apexVault = IApexVault(_params.apexVault);
        $.feeCenter = IFeeCenter(_params.feeCenter);
        $.classicFactory.setFeeReceiver(_params.feeCenter);

        emit ProtocolInitialized(
            _params.rewardToken,
            _params.classicFactory,
            _params.clFactory,
            _params.classicChef,
            _params.clMasterChef,
            _params.apexVault,
            _params.feeCenter
        );
    }

    // classic
    function setClassicGlobalFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setClassicGlobalFee(_fee);
    }

    function setClassicGlobalProtocolFee(uint256 _protocolFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setClassicGlobalProtocolFee(_protocolFee);
    }

    function setCLGlobalProtocolFee(uint32 _protocolFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setCLGlobalProtocolFee(_protocolFee);
    }

    function clGlobalProtocolFee() public view returns (uint32) {
        return ApexControllerFeePolicy.clGlobalProtocolFee();
    }

    function setClassicGlobalFeeReceiver(address _feeReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setClassicGlobalFeeReceiver(_feeReceiver);
    }

    function overrideClassicFeeReceiver(address _pair, address _feeReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.overrideClassicFeeReceiver(_pair, _feeReceiver);
    }

    function overrideClassicFee(address _pair, uint256 _fee) external onlyRole(FEE_OPERATOR) {
        ApexControllerFeePolicy.overrideClassicFee(_pair, _fee);
    }

    function overrideClassicProtocolFee(address _pair, uint256 _protocolFee) external onlyRole(FEE_OPERATOR) {
        ApexControllerFeePolicy.overrideClassicProtocolFee(_pair, _protocolFee);
    }

    // cl
    function overrideCLProtocolFee(address _pool, uint32 _feeProtocol0, uint32 _feeProtocol1)
        external
        onlyRole(FEE_OPERATOR)
    {
        ApexControllerFeePolicy.overrideCLProtocolFee(_pool, _feeProtocol0, _feeProtocol1);
    }

    function collectCLProtocolFees(address _pool, uint128 _amount0Requested, uint128 _amount1Requested)
        external
        onlyRole(FEE_OPERATOR)
        returns (uint128 amount0, uint128 amount1)
    {
        return ApexControllerFeePolicy.collectCLProtocolFees(_pool, _amount0Requested, _amount1Requested);
    }

    function collectClassicProtocolFees(address _pair)
        external
        onlyRole(FEE_OPERATOR)
        returns (uint256 amount0, uint256 amount1)
    {
        return ApexControllerFeePolicy.collectClassicProtocolFees(_pair);
    }

    function collectLauncherCLProtocolFees(address _pool)
        external
        nonReentrant
        returns (uint128 amount0, uint128 amount1)
    {
        return ApexControllerFeePolicy.collectLauncherCLProtocolFees(_pool);
    }

    function collectLauncherClassicProtocolFees(address _pair)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        return ApexControllerFeePolicy.collectLauncherClassicProtocolFees(_pair);
    }

    function configureLauncher(
        address _launcher,
        address _recipient,
        uint16 _creatorFeeBps,
        uint16 _veGigaFeeBps,
        bool _startGauged,
        LauncherPermission _permission,
        bool _active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.configureLauncher(
            _launcher, _recipient, _creatorFeeBps, _veGigaFeeBps, _startGauged, _permission, _active
        );
    }

    function updateLauncherPoolFeeSplit(address _pool, address _recipient, uint16 _creatorFeeBps, uint16 _veGigaFeeBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ApexControllerFeePolicy.updateLauncherPoolFeeSplit(_pool, _recipient, _creatorFeeBps, _veGigaFeeBps);
    }

    function createLauncherClassicPool(address _tokenA, address _tokenB, bool _stable)
        external
        nonReentrant
        returns (address pair)
    {
        return ApexControllerFeePolicy.createLauncherClassicPool(_tokenA, _tokenB, _stable);
    }

    function createLauncherCLPool(address _tokenA, address _tokenB, uint24 _fee, uint160 _sqrtPriceX96)
        external
        nonReentrant
        returns (address pool)
    {
        return ApexControllerFeePolicy.createLauncherCLPool(_tokenA, _tokenB, _fee, _sqrtPriceX96);
    }

    function launcherConfig(address _launcher)
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
        )
    {
        return ApexControllerFeePolicy.launcherConfig(_launcher);
    }

    function launcherPoolConfig(address _pool)
        external
        view
        returns (
            address launcher,
            address recipient,
            uint16 creatorFeeBps,
            uint16 veGigaFeeBps,
            PoolKind poolKind,
            bool gauged
        )
    {
        return ApexControllerFeePolicy.launcherPoolConfig(_pool);
    }

    function launchers(bool _activeOnly) external view returns (address[] memory) {
        return ApexControllerFeePolicy.launchers(_activeOnly);
    }

    function launcherPools() external view returns (address[] memory) {
        return ApexControllerFeePolicy.launcherPools();
    }

    function activeLauncherPools() external view returns (address[] memory) {
        return ApexControllerFeePolicy.activeLauncherPools();
    }

    function launcherPoolsByLauncher(address _launcher) external view returns (address[] memory) {
        return ApexControllerFeePolicy.launcherPoolsByLauncher(_launcher);
    }

    // farms
    function registerClassicFarm(address _pair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.registerClassicFarm(_pair);
    }

    function activateClassicFarm(address _pair, uint256 _allocPoint) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.activateClassicFarm(_pair, _allocPoint);
    }

    function deactivateClassicFarm(address _pair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.deactivateClassicFarm(_pair);
    }

    function registerCLFarm(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.registerCLFarm(_pool);
    }

    function activateCLFarm(address _pool, uint256 _allocPoint) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.activateCLFarm(_pool, _allocPoint);
    }

    function deactivateCLFarm(address _pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.deactivateCLFarm(_pool);
    }

    function setLmPoolDeployer(address _lmPoolDeployer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setLmPoolDeployer(_lmPoolDeployer);
    }

    function setCLMasterChefEmergency(bool _emergency) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setCLMasterChefEmergency(_emergency);
    }

    function setCLMevResistanceWindow(uint32 _window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setCLMevResistanceWindow(_window);
    }

    function setEmissionCenter(address _center) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setEmissionCenter(_center);
    }

    function stopAllEmissions() external onlyRole(EMISSION_OPERATOR) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        $.classicChef.massUpdatePools();
        $.clMasterChef.massUpdatePools();

        if ($.latestPeriodEndTime > block.timestamp) {
            $.rewardLiability -= (($.latestPeriodEndTime - block.timestamp) * $.latestPeriodRewardPerSecond)
                / REWARD_PRECISION;
        }
        $.latestPeriodEndTime = block.timestamp;
        $.latestPeriodRewardPerSecond = 0;
    }

    function rebalanceEmissions(uint256 _amount, uint256 _duration, EmissionWeight[] calldata _weights)
        external
        onlyRole(EMISSION_OPERATOR)
    {
        require(_duration != 0, ApexErrors.INVALID_DURATION());
        require(_weights.length != 0, ApexErrors.ZERO_AMOUNT());

        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        {
            IClassicChef classicChef = $.classicChef;
            ICLMasterChef clMasterChef = $.clMasterChef;
            bool hasClassicChef = address(classicChef) != address(0);
            bool hasClMasterChef = address(clMasterChef) != address(0);
            require(hasClassicChef || hasClMasterChef, ApexErrors.ZERO_ADDRESS());

            // settle old weights before changing the shared allocation denominator
            if (hasClassicChef) classicChef.massUpdatePools();
            if (hasClMasterChef) clMasterChef.massUpdatePools();

            uint256 classicWeight;
            uint256 clWeight;
            uint256 totalWeight;
            address previousPool;

            // rewrite each active farm weight, sorted pool addresses makes duplicate array checks cheaper than quadratic
            for (uint256 i; i < _weights.length; ++i) {
                EmissionWeight calldata weight = _weights[i];
                require(i == 0 || weight.pool > previousPool, ApexErrors.INVALID_ASSORTMENT());
                require($.activeFarm[weight.pool], ApexErrors.FARM_INACTIVE(weight.pool));

                previousPool = weight.pool;
                totalWeight += weight.allocPoint;

                if (weight.kind == PoolKind.CLASSIC) {
                    require(hasClassicChef, ApexErrors.ZERO_ADDRESS());
                    classicWeight += weight.allocPoint;
                    classicChef.setPoolAllocPoint(weight.pool, weight.allocPoint);
                } else {
                    require(hasClMasterChef, ApexErrors.ZERO_ADDRESS());
                    clWeight += weight.allocPoint;
                    clMasterChef.setPoolAllocPoint(weight.pool, weight.allocPoint);
                }

                $.totalAllocPoint = $.totalAllocPoint - $.farmAllocPoint[weight.pool] + weight.allocPoint;
                $.farmAllocPoint[weight.pool] = weight.allocPoint;
            }

            // the input must cover every active alloc point across both chefs
            require(totalWeight != 0, ApexErrors.ZERO_AMOUNT());
            require(
                $.totalAllocPoint == totalWeight,
                ApexErrors.ALLOC_POINT_MISMATCH(address(this), totalWeight, $.totalAllocPoint)
            );
            if (hasClassicChef) {
                uint256 classicTotalAllocPoint = classicChef.totalAllocPoint();
                require(
                    classicTotalAllocPoint == classicWeight,
                    ApexErrors.ALLOC_POINT_MISMATCH(address(classicChef), classicWeight, classicTotalAllocPoint)
                );
            }
            if (hasClMasterChef) {
                uint256 clTotalAllocPoint = clMasterChef.totalAllocPoint();
                require(
                    clTotalAllocPoint == clWeight,
                    ApexErrors.ALLOC_POINT_MISMATCH(address(clMasterChef), clWeight, clTotalAllocPoint)
                );
            }
        }

        uint256 requiredBalance = $.rewardLiability + _amount;
        uint256 balance = $.rewardToken.balanceOf(address(this));
        if (balance < requiredBalance && $.emissionCenter != address(0)) {
            _releaseAndSplitEmissions($);
            balance = $.rewardToken.balanceOf(address(this));
        }
        require(
            balance >= requiredBalance, ApexErrors.INSUFFICIENT_REWARD_BALANCE(address(this), requiredBalance, balance)
        );

        // roll unspent emissions into the new stream
        uint256 remainingReward;
        if ($.latestPeriodEndTime > block.timestamp && $.latestPeriodRewardPerSecond != 0) {
            remainingReward =
                (($.latestPeriodEndTime - block.timestamp) * $.latestPeriodRewardPerSecond) / REWARD_PRECISION;
            if (remainingReward > $.rewardLiability) remainingReward = $.rewardLiability;
        }

        uint256 rewardAmount = _amount + remainingReward;
        uint256 rewardPerSecond;
        uint256 endTime = block.timestamp;
        if (rewardAmount != 0) {
            require(block.timestamp <= type(uint32).max, ApexErrors.INVALID_DURATION());
            require(_duration <= type(uint32).max - block.timestamp, ApexErrors.INVALID_DURATION());
            endTime = block.timestamp + _duration;
            rewardPerSecond = (rewardAmount * REWARD_PRECISION) / _duration;
            require(rewardPerSecond != 0, ApexErrors.ZERO_AMOUNT());
        }

        // publish the new emission window
        unchecked {
            $.latestPeriodNumber++;
            $.latestPeriodStartTime = block.timestamp;
        }
        $.latestPeriodEndTime = endTime;
        $.latestPeriodRewardPerSecond = rewardPerSecond;
        $.rewardLiability += _amount;

        emit RebalanceEmissions(_amount, _duration, rewardAmount, rewardPerSecond);
    }

    function releaseAndSplitEmissions() external onlyRole(EMISSION_OPERATOR) {
        _releaseAndSplitEmissions(ApexControllerStorage.layout());
    }

    function _releaseAndSplitEmissions(ApexControllerStorage.Layout storage $) internal {
        uint256 released = IEmissionCenter($.emissionCenter).releaseVested(address($.rewardToken));

        uint256 treasuryAmount = released / 20;
        $.rewardToken.safeTransfer($.treasury, treasuryAmount);
    }

    function payReward(address _pool, address _to, uint256 _amount) external returns (uint256 paid) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        require(_to != address(0), ApexErrors.ZERO_ADDRESS());
        require(
            (msg.sender == address($.classicChef) && $.classicFarms.contains(_pool))
                || (msg.sender == address($.clMasterChef) && $.clFarms.contains(_pool)),
            ApexErrors.NOT_AUTHORIZED(msg.sender)
        );

        paid = _amount;
        if (paid > $.rewardLiability) paid = $.rewardLiability;
        uint256 balance = $.rewardToken.balanceOf(address(this));
        if (paid > balance) paid = balance;

        unchecked {
            // paid is clamped to rewardLiability immediately above.
            $.rewardLiability -= paid;
        }
        if (paid != 0) $.rewardToken.safeTransfer(_to, paid);
        emit RewardPaid(_pool, _to, paid);
    }

    function forfeitReward(address _pool, uint256 _amount) external returns (uint256 forfeited) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        require(
            (msg.sender == address($.classicChef) && $.classicFarms.contains(_pool))
                || (msg.sender == address($.clMasterChef) && $.clFarms.contains(_pool)),
            ApexErrors.NOT_AUTHORIZED(msg.sender)
        );

        forfeited = _amount;
        if (forfeited > $.rewardLiability) forfeited = $.rewardLiability;
        unchecked {
            // forfeited is clamped to rewardLiability immediately above.
            $.rewardLiability -= forfeited;
        }
        emit RewardForfeited(_pool, forfeited);
    }

    function getLatestPeriodInfo(address _pool) external view returns (uint256 rewardPerSecond, uint256 endTime) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        if ($.totalAllocPoint != 0) {
            rewardPerSecond = ($.latestPeriodRewardPerSecond * $.farmAllocPoint[_pool]) / $.totalAllocPoint;
        }
        endTime = $.latestPeriodEndTime;
    }

    // apex vault
    function setVaultRewardToken(address _token, bool _status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerStorage.layout().apexVault.setRewardToken(_token, _status);
    }

    function setVaultConfig(uint256 _minRemainingLock, uint256 _rewardDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerStorage.layout().apexVault.setVaultConfig(_minRemainingLock, _rewardDuration);
    }

    function setVeArtProxy(address _artProxy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerStorage.layout().apexVault.veNFT().setArtProxy(_artProxy);
    }

    function notifyVaultReward(address _token, uint256 _amount) external onlyRole(VAULT_OPERATOR) {
        require(address(ApexControllerStorage.layout().apexVault) != address(0), ApexErrors.ZERO_ADDRESS());
        ApexControllerStorage.layout().apexVault.notifyRewardAmount(msg.sender, _token, _amount);
    }

    function notifyVaultRewardFrom(address _from, address _token, uint256 _amount) external onlyRole(VAULT_OPERATOR) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        require(address($.apexVault) != address(0), ApexErrors.ZERO_ADDRESS());
        require(_from != address(0), ApexErrors.ZERO_ADDRESS());
        if (msg.sender != address($.feeCenter)) {
            require(_from == msg.sender, ApexErrors.NOT_AUTHORIZED(_from));
        }
        $.apexVault.notifyRewardAmount(_from, _token, _amount);
    }

    function notifyVaultCompoundReward(uint256 _amount) external onlyRole(VAULT_OPERATOR) {
        require(address(ApexControllerStorage.layout().apexVault) != address(0), ApexErrors.ZERO_ADDRESS());
        ApexControllerStorage.layout().apexVault.notifyCompoundAmount(msg.sender, _amount);
    }

    function notifyVaultCompoundRewardFrom(address _from, uint256 _amount) external onlyRole(VAULT_OPERATOR) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        require(address($.apexVault) != address(0), ApexErrors.ZERO_ADDRESS());
        require(_from != address(0), ApexErrors.ZERO_ADDRESS());
        if (msg.sender != address($.feeCenter)) {
            require(_from == msg.sender, ApexErrors.NOT_AUTHORIZED(_from));
        }
        $.apexVault.notifyCompoundAmount(_from, _amount);
    }

    function compoundVault(uint256 _tokenId) external onlyRole(VAULT_OPERATOR) returns (uint256 amount) {
        return ApexControllerStorage.layout().apexVault.compound(_tokenId);
    }

    function compoundVaultMany(uint256[] calldata _tokenIds)
        external
        onlyRole(VAULT_OPERATOR)
        returns (uint256 amount)
    {
        return ApexControllerStorage.layout().apexVault.compoundMany(_tokenIds);
    }

    function sweepVaultUnallocated(address _token) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        return ApexControllerStorage.layout().apexVault.sweepUnallocated(_token);
    }

    // fee center
    function setFeeReceiverImplementation(address _implementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerStorage.layout().feeCenter.setReceiverImplementation(_implementation);
    }

    function addFeeReceiver(address _outputToken) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address receiver) {
        return ApexControllerStorage.layout().feeCenter.addReceiver(_outputToken);
    }

    function removeFeeReceiver(address _outputToken) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address receiver) {
        return ApexControllerStorage.layout().feeCenter.removeReceiver(_outputToken);
    }

    function setFeeSwapper(address _swapper, bool _status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerStorage.layout().feeCenter.setSwapper(_swapper, _status);
    }

    function pushAndSplitFees(address[] calldata _tokens) external onlyRole(FEE_OPERATOR) {
        ApexControllerStorage.layout().feeCenter.pushAndSplitFees(_tokens);
    }

    function executeFeeReceiverSwap(
        address _receiver,
        address _tokenIn,
        address _target,
        uint256 _amount,
        uint256 _minAmountOut,
        bytes calldata _data
    ) external onlyRole(FEE_OPERATOR) nonReentrant returns (uint256 spent, uint256 received) {
        return ApexControllerFeePolicy.executeFeeReceiverSwap(
                _receiver, _tokenIn, _target, _amount, _minAmountOut, _data
            );
    }

    function notifyFeeReceiverVault(address _receiver, uint256 _amount) external onlyRole(FEE_OPERATOR) {
        ApexControllerStorage.layout().feeCenter.notifyReceiverVault(_receiver, _amount);
    }

    function notifyFeeReceiverVaultBalance(address _receiver) external onlyRole(FEE_OPERATOR) returns (uint256 amount) {
        return ApexControllerStorage.layout().feeCenter.notifyReceiverVaultBalance(_receiver);
    }

    function notifyFeeReceiverVaultCompound(address _receiver, uint256 _amount) external onlyRole(FEE_OPERATOR) {
        ApexControllerStorage.layout().feeCenter.notifyReceiverVaultCompound(_receiver, _amount);
    }

    function notifyFeeReceiverVaultCompoundBalance(address _receiver)
        external
        onlyRole(FEE_OPERATOR)
        returns (uint256 amount)
    {
        return ApexControllerStorage.layout().feeCenter.notifyReceiverVaultCompoundBalance(_receiver);
    }

    function rescueFeeReceiverToken(address _receiver, address _token, address _to, uint256 _amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ApexControllerStorage.layout().feeCenter.rescueReceiverToken(_receiver, _token, _to, _amount);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ApexControllerFeePolicy.setTreasury(_treasury);
    }

    // addresses
    function classicFactory() external view returns (IClassicFactory) {
        return ApexControllerStorage.layout().classicFactory;
    }

    function rewardToken() external view returns (address) {
        return address(ApexControllerStorage.layout().rewardToken);
    }

    function clFactory() external view returns (ICLFactory) {
        return ApexControllerStorage.layout().clFactory;
    }

    function getClassicChef() external view returns (IClassicChef) {
        return ApexControllerStorage.layout().classicChef;
    }

    function getCLMasterChef() external view returns (ICLMasterChef) {
        return ApexControllerStorage.layout().clMasterChef;
    }

    function apexVault() external view returns (IApexVault) {
        return ApexControllerStorage.layout().apexVault;
    }

    function feeCenter() external view returns (address) {
        return address(ApexControllerStorage.layout().feeCenter);
    }

    function emissionCenter() external view returns (address) {
        return ApexControllerStorage.layout().emissionCenter;
    }

    function treasury() external view returns (address) {
        return ApexControllerStorage.layout().treasury;
    }

    function isFarmRegistered(address _pool) external view returns (bool) {
        return ApexControllerStorage.layout().registeredFarm[_pool];
    }

    function isFarmActive(address _pool) external view returns (bool) {
        return ApexControllerStorage.layout().activeFarm[_pool];
    }

    function registeredClassicFarmsLength() external view returns (uint256) {
        return ApexControllerStorage.layout().classicFarms.length();
    }

    function registeredCLFarmsLength() external view returns (uint256) {
        return ApexControllerStorage.layout().clFarms.length();
    }

    function registeredClassicFarmAt(uint256 _index) external view returns (address) {
        return ApexControllerStorage.layout().classicFarms.at(_index);
    }

    function registeredCLFarmAt(uint256 _index) external view returns (address) {
        return ApexControllerStorage.layout().clFarms.at(_index);
    }

    function latestPeriodNumber() external view returns (uint256) {
        return ApexControllerStorage.layout().latestPeriodNumber;
    }

    function latestPeriodStartTime() external view returns (uint256) {
        return ApexControllerStorage.layout().latestPeriodStartTime;
    }

    function latestPeriodEndTime() external view returns (uint256) {
        return ApexControllerStorage.layout().latestPeriodEndTime;
    }

    function latestPeriodRewardPerSecond() external view returns (uint256) {
        return ApexControllerStorage.layout().latestPeriodRewardPerSecond;
    }

    function rewardLiability() external view returns (uint256) {
        return ApexControllerStorage.layout().rewardLiability;
    }

    function totalAllocPoint() external view returns (uint256) {
        return ApexControllerStorage.layout().totalAllocPoint;
    }

    function farmAllocPoint(address _pool) external view returns (uint256) {
        return ApexControllerStorage.layout().farmAllocPoint[_pool];
    }

    function _canonicalCLFactory(address _pool) internal view returns (ICLFactory clFactory_) {
        ApexControllerStorage.Layout storage $ = ApexControllerStorage.layout();
        clFactory_ = $.clFactory;
        require(address(clFactory_) != address(0), ApexErrors.ZERO_ADDRESS());
        ICLPool pool = ICLPool(_pool);
        require(pool.factory() == address(clFactory_), ApexErrors.INVALID_POOL(_pool));
        require(clFactory_.getPool(pool.token0(), pool.token1(), pool.fee()) == _pool, ApexErrors.INVALID_POOL(_pool));
    }
}
