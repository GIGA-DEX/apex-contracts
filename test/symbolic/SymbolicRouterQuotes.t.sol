// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    ApexMixedPeripheryToken,
    ICLPoolDeployerForMixedTest,
    IMixedQuoterForTest,
    INonfungiblePositionManagerForMixedTest,
    ISmartRouterForTest
} from "../periphery/MixedPeriphery.t.sol";
import {ClassicFactory} from "../../src/core/ClassicFactory.sol";
import {ClassicPool} from "../../src/core/ClassicPool.sol";
import {ICLFactory} from "../../src/core/interfaces/ICLFactory.sol";
import {IApexController} from "../../src/core/interfaces/IApexController.sol";

contract SymbolicRouterQuotesTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint24 internal constant CL_FEE = 3_000;
    uint24 internal constant CLASSIC_STABLE = 0x800000;
    uint24 internal constant CLASSIC_VOLATILE = 0x800001;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    ICLFactory internal clFactory;
    ClassicFactory internal classicFactory;
    INonfungiblePositionManagerForMixedTest internal nfp;
    ISmartRouterForTest internal smartRouter;
    IMixedQuoterForTest internal mixedQuoter;
    ApexMixedPeripheryToken internal tokenA;
    ApexMixedPeripheryToken internal tokenB;
    ApexMixedPeripheryToken internal tokenC;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0xA9E7);
    address internal weth = address(0xBEEF);

    function setUp() public {
        tokenA = new ApexMixedPeripheryToken("Token A", "TKNA");
        tokenB = new ApexMixedPeripheryToken("Token B", "TKNB");
        tokenC = new ApexMixedPeripheryToken("Token C", "TKNC");

        ICLPoolDeployerForMixedTest deployer =
            ICLPoolDeployerForMixedTest(deployCode("core/CLPoolDeployer.sol:CLPoolDeployer"));
        clFactory = ICLFactory(deployCode("core/CLFactory.sol:CLFactory", abi.encode(address(deployer), address(this))));
        deployer.setFactoryAddress(address(clFactory));

        classicFactory = new ClassicFactory(IApexController(address(this)));
        classicFactory.setFeeReceiver(treasury);

        nfp = INonfungiblePositionManagerForMixedTest(
            deployCode(
                "NonfungiblePositionManager.sol:NonfungiblePositionManager",
                abi.encode(address(deployer), address(clFactory), weth, address(0))
            )
        );
        smartRouter = ISmartRouterForTest(
            deployCode(
                "periphery/SmartRouter.sol:SmartRouter",
                abi.encode(address(deployer), address(clFactory), address(classicFactory), weth)
            )
        );
        mixedQuoter = IMixedQuoterForTest(
            deployCode(
                "periphery/MixedQuoter.sol:MixedQuoter",
                abi.encode(address(deployer), address(clFactory), address(classicFactory), weth)
            )
        );

        _mintAll(alice, 2_000_000 ether);
        _mintAll(bob, 2_000_000 ether);
    }

    function fuzzOnly_smartRouterClassicVolatileQuoteMatchesSwap(uint96 _amountIn) public {
        _smartRouterClassicVolatileQuoteMatchesSwap(_amountIn);
    }

    function testFuzz_smartRouterClassicVolatileQuoteMatchesSwap(uint96 _amountIn) public {
        _smartRouterClassicVolatileQuoteMatchesSwap(_amountIn);
    }

    function fuzzOnly_smartRouterClassicThenCLQuoteMatchesSwap(uint96 _amountIn) public {
        _smartRouterClassicThenCLQuoteMatchesSwap(_amountIn);
    }

    function testFuzz_smartRouterClassicThenCLQuoteMatchesSwap(uint96 _amountIn) public {
        _smartRouterClassicThenCLQuoteMatchesSwap(_amountIn);
    }

    function _smartRouterClassicVolatileQuoteMatchesSwap(uint96 _amountIn) internal {
        uint256 amountIn = bound(uint256(_amountIn), 1e6, 100 ether);
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        address tokenOut = ClassicPool(pair).token1();
        bytes memory path = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, tokenOut);

        uint256 quotedAmountOut = _quote(path, amountIn);
        uint256 amountOut = _swap(path, tokenIn, amountIn, quotedAmountOut);

        assertGt(quotedAmountOut, 0, "zero quote");
        assertEq(amountOut, quotedAmountOut, "router output differs from quote");
        assertEq(
            ApexMixedPeripheryToken(tokenOut).balanceOf(bob), 2_000_000 ether + amountOut, "recipient balance mismatch"
        );
    }

    function _smartRouterClassicThenCLQuoteMatchesSwap(uint96 _amountIn) internal {
        uint256 amountIn = bound(uint256(_amountIn), 1e6, 50 ether);
        address pair = _createClassicPair(false);
        address classicIn = ClassicPool(pair).token0();
        address shared = ClassicPool(pair).token1();
        _createCLPool(shared, address(tokenC));

        bytes memory path = abi.encodePacked(classicIn, CLASSIC_VOLATILE, shared, CL_FEE, address(tokenC));
        uint256 quotedAmountOut = _quote(path, amountIn);
        uint256 amountOut = _swap(path, classicIn, amountIn, quotedAmountOut);

        assertGt(quotedAmountOut, 0, "zero mixed-path quote");
        assertEq(amountOut, quotedAmountOut, "mixed-path router output differs from quote");
        assertEq(tokenC.balanceOf(bob), 2_000_000 ether + amountOut, "mixed-path recipient balance mismatch");
    }

    function _createClassicPair(bool _stable) internal returns (address pair) {
        pair = classicFactory.createPair(address(tokenA), address(tokenB), _stable);
        _addClassicLiquidity(pair, 10_000 ether, 10_000 ether);
    }

    function _addClassicLiquidity(address _pair, uint256 _amount0, uint256 _amount1) internal {
        ApexMixedPeripheryToken(ClassicPool(_pair).token0()).mint(_pair, _amount0);
        ApexMixedPeripheryToken(ClassicPool(_pair).token1()).mint(_pair, _amount1);
        ClassicPool(_pair).mint(alice);
    }

    function _createCLPool(address _tokenA, address _tokenB) internal {
        (address token0, address token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
        nfp.createAndInitializePoolIfNecessary(token0, token1, CL_FEE, SQRT_PRICE_1_1);

        vm.startPrank(alice);
        ApexMixedPeripheryToken(token0).approve(address(nfp), type(uint256).max);
        ApexMixedPeripheryToken(token1).approve(address(nfp), type(uint256).max);
        nfp.mint(
            INonfungiblePositionManagerForMixedTest.MintParams({
                token0: token0,
                token1: token1,
                fee: CL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 10_000 ether,
                amount1Desired: 10_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _quote(bytes memory _path, uint256 _amountIn) internal returns (uint256 amountOut) {
        (amountOut,,,) = mixedQuoter.quoteExactInput(_path, _amountIn);
    }

    function _swap(bytes memory _path, address _tokenIn, uint256 _amountIn, uint256 _amountOutMinimum)
        internal
        returns (uint256 amountOut)
    {
        vm.startPrank(bob);
        ApexMixedPeripheryToken(_tokenIn).approve(address(smartRouter), _amountIn);
        amountOut = smartRouter.exactInput(
            ISmartRouterForTest.ExactInputParams({
                path: _path, recipient: bob, amountIn: _amountIn, amountOutMinimum: _amountOutMinimum
            })
        );
        vm.stopPrank();
    }

    function _mintAll(address _to, uint256 _amount) internal {
        tokenA.mint(_to, _amount);
        tokenB.mint(_to, _amount);
        tokenC.mint(_to, _amount);
    }
}
