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
import {ApexErrors} from "./common/ApexErrors.sol";
import {ApexControllerStorage} from "../storage/ApexControllerStorage.sol";

library ApexControllerFeePolicy {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint8 internal constant LAUNCHER_PERMISSION_CLASSIC = 1;
    uint8 internal constant LAUNCHER_PERMISSION_CL = 2;
    uint8 private constant POOL_KIND_CLASSIC = 0;
    uint8 private constant POOL_KIND_CL = 1;
    uint16 private constant BPS = 10_000;
    uint256 private constant CLASSIC_PROTOCOL_FEE_BPS_SCALE = 100;
    uint256 private constant CLASSIC_FARM_PROTOCOL_FEE = 1_000_000;
    uint32 private constant CL_FARM_PROTOCOL_FEE = 10_000;
    uint32 private constant DEFAULT_CL_PROTOCOL_FEE = 2_000;
    uint32 private constant CL_PROTOCOL_FEE_DENOMINATOR = 10_000;

    event CLGlobalProtocolFeeSet(uint32 protocolFee);
    event EmissionCenterSet(address indexed center);
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);
    event LauncherAgreementSet(
        bytes32 indexed agreementId, address indexed recipient, uint16 creatorFeeBps, bool active
    );
    event LauncherCallerSet(address indexed caller, bytes32 indexed agreementId, uint8 permissions);
    event LauncherPoolCreated(
        bytes32 indexed agreementId,
        address indexed launcher,
        address indexed pool,
        uint8 poolKind,
        address recipient,
        uint16 creatorFeeBps
    );
    event ClassicFarmRegistered(address indexed pair);
    event ClassicFarmActivated(address indexed pair, uint256 allocPoint, address indexed feeReceiver);
    event ClassicFarmDeactivated(address indexed pair);
    event CLFarmRegistered(address indexed clFactory, address indexed pool);
    event CLFarmActivated(address indexed clFactory, address indexed pool, uint256 allocPoint);
    event CLFarmDeactivated(address indexed clFactory, address indexed pool);

    function setLauncherAgreement(bytes32 agreementId, address recipient, uint16 creatorFeeBps, bool active) external {
        require(agreementId != bytes32(0), ApexErrors.INVALID_ASSORTMENT());
        require(recipient != address(0), ApexErrors.ZERO_ADDRESS());
        require(creatorFeeBps != 0, ApexErrors.ZERO_FEE());
        require(creatorFeeBps <= BPS, ApexErrors.FEE_TOO_HIGH());
        ApexControllerStorage.layout().launcherAgreements[agreementId] = ApexControllerStorage.LauncherAgreement({
            recipient: recipient, creatorFeeBps: creatorFeeBps, active: active
        });
        emit LauncherAgreementSet(agreementId, recipient, creatorFeeBps, active);
    }

    function setLauncherCaller(address caller, bytes32 agreementId, uint8 permissions) external {
        require(caller != address(0), ApexErrors.ZERO_ADDRESS());
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        if (permissions == 0) {
            delete s.launcherAuthorizations[caller];
            emit LauncherCallerSet(caller, bytes32(0), 0);
            return;
        }
        require(
            permissions & ~(LAUNCHER_PERMISSION_CLASSIC | LAUNCHER_PERMISSION_CL) == 0, ApexErrors.INVALID_ASSORTMENT()
        );
        require(s.launcherAgreements[agreementId].recipient != address(0), ApexErrors.INVALID_ASSORTMENT());
        s.launcherAuthorizations[caller] =
            ApexControllerStorage.LauncherAuthorization({agreementId: agreementId, permissions: permissions});
        emit LauncherCallerSet(caller, agreementId, permissions);
    }

    function createLauncherClassicPool(address tokenA, address tokenB, bool stable) external returns (address pair) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        (bytes32 agreementId, ApexControllerStorage.LauncherAgreement memory agreement) =
            _launcherAgreement(s, LAUNCHER_PERMISSION_CLASSIC);
        IClassicFactory factory = s.classicFactory;
        require(factory.getPair(tokenA, tokenB, stable) == address(0), ApexErrors.PAIR_EXISTS());
        pair = factory.createPair(tokenA, tokenB, stable);

        uint256 minimumProtocolFee = uint256(agreement.creatorFeeBps) * CLASSIC_PROTOCOL_FEE_BPS_SCALE;
        if (IClassicPool(pair).protocolFee() < minimumProtocolFee) {
            factory.setPairProtocolFee(pair, minimumProtocolFee);
        }
        factory.setPairFeeReceiver(pair, address(s.feeCenter));
        s.feeCenter.setCreatorFeeConfig(pair, agreement.recipient, agreement.creatorFeeBps, POOL_KIND_CLASSIC);
        emit LauncherPoolCreated(
            agreementId, msg.sender, pair, POOL_KIND_CLASSIC, agreement.recipient, agreement.creatorFeeBps
        );
    }

    function createLauncherCLPool(address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        (bytes32 agreementId, ApexControllerStorage.LauncherAgreement memory agreement) =
            _launcherAgreement(s, LAUNCHER_PERMISSION_CL);
        ICLFactory factory = s.clFactory;
        address existingPool = factory.getPool(tokenA, tokenB, fee);
        require(existingPool == address(0), ApexErrors.POOL_EXISTS(existingPool));
        pool = factory.createPool(tokenA, tokenB, fee);
        ICLPool(pool).initialize(sqrtPriceX96);

        uint32 protocolFee = _clGlobalProtocolFee(s);
        if (protocolFee < agreement.creatorFeeBps) protocolFee = agreement.creatorFeeBps;
        factory.setFeeProtocol(pool, protocolFee, protocolFee);
        s.feeCenter.setCreatorFeeConfig(pool, agreement.recipient, agreement.creatorFeeBps, POOL_KIND_CL);
        emit LauncherPoolCreated(
            agreementId, msg.sender, pool, POOL_KIND_CL, agreement.recipient, agreement.creatorFeeBps
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
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pair);
        if (config.recipient != address(0)) {
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
        if (config.recipient != address(0)) {
            _collectClassicProtocolFees(s, pair);
            require(
                protocolFee >= uint256(config.feeBps) * CLASSIC_PROTOCOL_FEE_BPS_SCALE,
                ApexErrors.INVALID_PROTOCOL_FEE()
            );
        }
        factory.setPairProtocolFee(pair, protocolFee);
    }

    function overrideCLProtocolFee(address pool, uint32 feeProtocol0, uint32 feeProtocol1) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ICLFactory factory = _canonicalCLFactory(s, pool);
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pool);
        if (config.recipient != address(0)) {
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
            require(feeProtocol0 >= config.feeBps && feeProtocol1 >= config.feeBps, ApexErrors.INVALID_PROTOCOL_FEE());
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
        require(s.feeCenter.creatorFeeConfig(pool).recipient != address(0), ApexErrors.INVALID_POOL(pool));
        return _collectCLProtocolFees(s, _canonicalCLFactory(s, pool), pool, type(uint128).max, type(uint128).max);
    }

    function collectLauncherClassicProtocolFees(address pair) external returns (uint256 amount0, uint256 amount1) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.classicFactory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        require(s.feeCenter.creatorFeeConfig(pair).recipient != address(0), ApexErrors.INVALID_POOL(pair));
        return _collectClassicProtocolFees(s, pair);
    }

    function updateLauncherPoolCreatorFee(address pool, address recipient, uint16 creatorFeeBps) external {
        require(recipient != address(0), ApexErrors.ZERO_ADDRESS());
        require(creatorFeeBps != 0, ApexErrors.ZERO_FEE());
        require(creatorFeeBps <= BPS, ApexErrors.FEE_TOO_HIGH());
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pool);
        require(config.recipient != address(0), ApexErrors.INVALID_POOL(pool));

        if (config.poolKind == POOL_KIND_CLASSIC) {
            require(s.classicFactory.isPair(pool), ApexErrors.NOT_PAIR(pool));
            _collectClassicProtocolFees(s, pool);
            require(
                IClassicPool(pool).protocolFee() >= uint256(creatorFeeBps) * CLASSIC_PROTOCOL_FEE_BPS_SCALE,
                ApexErrors.INVALID_PROTOCOL_FEE()
            );
        } else {
            ICLFactory factory = _canonicalCLFactory(s, pool);
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
            (,,,,, uint32 feeProtocol,) = ICLPool(pool).slot0();
            require(
                feeProtocol % 65_536 >= creatorFeeBps && feeProtocol >> 16 >= creatorFeeBps,
                ApexErrors.INVALID_PROTOCOL_FEE()
            );
        }
        s.feeCenter.setCreatorFeeConfig(pool, recipient, creatorFeeBps, config.poolKind);
    }

    function activateClassicFarm(address pair, uint256 allocPoint) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        IClassicChef classicChef = s.classicChef;
        IClassicFactory factory = s.classicFactory;
        address feeReceiver = address(s.feeCenter);
        require(address(classicChef) != address(0) && feeReceiver != address(0), ApexErrors.ZERO_ADDRESS());

        if (!s.registeredFarm[pair]) {
            require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
            classicChef.addPool(pair, 0);
            s.registeredFarm[pair] = true;
            s.classicFarms.add(pair);
            emit ClassicFarmRegistered(pair);
        }
        require(allocPoint != 0 || !s.activeFarm[pair], ApexErrors.ZERO_AMOUNT());
        classicChef.massUpdatePools();
        s.clMasterChef.massUpdatePools();
        classicChef.setPoolAllocPoint(pair, allocPoint);
        s.totalAllocPoint = s.totalAllocPoint - s.farmAllocPoint[pair] + allocPoint;
        s.farmAllocPoint[pair] = allocPoint;

        if (s.feeCenter.creatorFeeConfig(pair).recipient != address(0)) {
            _collectClassicProtocolFees(s, pair);
        }
        factory.setPairProtocolFee(pair, CLASSIC_FARM_PROTOCOL_FEE);
        factory.setPairFeeReceiver(pair, feeReceiver);
        s.activeFarm[pair] = true;
        emit ClassicFarmActivated(pair, allocPoint, feeReceiver);
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

        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pair);
        if (config.recipient != address(0)) _collectClassicProtocolFees(s, pair);
        uint256 protocolFee = factory.protocolFee();
        uint256 minimumProtocolFee = uint256(config.feeBps) * CLASSIC_PROTOCOL_FEE_BPS_SCALE;
        if (protocolFee < minimumProtocolFee) protocolFee = minimumProtocolFee;
        factory.setPairProtocolFee(pair, protocolFee);
        factory.setPairFeeReceiver(pair, config.recipient == address(0) ? factory.feeReceiver() : address(s.feeCenter));
        s.activeFarm[pair] = false;
        emit ClassicFarmDeactivated(pair);
    }

    function activateCLFarm(address pool, uint256 allocPoint) external {
        require(pool != address(0), ApexErrors.ZERO_ADDRESS());
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        ICLMasterChef clMasterChef = s.clMasterChef;
        require(address(clMasterChef) != address(0), ApexErrors.ZERO_ADDRESS());
        ICLFactory factory = _canonicalCLFactory(s, pool);
        if (!s.registeredFarm[pool]) {
            address lmPoolDeployer = clMasterChef.lmPoolDeployer();
            require(lmPoolDeployer != address(0), ApexErrors.ZERO_ADDRESS());
            factory.setLmPoolDeployer(lmPoolDeployer);
            clMasterChef.addPool(pool, 0);
            s.registeredFarm[pool] = true;
            s.clFarms.add(pool);
            emit CLFarmRegistered(address(factory), pool);
        }
        require(allocPoint != 0 || !s.activeFarm[pool], ApexErrors.ZERO_AMOUNT());
        s.classicChef.massUpdatePools();
        clMasterChef.massUpdatePools();
        clMasterChef.setPoolAllocPoint(pool, allocPoint);
        s.totalAllocPoint = s.totalAllocPoint - s.farmAllocPoint[pool] + allocPoint;
        s.farmAllocPoint[pool] = allocPoint;

        if (s.feeCenter.creatorFeeConfig(pool).recipient != address(0)) {
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
        }
        factory.setFeeProtocol(pool, CL_FARM_PROTOCOL_FEE, CL_FARM_PROTOCOL_FEE);
        s.activeFarm[pool] = true;
        emit CLFarmActivated(address(factory), pool, allocPoint);
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

        IFeeCenter.CreatorFeeConfig memory config = s.feeCenter.creatorFeeConfig(pool);
        if (config.recipient != address(0)) {
            _collectCLProtocolFees(s, factory, pool, type(uint128).max, type(uint128).max);
        }
        uint32 protocolFee = _clGlobalProtocolFee(s);
        if (protocolFee < config.feeBps) protocolFee = config.feeBps;
        factory.setFeeProtocol(pool, protocolFee, protocolFee);
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

    function launcherAgreement(bytes32 agreementId)
        external
        view
        returns (address recipient, uint16 creatorFeeBps, bool active)
    {
        ApexControllerStorage.LauncherAgreement memory agreement =
            ApexControllerStorage.layout().launcherAgreements[agreementId];
        return (agreement.recipient, agreement.creatorFeeBps, agreement.active);
    }

    function launcherAuthorization(address caller) external view returns (bytes32 agreementId, uint8 permissions) {
        ApexControllerStorage.LauncherAuthorization memory authorization =
            ApexControllerStorage.layout().launcherAuthorizations[caller];
        return (authorization.agreementId, authorization.permissions);
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

    function _launcherAgreement(ApexControllerStorage.Layout storage s, uint8 permission)
        private
        view
        returns (bytes32 agreementId, ApexControllerStorage.LauncherAgreement memory agreement)
    {
        ApexControllerStorage.LauncherAuthorization memory authorization = s.launcherAuthorizations[msg.sender];
        require(authorization.permissions & permission != 0, ApexErrors.NOT_AUTHORIZED(msg.sender));
        agreementId = authorization.agreementId;
        agreement = s.launcherAgreements[agreementId];
        require(agreement.active, ApexErrors.NOT_AUTHORIZED(msg.sender));
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
