// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IClassicFactory} from "../interfaces/IClassicFactory.sol";
import {IClassicPool} from "../interfaces/IClassicPool.sol";
import {ICLFactory} from "../interfaces/ICLFactory.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";
import {ApexErrors} from "./common/ApexErrors.sol";
import {ApexControllerStorage} from "../storage/ApexControllerStorage.sol";

library ApexControllerFeePolicy {
    uint32 private constant DEFAULT_CL_PROTOCOL_FEE = 2_000;
    uint32 private constant CL_PROTOCOL_FEE_DENOMINATOR = 10_000;

    event CLGlobalProtocolFeeSet(uint32 protocolFee);
    event EmissionCenterSet(address indexed center);
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);

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

    function applyUngaugedProtocolFees(address[] calldata classicPairs, address[] calldata clPools) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        IClassicFactory classicFactory = s.classicFactory;
        uint256 classicProtocolFee = classicFactory.protocolFee();
        for (uint256 i; i < classicPairs.length; ++i) {
            address pair = classicPairs[i];
            require(!s.activeFarm[pair], ApexErrors.FARM_ACTIVE(pair));
            require(classicFactory.isPair(pair), ApexErrors.NOT_PAIR(pair));
            classicFactory.setPairProtocolFee(pair, classicProtocolFee);
        }

        uint32 clProtocolFee = _clGlobalProtocolFee(s);
        for (uint256 i; i < clPools.length; ++i) {
            address pool = clPools[i];
            require(!s.activeFarm[pool], ApexErrors.FARM_ACTIVE(pool));
            _canonicalCLFactory(s, pool).setFeeProtocol(pool, clProtocolFee, clProtocolFee);
        }
    }

    function overrideClassicFeeReceiver(address pair, address feeReceiver) external {
        IClassicFactory factory = ApexControllerStorage.layout().classicFactory;
        require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        factory.setPairFeeReceiver(pair, feeReceiver);
    }

    function overrideClassicFee(address pair, uint256 fee) external {
        IClassicFactory factory = ApexControllerStorage.layout().classicFactory;
        require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        factory.setPairFee(pair, fee);
    }

    function overrideClassicProtocolFee(address pair, uint256 protocolFee) external {
        IClassicFactory factory = ApexControllerStorage.layout().classicFactory;
        require(factory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        factory.setPairProtocolFee(pair, protocolFee);
    }

    function overrideCLProtocolFee(address pool, uint32 feeProtocol0, uint32 feeProtocol1) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        _canonicalCLFactory(s, pool).setFeeProtocol(pool, feeProtocol0, feeProtocol1);
    }

    function collectCLProtocolFees(address pool, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        address recipient = address(s.feeCenter);
        require(recipient != address(0), ApexErrors.ZERO_ADDRESS());
        return _canonicalCLFactory(s, pool).collectProtocol(pool, recipient, amount0Requested, amount1Requested);
    }

    function collectClassicProtocolFees(address pair) external returns (uint256 amount0, uint256 amount1) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.classicFactory.isPair(pair), ApexErrors.NOT_PAIR(pair));
        IClassicPool(pair).mintFee();
        return s.feeCenter.realizeClassicFees(pair);
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

    function _clGlobalProtocolFee(ApexControllerStorage.Layout storage s) private view returns (uint32) {
        uint32 stored = s.clGlobalProtocolFeePlusOne;
        return stored == 0 ? DEFAULT_CL_PROTOCOL_FEE : stored - 1;
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
