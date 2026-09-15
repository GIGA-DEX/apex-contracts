// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

/// @dev Namespaced storage for ApexSale. Append fields to Layout for future upgrades; never reorder existing fields.
library ApexSaleStorage {
    bytes32 internal constant SLOT = keccak256("apex.sale.storage.v1");

    struct Layout {
        IERC20 usdg;
        IERC20 giga;
        IVotingEscrow veGiga;
        address treasury;
        uint64 startTime;
        uint64 endTime;
        bool claimsActivated;
        bool claimsPaused;
        uint256 maxTotalContribution;
        uint256 maxContributionPerAccount;
        uint256 totalContributed;
        uint256 totalBaseAllocation;
        uint256 totalClaimedBaseAllocation;
        uint256 totalGigaDistributed;
        address[] participants;
        mapping(address account => uint256 amount) contributions;
        mapping(address account => uint256 amount) baseAllocations;
        mapping(address account => bool status) claimed;
        // Three-lane TGE claim configuration. These fields were appended after the
        // production sale deployment; never move them above the legacy fields.
        uint64 claimStartTime;
        uint64 saleClaimEndTime;
        uint64 pointsClaimEndTime;
        uint64 airdropClaimEndTime;
        uint256 pointsTotalEntitlement;
        uint256 airdropTotalEntitlement;
        uint256 totalPointsEntitlementClaimed;
        uint256 totalAirdropEntitlementClaimed;
        address[] pointsRecipients;
        address[] airdropRecipients;
        mapping(address account => uint256 amount) pointsAllocations;
        mapping(address account => uint256 amount) airdropAllocations;
        mapping(address account => bool status) pointsClaimed;
        mapping(address account => bool status) airdropClaimed;
        // One-time supplemental airdrop appended after TGE configuration. Separate
        // claim state prevents recipients from replaying an original airdrop claim.
        bool supplementalAirdropConfigured;
        address[] supplementalAirdropRecipients;
        mapping(address account => uint256 amount) supplementalAirdropAllocations;
        mapping(address account => bool status) supplementalAirdropClaimed;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
