// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library FeeReceiverStorage {
    bytes32 internal constant SLOT = keccak256("apex.fee.receiver.storage.v1");

    struct Layout {
        address feeCenter;
        address vault;
        address outputToken;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
