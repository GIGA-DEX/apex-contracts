// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

library ApexVaultStorage {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 internal constant SLOT = keccak256("apex.vault.storage.v1");

    struct RewardData {
        uint256 rewardRate;
        uint256 periodFinish;
        uint256 lastUpdateTime;
        uint256 rewardPerWeightStored;
        uint256 totalWeight;
        uint256 periodRemainder;
        uint256 scaledCarry;
        uint256 unallocated;
    }

    struct Position {
        address owner;
        bool staked;
        bool active;
    }

    struct Config {
        uint16 bps;
        uint256 weight;
    }

    struct Layout {
        IVotingEscrow veNFT;
        address apexController;
        uint256 minRemainingLock;
        uint256 rewardDuration;
        EnumerableSet.UintSet activePositions;
        EnumerableSet.AddressSet rewardTokens;
        mapping(address token => bool enabled) isRewardToken;
        mapping(address token => RewardData rewardData) rewardData;
        mapping(uint256 tokenId => Position position) positions;
        mapping(uint256 tokenId => address[] rewardTokens) userRewardTokens;
        mapping(uint256 tokenId => mapping(address rewardToken => Config config)) configs;
        mapping(uint256 tokenId => mapping(address token => uint256 rewardPerWeight)) userRewardPerWeightPaid;
        mapping(uint256 tokenId => mapping(address token => uint256 amount)) rewards;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
