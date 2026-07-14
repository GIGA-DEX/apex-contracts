// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ClassicChef} from "../../src/core/ClassicChef.sol";
import {ClassicFactory} from "../../src/core/ClassicFactory.sol";
import {ClassicPool} from "../../src/core/ClassicPool.sol";
import {IApexController} from "../../src/core/interfaces/IApexController.sol";
import {ClassicRouter} from "../../src/periphery/ClassicRouter.sol";

contract ClassicRouterToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ClassicRouterWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "WETH: ETH transfer failed");
    }
}

contract ClassicRouterTest is Test {
    ClassicFactory internal factory;
    ClassicChef internal classicChef;
    ClassicRouter internal router;
    ClassicRouterToken internal tokenA;
    ClassicRouterToken internal tokenB;
    ClassicRouterToken internal rewardToken;
    ClassicRouterWETH internal weth;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal feeReceiver = address(0xFEE);

    function setUp() public {
        factory = new ClassicFactory(IApexController(address(this)));
        factory.setFeeReceiver(feeReceiver);

        tokenA = new ClassicRouterToken("Token A", "TKNA");
        tokenB = new ClassicRouterToken("Token B", "TKNB");
        rewardToken = new ClassicRouterToken("Reward", "RWD");
        weth = new ClassicRouterWETH();
        classicChef = new ClassicChef(address(rewardToken), address(this));
        router = new ClassicRouter(address(factory), address(weth), address(classicChef));

        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob, 1_000_000 ether);
        tokenB.mint(bob, 1_000_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    function testAddLiquidityCreatesClassicPairAndMintsLp() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        tokenB.approve(address(router), 200 ether);

        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 100 ether,
                amountBDesired: 200 ether,
                amountAMin: 100 ether,
                amountBMin: 200 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        address pair = factory.getPair(address(tokenA), address(tokenB), false);
        assertTrue(factory.isPair(pair));
        assertEq(amountA, 100 ether);
        assertEq(amountB, 200 ether);
        assertGt(liquidity, 0);
        assertEq(ClassicPool(pair).balanceOf(alice), liquidity);
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
    }

    function testAddStableLiquidityCreatesPair() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        tokenB.approve(address(router), 100 ether);

        (,, uint256 liquidity) = router.addLiquidity(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: true,
                amountADesired: 100 ether,
                amountBDesired: 100 ether,
                amountAMin: 100 ether,
                amountBMin: 100 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        address pair = factory.getPair(address(tokenA), address(tokenB), true);
        assertTrue(ClassicPool(pair).stable());
        assertEq(ClassicPool(pair).balanceOf(alice), liquidity);
    }

    function testAddLiquidityETHWrapsEthAndRefundsExcess() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 200 ether);
        router.addLiquidityETH{value: 1 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: alice,
                deadline: block.timestamp
            })
        );

        uint256 balanceBefore = alice.balance;
        router.addLiquidityETH{value: 2 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        address pair = factory.getPair(address(tokenA), address(weth), false);
        assertEq(weth.balanceOf(pair), 2 ether);
        assertEq(alice.balance, balanceBefore - 1 ether);
    }

    function testDepositForPullsFromSenderAndCreditsRecipient() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        tokenB.approve(address(router), 200 ether);
        (,, uint256 liquidity) = router.addLiquidity(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 100 ether,
                amountBDesired: 200 ether,
                amountAMin: 100 ether,
                amountBMin: 200 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        address pair = factory.getPair(address(tokenA), address(tokenB), false);
        vm.stopPrank();

        classicChef.add(100, IERC20(pair));

        vm.startPrank(alice);
        ClassicPool(pair).approve(address(classicChef), liquidity);
        classicChef.depositFor(0, liquidity, bob);
        vm.stopPrank();

        (uint256 bobAmount,) = classicChef.userInfo(0, bob);
        (uint256 aliceAmount,) = classicChef.userInfo(0, alice);
        assertEq(bobAmount, liquidity);
        assertEq(aliceAmount, 0);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), liquidity);
    }

    function testAddLiquidityAndStakeCreditsChefPosition() public {
        address pair = _seedClassicPair();
        classicChef.add(100, IERC20(pair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 50 ether);
        tokenB.approve(address(router), 100 ether);
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidityAndStake(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 50 ether,
                amountBDesired: 100 ether,
                amountAMin: 50 ether,
                amountBMin: 100 ether,
                to: bob,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        (uint256 stakedAmount,) = classicChef.userInfo(0, bob);
        assertEq(amountA, 50 ether);
        assertEq(amountB, 100 ether);
        assertEq(stakedAmount, liquidity);
        assertEq(ClassicPool(pair).balanceOf(address(router)), 0);
        assertEq(ClassicPool(pair).balanceOf(bob), 0);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), liquidity);
        assertEq(ClassicPool(pair).allowance(address(router), address(classicChef)), 0);
    }

    function testAddLiquidityETHAndStakeCreditsChefPositionAndRefunds() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        router.addLiquidityETH{value: 1 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        address pair = factory.getPair(address(tokenA), address(weth), false);
        classicChef.add(100, IERC20(pair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 200 ether);
        uint256 balanceBefore = bob.balance;
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = router.addLiquidityETHAndStake{value: 2 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: bob,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        (uint256 stakedAmount,) = classicChef.userInfo(0, bob);
        assertEq(amountToken, 100 ether);
        assertEq(amountETH, 1 ether);
        assertEq(stakedAmount, liquidity);
        assertEq(bob.balance, balanceBefore - 1 ether);
        assertEq(ClassicPool(pair).balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
    }

    function testAddLiquidityAndStakeRevertsForUnregisteredFarm() public {
        vm.startPrank(bob);
        tokenA.approve(address(router), 50 ether);
        tokenB.approve(address(router), 100 ether);
        vm.expectRevert();
        router.addLiquidityAndStake(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 50 ether,
                amountBDesired: 100 ether,
                amountAMin: 50 ether,
                amountBMin: 100 ether,
                to: bob,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(factory.getPair(address(tokenA), address(tokenB), false), address(0));
    }

    function testRemoveLiquidityReturnsBothTokens() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        tokenB.approve(address(router), 200 ether);
        (,, uint256 liquidity) = router.addLiquidity(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 100 ether,
                amountBDesired: 200 ether,
                amountAMin: 100 ether,
                amountBMin: 200 ether,
                to: alice,
                deadline: block.timestamp
            })
        );

        address pair = factory.getPair(address(tokenA), address(tokenB), false);
        ClassicPool(pair).approve(address(router), liquidity);
        uint256 tokenABefore = tokenA.balanceOf(alice);
        uint256 tokenBBefore = tokenB.balanceOf(alice);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            ClassicRouter.RemoveLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                liquidity: liquidity,
                amountAMin: 1,
                amountBMin: 1,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertEq(tokenA.balanceOf(alice), tokenABefore + amountA);
        assertEq(tokenB.balanceOf(alice), tokenBBefore + amountB);
        assertEq(ClassicPool(pair).balanceOf(alice), 0);
    }

    function testRemoveLiquidityETHUnwrapsWeth() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        (,, uint256 liquidity) = router.addLiquidityETH{value: 1 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: alice,
                deadline: block.timestamp
            })
        );

        address pair = factory.getPair(address(tokenA), address(weth), false);
        ClassicPool(pair).approve(address(router), liquidity);
        uint256 ethBefore = alice.balance;
        (uint256 amountToken, uint256 amountETH) = router.removeLiquidityETH(
            ClassicRouter.RemoveLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                liquidity: liquidity,
                amountTokenMin: 1,
                amountETHMin: 1,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertGt(amountToken, 0);
        assertGt(amountETH, 0);
        assertEq(alice.balance, ethBefore + amountETH);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
    }

    function testWithdrawToSendsStakedLpToRecipient() public {
        address pair = _seedClassicPair();
        classicChef.add(100, IERC20(pair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 50 ether);
        tokenB.approve(address(router), 100 ether);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 50 ether,
                amountBDesired: 100 ether,
                amountAMin: 50 ether,
                amountBMin: 100 ether,
                to: bob,
                deadline: block.timestamp
            })
        );

        uint256 aliceLpBefore = ClassicPool(pair).balanceOf(alice);
        classicChef.withdrawTo(0, liquidity, alice);
        vm.stopPrank();

        (uint256 bobAmount,) = classicChef.userInfo(0, bob);
        assertEq(bobAmount, 0);
        assertEq(ClassicPool(pair).balanceOf(alice), aliceLpBefore + liquidity);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), 0);
    }

    function testWithdrawToAndCallRemovesStakedLiquidity() public {
        address pair = _seedClassicPair();
        classicChef.add(100, IERC20(pair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 50 ether);
        tokenB.approve(address(router), 100 ether);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 50 ether,
                amountBDesired: 100 ether,
                amountAMin: 50 ether,
                amountBMin: 100 ether,
                to: bob,
                deadline: block.timestamp
            })
        );

        uint256 tokenABefore = tokenA.balanceOf(bob);
        uint256 tokenBBefore = tokenB.balanceOf(bob);
        bytes memory callbackData = abi.encode(
            uint8(0),
            ClassicRouter.RemoveLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                liquidity: liquidity,
                amountAMin: 1,
                amountBMin: 1,
                to: bob,
                deadline: block.timestamp
            })
        );
        classicChef.withdrawToAndCall(0, liquidity, address(router), callbackData);
        vm.stopPrank();

        (uint256 bobAmount,) = classicChef.userInfo(0, bob);
        assertEq(bobAmount, 0);
        assertGt(tokenA.balanceOf(bob), tokenABefore);
        assertGt(tokenB.balanceOf(bob), tokenBBefore);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), 0);
        assertEq(ClassicPool(pair).balanceOf(address(router)), 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
    }

    function testWithdrawToAndCallRemovesStakedLiquidityETH() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        router.addLiquidityETH{value: 1 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        address pair = factory.getPair(address(tokenA), address(weth), false);
        classicChef.add(100, IERC20(pair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 100 ether);
        (,, uint256 liquidity) = router.addLiquidityETHAndStake{value: 1 ether}(
            ClassicRouter.AddLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                amountTokenDesired: 100 ether,
                amountTokenMin: 100 ether,
                amountETHMin: 1 ether,
                to: bob,
                deadline: block.timestamp
            })
        );

        uint256 tokenABefore = tokenA.balanceOf(bob);
        uint256 ethBefore = bob.balance;
        bytes memory callbackData = abi.encode(
            uint8(1),
            ClassicRouter.RemoveLiquidityETHParams({
                token: address(tokenA),
                stable: false,
                liquidity: liquidity,
                amountTokenMin: 1,
                amountETHMin: 1,
                to: bob,
                deadline: block.timestamp
            })
        );
        classicChef.withdrawToAndCall(0, liquidity, address(router), callbackData);
        vm.stopPrank();

        (uint256 bobAmount,) = classicChef.userInfo(0, bob);
        assertEq(bobAmount, 0);
        assertGt(tokenA.balanceOf(bob), tokenABefore);
        assertGt(bob.balance, ethBefore);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), 0);
        assertEq(ClassicPool(pair).balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(tokenA.balanceOf(address(router)), 0);
    }

    function testWithdrawCallbackRejectsNonChefCaller() public {
        bytes memory callbackData = abi.encode(
            uint8(0),
            ClassicRouter.RemoveLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                liquidity: 1,
                amountAMin: 1,
                amountBMin: 1,
                to: bob,
                deadline: block.timestamp
            })
        );

        vm.expectRevert("ClassicRouter: not chef");
        router.onClassicChefWithdraw(bob, 0, 1, callbackData);
    }

    function testWithdrawToAndCallRevertsOnLiquidityMismatch() public {
        address pair = _seedClassicPair();
        classicChef.add(100, IERC20(pair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 50 ether);
        tokenB.approve(address(router), 100 ether);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 50 ether,
                amountBDesired: 100 ether,
                amountAMin: 50 ether,
                amountBMin: 100 ether,
                to: bob,
                deadline: block.timestamp
            })
        );

        bytes memory callbackData = abi.encode(
            uint8(0),
            ClassicRouter.RemoveLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                liquidity: liquidity + 1,
                amountAMin: 1,
                amountBMin: 1,
                to: bob,
                deadline: block.timestamp
            })
        );
        vm.expectRevert("ClassicRouter: liquidity mismatch");
        classicChef.withdrawToAndCall(0, liquidity, address(router), callbackData);
        vm.stopPrank();

        (uint256 bobAmount,) = classicChef.userInfo(0, bob);
        assertEq(bobAmount, liquidity);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), liquidity);
        assertEq(ClassicPool(pair).balanceOf(address(router)), 0);
    }

    function testWithdrawToAndCallRevertsOnPidPairMismatch() public {
        address pair = _seedClassicPair();
        classicChef.add(100, IERC20(pair));

        ClassicRouterToken tokenC = new ClassicRouterToken("Token C", "TKNC");
        tokenC.mint(alice, 1_000_000 ether);
        vm.startPrank(alice);
        tokenA.approve(address(router), 10 ether);
        tokenC.approve(address(router), 10 ether);
        router.addLiquidity(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenC),
                stable: false,
                amountADesired: 10 ether,
                amountBDesired: 10 ether,
                amountAMin: 10 ether,
                amountBMin: 10 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        address otherPair = factory.getPair(address(tokenA), address(tokenC), false);
        classicChef.add(100, IERC20(otherPair));

        vm.startPrank(bob);
        tokenA.approve(address(router), 50 ether);
        tokenB.approve(address(router), 100 ether);
        (,, uint256 liquidity) = router.addLiquidityAndStake(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 50 ether,
                amountBDesired: 100 ether,
                amountAMin: 50 ether,
                amountBMin: 100 ether,
                to: bob,
                deadline: block.timestamp
            })
        );

        bytes memory callbackData = abi.encode(
            uint8(0),
            ClassicRouter.RemoveLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenC),
                stable: false,
                liquidity: liquidity,
                amountAMin: 1,
                amountBMin: 1,
                to: bob,
                deadline: block.timestamp
            })
        );
        vm.expectRevert("ClassicRouter: pid mismatch");
        classicChef.withdrawToAndCall(0, liquidity, address(router), callbackData);
        vm.stopPrank();

        (uint256 bobAmount,) = classicChef.userInfo(0, bob);
        assertEq(bobAmount, liquidity);
        assertEq(ClassicPool(pair).balanceOf(address(classicChef)), liquidity);
        assertEq(ClassicPool(otherPair).balanceOf(address(router)), 0);
    }

    function _seedClassicPair() internal returns (address pair) {
        vm.startPrank(alice);
        tokenA.approve(address(router), 100 ether);
        tokenB.approve(address(router), 200 ether);
        router.addLiquidity(
            ClassicRouter.AddLiquidityParams({
                tokenA: address(tokenA),
                tokenB: address(tokenB),
                stable: false,
                amountADesired: 100 ether,
                amountBDesired: 200 ether,
                amountAMin: 100 ether,
                amountBMin: 200 ether,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        pair = factory.getPair(address(tokenA), address(tokenB), false);
    }

    function getLatestPeriodInfo(address) external pure returns (uint256 rewardPerSecond, uint256 endTime) {
        return (0, 0);
    }

    function payReward(address, address, uint256) external pure returns (uint256 paid) {
        return 0;
    }

    function forfeitReward(address, uint256 amount) external pure returns (uint256 forfeited) {
        return amount;
    }
}
