// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

import {ApexController} from "../../src/core/ApexController.sol";
import {ClassicFactory} from "../../src/core/ClassicFactory.sol";
import {IApexController} from "../../src/core/interfaces/IApexController.sol";
import {IFeeCenter} from "../../src/core/interfaces/IFeeCenter.sol";
import {ApexErrors} from "../../src/core/libraries/common/ApexErrors.sol";
import {PoolAddress} from "../../src/periphery/libraries/PoolAddress.sol";

interface ICLFactoryHarness {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function owner() external view returns (address);
    function poolDeployer() external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function setOwner(address owner) external;
    function setFeeProtocol(address pool, uint32 feeProtocol0, uint32 feeProtocol1) external;
}

interface ICLPoolHarness {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function initialize(uint160 sqrtPriceX96) external;

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}

interface ICLPoolDeployerHarness {
    function setFactoryAddress(address factory) external;
    function factoryAddress() external view returns (address);
    function factoryAddressSetter() external view returns (address);
}

contract ApexProtocolMock {
    address public immutable rewardToken;
    address public immutable apexController;
    address public immutable vault;
    mapping(address pool => IFeeCenter.CreatorFeeConfig config) internal _creatorFeeConfigs;

    constructor(address _rewardToken, address _apexController) {
        rewardToken = _rewardToken;
        apexController = _apexController;
        vault = address(this);
    }

    function setCreatorFeeConfig(address pool, address recipient, uint16 feeBps, uint8 poolKind) external {
        _creatorFeeConfigs[pool] =
            IFeeCenter.CreatorFeeConfig({recipient: recipient, feeBps: feeBps, poolKind: poolKind});
    }

    function creatorFeeConfig(address pool) external view returns (IFeeCenter.CreatorFeeConfig memory config) {
        return _creatorFeeConfigs[pool];
    }
}

