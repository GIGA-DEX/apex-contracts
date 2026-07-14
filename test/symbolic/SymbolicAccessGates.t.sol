// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EmissionCenter} from "../../src/core/EmissionCenter.sol";
import {FeeCenter} from "../../src/core/FeeCenter.sol";
import {FeeReceiver} from "../../src/core/FeeReceiver.sol";
import {ApexErrors} from "../../src/core/libraries/common/ApexErrors.sol";

contract SymbolicAccessGatesTest is Test {
    address internal constant CONTROLLER = address(0xC0117E);
    address internal constant VAULT = address(0xA11CE);
    address internal constant TOKEN = address(0xA9E7);

    function check_emissionCenterRejectsNonControllerRelease(address _caller) public {
        if (_caller == CONTROLLER) return;

        EmissionCenter center = new EmissionCenter(CONTROLLER, uint64(block.timestamp), uint64(7 days));

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, _caller));
        center.release(TOKEN);
    }

    function check_feeCenterRejectsNonControllerReceiverCreation(address _caller) public {
        if (_caller == CONTROLLER) return;

        FeeCenter feeCenter = new FeeCenter();
        FeeReceiver receiverImplementation = new FeeReceiver();
        feeCenter.initialize(CONTROLLER, VAULT, address(receiverImplementation));

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, _caller));
        feeCenter.addReceiver(TOKEN);
    }
}
