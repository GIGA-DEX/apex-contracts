// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ApexToken} from "../src/core/ApexToken.sol";
import {ApexErrors} from "../src/core/libraries/common/ApexErrors.sol";

contract ApexTokenTest is Test {
    function testApexTokenMintsFixedSupplyToRecipient() public {
        address recipient = address(0xA9E7);
        ApexToken token = new ApexToken(recipient, "Giga", "GIGA");

        assertEq(token.name(), "Giga");
        assertEq(token.symbol(), "GIGA");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(recipient), 1_000_000_000 ether);
    }

    function testApexTokenRejectsZeroRecipient() public {
        vm.expectRevert(ApexErrors.ZERO_ADDRESS.selector);
        new ApexToken(address(0), "Giga", "GIGA");
    }

    function testApexTokenRejectsEmptyMetadata() public {
        vm.expectRevert("GIGA token name is empty");
        new ApexToken(address(0xA9E7), "", "GIGA");

        vm.expectRevert("GIGA token symbol is empty");
        new ApexToken(address(0xA9E7), "Giga", "");
    }
}
