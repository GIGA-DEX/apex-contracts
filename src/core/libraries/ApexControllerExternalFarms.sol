// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBrownFiFactory, IBrownFiPair} from "../interfaces/IBrownFi.sol";
import {ApexControllerStorage} from "../storage/ApexControllerStorage.sol";
import {ApexErrors} from "./common/ApexErrors.sol";

/// @notice External ERC20 farms using the BrownFi V3 factory/config ABI.
/// @dev Trust is explicit. An allowlisted factory must issue ordinary, non-rebasing,
/// non-taxed LP ERC20s and support the FeeCenter's burn(address) redemption path.
library ApexControllerExternalFarms {
    using EnumerableSet for EnumerableSet.AddressSet;

    event ExternalClassicFactorySet(address indexed factory, bool allowed);
    event ExternalClassicFarmRegistered(address indexed factory, address indexed pair);
    event ClassicFarmRegistered(address indexed pair);

    function setFactory(address factory, bool allowed) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(factory != address(0) && factory != address(s.classicFactory), ApexErrors.INVALID_POOL(factory));
        if (allowed) require(factory.code.length != 0, ApexErrors.INVALID_POOL(factory));
        s.externalClassicFactories[factory] = allowed;
        emit ExternalClassicFactorySet(factory, allowed);
    }

    function registerFarm(address factory, address pair) external {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        require(s.externalClassicFactories[factory], ApexErrors.NOT_AUTHORIZED(factory));
        require(address(s.classicChef) != address(0), ApexErrors.ZERO_ADDRESS());
        require(!s.registeredFarm[pair], ApexErrors.POOL_EXISTS(pair));
        _validatePair(factory, pair);
        s.externalClassicFarmFactory[pair] = factory;
        s.classicChef.addPool(pair, 0);
        s.registeredFarm[pair] = true;
        s.classicFarms.add(pair);
        // Keep existing farm discovery consumers compatible; pool kind remains PROPAMM.
        emit ClassicFarmRegistered(pair);
        emit ExternalClassicFarmRegistered(factory, pair);
    }

    /// @notice Validates factory approval and canonical pool identity.
    /// Fee sharing with external venues is coordinated off-chain.
    /// @dev Used at activation and positive rebalance. Never used on user exits or claims.
    function requireReady(address pair) external view {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        _requireReady(s, pair);
    }

    function requireReadyForWeight(address pair, uint256 weight) external view {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        if (weight != 0 && s.externalClassicFarmFactory[pair] != address(0)) _requireReady(s, pair);
    }

    function _requireReady(ApexControllerStorage.Layout storage s, address pair) private view {
        address factory = s.externalClassicFarmFactory[pair];
        require(s.externalClassicFactories[factory], ApexErrors.NOT_AUTHORIZED(factory));
        _validatePair(factory, pair);
    }

    /// @dev BrownFi mints protocol LP during swaps, without Apex's mintFee() hook.
    /// Collection remains available after factory revocation or farm deactivation.
    function collectFees(address pair) external returns (uint256 amount0, uint256 amount1) {
        ApexControllerStorage.Layout storage s = ApexControllerStorage.layout();
        _validatePair(s.externalClassicFarmFactory[pair], pair);
        return s.feeCenter.realizeClassicFees(pair);
    }

    function _validatePair(address factory, address pair) private view {
        require(factory != address(0) && pair.code.length != 0, ApexErrors.INVALID_POOL(pair));
        IBrownFiPair pool = IBrownFiPair(pair);
        require(pool.factory() == factory, ApexErrors.INVALID_POOL(pair));
        address token0 = pool.token0();
        address token1 = pool.token1();
        require(token0 != address(0) && token1 != address(0) && token0 != token1, ApexErrors.INVALID_POOL(pair));
        require(IBrownFiFactory(factory).getPair(token0, token1) == pair, ApexErrors.INVALID_POOL(pair));
    }
}
