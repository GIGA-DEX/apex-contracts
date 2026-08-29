// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IClassicChef} from "../interfaces/IClassicChef.sol";
import {IClassicFactory} from "../interfaces/IClassicFactory.sol";
import {ICLFactory} from "../interfaces/ICLFactory.sol";
import {ICLMasterChef} from "../interfaces/ICLMasterChef.sol";
import {IFeeCenter} from "../interfaces/IFeeCenter.sol";
import {IApexVault} from "../interfaces/IApexVault.sol";

library ApexControllerStorage {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    bytes32 internal constant SLOT = keccak256("apex.controller.storage.v1");

    struct LauncherAgreement {
        address recipient;
        uint16 creatorFeeBps;
        bool active;
        uint16 veGigaFeeBps;
        bool startGauged;
    }

    struct LauncherAuthorization {
        bytes32 agreementId;
        uint8 permissions;
    }

    struct LauncherPoolConfig {
        bytes32 agreementId;
        address launcher;
        uint16 veGigaFeeBps;
        uint8 poolKind;
        bool exists;
    }

    struct Layout {
        IERC20 rewardToken;
        IClassicFactory classicFactory;
        ICLFactory clFactory;
        IClassicChef classicChef;
        ICLMasterChef clMasterChef;
        IApexVault apexVault;
        address treasury;
        uint256 latestPeriodNumber;
        uint256 latestPeriodStartTime;
        uint256 latestPeriodEndTime;
        uint256 latestPeriodRewardPerSecond;
        uint256 rewardLiability;
        uint256 totalAllocPoint;
        mapping(address farm => uint256 allocPoint) farmAllocPoint;
        mapping(address farm => bool registered) registeredFarm;
        mapping(address farm => bool active) activeFarm;
        EnumerableSet.AddressSet classicFarms;
        EnumerableSet.AddressSet clFarms;
        IFeeCenter feeCenter;
        address emissionCenter;
        uint32 clGlobalProtocolFeePlusOne;
        mapping(bytes32 agreementId => LauncherAgreement agreement) launcherAgreements;
        mapping(address caller => LauncherAuthorization authorization) launcherAuthorizations;
        EnumerableSet.Bytes32Set launcherAgreementIds;
        EnumerableSet.Bytes32Set activeLauncherAgreementIds;
        EnumerableSet.AddressSet launcherCallers;
        EnumerableSet.AddressSet launcherPools;
        EnumerableSet.AddressSet activeLauncherPools;
        mapping(bytes32 agreementId => EnumerableSet.AddressSet pools) launcherPoolsByAgreement;
        mapping(address caller => EnumerableSet.AddressSet pools) launcherPoolsByCaller;
        mapping(address pool => LauncherPoolConfig config) launcherPoolConfigs;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
