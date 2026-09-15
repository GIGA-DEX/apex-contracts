// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClassicChef} from "../../src/core/ClassicChef.sol";
import {BrownfiRouter} from "../../src/periphery/BrownfiRouter.sol";
import {BrownfiTestToken, BrownfiTestV3Router} from "./BrownfiRouter.t.sol";

contract BrownfiSafetyFeeToken is BrownfiTestToken {
    bool public chargeFee;

    function setChargeFee(bool value) external {
        chargeFee = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 fee = chargeFee && from != address(0) && to != address(0) ? amount / 100 : 0;
        super._update(from, to, amount - fee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}

contract BrownfiSafetyWallet {
    BrownfiRouter internal router;
    ClassicChef internal chef;
    bool public rejectETH;
    bool public reenter;
    bytes4 public routerReentryError;
    bytes4 public chefReentryError;

    function configure(bool rejectETH_, bool reenter_) external {
        rejectETH = rejectETH_;
        reenter = reenter_;
    }

    function add(BrownfiRouter target, BrownfiRouter.AddLiquidityETHParams calldata p) external payable {
        router = target;
        chef = ClassicChef(address(target.classicChef()));
        IERC20(p.token).approve(address(target), p.amountTokenDesired);
        target.addLiquidityETHAndStake{value: msg.value}(p);
    }

    function exit(uint256 pid, BrownfiRouter.RemoveLiquidityETHParams calldata p) external {
        chef.withdrawToAndCall(pid, p.liquidity, address(router), abi.encode(uint8(1), p));
    }

    receive() external payable {
        require(!rejectETH, "wallet rejects ETH");
        if (reenter) {
            BrownfiRouter.RemoveLiquidityParams memory p;
            (bool ok, bytes memory result) = address(router).call(abi.encodeCall(router.removeLiquidity, (p)));
            require(!ok, "router reentry succeeded");
            routerReentryError = bytes4(result);
            (ok, result) = address(chef)
                .call(abi.encodeCall(chef.withdrawToAndCall, (1, 1, address(router), abi.encode(uint8(0), p))));
            require(!ok, "chef callback reentry succeeded");
            chefReentryError = bytes4(result);
        }
    }
}

/// @dev Real ClassicChef; only the external AMM and reward controller are mocked.
contract BrownfiRouterSafetyTest is Test {
    BrownfiRouter internal router;
    BrownfiTestV3Router internal upstream;
    ClassicChef internal chef;
    BrownfiSafetyFeeToken internal tokenA;
    BrownfiTestToken internal tokenB;
    BrownfiTestToken internal reward;
    BrownfiTestToken internal lp;
    BrownfiTestToken internal nativeLp;
    address internal constant WETH = address(0x1234);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant DEPOSIT_LP = 125 ether;
    uint256 internal rewardPaymentCap = type(uint256).max;
    bool internal failRewardRead;
    bool internal failRewardPayment;

    function setUp() public {
        vm.warp(1000);
        tokenA = new BrownfiSafetyFeeToken();
        tokenB = new BrownfiTestToken();
        reward = new BrownfiTestToken();
        lp = new BrownfiTestToken();
        nativeLp = new BrownfiTestToken();
        upstream = new BrownfiTestV3Router(WETH);
        upstream.setPair(address(tokenA), address(tokenB), address(lp));
        upstream.setPair(address(tokenA), WETH, address(nativeLp));
        chef = new ClassicChef(address(reward), address(this));
        chef.addPool(address(lp), 0);
        chef.addPool(address(nativeLp), 0);
        router = new BrownfiRouter(address(upstream), address(chef));
        reward.mint(address(this), 1_000_000 ether);
        address[2] memory users = [ALICE, BOB];
        for (uint256 i; i < users.length; ++i) {
            tokenA.mint(users[i], 1000 ether);
            tokenB.mint(users[i], 1000 ether);
            vm.deal(users[i], 1000 ether);
            vm.startPrank(users[i]);
            tokenA.approve(address(router), type(uint256).max);
            tokenB.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function getLatestPeriodInfo(address) external view returns (uint256, uint256) {
        require(!failRewardRead, "controller unavailable");
        return (1 ether * 1e12, 1_000_000);
    }

    function payReward(address, address account, uint256 amount) external returns (uint256) {
        require(msg.sender == address(chef), "not chef");
        require(!failRewardPayment, "reward payment failed");
        if (amount > rewardPaymentCap) amount = rewardPaymentCap;
        reward.transfer(account, amount);
        return amount;
    }

    function forfeitReward(address, uint256) external view {
        require(msg.sender == address(chef), "not chef");
    }

    function _add(address recipient) internal view returns (BrownfiRouter.AddLiquidityParams memory) {
        return BrownfiRouter.AddLiquidityParams(
            address(tokenA),
            address(tokenB),
            100 ether,
            100 ether,
            75 ether,
            50 ether,
            DEPOSIT_LP,
            recipient,
            block.timestamp,
            abi.encode(new bytes[](0))
        );
    }

    function _addETH(address recipient) internal view returns (BrownfiRouter.AddLiquidityETHParams memory) {
        return BrownfiRouter.AddLiquidityETHParams(
            address(tokenA),
            100 ether,
            75 ether,
            50 ether,
            DEPOSIT_LP,
            recipient,
            block.timestamp,
            abi.encode(new bytes[](0))
        );
    }

    function _remove(uint256 amount, address recipient)
        internal
        view
        returns (BrownfiRouter.RemoveLiquidityParams memory)
    {
        return BrownfiRouter.RemoveLiquidityParams(
            address(tokenA), address(tokenB), amount, amount * 3 / 5, amount * 2 / 5, recipient, block.timestamp
        );
    }

    function _removeETH(uint256 amount, address recipient)
        internal
        view
        returns (BrownfiRouter.RemoveLiquidityETHParams memory)
    {
        return BrownfiRouter.RemoveLiquidityETHParams(
            address(tokenA), amount, amount * 3 / 5, amount * 2 / 5, recipient, block.timestamp
        );
    }

    function _stake(address payer, address recipient) internal {
        vm.prank(payer);
        router.addLiquidityAndStake(_add(recipient));
    }

    function _exit(address user, uint256 amount) internal {
        vm.prank(user);
        chef.withdrawToAndCall(0, amount, address(router), abi.encode(uint8(0), _remove(amount, user)));
    }

    function _assertStake(uint256 pid, address user, uint256 expected) internal view {
        (uint256 amount,) = chef.userInfo(pid, user);
        assertEq(amount, expected);
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

    function testAnotherUserCannotSpendVictimsStakeOrAllowance() public {
        _stake(ALICE, ALICE);
        vm.startPrank(BOB);
        vm.expectRevert();
        chef.withdrawToAndCall(0, DEPOSIT_LP, address(router), abi.encode(uint8(0), _remove(DEPOSIT_LP, BOB)));
        vm.expectRevert(BrownfiRouter.NotChef.selector);
        router.onClassicChefWithdraw(ALICE, 0, DEPOSIT_LP, abi.encode(uint8(0), _remove(DEPOSIT_LP, BOB)));
        vm.expectRevert();
        router.removeLiquidity(_remove(DEPOSIT_LP, BOB));
        vm.stopPrank();
        _assertStake(0, ALICE, DEPOSIT_LP);
        _assertStake(0, BOB, 0);
        assertEq(lp.balanceOf(address(chef)), DEPOSIT_LP);
        assertEq(tokenA.balanceOf(BOB), 1000 ether);
        _assertClean();
    }

    function testFuzzTwoUsersCanIndependentlyExitAllPrincipal(uint96 partialAmount) public {
        uint256 partialLP = bound(partialAmount, 1, DEPOSIT_LP - 1);
        _stake(ALICE, ALICE);
        _stake(BOB, BOB);
        _exit(ALICE, partialLP);
        _assertStake(0, ALICE, DEPOSIT_LP - partialLP);
        _assertStake(0, BOB, DEPOSIT_LP);
        assertEq(lp.balanceOf(address(chef)), 2 * DEPOSIT_LP - partialLP);
        _exit(BOB, DEPOSIT_LP);
        _assertStake(0, ALICE, DEPOSIT_LP - partialLP);
        _assertStake(0, BOB, 0);
        assertEq(lp.balanceOf(address(chef)), DEPOSIT_LP - partialLP);
        _exit(ALICE, DEPOSIT_LP - partialLP);
        _assertStake(0, ALICE, 0);
        assertEq(lp.balanceOf(address(chef)), 0);
        (,,,, uint256 totalStaked) = chef.poolInfo(0);
        assertEq(totalStaked, 0);
        assertEq(tokenA.balanceOf(BOB), 1000 ether);
        assertEq(tokenB.balanceOf(BOB), 1000 ether);
        assertApproxEqAbs(tokenA.balanceOf(ALICE), 1000 ether, 1);
        assertApproxEqAbs(tokenB.balanceOf(ALICE), 1000 ether, 1);
        _assertClean();
    }

    function testTopupPaysExistingRewardsToBeneficiaryAndKeepsBothDepositsWithdrawable() public {
        _stake(ALICE, ALICE);
        vm.warp(block.timestamp + 100);
        _stake(BOB, ALICE);
        _assertStake(0, ALICE, 2 * DEPOSIT_LP);
        _assertStake(0, BOB, 0);
        assertEq(reward.balanceOf(ALICE), 100 ether);
        assertEq(reward.balanceOf(BOB), 0);
        assertEq(tokenA.balanceOf(BOB), 925 ether);
        vm.warp(block.timestamp + 50);
        _exit(ALICE, 2 * DEPOSIT_LP);
        assertEq(reward.balanceOf(ALICE), 150 ether);
        assertEq(lp.balanceOf(address(chef)), 0);
        assertEq(tokenA.balanceOf(ALICE), 1075 ether);
        assertEq(tokenB.balanceOf(ALICE), 1050 ether);
        _assertClean();
    }

    function testControllerFailurePreservesStakeAndEmergencyExitWorks() public {
        _stake(ALICE, ALICE);
        _stake(BOB, BOB);
        vm.warp(block.timestamp + 100);
        failRewardRead = true;
        vm.expectRevert("controller unavailable");
        _exit(ALICE, DEPOSIT_LP);
        _assertStake(0, ALICE, DEPOSIT_LP);
        _assertStake(0, BOB, DEPOSIT_LP);
        vm.startPrank(ALICE);
        chef.emergencyWithdraw(0);
        lp.approve(address(router), DEPOSIT_LP);
        router.removeLiquidity(_remove(DEPOSIT_LP, ALICE));
        vm.stopPrank();
        _assertStake(0, ALICE, 0);
        _assertStake(0, BOB, DEPOSIT_LP);
        assertEq(lp.balanceOf(address(chef)), DEPOSIT_LP);
        assertEq(tokenA.balanceOf(ALICE), 1000 ether);
        assertEq(tokenB.balanceOf(ALICE), 1000 ether);
        assertEq(reward.balanceOf(ALICE), 0);
        _assertClean();
    }

    function testRewardPaymentFailureRollsBackExitAndTopupThenEmergencyReturnsPrincipal() public {
        _stake(ALICE, ALICE);
        vm.warp(block.timestamp + 100);
        failRewardPayment = true;
        vm.expectRevert("reward payment failed");
        _exit(ALICE, DEPOSIT_LP);
        vm.expectRevert("reward payment failed");
        _stake(BOB, ALICE);
        _assertStake(0, ALICE, DEPOSIT_LP);
        assertEq(lp.totalSupply(), DEPOSIT_LP);
        assertEq(tokenA.balanceOf(BOB), 1000 ether);
        assertEq(tokenB.balanceOf(BOB), 1000 ether);
        assertEq(reward.balanceOf(ALICE), 0);
        vm.prank(ALICE);
        chef.emergencyWithdraw(0);
        assertEq(lp.balanceOf(ALICE), DEPOSIT_LP);
        assertEq(lp.balanceOf(address(chef)), 0);
        _assertStake(0, ALICE, 0);
        _assertClean();
    }

    function testInheritedShortRewardPaymentWritesOffRemainderWithoutTrappingPrincipal() public {
        _stake(ALICE, ALICE);
        vm.warp(block.timestamp + 100);
        assertEq(chef.pendingReward(0, ALICE), 100 ether);
        // ApexController also caps payments to its available balance and reward liability.
        // This models a broken funding assumption, not normal fully backed emissions.
        rewardPaymentCap = 40 ether;
        _exit(ALICE, DEPOSIT_LP / 2);
        assertEq(reward.balanceOf(ALICE), 40 ether);
        assertEq(chef.pendingReward(0, ALICE), 0);
        rewardPaymentCap = type(uint256).max;
        _exit(ALICE, DEPOSIT_LP / 2);
        assertEq(reward.balanceOf(ALICE), 40 ether);
        assertEq(tokenA.balanceOf(ALICE), 1000 ether);
        assertEq(tokenB.balanceOf(ALICE), 1000 ether);
        assertEq(lp.balanceOf(address(chef)), 0);
        _assertStake(0, ALICE, 0);
        _assertClean();
    }

    function testKnownInfrastructureRecipientsRevertMintAndUnstake() public {
        address[7] memory recipients = [
            address(0), address(router), address(chef), address(upstream), address(lp), address(tokenA), address(tokenB)
        ];
        for (uint256 i; i < recipients.length; ++i) {
            vm.expectRevert(BrownfiRouter.InvalidAddress.selector);
            vm.prank(ALICE);
            router.addLiquidityAndStake(_add(recipients[i]));
        }
        _stake(ALICE, ALICE);
        for (uint256 i; i < recipients.length; ++i) {
            vm.expectRevert(BrownfiRouter.InvalidAddress.selector);
            vm.prank(ALICE);
            chef.withdrawToAndCall(
                0, DEPOSIT_LP, address(router), abi.encode(uint8(0), _remove(DEPOSIT_LP, recipients[i]))
            );
        }
        _assertStake(0, ALICE, DEPOSIT_LP);
        assertEq(tokenA.balanceOf(ALICE), 925 ether);
        assertEq(tokenB.balanceOf(ALICE), 950 ether);
        _assertClean();
    }

    function testFeeOnTransferInputCannotConsumePrefundedTokens() public {
        tokenA.mint(address(router), 7 ether);
        tokenA.setChargeFee(true);
        vm.expectRevert();
        vm.prank(ALICE);
        router.addLiquidityAndStake(_add(ALICE));
        assertEq(tokenA.balanceOf(ALICE), 1000 ether);
        assertEq(tokenB.balanceOf(ALICE), 1000 ether);
        assertEq(tokenA.balanceOf(address(router)), 7 ether);
        assertEq(tokenA.allowance(address(router), address(upstream)), 0);
        _assertStake(0, ALICE, 0);
        assertEq(lp.totalSupply(), 0);
    }

    function testRejectingNativeRefundRevertsEntireDeposit() public {
        BrownfiSafetyWallet wallet = new BrownfiSafetyWallet();
        tokenA.mint(address(wallet), 100 ether);
        wallet.configure(true, false);
        vm.deal(address(this), 100 ether);
        vm.expectRevert(BrownfiRouter.ETHTransferFailed.selector);
        wallet.add{value: 100 ether}(router, _addETH(address(wallet)));
        assertEq(address(this).balance, 100 ether);
        assertEq(address(wallet).balance, 0);
        assertEq(tokenA.balanceOf(address(wallet)), 100 ether);
        assertEq(nativeLp.totalSupply(), 0);
        _assertStake(1, address(wallet), 0);
        _assertClean();
    }

    function testRejectingNativeOutputRevertsRewardPaymentAndTokenOutputAsWellAsUnstake() public {
        vm.prank(ALICE);
        router.addLiquidityETHAndStake{value: 100 ether}(_addETH(ALICE));
        BrownfiSafetyWallet wallet = new BrownfiSafetyWallet();
        wallet.configure(true, false);
        vm.warp(block.timestamp + 100);
        vm.expectRevert("ETH transfer failed");
        vm.prank(ALICE);
        chef.withdrawToAndCall(
            1, DEPOSIT_LP, address(router), abi.encode(uint8(1), _removeETH(DEPOSIT_LP, address(wallet)))
        );
        assertEq(tokenA.balanceOf(address(wallet)), 0);
        assertEq(address(wallet).balance, 0);
        assertEq(reward.balanceOf(ALICE), 0);
        assertEq(nativeLp.balanceOf(address(chef)), DEPOSIT_LP);
        _assertStake(1, ALICE, DEPOSIT_LP);
        _assertClean();
    }

    function testNativeRefundAndOutputCannotReenterEitherCustodyPath() public {
        BrownfiSafetyWallet wallet = new BrownfiSafetyWallet();
        tokenA.mint(address(wallet), 100 ether);
        wallet.configure(false, true);
        vm.deal(address(this), 100 ether);
        wallet.add{value: 100 ether}(router, _addETH(address(wallet)));
        bytes4 reentrant = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        assertEq(wallet.routerReentryError(), reentrant);
        assertEq(wallet.chefReentryError(), reentrant);
        assertEq(address(wallet).balance, 50 ether);
        _assertStake(1, address(wallet), DEPOSIT_LP);
        wallet.exit(1, _removeETH(DEPOSIT_LP, address(wallet)));
        assertEq(wallet.routerReentryError(), reentrant);
        assertEq(wallet.chefReentryError(), reentrant);
        assertEq(tokenA.balanceOf(address(wallet)), 100 ether);
        assertEq(address(wallet).balance, 100 ether);
        _assertStake(1, address(wallet), 0);
        assertEq(nativeLp.balanceOf(address(chef)), 0);
        _assertClean();
    }
}
