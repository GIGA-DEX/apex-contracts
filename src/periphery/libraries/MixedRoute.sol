// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

library MixedRoute {
    uint24 internal constant CLASSIC_FLAG = 0x800000;
    uint24 internal constant CLASSIC_STABLE = 0x800000;
    uint24 internal constant CLASSIC_VOLATILE = 0x800001;

    function hasClassicFlag(uint24 _action) internal pure returns (bool) {
        return _action & CLASSIC_FLAG != 0;
    }

    function stableFromAction(uint24 _action) internal pure returns (bool) {
        if (_action == CLASSIC_STABLE) return true;
        if (_action == CLASSIC_VOLATILE) return false;
        revert("Invalid Classic action");
    }

    function stableFromPancakeFlag(uint256 _flag) internal pure returns (bool) {
        if (_flag == 1) return false;
        if (_flag == 2 || _flag == 3) return true;
        revert("Invalid Classic flag");
    }
}
