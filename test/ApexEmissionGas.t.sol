// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test, console2} from "forge-std/Test.sol";

import {ApexController} from "../src/core/ApexController.sol";
import {ClassicChef} from "../src/core/ClassicChef.sol";
import {ClassicFactory} from "../src/core/ClassicFactory.sol";
import {ClassicPool} from "../src/core/ClassicPool.sol";
import {CLMasterChef} from "../src/core/CLMasterChef.sol";
import {ApexVault} from "../src/core/ApexVault.sol";
import {IApexController} from "../src/core/interfaces/IApexController.sol";
import {IFeeCenter} from "../src/core/interfaces/IFeeCenter.sol";

contract ApexGasToken is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract ApexGasVeNFT is ERC721 {
    uint256 public constant MAXTIME = 26 weeks;

    constructor() ERC721("VeApexToken", "veTOKEN") {}

    function balanceOfNFT(uint256) external pure returns (uint256) {
        return 1 ether;
    }
}

contract ApexGasCLPositionManager is ERC721 {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 => Position) public positionInfo;

    constructor() ERC721("Apex CL Position", "apexCL") {}

    function WETH9() external pure returns (address) {
        return address(0xBEEF);
    }

    function mintPosition(
        address _to,
        uint256 _tokenId,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _liquidity
    ) external {
        positionInfo[_tokenId] = Position({
            token0: _token0,
            token1: _token1,
            fee: _fee,
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            liquidity: _liquidity
        });
        _mint(_to, _tokenId);
    }

    function positions(uint256 _tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = positionInfo[_tokenId];
        return (
            nonce,
            operator,
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1
        );
    }
}

contract ApexGasCLPool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint128 public constant maxLiquidityPerTick = type(uint128).max;

    address public lmPool;
    uint32 public feeProtocol;

    constructor(address _factory, address _token0, address _token1, uint24 _fee) {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
    }

    function setLmPool(address _lmPool) external {
        lmPool = _lmPool;
    }

    function setFeeProtocol(uint32 _feeProtocol0, uint32 _feeProtocol1) external {
        feeProtocol = _feeProtocol0 + (_feeProtocol1 << 16);
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol_,
            bool unlocked
        )
    {
        return (
            sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinalityNext, feeProtocol, true
        );
    }
}

contract ApexGasCLFactory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
    address public owner;
    address public lmPoolDeployer;

    function setOwner(address _owner) external {
        owner = _owner;
    }

    function setPool(address _token0, address _token1, uint24 _fee, address _pool) external {
        getPool[_token0][_token1][_fee] = _pool;
        getPool[_token1][_token0][_fee] = _pool;
    }

    function setFeeProtocol(address _pool, uint32 _feeProtocol0, uint32 _feeProtocol1) external {
        ApexGasCLPool(_pool).setFeeProtocol(_feeProtocol0, _feeProtocol1);
    }

    function setLmPoolDeployer(address _lmPoolDeployer) external {
        lmPoolDeployer = _lmPoolDeployer;
    }

    function setLmPool(address _pool, address _lmPool) external {
        require(msg.sender == lmPoolDeployer, "Not LM pool deployer");
        ApexGasCLPool(_pool).setLmPool(_lmPool);
    }
}

contract ApexGasFeeCenterMock {
    address public immutable apexController;
    address public immutable vault;

    constructor(address _apexController, address _vault) {
        apexController = _apexController;
        vault = _vault;
    }

    function creatorFeeConfig(address) external pure returns (IFeeCenter.CreatorFeeConfig memory config) {
        return config;
    }
}

