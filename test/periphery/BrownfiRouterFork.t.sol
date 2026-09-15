// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BrownfiRouter} from "../../src/periphery/BrownfiRouter.sol";
import {ClassicChef} from "../../src/core/ClassicChef.sol";

/// @dev Opt in with BROWNFI_ROUTER_FORK=true and BROWNFI_UPDATE_DATA at a matching pinned fork block.
contract BrownfiRouterForkTest is Test {
    address constant UPSTREAM = 0x2A08Da7B6590ce5D217161F234069CfC54DBe554;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant PAIR = 0x8825EDfF851F6fC8f0d91D3942C946910D38771b;
    ClassicChef internal chef = ClassicChef(0xCA4E6055811264C185c7b3851f775Aa0933CD8d9);
    BrownfiRouter internal router;
    address internal alice = address(0xA11CE);
    bytes internal updateData;

    function setUp() public {
        if (!vm.envOr("BROWNFI_ROUTER_FORK", false)) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663);
        updateData = vm.envBytes("BROWNFI_UPDATE_DATA");
        router = new BrownfiRouter(UPSTREAM, address(chef));
        deal(USDG, alice, 10_000e6);
        deal(NVDA, alice, 10 ether);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IERC20(NVDA).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testForkNvdaAddStakeAndPartialExit() public {
        BrownfiRouter.AddLiquidityParams memory p =
            BrownfiRouter.AddLiquidityParams(USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp, updateData);
        vm.prank(alice);
        (uint256 a, uint256 b, uint256 liquidity) = router.addLiquidityAndStake(p);
        assertGt(liquidity, 0);
        assertEq(IERC20(USDG).balanceOf(alice), 10_000e6 - a);
        assertEq(IERC20(NVDA).balanceOf(alice), 10 ether - b);
        uint256 pid = chef.pidOf(PAIR);
        (uint256 staked,) = chef.userInfo(pid, alice);
        assertEq(staked, liquidity);
        assertEq(IERC20(PAIR).balanceOf(alice), 0);
        uint256 half = liquidity / 2;
        BrownfiRouter.RemoveLiquidityParams memory r =
            BrownfiRouter.RemoveLiquidityParams(USDG, NVDA, half, 1, 1, alice, block.timestamp);
        vm.prank(alice);
        chef.withdrawToAndCall(pid, half, address(router), abi.encode(uint8(0), r));
        (staked,) = chef.userInfo(pid, alice);
        assertEq(staked, liquidity - half);
        assertGt(IERC20(USDG).balanceOf(alice), 10_000e6 - a);
        assertGt(IERC20(NVDA).balanceOf(alice), 10 ether - b);
        _assertClean(PAIR);
    }

    function testForkNativeStakeAndExit() public {
        // WETH/USDG is not a live gauge yet: use the actual Chef implementation locally on the fork.
        chef = new ClassicChef(USDG, address(this));
        router = new BrownfiRouter(UPSTREAM, address(chef));
        address pair = router.brownfiFactory().getPair(USDG, router.WETH9());
        chef.addPool(pair, 0);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), type(uint256).max);
        (uint256 tokenUsed, uint256 ethUsed, uint256 liquidity) = router.addLiquidityETHAndStake{value: 1 ether}(
            BrownfiRouter.AddLiquidityETHParams(USDG, 1000e6, 1, 1, 1, alice, block.timestamp, updateData)
        );
        vm.stopPrank();
        assertGt(liquidity, 0);
        assertLt(ethUsed, 1 ether);
        assertEq(IERC20(USDG).balanceOf(alice), 10_000e6 - tokenUsed);
        assertEq(alice.balance, 10 ether - ethUsed);
        vm.prank(alice);
        chef.withdrawToAndCall(
            0,
            liquidity,
            address(router),
            abi.encode(uint8(1), BrownfiRouter.RemoveLiquidityETHParams(USDG, liquidity, 1, 1, alice, block.timestamp))
        );
        (uint256 staked,) = chef.userInfo(0, alice);
        assertEq(staked, 0);
        assertGt(IERC20(USDG).balanceOf(alice), 10_000e6 - tokenUsed);
        assertGt(alice.balance, 10 ether - ethUsed);
        _assertClean(pair);
    }

    function testForkDepositMatchesDirectBrownfiExecution() public {
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(alice);
        IERC20(USDG).approve(UPSTREAM, 300e6);
        IERC20(NVDA).approve(UPSTREAM, 1 ether);
        (uint256 directA, uint256 directB, uint256 directLP) =
            router.brownfiRouter().addLiquidity(USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp, updateData);
        vm.stopPrank();
        assertTrue(vm.revertToState(snapshot));
        vm.prank(alice);
        (uint256 a, uint256 b, uint256 liquidity) = router.addLiquidityAndStake(
            BrownfiRouter.AddLiquidityParams(USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp, updateData)
        );
        assertEq(a, directA);
        assertEq(b, directB);
        assertEq(liquidity, directLP);
        _assertClean(PAIR);
    }

    function testForkAccruedRewardsAndFullPrincipalExit() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            BrownfiRouter.AddLiquidityParams(USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp, updateData)
        );
        uint256 pid = chef.pidOf(PAIR);
        vm.warp(block.timestamp + 300);
        uint256 pending = chef.pendingReward(pid, alice);
        assertGt(pending, 0);
        uint256 beforeReward = chef.rewardToken().balanceOf(alice);
        vm.prank(alice);
        chef.withdrawToAndCall(
            pid,
            liquidity,
            address(router),
            abi.encode(
                uint8(0), BrownfiRouter.RemoveLiquidityParams(USDG, NVDA, liquidity, 1, 1, alice, block.timestamp)
            )
        );
        assertEq(chef.rewardToken().balanceOf(alice) - beforeReward, pending);
        (uint256 staked,) = chef.userInfo(pid, alice);
        assertEq(staked, 0);
        _assertClean(PAIR);
    }

    function testForkWrappedExitWorksForWalletThatCannotReceiveETH() public {
        chef = new ClassicChef(USDG, address(this));
        router = new BrownfiRouter(UPSTREAM, address(chef));
        address weth = router.WETH9();
        address pair = router.brownfiFactory().getPair(USDG, weth);
        chef.addPool(pair, 0);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), type(uint256).max);
        (,, uint256 liquidity) = router.addLiquidityETHAndStake{value: 1 ether}(
            BrownfiRouter.AddLiquidityETHParams(USDG, 1000e6, 1, 1, 1, alice, block.timestamp, updateData)
        );
        chef.withdrawToAndCall(
            0,
            liquidity,
            address(router),
            abi.encode(
                uint8(0),
                BrownfiRouter.RemoveLiquidityParams(USDG, weth, liquidity, 1, 1, address(this), block.timestamp)
            )
        );
        vm.stopPrank();
        // This test contract has no payable receive/fallback. Token redemption must still succeed.
        assertGt(IERC20(weth).balanceOf(address(this)), 0);
        assertGt(IERC20(USDG).balanceOf(address(this)), 0);
        (uint256 staked,) = chef.userInfo(0, alice);
        assertEq(staked, 0);
        _assertClean(pair);
    }

    function testForkAtomicExitMatchesSeparateChefAndBrownfiCalls() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            BrownfiRouter.AddLiquidityParams(USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp, updateData)
        );
        uint256 pid = chef.pidOf(PAIR);
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(alice);
        chef.withdraw(pid, liquidity);
        IERC20(PAIR).approve(UPSTREAM, liquidity);
        router.brownfiRouter().removeLiquidity(USDG, NVDA, liquidity, 1, 1, alice, block.timestamp);
        vm.stopPrank();
        uint256 directA = IERC20(USDG).balanceOf(alice);
        uint256 directB = IERC20(NVDA).balanceOf(alice);
        assertTrue(vm.revertToState(snapshot));
        vm.prank(alice);
        chef.withdrawToAndCall(
            pid,
            liquidity,
            address(router),
            abi.encode(
                uint8(0), BrownfiRouter.RemoveLiquidityParams(USDG, NVDA, liquidity, 1, 1, alice, block.timestamp)
            )
        );
        assertEq(IERC20(USDG).balanceOf(alice), directA);
        assertEq(IERC20(NVDA).balanceOf(alice), directB);
        (uint256 staked,) = chef.userInfo(pid, alice);
        assertEq(staked, 0);
        _assertClean(PAIR);
    }

    function testForkRejectedExitLeavesStakeIntactAndWalletExitStillWorks() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            BrownfiRouter.AddLiquidityParams(USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp, updateData)
        );
        uint256 pid = chef.pidOf(PAIR);
        vm.prank(alice);
        vm.expectRevert();
        chef.withdrawToAndCall(
            pid,
            liquidity,
            address(router),
            abi.encode(
                uint8(0),
                BrownfiRouter.RemoveLiquidityParams(USDG, NVDA, liquidity, type(uint256).max, 1, alice, block.timestamp)
            )
        );
        (uint256 staked,) = chef.userInfo(pid, alice);
        assertEq(staked, liquidity);
        vm.prank(alice);
        chef.withdraw(pid, liquidity);
        assertEq(IERC20(PAIR).balanceOf(alice), liquidity);
        _assertClean(PAIR);
    }

    function testForkOracleAndDeadlineFailuresDoNotMoveTokens() public {
        BrownfiRouter.AddLiquidityParams memory p = BrownfiRouter.AddLiquidityParams(
            USDG, NVDA, 300e6, 1 ether, 1, 1, 1, alice, block.timestamp - 1, updateData
        );
        vm.startPrank(alice);
        vm.expectRevert();
        router.addLiquidityAndStake(p);
        p.deadline = block.timestamp;
        p.updateData = hex"1234";
        vm.expectRevert();
        router.addLiquidityAndStake(p);
        vm.stopPrank();
        assertEq(IERC20(USDG).balanceOf(alice), 10_000e6);
        assertEq(IERC20(NVDA).balanceOf(alice), 10 ether);
        _assertClean(PAIR);
    }

    function getLatestPeriodInfo(address) external view returns (uint256, uint256) {
        return (0, block.timestamp);
    }

    function _assertClean(address pair) internal view {
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(IERC20(NVDA).balanceOf(address(router)), 0);
        assertEq(IERC20(pair).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(USDG).allowance(address(router), UPSTREAM), 0);
        assertEq(IERC20(NVDA).allowance(address(router), UPSTREAM), 0);
        assertEq(IERC20(pair).allowance(address(router), UPSTREAM), 0);
        assertEq(IERC20(pair).allowance(address(router), address(chef)), 0);
    }
}
