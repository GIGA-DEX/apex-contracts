// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./interfaces/ILmPool.sol";
import "./interfaces/ILmPoolDeployer.sol";
import "./interfaces/ICLPool.sol";
import "./interfaces/ICLMasterChef.sol";
import "./libraries/cl/FixedPoint128.sol";
import "./libraries/cl/FullMath.sol";
import "./libraries/cl/LiquidityMath.sol";
import "./libraries/cl/RewardTick.sol";
import "./libraries/cl/LowGasSafeMath.sol";
import "./libraries/cl/SafeCast.sol";

contract LmPool is ILmPool {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using RewardTick for mapping(int24 => RewardTick.Info);

    uint256 public constant REWARD_PRECISION = 1e12;

    ICLPool public immutable pool;
    ICLMasterChef public immutable masterChef;

    uint256 public rewardGrowthGlobalX128;
    mapping(int24 => RewardTick.Info) public lmTicks;
    uint128 public lmLiquidity;
    uint32 public lastRewardTimestamp;

    modifier onlyPool() {
        require(msg.sender == address(pool), "Not pool");
        _;
    }

    modifier onlyMasterChef() {
        require(msg.sender == address(masterChef), "Not MC");
        _;
    }

    modifier onlyPoolOrMasterChef() {
        require(msg.sender == address(pool) || msg.sender == address(masterChef), "Not pool or MC");
        _;
    }

    constructor() {
        (address poolAddress, address masterChefAddress) = ILmPoolDeployer(msg.sender).parameters();
        pool = ICLPool(poolAddress);
        masterChef = ICLMasterChef(masterChefAddress);
        lastRewardTimestamp = uint32(block.timestamp);
    }

    function accumulateReward(uint32 currTimestamp) external override onlyPoolOrMasterChef {
        if (currTimestamp <= lastRewardTimestamp) return;

        (uint256 rewardPerSecond, uint256 endTime) = masterChef.getLatestPeriodInfo(address(pool));
        uint32 endTimestamp = uint32(endTime);
        uint32 duration;
        if (endTimestamp > currTimestamp) {
            duration = currTimestamp - lastRewardTimestamp;
        } else if (endTimestamp > lastRewardTimestamp) {
            duration = endTimestamp - lastRewardTimestamp;
        }

        if (duration == 0 || rewardPerSecond == 0) {
            lastRewardTimestamp = currTimestamp;
            return;
        }

        if (lmLiquidity != 0) {
            rewardGrowthGlobalX128 += FullMath.mulDiv(
                duration, FullMath.mulDiv(rewardPerSecond, FixedPoint128.Q128, REWARD_PRECISION), lmLiquidity
            );
        } else {
            // release elapsed emissions that no in-range liquidity can ever claim
            uint256 skippedReward = FullMath.mulDiv(duration, rewardPerSecond, REWARD_PRECISION);
            if (skippedReward != 0) masterChef.forfeitReward(address(pool), skippedReward);
        }

        lastRewardTimestamp = currTimestamp;
    }

    function crossLmTick(int24 tick, bool zeroForOne) external override onlyPool {
        if (lmTicks[tick].liquidityGross == 0) return;

        int128 lmLiquidityNet = lmTicks.cross(tick, rewardGrowthGlobalX128);
        if (zeroForOne) lmLiquidityNet = -lmLiquidityNet;
        lmLiquidity = LiquidityMath.addDelta(lmLiquidity, lmLiquidityNet);
    }

    function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external override onlyMasterChef {
        (, int24 tick,,,,,) = pool.slot0();
        uint128 maxLiquidityPerTick = pool.maxLiquidityPerTick();
        uint256 rewardGrowthGlobalX128_ = rewardGrowthGlobalX128;

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower =
                lmTicks.update(tickLower, tick, liquidityDelta, rewardGrowthGlobalX128_, false, maxLiquidityPerTick);
            flippedUpper =
                lmTicks.update(tickUpper, tick, liquidityDelta, rewardGrowthGlobalX128_, true, maxLiquidityPerTick);
        }

        if (tick >= tickLower && tick < tickUpper) {
            lmLiquidity = LiquidityMath.addDelta(lmLiquidity, liquidityDelta);
        }

        if (liquidityDelta < 0) {
            if (flippedLower) lmTicks.clear(tickLower);
            if (flippedUpper) lmTicks.clear(tickUpper);
        }
    }

    function getRewardGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (uint256 rewardGrowthInsideX128)
    {
        (, int24 tick,,,,,) = pool.slot0();
        rewardGrowthInsideX128 = lmTicks.getRewardGrowthInside(tickLower, tickUpper, tick, rewardGrowthGlobalX128);
    }
}
