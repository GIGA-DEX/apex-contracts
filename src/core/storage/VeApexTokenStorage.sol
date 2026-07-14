// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

library VeApexTokenStorage {
    bytes32 internal constant SLOT = keccak256("apex.ve.storage.v1");

    struct UserPoint {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
        uint256 permanent;
    }

    struct GlobalPoint {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
        uint256 permanentLockBalance;
    }

    struct Layout {
        address token;
        address team;
        address artProxy;
        uint256 tokenId;
        uint256 epoch;
        uint256 supply;
        mapping(uint256 epoch => GlobalPoint point) pointHistory;
        mapping(uint256 tokenId => IVotingEscrow.LockedBalance lock) locked;
        mapping(uint256 tokenId => mapping(uint256 epoch => UserPoint point)) userPointHistory;
        mapping(uint256 tokenId => uint256 epoch) userPointEpoch;
        mapping(uint256 time => int128 slopeChange) slopeChanges;
        mapping(uint256 tokenId => address owner) idToOwner;
        mapping(address owner => uint256 count) ownerToNFTokenCount;
        mapping(uint256 tokenId => address approved) idToApprovals;
        mapping(address owner => mapping(address operator => bool approved)) ownerToOperators;
        mapping(uint256 tokenId => uint256 blockNumber) ownershipChange;
        mapping(address owner => mapping(uint256 index => uint256 tokenId)) ownerToNFTokenIdList;
        mapping(uint256 tokenId => uint256 index) tokenToOwnerIndex;
        mapping(bytes4 interfaceId => bool supported) supportedInterfaces;
        string name;
        string symbol;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
