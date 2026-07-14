// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.9.0;

interface ILmPool {
    function accumulateReward(uint32 currTimestamp) external;

    function crossLmTick(int24 tick, bool zeroForOne) external;

    function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external;

    function getRewardGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 rewardGrowthInsideX128);
}
