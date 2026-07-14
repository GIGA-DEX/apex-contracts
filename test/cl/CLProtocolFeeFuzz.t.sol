// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ICLFactory} from "../../src/core/interfaces/ICLFactory.sol";
import {ICLPool} from "../../src/core/interfaces/ICLPool.sol";
import {IPancakeV3FlashCallback} from "../../src/core/interfaces/callback/IPancakeV3FlashCallback.sol";
import {IPancakeV3MintCallback} from "../../src/core/interfaces/callback/IPancakeV3MintCallback.sol";

interface ICLPoolDeployerHarness {
    function setFactoryAddress(address factory) external;
}

contract CLProtocolFeeToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address account => uint256 balance) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address _to, uint256 _amount) external {
        balanceOf[_to] += _amount;
        totalSupply += _amount;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount;
        return true;
    }
}

contract CLProtocolFeeFuzzTest is Test, IPancakeV3MintCallback, IPancakeV3FlashCallback {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant CL_PROTOCOL_FEE_DENOMINATOR = 10_000;
    uint256 internal constant CL_PROTOCOL_FEE_SP = 65_536;
    uint256 internal constant CL_SWAP_FEE_DENOMINATOR = 1_000_000;
    uint24 internal constant POOL_FEE = 3_000;
    uint128 internal constant MINT_LIQUIDITY = 1e18;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    ICLFactory internal factory;
    ICLPool internal pool;
    CLProtocolFeeToken internal token0;
    CLProtocolFeeToken internal token1;

    struct FlashRepayment {
        uint256 amount0;
        uint256 amount1;
    }

    function setUp() public {
        CLProtocolFeeToken tokenA = new CLProtocolFeeToken("Token A", "TKNA");
        CLProtocolFeeToken tokenB = new CLProtocolFeeToken("Token B", "TKNB");
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        ICLPoolDeployerHarness deployer = ICLPoolDeployerHarness(deployCode("core/CLPoolDeployer.sol:CLPoolDeployer"));
        factory = ICLFactory(deployCode("core/CLFactory.sol:CLFactory", abi.encode(address(deployer), address(this))));
        deployer.setFactoryAddress(address(factory));

        pool = ICLPool(factory.createPool(address(token0), address(token1), POOL_FEE));
        pool.initialize(SQRT_PRICE_1_1);

        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        pool.mint(address(this), TICK_LOWER, TICK_UPPER, MINT_LIQUIDITY, "");
    }

    function testFuzzProtocolFeeSetterAcceptsFullSafeRange(uint32 _feeProtocol0, uint32 _feeProtocol1) public {
        _feeProtocol0 = uint32(bound(_feeProtocol0, 0, CL_PROTOCOL_FEE_DENOMINATOR));
        _feeProtocol1 = uint32(bound(_feeProtocol1, 0, CL_PROTOCOL_FEE_DENOMINATOR));

        factory.setFeeProtocol(address(pool), _feeProtocol0, _feeProtocol1);
        (,,,,, uint32 feeProtocol,) = pool.slot0();

        assertEq(feeProtocol % CL_PROTOCOL_FEE_SP, _feeProtocol0);
        assertEq(feeProtocol >> 16, _feeProtocol1);
    }

    function testFuzzProtocolFeeSetterRejectsAboveOneHundredPercent(uint32 _feeProtocol0, uint32 _feeProtocol1) public {
        _feeProtocol0 = uint32(bound(_feeProtocol0, CL_PROTOCOL_FEE_DENOMINATOR + 1, type(uint32).max));
        _feeProtocol1 = uint32(bound(_feeProtocol1, 0, CL_PROTOCOL_FEE_DENOMINATOR));

        vm.expectRevert();
        factory.setFeeProtocol(address(pool), _feeProtocol0, _feeProtocol1);

        _feeProtocol0 = uint32(bound(_feeProtocol0, 0, CL_PROTOCOL_FEE_DENOMINATOR));
        _feeProtocol1 = uint32(bound(_feeProtocol1, CL_PROTOCOL_FEE_DENOMINATOR + 1, type(uint32).max));

        vm.expectRevert();
        factory.setFeeProtocol(address(pool), _feeProtocol0, _feeProtocol1);
    }

    function testFuzzProtocolFeeMathConservesFees(uint128 _feeAmount, uint32 _feeProtocol) public pure {
        _feeProtocol = uint32(bound(_feeProtocol, 0, CL_PROTOCOL_FEE_DENOMINATOR));

        uint256 feeAmount = uint256(_feeAmount);
        uint256 protocolFee = (feeAmount * _feeProtocol) / CL_PROTOCOL_FEE_DENOMINATOR;
        uint256 lpFee = feeAmount - protocolFee;

        assertLe(protocolFee, feeAmount);
        assertEq(protocolFee + lpFee, feeAmount);
        if (_feeProtocol == CL_PROTOCOL_FEE_DENOMINATOR) assertEq(lpFee, 0);
    }

    function testFuzzProtocolFeeAboveOneHundredPercentCanExceedFees(uint128 _feeAmount, uint32 _feeProtocol)
        public
        pure
    {
        uint256 feeAmount = bound(uint256(_feeAmount), CL_PROTOCOL_FEE_DENOMINATOR, type(uint128).max);
        _feeProtocol = uint32(bound(_feeProtocol, CL_PROTOCOL_FEE_DENOMINATOR + 1, type(uint32).max));

        uint256 protocolFee = (feeAmount * _feeProtocol) / CL_PROTOCOL_FEE_DENOMINATOR;

        assertGt(protocolFee, feeAmount);
    }

    function testFuzzFlashProtocolFeeMathMatchesPoolAccounting(
        uint32 _feeProtocol0,
        uint32 _feeProtocol1,
        uint128 _amount0,
        uint128 _amount1
    ) public {
        _feeProtocol0 = uint32(bound(_feeProtocol0, 0, CL_PROTOCOL_FEE_DENOMINATOR));
        _feeProtocol1 = uint32(bound(_feeProtocol1, 0, CL_PROTOCOL_FEE_DENOMINATOR));
        uint256 amount0 = bound(uint256(_amount0), 0, 1e17);
        uint256 amount1 = bound(uint256(_amount1), 0, 1e17);

        factory.setFeeProtocol(address(pool), _feeProtocol0, _feeProtocol1);

        uint256 fee0 = _flashFee(amount0);
        uint256 fee1 = _flashFee(amount1);

        pool.flash(address(this), amount0, amount1, abi.encode(FlashRepayment({amount0: amount0, amount1: amount1})));

        (uint128 protocolFees0, uint128 protocolFees1) = pool.protocolFees();
        assertEq(protocolFees0, (fee0 * _feeProtocol0) / CL_PROTOCOL_FEE_DENOMINATOR);
        assertEq(protocolFees1, (fee1 * _feeProtocol1) / CL_PROTOCOL_FEE_DENOMINATOR);
    }

    function pancakeV3MintCallback(uint256 _amount0Owed, uint256 _amount1Owed, bytes calldata) external override {
        token0.transfer(msg.sender, _amount0Owed);
        token1.transfer(msg.sender, _amount1Owed);
    }

    function pancakeV3FlashCallback(uint256 _fee0, uint256 _fee1, bytes calldata _data) external override {
        FlashRepayment memory repayment = abi.decode(_data, (FlashRepayment));
        token0.transfer(msg.sender, repayment.amount0 + _fee0);
        token1.transfer(msg.sender, repayment.amount1 + _fee1);
    }

    function _flashFee(uint256 _amount) internal pure returns (uint256 fee) {
        fee = (_amount * POOL_FEE) / CL_SWAP_FEE_DENOMINATOR;
        if ((_amount * POOL_FEE) % CL_SWAP_FEE_DENOMINATOR != 0) fee++;
    }
}
