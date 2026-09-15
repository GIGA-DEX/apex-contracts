// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClassicChef} from "../../src/core/ClassicChef.sol";
import {BrownfiRouter} from "../../src/periphery/BrownfiRouter.sol";
import {IBrownfiV3Router} from "../../src/periphery/interfaces/IBrownfiV3Router.sol";

contract BrownfiTestToken is ERC20 {
    constructor() ERC20("Test", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Deliberately consumes only part of each desired amount to exercise refund accounting.
contract BrownfiTestV3Router is IBrownfiV3Router {
    address public immutable WETH;
    mapping(address => mapping(address => address)) public getPair;
    bytes32 public lastUpdateHash;
    bool public paused;

    constructor(address weth) {
        WETH = weth;
    }
    receive() external payable {}

    function factory() external view returns (address) {
        return address(this);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setPair(address a, address b, address pair) external {
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 desiredA,
        uint256 desiredB,
        uint256 minA,
        uint256 minB,
        uint256 minLiquidity,
        address to,
        uint256 deadline,
        bytes calldata updateData
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(!paused && deadline >= block.timestamp, "unavailable");
        lastUpdateHash = keccak256(updateData);
        amountA = desiredA * 3 / 4;
        amountB = desiredB / 2;
        liquidity = amountA + amountB;
        require(amountA >= minA && amountB >= minB && liquidity >= minLiquidity, "slippage");
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountB);
        BrownfiTestToken(getPair[tokenA][tokenB]).mint(to, liquidity);
    }

    function addLiquidityETH(
        address token,
        uint256 desired,
        uint256 minToken,
        uint256 minETH,
        uint256 minLiquidity,
        address to,
        uint256 deadline,
        bytes calldata updateData
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(!paused && deadline >= block.timestamp, "unavailable");
        lastUpdateHash = keccak256(updateData);
        amountToken = desired * 3 / 4;
        amountETH = msg.value / 2;
        liquidity = amountToken + amountETH;
        require(amountToken >= minToken && amountETH >= minETH && liquidity >= minLiquidity, "slippage");
        IERC20(token).transferFrom(msg.sender, address(this), amountToken);
        BrownfiTestToken(getPair[token][WETH]).mint(to, liquidity);
        (bool ok,) = msg.sender.call{value: msg.value - amountETH}("");
        require(ok, "refund failed");
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 minA,
        uint256 minB,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "expired");
        (amountA, amountB) = (liquidity * 3 / 5, liquidity * 2 / 5);
        require(amountA >= minA && amountB >= minB, "slippage");
        _burn(getPair[tokenA][tokenB], liquidity);
        IERC20(tokenA).transfer(to, amountA);
        IERC20(tokenB).transfer(to, amountB);
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 minToken,
        uint256 minETH,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH) {
        require(deadline >= block.timestamp, "expired");
        (amountToken, amountETH) = (liquidity * 3 / 5, liquidity * 2 / 5);
        require(amountToken >= minToken && amountETH >= minETH, "slippage");
        _burn(getPair[token][WETH], liquidity);
        IERC20(token).transfer(to, amountToken);
        (bool ok,) = to.call{value: amountETH}("");
        require(ok, "ETH transfer failed");
    }

    function _burn(address pair, uint256 amount) internal {
        IERC20(pair).transferFrom(msg.sender, address(this), amount);
        BrownfiTestToken(pair).burn(amount);
    }
}

contract BrownfiReentrantUser {
    BrownfiRouter internal router;
    bytes4 public reentryError;

    function add(BrownfiRouter target, BrownfiRouter.AddLiquidityETHParams calldata p) external payable {
        router = target;
        IERC20(p.token).approve(address(target), p.amountTokenDesired);
        target.addLiquidityETHAndStake{value: msg.value}(p);
    }

    receive() external payable {
        BrownfiRouter.RemoveLiquidityParams memory p;
        (bool ok, bytes memory result) = address(router).call(abi.encodeCall(router.removeLiquidity, (p)));
        require(!ok, "reentry succeeded");
        reentryError = bytes4(result);
    }
}

contract BrownfiRouterTest is Test {
    BrownfiRouter internal router;
    BrownfiTestV3Router internal upstream;
    ClassicChef internal chef;
    BrownfiTestToken internal tokenA;
    BrownfiTestToken internal tokenB;
    BrownfiTestToken internal lp;
    BrownfiTestToken internal nativeLp;
    address internal weth = address(0x1234);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        tokenA = new BrownfiTestToken();
        tokenB = new BrownfiTestToken();
        lp = new BrownfiTestToken();
        nativeLp = new BrownfiTestToken();
        upstream = new BrownfiTestV3Router(weth);
        upstream.setPair(address(tokenA), address(tokenB), address(lp));
        upstream.setPair(address(tokenA), weth, address(nativeLp));
        chef = new ClassicChef(address(tokenB), address(this));
        chef.addPool(address(lp), 0);
        chef.addPool(address(nativeLp), 0);
        router = new BrownfiRouter(address(upstream), address(chef));
        tokenA.mint(alice, 1000 ether);
        tokenB.mint(alice, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function getLatestPeriodInfo(address) external view returns (uint256, uint256) {
        return (0, block.timestamp);
    }

    function _add() internal view returns (BrownfiRouter.AddLiquidityParams memory) {
        return BrownfiRouter.AddLiquidityParams(
            address(tokenA),
            address(tokenB),
            100 ether,
            100 ether,
            75 ether,
            50 ether,
            125 ether,
            alice,
            block.timestamp,
            abi.encode(new bytes[](0))
        );
    }

    function _addETH() internal view returns (BrownfiRouter.AddLiquidityETHParams memory) {
        return BrownfiRouter.AddLiquidityETHParams(
            address(tokenA), 100 ether, 75 ether, 50 ether, 125 ether, alice, block.timestamp, hex"112233"
        );
    }

    function _remove(uint256 amount) internal view returns (BrownfiRouter.RemoveLiquidityParams memory) {
        return BrownfiRouter.RemoveLiquidityParams(
            address(tokenA), address(tokenB), amount, amount * 3 / 5, amount * 2 / 5, bob, block.timestamp
        );
    }

    function _removeETH(uint256 amount) internal view returns (BrownfiRouter.RemoveLiquidityETHParams memory) {
        return BrownfiRouter.RemoveLiquidityETHParams(
            address(tokenA), amount, amount * 3 / 5, amount * 2 / 5, bob, block.timestamp
        );
    }

    function _stake() internal returns (uint256 liquidity) {
        vm.prank(alice);
        (,, liquidity) = router.addLiquidityAndStake(_add());
    }

    function _assertClean() internal view {
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
        assertEq(lp.balanceOf(address(router)), 0);
        assertEq(nativeLp.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(tokenA.allowance(address(router), address(upstream)), 0);
        assertEq(tokenB.allowance(address(router), address(upstream)), 0);
        assertEq(lp.allowance(address(router), address(upstream)), 0);
        assertEq(nativeLp.allowance(address(router), address(upstream)), 0);
        assertEq(lp.allowance(address(router), address(chef)), 0);
        assertEq(nativeLp.allowance(address(router), address(chef)), 0);
    }

    function testAddAndStakeRefundsAndCreditsRecipient() public {
        BrownfiRouter.AddLiquidityParams memory p = _add();
        p.to = bob;
        vm.prank(alice);
        (uint256 a, uint256 b, uint256 liquidity) = router.addLiquidityAndStake(p);
        assertEq(a, 75 ether);
        assertEq(b, 50 ether);
        assertEq(tokenA.balanceOf(alice), 925 ether);
        assertEq(tokenB.balanceOf(alice), 950 ether);
        assertEq(upstream.lastUpdateHash(), keccak256(p.updateData));
        (uint256 stake,) = chef.userInfo(0, bob);
        assertEq(stake, liquidity);
        assertEq(lp.balanceOf(address(chef)), liquidity);
        _assertClean();
    }

    function testWalletAddAndRemove() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidity(_add());
        assertEq(lp.balanceOf(alice), liquidity);
        vm.startPrank(alice);
        lp.approve(address(router), liquidity);
        router.removeLiquidity(_remove(liquidity));
        vm.stopPrank();
        assertEq(tokenA.balanceOf(bob), 75 ether);
        assertEq(tokenB.balanceOf(bob), 50 ether);
        _assertClean();
    }

    function testPartialAndFullExitRemainAtomic() public {
        uint256 liquidity = _stake();
        vm.prank(alice);
        chef.withdrawToAndCall(0, liquidity / 2, address(router), abi.encode(uint8(0), _remove(liquidity / 2)));
        (uint256 remaining,) = chef.userInfo(0, alice);
        assertEq(remaining, liquidity / 2);
        assertEq(lp.allowance(alice, address(router)), 0);
        vm.prank(alice);
        chef.withdrawToAndCall(0, remaining, address(router), abi.encode(uint8(0), _remove(remaining)));
        (remaining,) = chef.userInfo(0, alice);
        assertEq(remaining, 0);
        assertEq(tokenA.balanceOf(bob), 75 ether);
        assertEq(tokenB.balanceOf(bob), 50 ether);
        _assertClean();
    }

    function testNativeAddAndStakedExit() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidityETHAndStake{value: 100 ether}(_addETH());
        assertEq(alice.balance, 950 ether);
        assertEq(tokenA.balanceOf(alice), 925 ether);
        assertEq(upstream.lastUpdateHash(), keccak256(hex"112233"));
        vm.prank(alice);
        chef.withdrawToAndCall(1, liquidity, address(router), abi.encode(uint8(1), _removeETH(liquidity)));
        assertEq(bob.balance, 50 ether);
        assertEq(tokenA.balanceOf(bob), 75 ether);
        _assertClean();
    }

    function testNativeWalletAddAndRemove() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidityETH{value: 100 ether}(_addETH());
        vm.startPrank(alice);
        nativeLp.approve(address(router), liquidity);
        router.removeLiquidityETH(_removeETH(liquidity));
        vm.stopPrank();
        assertEq(bob.balance, 50 ether);
        _assertClean();
    }

    function testCallbackCannotBeCalledByUser() public {
        vm.expectRevert(BrownfiRouter.NotChef.selector);
        router.onClassicChefWithdraw(alice, 0, 1, abi.encode(uint8(0), _remove(1)));
    }

    function testWrongPidCannotSpendPrefundedLp() public {
        uint256 liquidity = _stake();
        nativeLp.mint(address(router), liquidity);
        vm.expectRevert(BrownfiRouter.InvalidCallback.selector);
        vm.prank(alice);
        chef.withdrawToAndCall(0, liquidity, address(router), abi.encode(uint8(1), _removeETH(liquidity)));
        (uint256 remaining,) = chef.userInfo(0, alice);
        assertEq(remaining, liquidity);
        assertEq(nativeLp.balanceOf(address(router)), liquidity);
    }

    function testWrongAmountAndActionRevertWithdrawal() public {
        uint256 liquidity = _stake();
        vm.startPrank(alice);
        vm.expectRevert(BrownfiRouter.InvalidCallback.selector);
        chef.withdrawToAndCall(0, liquidity, address(router), abi.encode(uint8(0), _remove(liquidity + 1)));
        vm.expectRevert(BrownfiRouter.InvalidCallback.selector);
        chef.withdrawToAndCall(0, liquidity, address(router), abi.encode(uint8(2), _remove(liquidity)));
        vm.expectRevert(BrownfiRouter.InvalidCallback.selector);
        chef.withdrawToAndCall(0, 0, address(router), abi.encode(uint8(0), _remove(0)));
        vm.expectRevert();
        chef.withdrawToAndCall(0, liquidity, address(router), hex"01");
        vm.stopPrank();
        (uint256 remaining,) = chef.userInfo(0, alice);
        assertEq(remaining, liquidity);
        _assertClean();
    }

    function testRemovalSlippageAndDeadlineRollBackUnstake() public {
        uint256 liquidity = _stake();
        BrownfiRouter.RemoveLiquidityParams memory p = _remove(liquidity);
        p.amountAMin++;
        vm.prank(alice);
        vm.expectRevert("slippage");
        chef.withdrawToAndCall(0, liquidity, address(router), abi.encode(uint8(0), p));
        p = _remove(liquidity);
        p.deadline--;
        vm.prank(alice);
        vm.expectRevert("expired");
        chef.withdrawToAndCall(0, liquidity, address(router), abi.encode(uint8(0), p));
        (uint256 remaining,) = chef.userInfo(0, alice);
        assertEq(remaining, liquidity);
        _assertClean();
    }

    function testDepositMinimumLpAndDeadlineRollBackTokens() public {
        BrownfiRouter.AddLiquidityParams memory p = _add();
        p.minLiquidity++;
        vm.startPrank(alice);
        vm.expectRevert("slippage");
        router.addLiquidityAndStake(p);
        p = _add();
        p.deadline--;
        vm.expectRevert("unavailable");
        router.addLiquidityAndStake(p);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(alice), 1000 ether);
        assertEq(tokenB.balanceOf(alice), 1000 ether);
        _assertClean();
    }

    function testMissingPoolAndUnregisteredGauge() public {
        BrownfiRouter.AddLiquidityParams memory p = _add();
        p.tokenB = address(0xBAD);
        vm.startPrank(alice);
        vm.expectRevert(BrownfiRouter.PairMissing.selector);
        router.addLiquidityAndStake(p);
        vm.stopPrank();
        BrownfiTestToken otherLp = new BrownfiTestToken();
        upstream.setPair(address(tokenA), address(tokenB), address(otherLp));
        vm.prank(alice);
        vm.expectRevert();
        router.addLiquidityAndStake(_add());
        assertEq(tokenA.balanceOf(alice), 1000 ether);
        _assertClean();
    }

    function testPausedDepositsStillAllowExit() public {
        uint256 liquidity = _stake();
        upstream.setPaused(true);
        vm.startPrank(alice);
        vm.expectRevert("unavailable");
        router.addLiquidityAndStake(_add());
        chef.withdrawToAndCall(0, liquidity, address(router), abi.encode(uint8(0), _remove(liquidity)));
        vm.stopPrank();
        _assertClean();
    }

    function testRefundsDoNotSweepExistingBalances() public {
        tokenA.mint(address(router), 7 ether);
        lp.mint(address(router), 3 ether);
        vm.deal(address(router), 5 ether);
        _stake();
        vm.prank(alice);
        router.addLiquidityETHAndStake{value: 100 ether}(_addETH());
        assertEq(tokenA.balanceOf(address(router)), 7 ether);
        assertEq(lp.balanceOf(address(router)), 3 ether);
        assertEq(address(router).balance, 5 ether);
    }

    function testRecipientAndConstructorValidation() public {
        vm.expectRevert(BrownfiRouter.InvalidAddress.selector);
        new BrownfiRouter(address(0), address(chef));
        vm.expectRevert(BrownfiRouter.InvalidAddress.selector);
        new BrownfiRouter(address(upstream), address(0));
        BrownfiRouter.AddLiquidityParams memory p = _add();
        address[3] memory invalid = [address(0), address(router), address(chef)];
        for (uint256 i; i < invalid.length; ++i) {
            p.to = invalid[i];
            vm.prank(alice);
            vm.expectRevert(BrownfiRouter.InvalidAddress.selector);
            router.addLiquidityAndStake(p);
        }
    }

    function testRejectsUnsolicitedETH() public {
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testStakeFailureRollsBackMintAndTransfers() public {
        vm.mockCallRevert(
            address(chef),
            abi.encodeWithSelector(chef.depositFor.selector, 0, 125 ether, alice),
            abi.encodeWithSignature("Error(string)", "stake failed")
        );
        vm.prank(alice);
        vm.expectRevert("stake failed");
        router.addLiquidityAndStake(_add());
        assertEq(lp.totalSupply(), 0);
        assertEq(tokenA.balanceOf(alice), 1000 ether);
        assertEq(tokenB.balanceOf(alice), 1000 ether);
        _assertClean();
    }

    function testRejectingEthRecipientRollsBackWithdrawal() public {
        vm.prank(alice);
        (,, uint256 liquidity) = router.addLiquidityETHAndStake{value: 100 ether}(_addETH());
        BrownfiRouter.RemoveLiquidityETHParams memory p = _removeETH(liquidity);
        p.to = address(this);
        vm.prank(alice);
        vm.expectRevert("ETH transfer failed");
        chef.withdrawToAndCall(1, liquidity, address(router), abi.encode(uint8(1), p));
        (uint256 staked,) = chef.userInfo(1, alice);
        assertEq(staked, liquidity);
        _assertClean();
    }

    function testNativeRefundCannotReenterRouter() public {
        BrownfiReentrantUser user = new BrownfiReentrantUser();
        tokenA.mint(address(user), 100 ether);
        BrownfiRouter.AddLiquidityETHParams memory p = _addETH();
        p.to = address(user);
        vm.deal(address(this), 100 ether);
        user.add{value: 100 ether}(router, p);
        assertEq(user.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(address(user).balance, 50 ether);
        assertEq(tokenA.balanceOf(address(user)), 25 ether);
        (uint256 staked,) = chef.userInfo(1, address(user));
        assertEq(staked, 125 ether);
        _assertClean();
    }

    function testFuzzDepositAccountsForEveryToken(uint96 desiredA, uint96 desiredB) public {
        desiredA = uint96(bound(desiredA, 4, 1000 ether));
        desiredB = uint96(bound(desiredB, 2, 1000 ether));
        BrownfiRouter.AddLiquidityParams memory p = _add();
        p.amountADesired = desiredA;
        p.amountBDesired = desiredB;
        p.amountAMin = 0;
        p.amountBMin = 0;
        p.minLiquidity = 1;
        vm.prank(alice);
        (uint256 a, uint256 b, uint256 liquidity) = router.addLiquidityAndStake(p);
        assertEq(tokenA.balanceOf(alice) + a, 1000 ether);
        assertEq(tokenB.balanceOf(alice) + b, 1000 ether);
        (uint256 staked,) = chef.userInfo(0, alice);
        assertEq(staked, liquidity);
        _assertClean();
    }
}