contract ApexEmissionGasTest is Test {
    uint256 internal constant FARM_COUNT = 100;
    uint24 internal constant CL_FEE = 3_000;
    int24 internal constant TICK_LOWER = -60;
    int24 internal constant TICK_UPPER = 60;

    ApexController internal controller;
    ClassicFactory internal classicFactory;
    ClassicChef internal classicChef;
    CLMasterChef internal clChef;
    ApexVault internal vault;
    ApexGasVeNFT internal veNFT;
    ApexGasCLPositionManager internal clNfp;
    ApexGasCLFactory internal clFactory;
    ApexGasToken internal apex;

    address internal treasury = address(0xA9E7);
    address internal feeCenter = address(0xFEECE);
    address internal alice = address(0xA11CE);

    address[] internal classicPools;
    address[] internal clPools;

    function setUp() public {
        apex = new ApexGasToken("Apex", "APEX");
        veNFT = new ApexGasVeNFT();
        clNfp = new ApexGasCLPositionManager();
        clFactory = new ApexGasCLFactory();

        controller = _deployControllerProxy(address(this));
        clFactory.setOwner(address(controller));
        classicFactory = new ClassicFactory(controller);
        classicChef = new ClassicChef(address(apex), address(controller));
        clChef = new CLMasterChef(address(apex), address(controller), address(clNfp));
        vault = _deployVaultProxy(address(veNFT), address(controller));
        feeCenter = address(new ApexGasFeeCenterMock(address(controller), address(vault)));

        controller.initialize(IApexController.InitParams({admin: address(this), treasury: treasury}));
        controller.initializeProtocol(
            IApexController.ProtocolParams({
                rewardToken: address(apex),
                classicFactory: address(classicFactory),
                clFactory: address(clFactory),
                classicChef: address(classicChef),
                clMasterChef: address(clChef),
                apexVault: address(vault),
                feeCenter: feeCenter
            })
        );

        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));
        controller.setLmPoolDeployer(lmPoolDeployer);

        apex.mint(address(controller), 1_000_000 ether);
        apex.mint(address(controller), 1_000_000 ether);
    }

    function testGasCurrentRebalanceOneHundredClassicAndClFarms() public {
        _seedClassicFarms(FARM_COUNT);
        _seedCLFarms(FARM_COUNT);
        _primeEmissions();
        skip(1 days);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](FARM_COUNT * 2);
        for (uint256 i; i < FARM_COUNT; ++i) {
            weights[i] = IApexController.EmissionWeight({
                kind: IApexController.PoolKind.CLASSIC, pool: classicPools[i], allocPoint: i + 1
            });
            weights[FARM_COUNT + i] = IApexController.EmissionWeight({
                kind: IApexController.PoolKind.CL, pool: clPools[i], allocPoint: FARM_COUNT - i
            });
        }
        _sortEmissionWeights(weights);

        uint256 gasBefore = gasleft();
        controller.rebalanceEmissions(20_000 ether, 7 days, weights);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("rebalanceEmissions 100 Classic + 100 CL farms gas", gasUsed);
    }

    function testGasCurrentRebalanceOneHundredClassicFarms() public {
        _seedClassicFarms(FARM_COUNT);
        _primeClassicEmissions();
        skip(1 days);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](FARM_COUNT);
        for (uint256 i; i < FARM_COUNT; ++i) {
            weights[i] = IApexController.EmissionWeight({
                kind: IApexController.PoolKind.CLASSIC, pool: classicPools[i], allocPoint: i + 1
            });
        }
        _sortEmissionWeights(weights);

        uint256 gasBefore = gasleft();
        controller.rebalanceEmissions(10_000 ether, 7 days, weights);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("rebalanceEmissions 100 Classic farms gas", gasUsed);
    }

    function testGasCurrentRebalanceOneHundredClFarms() public {
        _seedCLFarms(FARM_COUNT);
        _primeCLEmissions();
        skip(1 days);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](FARM_COUNT);
        for (uint256 i; i < FARM_COUNT; ++i) {
            weights[i] = IApexController.EmissionWeight({
                kind: IApexController.PoolKind.CL, pool: clPools[i], allocPoint: FARM_COUNT - i
            });
        }
        _sortEmissionWeights(weights);

        uint256 gasBefore = gasleft();
        controller.rebalanceEmissions(10_000 ether, 7 days, weights);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("rebalanceEmissions 100 CL farms gas", gasUsed);
    }

    function _seedClassicFarms(uint256 _count) internal {
        for (uint256 i; i < _count; ++i) {
            ApexGasToken tokenA = new ApexGasToken("Classic A", "BA");
            ApexGasToken tokenB = new ApexGasToken("Classic B", "BB");
            address pair = classicFactory.createPair(address(tokenA), address(tokenB), false);

            controller.activateClassicFarm(pair, 1);
            classicPools.push(pair);

            tokenA.mint(pair, 10 ether);
            tokenB.mint(pair, 10 ether);
            ClassicPool(pair).mint(alice);

            vm.startPrank(alice);
            ClassicPool(pair).approve(address(classicChef), type(uint256).max);
            classicChef.deposit(classicChef.pidOf(pair), ClassicPool(pair).balanceOf(alice));
            vm.stopPrank();
        }
    }

    function _seedCLFarms(uint256 _count) internal {
        for (uint256 i; i < _count; ++i) {
            ApexGasToken tokenA = new ApexGasToken("CL A", "CLA");
            ApexGasToken tokenB = new ApexGasToken("CL B", "CLB");
            (address token0, address token1) = address(tokenA) < address(tokenB)
                ? (address(tokenA), address(tokenB))
                : (address(tokenB), address(tokenA));

            ApexGasCLPool pool = new ApexGasCLPool(address(clFactory), token0, token1, CL_FEE);
            clFactory.setPool(token0, token1, CL_FEE, address(pool));

            controller.activateCLFarm(address(pool), 1);
            clPools.push(address(pool));

            uint256 tokenId = i + 1;
            clNfp.mintPosition(alice, tokenId, token0, token1, CL_FEE, TICK_LOWER, TICK_UPPER, 1 ether);

            vm.prank(alice);
            clNfp.safeTransferFrom(alice, address(clChef), tokenId);
        }
    }

    function _primeEmissions() internal {
        IApexController.EmissionWeight[] memory weights =
            new IApexController.EmissionWeight[](classicPools.length + clPools.length);
        for (uint256 i; i < classicPools.length; ++i) {
            weights[i] = IApexController.EmissionWeight({
                kind: IApexController.PoolKind.CLASSIC, pool: classicPools[i], allocPoint: 1
            });
        }
        for (uint256 i; i < clPools.length; ++i) {
            weights[classicPools.length + i] =
                IApexController.EmissionWeight({kind: IApexController.PoolKind.CL, pool: clPools[i], allocPoint: 1});
        }
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(20_000 ether, 7 days, weights);
    }

    function _primeClassicEmissions() internal {
        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](classicPools.length);
        for (uint256 i; i < classicPools.length; ++i) {
            weights[i] = IApexController.EmissionWeight({
                kind: IApexController.PoolKind.CLASSIC, pool: classicPools[i], allocPoint: 1
            });
        }
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(10_000 ether, 7 days, weights);
    }

    function _primeCLEmissions() internal {
        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](clPools.length);
        for (uint256 i; i < clPools.length; ++i) {
            weights[i] =
                IApexController.EmissionWeight({kind: IApexController.PoolKind.CL, pool: clPools[i], allocPoint: 1});
        }
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(10_000 ether, 7 days, weights);
    }

    function _sortEmissionWeights(IApexController.EmissionWeight[] memory _weights) internal pure {
        for (uint256 i = 1; i < _weights.length; ++i) {
            IApexController.EmissionWeight memory key = _weights[i];
            uint256 j = i;
            while (j != 0 && _weights[j - 1].pool > key.pool) {
                _weights[j] = _weights[j - 1];
                --j;
            }
            _weights[j] = key;
        }
    }

    function _deployControllerProxy(address _admin) internal returns (ApexController controller_) {
        ApexController implementation = new ApexController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), _admin, "");
        controller_ = ApexController(address(proxy));
    }

    function _deployVaultProxy(address _veNFT, address _controller) internal returns (ApexVault vault_) {
        ApexVault implementation = new ApexVault();
        bytes memory initData = abi.encodeCall(ApexVault.initialize, (_veNFT, _controller, 22 weeks, 7 days));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        vault_ = ApexVault(address(proxy));
    }
}
