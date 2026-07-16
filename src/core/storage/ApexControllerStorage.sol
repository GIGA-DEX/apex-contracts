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

    bytes32 internal constant SLOT = keccak256("apex.controller.storage.v1");

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
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
