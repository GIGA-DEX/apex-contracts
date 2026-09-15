// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {Test} from "forge-std/Test.sol";

import {IVotingEscrow} from "../src/core/interfaces/IVotingEscrow.sol";
import {VeApexToken} from "../src/core/VeApexToken.sol";

contract VeApexTokenTestToken is ERC20 {
    constructor() ERC20("Apex", "APEX") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract VeApexTokenTest is Test {
    bytes32 internal constant ERC1967_ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    VeApexTokenTestToken internal apex;
    VeApexToken internal veApexToken;

    address internal alice = address(0xA11CE);
    address internal operator = address(0x0BEEF);

    function setUp() public {
        apex = new VeApexTokenTestToken();

        VeApexToken implementation = new VeApexToken();
        bytes memory initData =
            abi.encodeCall(VeApexToken.initialize, (address(apex), address(0), address(this), "Ve GIGA", "veGIGA"));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        veApexToken = VeApexToken(address(proxy));

        apex.mint(alice, 1_000 ether);
        vm.startPrank(alice);
        apex.approve(address(veApexToken), type(uint256).max);
        veApexToken.createLock(100 ether, 26 weeks);
        vm.stopPrank();
    }

    function testTransferFromRejectsZeroAddressRecipient() public {
        vm.prank(alice);
        vm.expectRevert(VeApexToken.ZeroAddress.selector);
        veApexToken.transferFrom(alice, address(0), 1);

        assertEq(veApexToken.ownerOf(1), alice);
    }

    function testMetadataComesFromInitializer() public view {
        assertEq(veApexToken.name(), "Ve GIGA");
        assertEq(veApexToken.symbol(), "veGIGA");
    }

    function testSafeTransferFromRejectsZeroAddressRecipient() public {
        vm.prank(alice);
        vm.expectRevert(VeApexToken.ZeroAddress.selector);
        veApexToken.safeTransferFrom(alice, address(0), 1);

        assertEq(veApexToken.ownerOf(1), alice);
    }

    function testSafeTransferFromWithDataRejectsZeroAddressRecipient() public {
        vm.prank(alice);
        vm.expectRevert(VeApexToken.ZeroAddress.selector);
        veApexToken.safeTransferFrom(alice, address(0), 1, "");

        assertEq(veApexToken.ownerOf(1), alice);
    }

    function testApprovedOperatorCanWithdrawExpiredLock() public {
        vm.prank(alice);
        veApexToken.approve(operator, 1);

        skip(26 weeks + 1);

        uint256 balanceBefore = apex.balanceOf(operator);
        vm.prank(operator);
        veApexToken.withdraw(1);

        assertEq(apex.balanceOf(operator) - balanceBefore, 100 ether);
        vm.expectRevert(VeApexToken.NonExistentToken.selector);
        veApexToken.tokenURI(1);
    }

    function testTotalSupplyAtUsesTimestampCheckpointsLikeVeAero() public {
        uint256 historicalTimestamp = block.timestamp;
        uint256 historicalSupply = veApexToken.totalSupply();
        VeApexToken.GlobalPoint memory point = veApexToken.pointHistory(1);
        VeApexToken.UserPoint memory userPoint = veApexToken.userPointHistory(1, 1);
        assertGt(uint256(uint128(userPoint.bias)), 0);
        assertGt(uint256(uint128(point.bias)), 0);
        assertGt(historicalSupply, 0);

        skip(2 weeks);
        vm.roll(block.number + 100);
        vm.prank(alice);
        veApexToken.createLock(50 ether, 20 weeks);

        assertEq(veApexToken.totalSupplyAt(historicalTimestamp), historicalSupply);
        assertEq(veApexToken.totalSupplyAtT(historicalTimestamp), historicalSupply);
        assertGt(veApexToken.totalSupply(), historicalSupply);
    }

    function testIncreaseAmountUpdatesGlobalSupply() public {
        uint256 supplyBefore = veApexToken.totalSupply();

        skip(1 weeks);
        vm.prank(alice);
        veApexToken.increaseAmount(1, 50 ether);

        assertGt(veApexToken.totalSupply(), supplyBefore);
    }

    function testOwnershipGuardPersistsUntilSolidityBlockNumberAdvances() public {
        uint256 balanceBefore = veApexToken.balanceOfNFT(1);
        assertGt(balanceBefore, 0);

        vm.prank(alice);
        veApexToken.transferFrom(alice, operator, 1);

        assertEq(veApexToken.balanceOfNFT(1), 0);
        vm.warp(block.timestamp + 1 minutes);
        assertEq(veApexToken.balanceOfNFT(1), 0);

        vm.roll(block.number + 1);
        assertGt(veApexToken.balanceOfNFT(1), 0);
    }

    function testVeApexTokenStorageSurvivesImplementationUpgrade() public {
        VeApexToken.GlobalPoint memory pointBefore = veApexToken.pointHistory(1);
        VeApexToken.UserPoint memory userPointBefore = veApexToken.userPointHistory(1, 1);
        IVotingEscrow.LockedBalance memory lockBefore = veApexToken.locked(1);
        uint256 totalSupplyBefore = veApexToken.totalSupply();

        VeApexToken implementation = new VeApexToken();
        ProxyAdmin(_proxyAdmin(address(veApexToken)))
            .upgradeAndCall(ITransparentUpgradeableProxy(payable(address(veApexToken))), address(implementation), "");

        assertEq(veApexToken.token(), address(apex));
        assertEq(veApexToken.team(), address(this));
        assertEq(veApexToken.name(), "Ve GIGA");
        assertEq(veApexToken.symbol(), "veGIGA");
        assertEq(veApexToken.ownerOf(1), alice);
        assertEq(veApexToken.totalSupply(), totalSupplyBefore);

        IVotingEscrow.LockedBalance memory lockAfter = veApexToken.locked(1);
        assertEq(lockAfter.amount, lockBefore.amount);
        assertEq(lockAfter.end, lockBefore.end);

        VeApexToken.GlobalPoint memory pointAfter = veApexToken.pointHistory(1);
        assertEq(pointAfter.bias, pointBefore.bias);
        assertEq(pointAfter.slope, pointBefore.slope);
        assertEq(pointAfter.ts, pointBefore.ts);

        VeApexToken.UserPoint memory userPointAfter = veApexToken.userPointHistory(1, 1);
        assertEq(userPointAfter.bias, userPointBefore.bias);
        assertEq(userPointAfter.slope, userPointBefore.slope);
        assertEq(userPointAfter.ts, userPointBefore.ts);
    }

    function testTotalSupplyAtBeforeFirstCheckpointReturnsZero() public view {
        assertEq(veApexToken.totalSupplyAt(block.timestamp - 1), 0);
    }

    function testClockModeMatchesVeAeroTimestampMode() public view {
        assertEq(veApexToken.clock(), uint48(block.timestamp));
        assertEq(veApexToken.CLOCK_MODE(), "mode=timestamp");
        assertTrue(veApexToken.supportsInterface(type(IERC6372).interfaceId));
    }

    function testFuzzMaxTimeLockDurationIsAcceptedAtEveryWeeklyResidue(uint256 _residue) public {
        _residue = bound(_residue, 0, 1 weeks - 1);
        vm.warp(100 weeks + _residue);
        uint256 maxTime = veApexToken.MAXTIME();

        vm.prank(alice);
        uint256 tokenId = veApexToken.createLock(1 ether, maxTime);

        IVotingEscrow.LockedBalance memory lock = veApexToken.locked(tokenId);
        assertGt(lock.end, block.timestamp);
        assertLe(lock.end, block.timestamp + maxTime);
    }

    function testMaxTimePlusOneCanFailAtWorstCaseWeeklyResidue() public {
        vm.warp(100 weeks + 1 weeks - 1);
        uint256 maxTime = veApexToken.MAXTIME();

        vm.prank(alice);
        vm.expectRevert(VeApexToken.LockDurationTooLong.selector);
        veApexToken.createLock(1 ether, maxTime + 1);
    }

    function testIncreaseUnlockTimeMaxTimeRevertsWhenAlreadyAtRoundedMax() public {
        uint256 maxTime = veApexToken.MAXTIME();

        vm.prank(alice);
        vm.expectRevert(VeApexToken.LockDurationNotInFuture.selector);
        veApexToken.increaseUnlockTime(1, maxTime);
    }

    function testFuzzIncreaseUnlockTimeMaxTimeSucceedsOnceRoundedMaxMovesForward(uint256 _elapsed) public {
        _elapsed = bound(_elapsed, 1 weeks, 25 weeks);
        skip(_elapsed);
        uint256 maxTime = veApexToken.MAXTIME();

        vm.prank(alice);
        veApexToken.increaseUnlockTime(1, maxTime);

        IVotingEscrow.LockedBalance memory lock = veApexToken.locked(1);
        assertGt(lock.end, block.timestamp);
        assertLe(lock.end, block.timestamp + maxTime);
    }

    function _proxyAdmin(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, ERC1967_ADMIN_SLOT))));
    }
}
