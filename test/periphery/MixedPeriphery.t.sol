// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ClassicFactory} from "../../src/core/ClassicFactory.sol";
import {ClassicPool} from "../../src/core/ClassicPool.sol";
import {ICLFactory} from "../../src/core/interfaces/ICLFactory.sol";
import {IApexController} from "../../src/core/interfaces/IApexController.sol";

interface ICLPoolDeployerForMixedTest {
    function setFactoryAddress(address _factory) external;
}

interface INonfungiblePositionManagerForMixedTest {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(address _token0, address _token1, uint24 _fee, uint160 _sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata _params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface ISmartRouterForTest {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata _params) external payable returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata _params) external payable returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata _params) external payable returns (uint256 amountIn);

    function multicall(uint256 _deadline, bytes[] calldata _data) external payable returns (bytes[] memory results);

    function swapExactTokensForTokens(uint256 _amountIn, uint256 _amountOutMin, address[] calldata _path, address _to)
        external
        payable
        returns (uint256 amountOut);

    function exactInputStableSwap(
        address[] calldata _path,
        uint256[] calldata _flags,
        uint256 _amountIn,
        uint256 _amountOutMin,
        address _to
    ) external payable returns (uint256 amountOut);
}

interface IMixedQuoterForTest {
    function quoteExactInput(bytes memory _path, uint256 _amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    function quoteExactInput(bytes memory _path, uint256[] memory _flags, uint256 _amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

contract ApexMixedPeripheryToken is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract ApexMixedPeripheryTest is Test {
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

    function testMixedQuoterAndRouterHandleClassicVolatilePath() public {
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        address tokenOut = ClassicPool(pair).token1();
        bytes memory path = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, tokenOut);

        uint256 quotedAmountOut = _quote(path, 10 ether);
        uint256 amountOut = _swap(path, tokenIn, 10 ether, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
        assertEq(ApexMixedPeripheryToken(tokenOut).balanceOf(bob), 2_000_000 ether + amountOut);
    }

    function testFuzzSmartRouterClassicVolatileQuoteMatchesSwap(uint128 _amountIn) public {
        uint256 amountIn = bound(uint256(_amountIn), 1e6, 100 ether);
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        bytes memory path = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, ClassicPool(pair).token1());

        uint256 quotedAmountOut = _quote(path, amountIn);
        uint256 amountOut = _swap(path, tokenIn, amountIn, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
    }

    function testMixedQuoterAndRouterHandleClassicStablePath() public {
        address pair = _createClassicPair(true);
        address tokenIn = ClassicPool(pair).token0();
        address tokenOut = ClassicPool(pair).token1();
        bytes memory path = abi.encodePacked(tokenIn, CLASSIC_STABLE, tokenOut);

        uint256 quotedAmountOut = _quote(path, 10 ether);
        uint256 amountOut = _swap(path, tokenIn, 10 ether, quotedAmountOut);

        assertGt(quotedAmountOut, 9.9 ether);
        assertEq(amountOut, quotedAmountOut);
    }

    function testMixedQuoterAndRouterHandleCLPath() public {
        _createCLPool(address(tokenA), address(tokenB));
        bytes memory path = abi.encodePacked(address(tokenA), CL_FEE, address(tokenB));

        uint256 quotedAmountOut = _quote(path, 10 ether);
        uint256 amountOut = _swap(path, address(tokenA), 10 ether, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
        assertEq(tokenB.balanceOf(bob), 2_000_000 ether + amountOut);
    }

    function testSmartRouterExactOutputSingleHandlesCLPath() public {
        _createCLPool(address(tokenA), address(tokenB));

        vm.startPrank(bob);
        tokenA.approve(address(smartRouter), 2 ether);
        uint256 amountIn = smartRouter.exactOutputSingle(
            ISmartRouterForTest.ExactOutputSingleParams({
                tokenIn: address(tokenA),
                tokenOut: address(tokenB),
                fee: CL_FEE,
                recipient: bob,
                amountOut: 1 ether,
                amountInMaximum: 2 ether,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        assertGt(amountIn, 0);
        assertLe(amountIn, 2 ether);
        assertEq(tokenB.balanceOf(bob), 2_000_001 ether);
    }

    function testMixedQuoterAndRouterHandleClassicThenCLPath() public {
        address pair = _createClassicPair(false);
        address classicIn = ClassicPool(pair).token0();
        address shared = ClassicPool(pair).token1();
        _createCLPool(shared, address(tokenC));

        bytes memory path = abi.encodePacked(classicIn, CLASSIC_VOLATILE, shared, CL_FEE, address(tokenC));
        uint256 quotedAmountOut = _quote(path, 10 ether);
        uint256 amountOut = _swap(path, classicIn, 10 ether, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
        assertEq(tokenC.balanceOf(bob), 2_000_000 ether + amountOut);
    }

    function testFuzzSmartRouterClassicThenCLQuoteMatchesSwap(uint128 _amountIn) public {
        uint256 amountIn = bound(uint256(_amountIn), 1e6, 50 ether);
        address pair = _createClassicPair(false);
        address classicIn = ClassicPool(pair).token0();
        address shared = ClassicPool(pair).token1();
        _createCLPool(shared, address(tokenC));

        bytes memory path = abi.encodePacked(classicIn, CLASSIC_VOLATILE, shared, CL_FEE, address(tokenC));
        uint256 quotedAmountOut = _quote(path, amountIn);
        uint256 amountOut = _swap(path, classicIn, amountIn, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
    }

    function testMixedQuoterAndRouterHandleCLThenClassicPath() public {
        address pair = _createClassicPair(false);
        address shared = ClassicPool(pair).token0();
        address classicOut = ClassicPool(pair).token1();
        _createCLPool(address(tokenC), shared);

        bytes memory path = abi.encodePacked(address(tokenC), CL_FEE, shared, CLASSIC_VOLATILE, classicOut);
        uint256 quotedAmountOut = _quote(path, 10 ether);
        uint256 amountOut = _swap(path, address(tokenC), 10 ether, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
        assertEq(ApexMixedPeripheryToken(classicOut).balanceOf(bob), 2_000_000 ether + amountOut);
    }

    function testMixedQuoterAndRouterHandleClassicThenClassicPath() public {
        address pair0 = _createClassicPair(address(tokenA), address(tokenB), false);
        address shared = ClassicPool(pair0).token1();
        address pair1 = _createClassicPair(shared, address(tokenC), true);

        bytes memory path =
            abi.encodePacked(ClassicPool(pair0).token0(), CLASSIC_VOLATILE, shared, CLASSIC_STABLE, address(tokenC));
        uint256 quotedAmountOut = _quote(path, 10 ether);
        uint256 amountOut = _swap(path, ClassicPool(pair0).token0(), 10 ether, quotedAmountOut);

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
        assertEq(tokenC.balanceOf(bob), 2_000_000 ether + amountOut);
        assertTrue(pair1 != address(0));
    }

    function testPancakeSmartRouterFlagOverloadCanQuoteVolatileClassicPath() public {
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        address tokenOut = ClassicPool(pair).token1();
        bytes memory apexPath = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, tokenOut);
        bytes memory pancakePath = abi.encodePacked(tokenIn, CLASSIC_STABLE, tokenOut);
        uint256[] memory flags = new uint256[](1);
        flags[0] = 1;

        uint256 apexQuote = _quote(apexPath, 10 ether);
        (uint256 pancakeQuote,,,) = mixedQuoter.quoteExactInput(pancakePath, flags, 10 ether);

        assertEq(pancakeQuote, apexQuote);
    }

    function testPancakeSmartRouterFlagOverloadRejectsExtraFlags() public {
        address pair = _createClassicPair(false);
        bytes memory path = abi.encodePacked(ClassicPool(pair).token0(), CLASSIC_STABLE, ClassicPool(pair).token1());
        uint256[] memory flags = new uint256[](2);
        flags[0] = 1;
        flags[1] = 1;

        vm.expectRevert(bytes("Flag length mismatch"));
        mixedQuoter.quoteExactInput(path, flags, 10 ether);
    }

    function testSmartRouterSupportsPancakeVolatileClassicEntrypoint() public {
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        address tokenOut = ClassicPool(pair).token1();
        bytes memory quotePath = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, tokenOut);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256 quotedAmountOut = _quote(quotePath, 10 ether);
        vm.startPrank(bob);
        ApexMixedPeripheryToken(tokenIn).approve(address(smartRouter), 10 ether);
        uint256 amountOut = smartRouter.swapExactTokensForTokens(10 ether, quotedAmountOut, path, bob);
        vm.stopPrank();

        assertEq(amountOut, quotedAmountOut);
        assertEq(ApexMixedPeripheryToken(tokenOut).balanceOf(bob), 2_000_000 ether + amountOut);
    }

    function testSmartRouterSupportsPancakeStableClassicEntrypoint() public {
        address pair = _createClassicPair(true);
        address tokenIn = ClassicPool(pair).token0();
        address tokenOut = ClassicPool(pair).token1();
        bytes memory quotePath = abi.encodePacked(tokenIn, CLASSIC_STABLE, tokenOut);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory flags = new uint256[](1);
        flags[0] = 2;

        uint256 quotedAmountOut = _quote(quotePath, 10 ether);
        vm.startPrank(bob);
        ApexMixedPeripheryToken(tokenIn).approve(address(smartRouter), 10 ether);
        uint256 amountOut = smartRouter.exactInputStableSwap(path, flags, 10 ether, quotedAmountOut, bob);
        vm.stopPrank();

        assertEq(amountOut, quotedAmountOut);
        assertEq(ApexMixedPeripheryToken(tokenOut).balanceOf(bob), 2_000_000 ether + amountOut);
    }

    function testSmartRouterRevertsWhenSlippageTooHigh() public {
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        bytes memory path = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, ClassicPool(pair).token1());
        uint256 quotedAmountOut = _quote(path, 10 ether);

        vm.startPrank(bob);
        ApexMixedPeripheryToken(tokenIn).approve(address(smartRouter), 10 ether);
        vm.expectRevert(bytes("Too little received"));
        smartRouter.exactInput(
            ISmartRouterForTest.ExactInputParams({
                path: path, recipient: bob, amountIn: 10 ether, amountOutMinimum: quotedAmountOut + 1
            })
        );
        vm.stopPrank();
    }

    function testSmartRouterRevertsWhenDeadlineExpired() public {
        address pair = _createClassicPair(false);
        address tokenIn = ClassicPool(pair).token0();
        bytes memory path = abi.encodePacked(tokenIn, CLASSIC_VOLATILE, ClassicPool(pair).token1());

        vm.warp(100);
        vm.startPrank(bob);
        ApexMixedPeripheryToken(tokenIn).approve(address(smartRouter), 10 ether);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(
            ISmartRouterForTest.exactInput,
            (ISmartRouterForTest.ExactInputParams({
                    path: path, recipient: bob, amountIn: 10 ether, amountOutMinimum: 0
                }))
        );
        vm.expectRevert(bytes("Transaction too old"));
        smartRouter.multicall(99, data);
        vm.stopPrank();
    }

    function testMixedQuoterAndRouterRevertForMissingClassicPair() public {
        bytes memory path = abi.encodePacked(address(tokenA), CLASSIC_VOLATILE, address(tokenC));

        vm.expectRevert(bytes("Classic pair missing"));
        mixedQuoter.quoteExactInput(path, 10 ether);

        vm.startPrank(bob);
        tokenA.approve(address(smartRouter), 10 ether);
        vm.expectRevert(bytes("Classic pair missing"));
        smartRouter.exactInput(
            ISmartRouterForTest.ExactInputParams({path: path, recipient: bob, amountIn: 10 ether, amountOutMinimum: 0})
        );
        vm.stopPrank();
    }

    function testMixedQuoterAndRouterRevertForInvalidClassicAction() public {
        bytes memory path = abi.encodePacked(address(tokenA), uint24(0x800002), address(tokenB));

        vm.expectRevert(bytes("Invalid Classic action"));
        mixedQuoter.quoteExactInput(path, 10 ether);

        vm.startPrank(bob);
        tokenA.approve(address(smartRouter), 10 ether);
        vm.expectRevert(bytes("Invalid Classic action"));
        smartRouter.exactInput(
            ISmartRouterForTest.ExactInputParams({path: path, recipient: bob, amountIn: 10 ether, amountOutMinimum: 0})
        );
        vm.stopPrank();
    }

    function _createClassicPair(bool _stable) internal returns (address pair) {
        pair = _createClassicPair(address(tokenA), address(tokenB), _stable);
    }

    function _createClassicPair(address _tokenA, address _tokenB, bool _stable) internal returns (address pair) {
        pair = classicFactory.createPair(_tokenA, _tokenB, _stable);
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
