// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;

import "./LiquidityMath.sol";
import "./LowGasSafeMath.sol";
import "./SafeCast.sol";

library RewardTick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    struct Info {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 rewardGrowthOutsideX128;
    }

    function getRewardGrowthInside(
        mapping(int24 => Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 rewardGrowthGlobalX128
    ) internal view returns (uint256 rewardGrowthInsideX128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        uint256 rewardGrowthBelowX128;
        if (tickCurrent >= tickLower) {
            rewardGrowthBelowX128 = lower.rewardGrowthOutsideX128;
        } else {
            rewardGrowthBelowX128 = rewardGrowthGlobalX128 - lower.rewardGrowthOutsideX128;
        }

        uint256 rewardGrowthAboveX128;
        if (tickCurrent < tickUpper) {
            rewardGrowthAboveX128 = upper.rewardGrowthOutsideX128;
        } else {
            rewardGrowthAboveX128 = rewardGrowthGlobalX128 - upper.rewardGrowthOutsideX128;
        }

        rewardGrowthInsideX128 = rewardGrowthGlobalX128 - rewardGrowthBelowX128 - rewardGrowthAboveX128;
    }

    function update(
        mapping(int24 => Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 rewardGrowthGlobalX128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);
        require(liquidityGrossAfter <= maxLiquidity, "LO");

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0 && tick <= tickCurrent) {
            info.rewardGrowthOutsideX128 = rewardGrowthGlobalX128;
        }

        info.liquidityGross = liquidityGrossAfter;
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    function clear(mapping(int24 => Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    function cross(mapping(int24 => Info) storage self, int24 tick, uint256 rewardGrowthGlobalX128)
        internal
        returns (int128 liquidityNet)
    {
        Info storage info = self[tick];
        info.rewardGrowthOutsideX128 = rewardGrowthGlobalX128 - info.rewardGrowthOutsideX128;
        liquidityNet = info.liquidityNet;
    }
}
