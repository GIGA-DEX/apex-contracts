// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {ApexController} from "../../src/core/ApexController.sol";
import {ClassicFactory} from "../../src/core/ClassicFactory.sol";
import {ClassicPool} from "../../src/core/ClassicPool.sol";
import {IApexController} from "../../src/core/interfaces/IApexController.sol";
import {ApexErrors} from "../../src/core/libraries/common/ApexErrors.sol";

contract ApexMockERC20 is ERC20 {
    uint8 private immutable _apexDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _apexDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _apexDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ApexProtocolMock {
    address public immutable rewardToken;
    address public immutable apexController;
    address public immutable owner;
    address public immutable vault;

    constructor(address _rewardToken, address _apexController) {
        rewardToken = _rewardToken;
        apexController = _apexController;
        owner = _apexController;
        vault = address(this);
    }
}

contract ClassicFactoryTest is Test {
    event SetPairFee(address indexed pair, uint256 indexed fee);

    ApexController internal controller;
    ClassicFactory internal factory;
    ApexMockERC20 internal tokenA;
    ApexMockERC20 internal tokenB;

    address internal treasury = address(0xA9E7);
    address internal feeCenter;
    address internal lp = address(0xBEEF);
    address internal trader = address(0xCAFE);

    function setUp() public {
        controller = _deployControllerProxy(address(this));
        factory = new ClassicFactory(controller);
        _initializeController(address(this), treasury, address(factory));

        tokenA = new ApexMockERC20("Apex Token A", "APXA", 18);
        tokenB = new ApexMockERC20("Apex Token B", "APXB", 18);
    }

    function testCreateVolatileAndStableApexPairs() public {
        address volatilePair = factory.createPair(address(tokenA), address(tokenB), false);
        address stablePair = factory.createPair(address(tokenA), address(tokenB), true);

        assertTrue(factory.isPair(volatilePair));
        assertTrue(factory.isPair(stablePair));
        assertNotEq(volatilePair, stablePair);
        assertEq(factory.allPairsLength(), 2);

        ClassicPool volatile = ClassicPool(volatilePair);
        ClassicPool stable = ClassicPool(stablePair);

        assertFalse(volatile.stable());
        assertTrue(stable.stable());
        string memory symbol0 = IERC20Metadata(volatile.token0()).symbol();
        string memory symbol1 = IERC20Metadata(volatile.token1()).symbol();
        assertEq(volatile.name(), string.concat("Giga Volatile AMM - ", symbol0, "/", symbol1));
        assertEq(stable.name(), string.concat("Giga Stable AMM - ", symbol0, "/", symbol1));
        assertEq(volatile.fee(), 3000);
        assertEq(volatile.protocolFee(), 200_000);
        assertEq(volatile.feeReceiver(), feeCenter);
        assertEq(factory.pairFee(volatilePair), 3000);
    }

    function testClassicPoolInitCodeHashMatchesCurrentCreationCode() public {
        address pair = factory.createPair(address(tokenA), address(tokenB), false);
        (address token0, address token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        bytes32 currentInitCodeHash = keccak256(type(ClassicPool).creationCode);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, false));

        assertEq(factory.pairCodeHash(), currentInitCodeHash);
        assertEq(pair, _computeCreate2(address(factory), salt, currentInitCodeHash));
    }

    function testApexControllerControlsFactoryFees() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(0xBAD)));
        factory.setFee(4000);

        controller.setClassicGlobalFee(4000);
        assertEq(factory.fee(), 4000);

        address pair = factory.createPair(address(tokenA), address(tokenB), false);
        controller.overrideClassicFee(pair, 9000);
        assertEq(ClassicPool(pair).fee(), 9000);
        assertEq(factory.pairFee(pair), 9000);

        vm.expectEmit(true, true, false, true, address(factory));
        emit SetPairFee(pair, 4000);
        controller.overrideClassicFee(pair, 0);
        assertEq(ClassicPool(pair).fee(), 4000);
        assertEq(factory.pairFee(pair), 4000);

        controller.overrideClassicProtocolFee(pair, 123_456);
        assertEq(ClassicPool(pair).protocolFee(), 123_456);
    }

    function testStablePairUsesStableCurve() public {
        address pair = factory.createPair(address(tokenA), address(tokenB), true);
        _addLiquidity(pair, 1_000 ether, 1_000 ether);

        uint256 amountOut = ClassicPool(pair).getAmountOut(10 ether, ClassicPool(pair).token0());

        assertGt(amountOut, 9.9 ether);
    }

    function testStableInitialLiquidityRequiresBalancedRatio() public {
        address pair = factory.createPair(address(tokenA), address(tokenB), true);
        _mintPairToken(ClassicPool(pair).token0(), pair, 1_000 ether);
        _mintPairToken(ClassicPool(pair).token1(), pair, 900 ether);

        vm.expectRevert(ApexErrors.UNSTABLE_RATIO.selector);
        ClassicPool(pair).mint(lp);
    }

    function testOneHundredPercentProtocolFeeMintsProtocolFeeReceiverLiquidity() public {
        controller.setClassicGlobalProtocolFee(1_000_000);
        address pair = factory.createPair(address(tokenA), address(tokenB), false);
        _addLiquidity(pair, 1_000 ether, 1_000 ether);

        address tokenIn = ClassicPool(pair).token0();
        uint256 amountOut = ClassicPool(pair).getAmountOut(100 ether, tokenIn);
        _mintPairToken(tokenIn, pair, 100 ether);
        ClassicPool(pair).swap(0, amountOut, trader, "");

        uint256 feeCenterBalanceBefore = IERC20(pair).balanceOf(feeCenter);
        ClassicPool(pair).mintFee();
        uint256 feeCenterBalanceAfter = IERC20(pair).balanceOf(feeCenter);

        assertEq(ClassicPool(pair).protocolFee(), 1_000_000);
        assertGt(feeCenterBalanceAfter, feeCenterBalanceBefore);
    }

    function testApexControllerControlsClassicFeeReceivers() public {
        address pair = factory.createPair(address(tokenA), address(tokenB), false);
        address feeReceiver = address(0xFEE5);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(0xBAD)));
        factory.setFeeReceiver(address(0xA9E8));

        vm.expectRevert(ApexErrors.ZERO_ADDRESS.selector);
        controller.overrideClassicFeeReceiver(pair, address(0));

        controller.overrideClassicFeeReceiver(pair, feeReceiver);

        assertEq(ClassicPool(pair).feeReceiver(), feeReceiver);

        address globalFeeReceiver = address(0xFEE6);
        controller.setClassicGlobalFeeReceiver(globalFeeReceiver);
        ApexMockERC20 tokenC = new ApexMockERC20("Apex Token C", "APXC", 18);
        address newPair = factory.createPair(address(tokenA), address(tokenC), false);

        assertEq(factory.feeReceiver(), globalFeeReceiver);
        assertEq(ClassicPool(newPair).feeReceiver(), globalFeeReceiver);
        assertEq(ClassicPool(pair).feeReceiver(), feeReceiver);
    }

    function testApexControllerInitializesClassicFactoryRouting() public {
        ApexController freshController = _deployControllerProxy(address(this));
        ClassicFactory freshFactory = new ClassicFactory(freshController);
        ApexProtocolMock protocolMock = new ApexProtocolMock(address(0xA9E7), address(freshController));

        freshController.initialize(IApexController.InitParams({admin: address(this), treasury: treasury}));
        freshController.initializeProtocol(
            IApexController.ProtocolParams({
                rewardToken: address(0xA9E7),
                classicFactory: address(freshFactory),
                clFactory: address(protocolMock),
                classicChef: address(protocolMock),
                clMasterChef: address(protocolMock),
                apexVault: address(protocolMock),
                feeCenter: address(protocolMock)
            })
        );

        assertEq(address(freshController.classicFactory()), address(freshFactory));
        assertEq(freshFactory.feeReceiver(), address(protocolMock));
    }

    function _addLiquidity(address pair, uint256 amount0, uint256 amount1) internal {
        _mintPairToken(ClassicPool(pair).token0(), pair, amount0);
        _mintPairToken(ClassicPool(pair).token1(), pair, amount1);
        ClassicPool(pair).mint(lp);
    }

    function _mintPairToken(address token, address to, uint256 amount) internal {
        ApexMockERC20(token).mint(to, amount);
    }

    function _deployControllerProxy(address admin) internal returns (ApexController controller_) {
        ApexController implementation = new ApexController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, "");
        controller_ = ApexController(address(proxy));
    }

    function _initializeController(address admin, address treasury_, address classicFactory) internal {
        ApexProtocolMock protocolMock = new ApexProtocolMock(address(0xA9E7), address(controller));
        feeCenter = address(protocolMock);

        controller.initialize(IApexController.InitParams({admin: admin, treasury: treasury_}));
        controller.initializeProtocol(
            IApexController.ProtocolParams({
                rewardToken: address(0xA9E7),
                classicFactory: classicFactory,
                clFactory: address(protocolMock),
                classicChef: address(protocolMock),
                clMasterChef: address(protocolMock),
                apexVault: address(protocolMock),
                feeCenter: feeCenter
            })
        );
    }

    function _computeCreate2(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initCodeHash)))));
    }
}
