// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IClassicFactory} from "../interfaces/IClassicFactory.sol";
import {IClassicPool} from "../interfaces/IClassicPool.sol";
import {ICLFactory} from "../interfaces/ICLFactory.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";
import {IClassicChef} from "../interfaces/IClassicChef.sol";
import {ICLMasterChef} from "../interfaces/ICLMasterChef.sol";
import {IFeeCenter} from "../interfaces/IFeeCenter.sol";
import {IApexController} from "../interfaces/IApexController.sol";
import {ApexErrors} from "./common/ApexErrors.sol";
import {ApexControllerStorage} from "../storage/ApexControllerStorage.sol";

library ApexControllerFeePolicy {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint16 private constant BPS = 10_000;
    uint256 private constant CLASSIC_PROTOCOL_FEE_BPS_SCALE = 100;
    uint256 private constant CLASSIC_FARM_PROTOCOL_FEE = 1_000_000;
    uint32 private constant CL_FARM_PROTOCOL_FEE = 10_000;
    uint32 private constant DEFAULT_CL_PROTOCOL_FEE = 2_000;
    uint32 private constant CL_PROTOCOL_FEE_DENOMINATOR = 10_000;

    event CLGlobalProtocolFeeSet(uint32 protocolFee);
    event EmissionCenterSet(address indexed center);
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);
    event LauncherConfigured(
        address indexed launcher,
        address indexed recipient,
        uint16 creatorFeeBps,
        uint16 veGigaFeeBps,
        bool startGauged,
        IApexController.LauncherPermission permission,
        bool active
    );
    event LauncherPoolCreated(
        address indexed launcher,
        address indexed pool,
        IApexController.PoolKind indexed poolKind,
        address recipient,
        uint16 creatorFeeBps,
        uint16 veGigaFeeBps,
        bool gauged
    );
    event LauncherPoolFeeSplitSet(
        address indexed pool, address indexed recipient, uint16 creatorFeeBps, uint16 veGigaFeeBps
    );
    event ClassicFarmRegistered(address indexed pair);
    event ClassicFarmActivated(address indexed pair, uint256 allocPoint, address indexed feeReceiver);
    event ClassicFarmDeactivated(address indexed pair);
    event CLFarmRegistered(address indexed clFactory, address indexed pool);
    event CLFarmActivated(address indexed clFactory, address indexed pool, uint256 allocPoint);
    event CLFarmDeactivated(address indexed clFactory, address indexed pool);

    function configureLauncher(
        address launcher,
        address recipient,
        uint16 creatorFeeBps,
        uint16 veGigaFeeBps,
        bool startGauged,
        IApexController.LauncherPermission permission,
        bool active
    ) external {
        require(launcher != address(0), ApexErrors.ZERO_ADDRESS());
        _validateFeeSplit(recipient, creatorFeeBps, veGigaFeeBps);
        if (active) require(permission != IApexController.LauncherPermission.NONE, ApexErrors.INVALID_ASSORTMENT());
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        s.launchers.add(launcher);
        if (active) s.activeLaunchers.add(launcher);
        else s.activeLaunchers.remove(launcher);
        s.launcherConfigs[launcher] = ApexControllerStorage.LauncherConfig({
            recipient: recipient,
            creatorFeeBps: creatorFeeBps,
            veGigaFeeBps: veGigaFeeBps,
            permission: uint8(permission),
            startGauged: startGauged,
            active: active,
            exists: true
        });
        emit LauncherConfigured(launcher, recipient, creatorFeeBps, veGigaFeeBps, startGauged, permission, active);
    }

    function createLauncherClassicPool(address tokenA, address tokenB, bool stable) external returns (address pair) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ApexControllerStorage.LauncherConfig memory config =
            _launcherConfig(s, IApexController.LauncherPermission.CLASSIC);
        IClassicFactory factory = s.classicFactory;
        require(factory.getPair(tokenA, tokenB, stable) == address(0), ApexErrors.PAIR_EXISTS());
        pair = factory.createPair(tokenA, tokenB, stable);

        _registerLauncherPool(s, pair, IApexController.PoolKind.CLASSIC, config);
        if (config.startGauged) _activateClassicFarm(s, pair, 0);
        else _applyLauncherBaseFee(s, pair);
        emit LauncherPoolCreated(
            msg.sender,
            pair,
            IApexController.PoolKind.CLASSIC,
            config.recipient,
            config.creatorFeeBps,
            config.veGigaFeeBps,
            config.startGauged
        );
    }

    function createLauncherCLPool(address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ApexControllerStorage.LauncherConfig memory config = _launcherConfig(s, IApexController.LauncherPermission.CL);
        ICLFactory factory = s.clFactory;
        address existingPool = factory.getPool(tokenA, tokenB, fee);
        require(existingPool == address(0), ApexErrors.POOL_EXISTS(existingPool));
        pool = factory.createPool(tokenA, tokenB, fee);
        ICLPool(pool).initialize(sqrtPriceX96);

        _registerLauncherPool(s, pool, IApexController.PoolKind.CL, config);
        if (config.startGauged) _activateCLFarm(s, pool, 0);
        else _applyLauncherBaseFee(s, pool);
        emit LauncherPoolCreated(
            msg.sender,
            pool,
            IApexController.PoolKind.CL,
            config.recipient,
            config.creatorFeeBps,
            config.veGigaFeeBps,
            config.startGauged
        );
    }

    function setTreasury(address treasury) external {
        require(treasury != address(0), ApexErrors.ZERO_ADDRESS());
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        address previousTreasury = s.treasury;
        s.treasury = treasury;
        emit TreasurySet(previousTreasury, treasury);
    }

    function setCLGlobalProtocolFee(uint32 protocolFee) external {
        require(protocolFee <= CL_PROTOCOL_FEE_DENOMINATOR, ApexErrors.INVALID_PROTOCOL_FEE());
        ApexControllerStorage.layout().clGlobalProtocolFeePlusOne = protocolFee + 1;
        emit CLGlobalProtocolFeeSet(protocolFee);
    }

    function setClassicGlobalFee(uint256 fee) external {
        ApexControllerStorage.layout().classicFactory.setFee(fee);
    }

    function setClassicGlobalProtocolFee(uint256 protocolFee) external {
        ApexControllerStorage.layout().classicFactory.setProtocolFee(protocolFee);
    }

    function setClassicGlobalFeeReceiver(address feeReceiver) external {
        ApexControllerStorage.layout().classicFactory.setFeeReceiver(feeReceiver);
    }

    function clGlobalProtocolFee() external view returns (uint32) {
        uint32 stored = ApexControllerStorage.layout().clGlobalProtocolFeePlusOne;
        return stored == 0 ? DEFAULT_CL_PROTOCOL_FEE : stored - 1;
    }

    function overrideClassicFeeReceiver(address pair, address feeReceiver) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        IClassicFactory factory = s.classicFactory;
        require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        if (s.launcherPoolConfigs[pair].exists) {
            require(feeReceiver == address(s.feeCenter), ApexErrors.INVALID_TARGET(feeReceiver));
        }
        factory.setPairFeeReceiver(pair, feeReceiver);
    }

    function overrideClassicFee(address pair, uint256 fee) external {
        IClassicFactory factory = ApexControllerStorage.layout().classicFactory;
        require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        factory.setPairFee(pair, fee);
    }

    function overrideClassicProtocolFee(address pair, uint256 protocolFee) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        IClassicFactory factory = s.classicFactory;
        require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pair);
        ApexControllerStorage.LauncherPoolConfig storage poolConfig = s.launcherPoolConfigs[pair];
        if (poolConfig.exists) {
            _collectClassicProtocolFees(s, pair);
            require(protocolFee % CLASSIC_PROTOCOL_FEE_BPS_SCALE == 0, ApexErrors.INVALID_PROTOCOL_FEE());
            uint256 protocolFeeBps = protocolFee / CLASSIC_PROTOCOL_FEE_BPS_SCALE;
            require(protocolFeeBps >= config.feeBps && protocolFeeBps <= BPS, ApexErrors.INVALID_PROTOCOL_FEE());
            if (s.activeFarm[pair]) {
                require(protocolFeeBps == BPS, ApexErrors.INVALID_PROTOCOL_FEE());
            } else {
                poolConfig.veGigaFeeBps = uint16(protocolFeeBps - config.feeBps);
                emit LauncherPoolFeeSplitSet(pair, config.recipient, config.feeBps, poolConfig.veGigaFeeBps);
            }
        }
        factory.setPairProtocolFee(pair, protocolFee);
    }

    function overrideCLProtocolFee(address pool, uint32 feeProtocol0, uint32 feeProtocol1) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ICLFactory factory = _canonicalCLFactory(s, pool);
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pool);
        ApexControllerStorage.LauncherPoolConfig storage poolConfig = s.launcherPoolConfigs[pool];
        if (poolConfig.exists) {
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
            require(
                feeProtocol0 == feeProtocol1 && feeProtocol0 >= config.feeBps && feeProtocol0 <= BPS,
                ApexErrors.INVALID_PROTOCOL_FEE()
            );
            if (s.activeFarm[pool]) {
                require(feeProtocol0 == BPS, ApexErrors.INVALID_PROTOCOL_FEE());
            } else {
                poolConfig.veGigaFeeBps = uint16(feeProtocol0 - config.feeBps);
                emit LauncherPoolFeeSplitSet(pool, config.recipient, config.feeBps, poolConfig.veGigaFeeBps);
            }
        }
        factory.setFeeProtocol(pool, feeProtocol0, feeProtocol1);
    }

    function collectCLProtocolFees(address pool, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        return _collectCLProtocolFees(s, _canonicalCLFactory(s, pool), pool, amount0Requested, amount1Requested);
    }

    function collectClassicProtocolFees(address pair) external returns (uint256 amount0, uint256 amount1) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.classicFactory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        return _collectClassicProtocolFees(s, pair);
    }

    function collectLauncherCLProtocolFees(address pool) external returns (uint128 amount0, uint128 amount1) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.launcherPoolConfigs[pool].exists, ApexErrors.INVALID_POOL(pool));
        return _collectCLProtocolFees(s, _canonicalCLFactory(s, pool), pool, type(uint128).max, type(uint128).max);
    }

    function collectLauncherClassicProtocolFees(address pair) external returns (uint256 amount0, uint256 amount1) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.classicFactory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        require(s.launcherPoolConfigs[pair].exists, ApexErrors.INVALID_POOL(pair));
        return _collectClassicProtocolFees(s, pair);
    }

    function updateLauncherPoolFeeSplit(address pool, address recipient, uint16 creatorFeeBps, uint16 veGigaFeeBps)
        external
    {
        _validateFeeSplit(recipient, creatorFeeBps, veGigaFeeBps);
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ApexControllerStorage.LauncherPoolConfig storage poolConfig = s.launcherPoolConfigs[pool];
        require(poolConfig.exists, ApexErrors.INVALID_POOL(pool));

        if (poolConfig.poolKind == uint8(IApexController.PoolKind.CLASSIC)) {
            require(s.classicFactory.isPair(pool), ApexErrors.NOT_PAIR(pool));
            _collectClassicProtocolFees(s, pool);
        } else {
            ICLFactory factory = _canonicalCLFactory(s, pool);
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
        }
        poolConfig.veGigaFeeBps = veGigaFeeBps;
        s.feeCenter.setCreatorFeeConfig(pool, recipient, creatorFeeBps, poolConfig.poolKind);
        if (!s.activeFarm[pool]) _applyLauncherBaseFee(s, pool);
        emit LauncherPoolFeeSplitSet(pool, recipient, creatorFeeBps, veGigaFeeBps);
    }

    function registerClassicFarm(address pair) external {
        _registerClassicFarm(ApexControllerStorage.layout(), pair);
    }

    function activateClassicFarm(address pair, uint256 allocPoint) external {
        _activateClassicFarm(ApexControllerStorage.layout(), pair, allocPoint);
    }

    function deactivateClassicFarm(address pair) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.registeredFarm[pair], ApexErrors.INVALID_POOL(pair));

        IClassicFactory factory = s.classicFactory;
        IClassicChef classicChef = s.classicChef;
        require(
            s.farmAllocPoint[pair] != s.totalAllocPoint || s.latestPeriodEndTime <= block.timestamp
                || s.latestPeriodRewardPerSecond == 0,
            ApexErrors.ZERO_AMOUNT()
        );
        classicChef.massUpdatePools();
        s.clMasterChef.massUpdatePools();
        classicChef.setPoolAllocPoint(pair, 0);
        s.totalAllocPoint -= s.farmAllocPoint[pair];
        s.farmAllocPoint[pair] = 0;

        ApexControllerStorage.LauncherPoolConfig storage poolConfig = s.launcherPoolConfigs[pair];
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pair);
        if (poolConfig.exists) {
            _collectClassicProtocolFees(s, pair);
            _applyLauncherBaseFee(s, pair);
            s.activeLauncherPools.remove(pair);
        } else {
            if (config.recipient != address(0)) _collectClassicProtocolFees(s, pair);
            uint256 protocolFee = factory.protocolFee();
            uint256 minimumProtocolFee = uint256(config.feeBps) * CLASSIC_PROTOCOL_FEE_BPS_SCALE;
            if (protocolFee < minimumProtocolFee) protocolFee = minimumProtocolFee;
            factory.setPairProtocolFee(pair, protocolFee);
            factory.setPairFeeReceiver(
                pair, config.recipient == address(0) ? factory.feeReceiver() : address(s.feeCenter)
            );
        }
        s.activeFarm[pair] = false;
        emit ClassicFarmDeactivated(pair);
    }

    function registerCLFarm(address pool) external {
        _registerCLFarm(ApexControllerStorage.layout(), pool);
    }

    function activateCLFarm(address pool, uint256 allocPoint) external {
        _activateCLFarm(ApexControllerStorage.layout(), pool, allocPoint);
    }

    function deactivateCLFarm(address pool) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.registeredFarm[pool], ApexErrors.INVALID_POOL(pool));
        ICLFactory factory = _canonicalCLFactory(s, pool);
        ICLMasterChef clMasterChef = s.clMasterChef;
        require(
            s.farmAllocPoint[pool] != s.totalAllocPoint || s.latestPeriodEndTime <= block.timestamp
                || s.latestPeriodRewardPerSecond == 0,
            ApexErrors.ZERO_AMOUNT()
        );
        s.classicChef.massUpdatePools();
        clMasterChef.massUpdatePools();
        clMasterChef.setPoolAllocPoint(pool, 0);
        s.totalAllocPoint -= s.farmAllocPoint[pool];
        s.farmAllocPoint[pool] = 0;

        ApexControllerStorage.LauncherPoolConfig storage poolConfig = s.launcherPoolConfigs[pool];
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pool);
        if (poolConfig.exists) {
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
            _applyLauncherBaseFee(s, pool);
            s.activeLauncherPools.remove(pool);
        } else {
            if (config.recipient != address(0)) {
                _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
            }
            uint32 protocolFee = _clGlobalProtocolFee(s);
            if (protocolFee < config.feeBps) protocolFee = config.feeBps;
            factory.setFeeProtocol(pool, protocolFee, protocolFee);
        }
        s.activeFarm[pool] = false;
        emit CLFarmDeactivated(address(factory), pool);
    }

    function executeFeeReceiverSwap(
        address receiver,
        address tokenIn,
        address target,
        uint256 amount,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 spent, uint256 received) {
        return ApexControllerStorage.layout().feeCenter
            .executeReceiverSwap(receiver, tokenIn, target, amount, minAmountOut, data);
    }

    function setLmPoolDeployer(address lmPoolDeployer) external {
        ApexControllerStorage.layout().clMasterChef.setLMPoolDeployer(lmPoolDeployer);
    }

    function setCLMasterChefEmergency(bool emergency) external {
        ApexControllerStorage.layout().clMasterChef.setEmergency(emergency);
    }

    function setCLMevResistanceWindow(uint32 window) external {
        ApexControllerStorage.layout().clMasterChef.setMevResistanceWindow(window);
    }

    function setEmissionCenter(address center) external {
        if (center != address(0)) require(center.code.length != 0, ApexErrors.ZERO_ADDRESS());
        ApexControllerStorage.layout().emissionCenter = center;
        emit EmissionCenterSet(center);
    }

    function launcherConfig(address launcher)
        external
        view
        returns (
            address recipient,
            uint16 creatorFeeBps,
            uint16 veGigaFeeBps,
            bool startGauged,
            IApexController.LauncherPermission permission,
            bool active,
            bool configured
        )
    {
        ApexControllerStorage.LauncherConfig memory config = ApexControllerStorage.layout().launcherConfigs[launcher];
        return (
            config.recipient,
            config.creatorFeeBps,
            config.veGigaFeeBps,
            config.startGauged,
            IApexController.LauncherPermission(config.permission),
            config.active,
            config.exists
        );
    }

    function launcherPoolConfig(address pool)
        external
        view
        returns (
            address launcher,
            address recipient,
            uint16 creatorFeeBps,
            uint16 veGigaFeeBps,
            IApexController.PoolKind poolKind,
            bool gauged
        )
    {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ApexControllerStorage.LauncherPoolConfig memory poolConfig = s.launcherPoolConfigs[pool];
        require(poolConfig.exists, ApexErrors.INVALID_POOL(pool));
        IFeeCenter.CreatorFeeConfig memory creatorConfig = s.feeCenter.creatorFeeConfig(pool);
        launcher = poolConfig.launcher;
        recipient = creatorConfig.recipient;
        creatorFeeBps = creatorConfig.feeBps;
        veGigaFeeBps = poolConfig.veGigaFeeBps;
        poolKind = IApexController.PoolKind(poolConfig.poolKind);
        gauged = s.activeFarm[pool];
    }

    function launchers(bool activeOnly) external view returns (address[] memory) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        return activeOnly ? s.activeLaunchers.values() : s.launchers.values();
    }

    function launcherPools() external view returns (address[] memory) {
        return ApexControllerStorage.layout().launcherPools.values();
    }

    function activeLauncherPools() external view returns (address[] memory) {
        return ApexControllerStorage.layout().activeLauncherPools.values();
    }

    function launcherPoolsByLauncher(address launcher) external view returns (address[] memory) {
        return ApexControllerStorage.layout().launcherPoolsByLauncher[launcher].values();
    }

    function _clGlobalProtocolFee(ApexControllerStorage.Layout storage s) private view returns (uint32) {
        uint32 stored = s.clGlobalProtocolFeePlusOne;
        return stored == 0 ? DEFAULT_CL_PROTOCOL_FEE : stored - 1;
    }

    function _collectClassicProtocolFees(ApexControllerStorage.Layout storage s, address pair)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        IClassicPool(pair).mintFee();
        return s.feeCenter.realizeClassicFees(pair);
    }

    function _collectCLProtocolFees(
        ApexControllerStorage.Layout storage s,
        ICLFactory factory,
        address pool,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) private returns (uint128 amount0, uint128 amount1) {
        address recipient = address(s.feeCenter);
        require(recipient != address(0), ApexErrors.ZERO_ADDRESS());
        (,,,,, uint32 feeProtocol,) = ICLPool(pool).slot0();
        uint32 feeProtocol0 = feeProtocol % 65_536;
        uint32 feeProtocol1 = feeProtocol >> 16;
        (amount0, amount1) = factory.collectProtocol(pool, recipient, amount0Requested, amount1Requested);
        s.feeCenter.distributeCLCreatorFees(pool, amount0, amount1, feeProtocol0, feeProtocol1);
    }

    function _launcherConfig(
        ApexControllerStorage.Layout storage s,
        IApexController.LauncherPermission requiredPermission
    ) private view returns (ApexControllerStorage.LauncherConfig memory config) {
        config = s.launcherConfigs[msg.sender];
        IApexController.LauncherPermission permission = IApexController.LauncherPermission(config.permission);
        require(
            config.active
                && (permission == requiredPermission || permission == IApexController.LauncherPermission.BOTH),
            ApexErrors.NOT_AUTHORIZED(msg.sender)
        );
    }

    function _registerLauncherPool(
        ApexControllerStorage.Layout storage s,
        address pool,
        IApexController.PoolKind poolKind,
        ApexControllerStorage.LauncherConfig memory config
    ) private {
        require(!s.launcherPoolConfigs[pool].exists, ApexErrors.POOL_EXISTS(pool));
        s.launcherPoolConfigs[pool] = ApexControllerStorage.LauncherPoolConfig({
            launcher: msg.sender, veGigaFeeBps: config.veGigaFeeBps, poolKind: uint8(poolKind), exists: true
        });
        s.launcherPools.add(pool);
        s.launcherPoolsByLauncher[msg.sender].add(pool);
        s.feeCenter.setCreatorFeeConfig(pool, config.recipient, config.creatorFeeBps, uint8(poolKind));
    }

    function _applyLauncherBaseFee(ApexControllerStorage.Layout storage s, address pool) private {
        ApexControllerStorage.LauncherPoolConfig storage poolConfig = s.launcherPoolConfigs[pool];
        require(poolConfig.exists, ApexErrors.INVALID_POOL(pool));
        uint16 creatorFeeBps = s.feeCenter.creatorFeeConfig(pool).feeBps;
        uint256 totalProtocolFeeBps = uint256(creatorFeeBps) + poolConfig.veGigaFeeBps;
        require(totalProtocolFeeBps <= BPS, ApexErrors.FEE_TOO_HIGH());

        if (poolConfig.poolKind == uint8(IApexController.PoolKind.CLASSIC)) {
            s.classicFactory.setPairProtocolFee(pool, totalProtocolFeeBps * CLASSIC_PROTOCOL_FEE_BPS_SCALE);
            s.classicFactory.setPairFeeReceiver(pool, address(s.feeCenter));
        } else {
            _canonicalCLFactory(s, pool).setFeeProtocol(pool, uint32(totalProtocolFeeBps), uint32(totalProtocolFeeBps));
        }
    }

    function _activateClassicFarm(ApexControllerStorage.Layout storage s, address pair, uint256 allocPoint) private {
        IClassicChef classicChef = s.classicChef;
        IClassicFactory factory = s.classicFactory;
        address feeReceiver = address(s.feeCenter);
        require(address(classicChef) != address(0) && feeReceiver != address(0), ApexErrors.ZERO_ADDRESS());

        if (!s.registeredFarm[pair]) _registerClassicFarm(s, pair);
        require(allocPoint != 0 || !s.activeFarm[pair], ApexErrors.ZERO_AMOUNT());
        classicChef.massUpdatePools();
        s.clMasterChef.massUpdatePools();
        classicChef.setPoolAllocPoint(pair, allocPoint);
        s.totalAllocPoint = s.totalAllocPoint - s.farmAllocPoint[pair] + allocPoint;
        s.farmAllocPoint[pair] = allocPoint;

        if (s.launcherPoolConfigs[pair].exists) _collectClassicProtocolFees(s, pair);
        factory.setPairProtocolFee(pair, CLASSIC_FARM_PROTOCOL_FEE);
        factory.setPairFeeReceiver(pair, feeReceiver);
        s.activeFarm[pair] = true;
        if (s.launcherPoolConfigs[pair].exists) s.activeLauncherPools.add(pair);
        emit ClassicFarmActivated(pair, allocPoint, feeReceiver);
    }

    function _registerClassicFarm(ApexControllerStorage.Layout storage s, address pair) private {
        require(address(s.classicChef) != address(0), ApexErrors.ZERO_ADDRESS());
        require(s.classicFactory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        require(!s.registeredFarm[pair], ApexErrors.POOL_EXISTS(pair));

        s.classicChef.addPool(pair, 0);
        s.registeredFarm[pair] = true;
        s.classicFarms.add(pair);
        emit ClassicFarmRegistered(pair);
    }

    function _activateCLFarm(ApexControllerStorage.Layout storage s, address pool, uint256 allocPoint) private {
        require(pool != address(0), ApexErrors.ZERO_ADDRESS());
        ICLMasterChef clMasterChef = s.clMasterChef;
        require(address(clMasterChef) != address(0), ApexErrors.ZERO_ADDRESS());
        ICLFactory factory = _canonicalCLFactory(s, pool);
        if (!s.registeredFarm[pool]) _registerCLFarm(s, pool);
        require(allocPoint != 0 || !s.activeFarm[pool], ApexErrors.ZERO_AMOUNT());
        s.classicChef.massUpdatePools();
        clMasterChef.massUpdatePools();
        clMasterChef.setPoolAllocPoint(pool, allocPoint);
        s.totalAllocPoint = s.totalAllocPoint - s.farmAllocPoint[pool] + allocPoint;
        s.farmAllocPoint[pool] = allocPoint;

        if (s.launcherPoolConfigs[pool].exists) {
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
        }
        factory.setFeeProtocol(pool, CL_FARM_PROTOCOL_FEE, CL_FARM_PROTOCOL_FEE);
        s.activeFarm[pool] = true;
        if (s.launcherPoolConfigs[pool].exists) s.activeLauncherPools.add(pool);
        emit CLFarmActivated(address(factory), pool, allocPoint);
    }

    function _registerCLFarm(ApexControllerStorage.Layout storage s, address pool) private {
        require(pool != address(0), ApexErrors.ZERO_ADDRESS());
        ICLMasterChef clMasterChef = s.clMasterChef;
        require(address(clMasterChef) != address(0), ApexErrors.ZERO_ADDRESS());
        require(!s.registeredFarm[pool], ApexErrors.POOL_EXISTS(pool));

        ICLFactory factory = _canonicalCLFactory(s, pool);
        address lmPoolDeployer = clMasterChef.lmPoolDeployer();
        require(lmPoolDeployer != address(0), ApexErrors.ZERO_ADDRESS());
        factory.setLmPoolDeployer(lmPoolDeployer);
        clMasterChef.addPool(pool, 0);
        s.registeredFarm[pool] = true;
        s.clFarms.add(pool);
        emit CLFarmRegistered(address(factory), pool);
    }

    function _validateFeeSplit(address recipient, uint16 creatorFeeBps, uint16 veGigaFeeBps) private pure {
        if (creatorFeeBps == 0) require(recipient == address(0), ApexErrors.INVALID_ASSORTMENT());
        else require(recipient != address(0), ApexErrors.ZERO_ADDRESS());
        require(uint256(creatorFeeBps) + veGigaFeeBps <= BPS, ApexErrors.FEE_TOO_HIGH());
    }

    function _canonicalCLFactory(ApexControllerStorage.Layout storage s, address poolAddress)
        private
        view
        returns (ICLFactory clFactory)
    {
        clFactory = s.clFactory;
        require(address(clFactory) != address(0), ApexErrors.ZERO_ADDRESS());
        ICLPool pool = ICLPool(poolAddress);
        require(pool.factory() == address(clFactory), ApexErrors.INVALID_POOL(poolAddress));
        require(
            clFactory.getPool(pool.token0(), pool.token1(), pool.fee()) == poolAddress,
            ApexErrors.INVALID_POOL(poolAddress)
        );
    }
}
