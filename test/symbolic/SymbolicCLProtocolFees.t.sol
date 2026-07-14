// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

contract SymbolicCLProtocolFeesTest is Test {
    uint256 internal constant CL_PROTOCOL_FEE_DENOMINATOR = 10_000;
    uint256 internal constant CL_SWAP_FEE_DENOMINATOR = 1_000_000;
    uint24 internal constant POOL_FEE = 3_000;

    function fuzzOnly_protocolFeeMathConservesFeesWhenFeeIsBounded(uint16 _feeAmount, uint16 _feeProtocol) public pure {
        if (_feeProtocol > CL_PROTOCOL_FEE_DENOMINATOR) return;
        _protocolFeeMathConservesFeesWhenFeeIsBounded(_feeAmount, _feeProtocol);
    }

    function testFuzz_protocolFeeMathConservesFeesWhenFeeIsBounded(uint128 _feeAmount, uint16 _feeProtocol)
        public
        pure
    {
        uint256 feeProtocol = uint256(_feeProtocol) % (CL_PROTOCOL_FEE_DENOMINATOR + 1);
        _protocolFeeMathConservesFeesWhenFeeIsBounded(_feeAmount, feeProtocol);
    }

    function fuzzOnly_flashFeeNeverExceedsAmountForProtocolFeeAtOrBelowOneHundredPercent(
        uint16 _amount,
        uint16 _feeProtocol
    ) public pure {
        if (_feeProtocol > CL_PROTOCOL_FEE_DENOMINATOR) return;
        _flashFeeNeverExceedsAmountForProtocolFeeAtOrBelowOneHundredPercent(_amount, _feeProtocol);
    }

    function testFuzz_flashFeeNeverExceedsAmountForProtocolFeeAtOrBelowOneHundredPercent(
        uint128 _amount,
        uint16 _feeProtocol
    ) public pure {
        uint256 feeProtocol = uint256(_feeProtocol) % (CL_PROTOCOL_FEE_DENOMINATOR + 1);
        _flashFeeNeverExceedsAmountForProtocolFeeAtOrBelowOneHundredPercent(_amount, feeProtocol);
    }

    function _protocolFeeMathConservesFeesWhenFeeIsBounded(uint256 _feeAmount, uint256 _feeProtocol) internal pure {
        uint256 feeAmount = uint256(_feeAmount);
        uint256 feeProtocol = uint256(_feeProtocol);
        uint256 protocolFee = (feeAmount * feeProtocol) / CL_PROTOCOL_FEE_DENOMINATOR;
        uint256 lpFee = feeAmount - protocolFee;

        assert(protocolFee <= feeAmount);
        assert(protocolFee + lpFee == feeAmount);
        if (feeProtocol == CL_PROTOCOL_FEE_DENOMINATOR) assert(lpFee == 0);
    }

    function _flashFeeNeverExceedsAmountForProtocolFeeAtOrBelowOneHundredPercent(uint256 _amount, uint256 _feeProtocol)
        internal
        pure
    {
        uint256 amount = uint256(_amount);
        uint256 feeProtocol = uint256(_feeProtocol);
        uint256 flashFee = _flashFee(amount);
        uint256 protocolFee = (flashFee * feeProtocol) / CL_PROTOCOL_FEE_DENOMINATOR;
        uint256 lpFee = flashFee - protocolFee;

        assert(protocolFee <= flashFee);
        assert(protocolFee + lpFee == flashFee);
    }

    function _flashFee(uint256 _amount) internal pure returns (uint256 fee) {
        fee = (_amount * POOL_FEE) / CL_SWAP_FEE_DENOMINATOR;
        if ((_amount * POOL_FEE) % CL_SWAP_FEE_DENOMINATOR != 0) fee++;
    }
}
