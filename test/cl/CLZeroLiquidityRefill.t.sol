// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CLPeripheryTest, CLPeripheryToken} from "./CLPeriphery.t.sol";
import {CLMasterChef} from "../../src/core/CLMasterChef.sol";
import {ICLNonfungiblePositionManager} from "../../src/core/interfaces/ICLNonfungiblePositionManager.sol";

contract CLZeroLiquidityRefillTest is CLPeripheryTest {
    function testZeroLiquidityRefillSoleStaker() public {
        _checkRefill(false);
    }

    function testZeroLiquidityRefillSharedTicks() public {
        _checkRefill(true);
    }

    function _checkRefill(bool sharedTicks) internal {
        // Disable the MEV guard: accounting must stand on its own.
        (CLMasterChef chef, CLPeripheryToken reward,) = _deployRewardingCLChef(1_000, 0);
        uint256 principal0 = token0.balanceOf(alice);
        uint256 principal1 = token1.balanceOf(alice);
        (uint256 id, uint128 liquidity) = _mintAndStake(chef);
        uint256 otherId;
        if (sharedTicks) (otherId,) = _mintAndStake(chef);
        vm.warp(block.timestamp + 200);
        vm.startPrank(alice);
        token0.approve(address(chef), type(uint256).max);
        token1.approve(address(chef), type(uint256).max);
        for (uint256 i; i < 5; ++i) {
            chef.decreaseLiquidity(
                ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
            chef.collect(
                ICLNonfungiblePositionManager.CollectParams({
                    tokenId: id, recipient: alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );
            (uint128 cachedLiquidity,,,,,,,) = chef.userPositionInfos(id);
            assertEq(cachedLiquidity, 0);
            uint256 rewardBefore = reward.balanceOf(alice);
            vm.warp(block.timestamp + 10);
            // Explicitly exercise permissionless synchronization while empty.
            chef.updateLiquidity(id);
            (liquidity,,) = chef.increaseLiquidity(
                ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: id,
                    amount0Desired: 1_000 ether,
                    amount1Desired: 1_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            chef.harvest(id, alice);
            assertEq(reward.balanceOf(alice), rewardBefore, "empty/refill minted rewards");
            (cachedLiquidity,,,,,,,) = chef.userPositionInfos(id);
            assertEq(cachedLiquidity, liquidity);
        }
        chef.decreaseLiquidity(
            ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        chef.collect(
            ICLNonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        if (sharedTicks) chef.harvest(otherId, alice);
        assertLe(reward.balanceOf(alice), sharedTicks ? 250 ether : 200 ether);
        assertLe(token0.balanceOf(alice), principal0);
        assertLe(token1.balanceOf(alice), principal1);
        vm.stopPrank();
    }
}