contract CLFactoryTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    ICLFactoryHarness internal factory;
    ICLPoolDeployerHarness internal deployer;

    address internal tokenA = address(0xA11CE);
    address internal tokenB = address(0xB0B);

    function setUp() public {
        (factory, deployer) = _deployFactory(address(this));
    }

    function testCreateCLPoolFromFactory() public {
        address pool = factory.createPool(tokenA, tokenB, 500);

        assertEq(factory.getPool(tokenA, tokenB, 500), pool);
        assertEq(factory.getPool(tokenB, tokenA, 500), pool);
        assertEq(factory.owner(), address(this));
        assertEq(factory.poolDeployer(), address(deployer));

        ICLPoolHarness clPool = ICLPoolHarness(pool);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        assertEq(clPool.factory(), address(factory));
        assertEq(clPool.token0(), token0);
        assertEq(clPool.token1(), token1);
        assertEq(clPool.fee(), 500);
        assertEq(clPool.tickSpacing(), 10);
    }

    function testOnlyDeployerCanBindCLFactory() public {
        ICLPoolDeployerHarness deployedDeployer =
            ICLPoolDeployerHarness(deployCode("core/CLPoolDeployer.sol:CLPoolDeployer"));

        assertEq(deployedDeployer.factoryAddressSetter(), address(this));

        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("not factory address setter"));
        deployedDeployer.setFactoryAddress(address(factory));

        deployedDeployer.setFactoryAddress(address(factory));
        assertEq(deployedDeployer.factoryAddress(), address(factory));

        vm.expectRevert(bytes("already initialized"));
        deployedDeployer.setFactoryAddress(address(0xCAFE));
    }

    function testCLFactoryBindingRejectsZeroAddress() public {
        ICLPoolDeployerHarness deployedDeployer =
            ICLPoolDeployerHarness(deployCode("core/CLPoolDeployer.sol:CLPoolDeployer"));

        vm.expectRevert(bytes("zero factory address"));
        deployedDeployer.setFactoryAddress(address(0));
    }

    function testCLPoolInitCodeHashMatchesCurrentCreationCode() public {
        uint24 fee = 500;
        address pool = factory.createPool(tokenA, tokenB, fee);
        PoolAddress.PoolKey memory key = PoolAddress.getPoolKey(tokenA, tokenB, fee);
        bytes32 currentInitCodeHash = keccak256(vm.getCode("core/CLPool.sol:CLPool"));
        bytes32 salt = keccak256(abi.encode(key.token0, key.token1, fee));

        assertEq(
            PoolAddress.computeAddress(address(deployer), key),
            _computeCreate2(address(deployer), salt, currentInitCodeHash)
        );
        assertEq(pool, _computeCreate2(address(deployer), salt, currentInitCodeHash));
    }

    function testCLFactoryEnablesDefaultFeeTiers() public view {
        assertEq(factory.feeAmountTickSpacing(100), 1);
        assertEq(factory.feeAmountTickSpacing(200), 4);
        assertEq(factory.feeAmountTickSpacing(500), 10);
        assertEq(factory.feeAmountTickSpacing(1000), 20);
        assertEq(factory.feeAmountTickSpacing(2000), 40);
        assertEq(factory.feeAmountTickSpacing(3000), 60);
        assertEq(factory.feeAmountTickSpacing(10000), 200);
        assertEq(factory.feeAmountTickSpacing(20000), 400);
        assertEq(factory.feeAmountTickSpacing(2500), 0);
    }

    function testCLPoolAllowsOneHundredPercentProtocolFee() public {
        address pool = factory.createPool(tokenA, tokenB, 3000);
        ICLPoolHarness(pool).initialize(SQRT_PRICE_1_1);

        factory.setFeeProtocol(pool, 10_000, 10_000);
        (,,,,, uint32 feeProtocol,) = ICLPoolHarness(pool).slot0();

        assertEq(feeProtocol % 65_536, 10_000);
        assertEq(feeProtocol >> 16, 10_000);
    }

    function testCLPoolInitializationFallbackRemainsTenPercent() public {
        address pool = factory.createPool(tokenA, tokenB, 3000);
        ICLPoolHarness(pool).initialize(SQRT_PRICE_1_1);

        (,,,,, uint32 feeProtocol,) = ICLPoolHarness(pool).slot0();
        assertEq(feeProtocol % 65_536, 1_000);
        assertEq(feeProtocol >> 16, 1_000);
    }

    function testCLPoolRejectsProtocolFeeAboveOneHundredPercent() public {
        address pool = factory.createPool(tokenA, tokenB, 3000);
        ICLPoolHarness(pool).initialize(SQRT_PRICE_1_1);

        vm.expectRevert();
        factory.setFeeProtocol(pool, 10_001, 10_000);

        vm.expectRevert();
        factory.setFeeProtocol(pool, 10_000, 10_001);
    }

    function testApexControllerOverridesCLProtocolFee() public {
        (ApexController controller, ICLFactoryHarness controllerFactory) =
            _deployControllerAndFactory(address(this), address(0xA9E7));

        address pool = controllerFactory.createPool(tokenA, tokenB, 3000);
        ICLPoolHarness(pool).initialize(SQRT_PRICE_1_1);

        controller.overrideCLProtocolFee(pool, 10_000, 10_000);

        (,,,,, uint32 feeProtocol,) = ICLPoolHarness(pool).slot0();
        assertEq(feeProtocol % 65_536, 10_000);
        assertEq(feeProtocol >> 16, 10_000);
    }

    function testApexControllerCreatesAndRegistersLauncherPoolThroughCanonicalFactory() public {
        (ApexController controller, ICLFactoryHarness controllerFactory) =
            _deployControllerAndFactory(address(this), address(0xA9E7));
        address recipient = address(0xC0FFEE);
        controller.configureLauncher(
            address(this), recipient, 500, 1_500, false, IApexController.LauncherPermission.CL, true
        );

        address pool = controller.createLauncherCLPool(tokenA, tokenB, 3000, SQRT_PRICE_1_1);

        assertEq(controllerFactory.getPool(tokenA, tokenB, 3000), pool);
        (,,,,, uint32 feeProtocol,) = ICLPoolHarness(pool).slot0();
        assertEq(feeProtocol % 65_536, 2_000);
        assertEq(feeProtocol >> 16, 2_000);
        ApexProtocolMock feeCenter = ApexProtocolMock(controller.feeCenter());
        IFeeCenter.CreatorFeeConfig memory config = feeCenter.creatorFeeConfig(pool);
        assertEq(config.recipient, recipient);
        assertEq(config.feeBps, 500);
        assertEq(config.poolKind, uint8(IApexController.PoolKind.CL));
    }

    function testApexControllerRejectsNonCanonicalCLProtocolFeeOverride() public {
        (ApexController controller,) = _deployControllerAndFactory(address(this), address(0xA9E7));
        address pool = factory.createPool(tokenA, tokenB, 3000);
        ICLPoolHarness(pool).initialize(SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.INVALID_POOL.selector, pool));
        controller.overrideCLProtocolFee(pool, 10_000, 10_000);
    }

    function _deployFactory(address owner_)
        internal
        returns (ICLFactoryHarness deployedFactory, ICLPoolDeployerHarness deployedDeployer)
    {
        deployedDeployer = ICLPoolDeployerHarness(deployCode("core/CLPoolDeployer.sol:CLPoolDeployer"));
        deployedFactory = ICLFactoryHarness(
            deployCode("core/CLFactory.sol:CLFactory", abi.encode(address(deployedDeployer), owner_))
        );
        deployedDeployer.setFactoryAddress(address(deployedFactory));
    }

    function _deployControllerAndFactory(address admin, address treasury_)
        internal
        returns (ApexController controller_, ICLFactoryHarness clFactory_)
    {
        ApexController implementation = new ApexController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, "");
        controller_ = ApexController(address(proxy));
        ClassicFactory classicFactory = new ClassicFactory(controller_);
        (clFactory_,) = _deployFactory(address(controller_));
        ApexProtocolMock protocolMock = new ApexProtocolMock(address(0xA9E7), address(controller_));

        controller_.initialize(IApexController.InitParams({admin: admin, treasury: treasury_}));
        controller_.initializeProtocol(
            IApexController.ProtocolParams({
                rewardToken: address(0xA9E7),
                classicFactory: address(classicFactory),
                clFactory: address(clFactory_),
                classicChef: address(protocolMock),
                clMasterChef: address(protocolMock),
                apexVault: address(protocolMock),
                feeCenter: address(protocolMock)
            })
        );
    }

    function _computeCreate2(address deployer_, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer_, salt, initCodeHash)))));
    }
}
