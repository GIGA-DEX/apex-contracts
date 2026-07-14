// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library FeeCenterStorage {
    bytes32 internal constant SLOT = keccak256("apex.fee.center.storage.v1");

    struct Layout {
        address apexController;
        address vault;
        address implementation;
        mapping(address outputToken => address receiver) receiverForOutput;
        mapping(address receiver => address outputToken) receiverOutput;
        mapping(address swapper => bool whitelisted) isSwapper;
        EnumerableSet.AddressSet activeReceivers;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
