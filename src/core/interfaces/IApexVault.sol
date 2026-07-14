// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVotingEscrow} from "./IVotingEscrow.sol";

interface IApexVault {
    function apexController() external view returns (address);

    function veNFT() external view returns (IVotingEscrow);

    function setRewardToken(address token, bool status) external;

    function isRewardToken(address token) external view returns (bool);

    function setVaultConfig(uint256 minRemainingLock, uint256 rewardDuration) external;

    function sweepUnallocated(address token) external returns (uint256 amount);

    function notifyRewardAmount(address from, address token, uint256 amount) external;

    function notifyCompoundAmount(address from, uint256 amount) external;

    function claimAndExtendLock(uint256 tokenId, address[] calldata tokens) external;

    function compound(uint256 tokenId) external returns (uint256 amount);

    function compoundMany(uint256[] calldata tokenIds) external returns (uint256 amount);
}
