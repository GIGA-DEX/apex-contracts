// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ClassicChef} from "../../src/core/ClassicChef.sol";

contract SymbolicChefToken is ERC20 {
    constructor() ERC20("LP", "LP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SymbolicClassicChefWithdrawTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RECIPIENT = address(0xCAFE);

    function check_withdrawToDebitsOnlyCaller(uint8 rawAmount) public {
        uint256 amount = uint256(rawAmount) + 1;
        uint256 aliceDeposit = amount + 1;
        uint256 bobDeposit = amount + 2;

        SymbolicChefToken rewardToken = new SymbolicChefToken();
        SymbolicChefToken lpToken = new SymbolicChefToken();
        ClassicChef chef = new ClassicChef(address(rewardToken), address(this));
        chef.add(100, lpToken);

        lpToken.mint(ALICE, aliceDeposit);
        lpToken.mint(BOB, bobDeposit);

        vm.prank(ALICE);
        lpToken.approve(address(chef), aliceDeposit);
        vm.prank(ALICE);
        chef.deposit(0, aliceDeposit);

        vm.prank(BOB);
        lpToken.approve(address(chef), bobDeposit);
        vm.prank(BOB);
        chef.deposit(0, bobDeposit);

        vm.prank(ALICE);
        chef.withdrawTo(0, amount, RECIPIENT);

        (uint256 aliceAmount,) = chef.userInfo(0, ALICE);
        (uint256 bobAmount,) = chef.userInfo(0, BOB);
        assertEq(aliceAmount, aliceDeposit - amount);
        assertEq(bobAmount, bobDeposit);
        assertEq(lpToken.balanceOf(RECIPIENT), amount);
        assertEq(lpToken.balanceOf(address(chef)), aliceDeposit + bobDeposit - amount);
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
