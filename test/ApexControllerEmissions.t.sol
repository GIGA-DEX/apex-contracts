// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

import {ApexController} from "../src/core/ApexController.sol";
import {EmissionCenter} from "../src/core/EmissionCenter.sol";
import {ClassicChef} from "../src/core/ClassicChef.sol";
import {ClassicFactory} from "../src/core/ClassicFactory.sol";
import {ClassicPool} from "../src/core/ClassicPool.sol";
import {CLMasterChef} from "../src/core/CLMasterChef.sol";
import {ApexVault} from "../src/core/ApexVault.sol";
import {FeeCenter} from "../src/core/FeeCenter.sol";
import {FeeReceiver} from "../src/core/FeeReceiver.sol";
import {IApexController} from "../src/core/interfaces/IApexController.sol";
import {IFeeCenter} from "../src/core/interfaces/IFeeCenter.sol";
import {IVotingEscrow} from "../src/core/interfaces/IVotingEscrow.sol";
import {ApexErrors} from "../src/core/libraries/common/ApexErrors.sol";

error MockSwapFailed();

contract ApexEmissionMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ApexMockVeNFT is ERC721 {
    uint256 public constant MAXTIME = 26 weeks;

    mapping(uint256 tokenId => uint256 weight) public weights;
    mapping(uint256 tokenId => uint256 end) public lockEnd;
    address public token = address(0xA9E7);

    constructor() ERC721("VeApexToken", "veTOKEN") {}

    function setToken(address token_) external {
        token = token_;
    }

    function mint(address to, uint256 tokenId, uint256 weight) external {
        weights[tokenId] = weight;
        lockEnd[tokenId] = block.timestamp + MAXTIME;
        _mint(to, tokenId);
    }

    function balanceOfNFT(uint256 tokenId) external view returns (uint256) {
        return weights[tokenId];
    }

    function locked(uint256 tokenId) external view returns (IVotingEscrow.LockedBalance memory) {
        return IVotingEscrow.LockedBalance({
            amount: int128(uint128(weights[tokenId])), end: lockEnd[tokenId], isPermanent: false
        });
    }

    function depositFor(uint256 tokenId, uint256 value) external {
        ERC20(token).transferFrom(msg.sender, address(this), value);
        weights[tokenId] += value;
    }

    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external {
        lockEnd[tokenId] = block.timestamp + lockDuration;
    }

    function merge(uint256 from, uint256 to) external {
        weights[to] += weights[from];
        delete weights[from];
        delete lockEnd[from];
        _burn(from);
    }
}

contract ApexMockSwapper {
    uint256 public amountOut;
    address public lastCaller;
    bool public shouldRevert;

    function setAmountOut(uint256 _amountOut) external {
        amountOut = _amountOut;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, address recipient) external {
        if (shouldRevert) revert MockSwapFailed();
        lastCaller = msg.sender;
        require(ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "transfer failed");
        ApexEmissionMockERC20(tokenOut).mint(recipient, amountOut);
    }
}

contract ApexMockCLPositionManager is ERC721 {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 tokenId => Position position) public positionInfo;

    constructor() ERC721("Apex CL Position", "apexCL") {}

    function WETH9() external pure returns (address) {
        return address(0xBEEF);
    }

    function mintPosition(
        address to,
        uint256 tokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        positionInfo[tokenId] = Position({
            token0: token0, token1: token1, fee: fee, tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity
        });
        _mint(to, tokenId);
    }

    function positions(uint256 tokenId)
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
        Position memory position = positionInfo[tokenId];
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

contract ApexMockCLPool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint128 public constant maxLiquidityPerTick = type(uint128).max;

    address public lmPool;
    uint32 public feeProtocol;
    uint160 public sqrtPriceX96;
    uint128 public protocolFees0;
    uint128 public protocolFees1;

    constructor(address factory_, address token0_, address token1_, uint24 fee_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setLmPool(address lmPool_) external {
        lmPool = lmPool_;
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "AI");
        require(sqrtPriceX96_ != 0, "SPL");
        sqrtPriceX96 = sqrtPriceX96_;
        feeProtocol = 1_000 + (1_000 << 16);
    }

    function seedProtocolFees(uint128 amount0, uint128 amount1) external {
        protocolFees0 += amount0;
        protocolFees1 += amount1;
        if (amount0 != 0) ApexEmissionMockERC20(token0).mint(address(this), amount0);
        if (amount1 != 0) ApexEmissionMockERC20(token1).mint(address(this), amount1);
    }

    function collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        amount0 = amount0Requested > protocolFees0 ? protocolFees0 : amount0Requested;
        amount1 = amount1Requested > protocolFees1 ? protocolFees1 : amount1Requested;
        protocolFees0 -= amount0;
        protocolFees1 -= amount1;
        if (amount0 != 0) require(ERC20(token0).transfer(recipient, amount0));
        if (amount1 != 0) require(ERC20(token1).transfer(recipient, amount1));
    }

    function setFeeProtocol(uint32 feeProtocol0_, uint32 feeProtocol1_) external {
        feeProtocol = feeProtocol0_ + (feeProtocol1_ << 16);
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96_,
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

contract ApexMockCLFeeFactory {
    struct FeeProtocol {
        uint32 token0;
        uint32 token1;
    }

    mapping(address pool => FeeProtocol feeProtocol) public feeProtocols;
    mapping(address token0 => mapping(address token1 => mapping(uint24 fee => address pool))) public getPool;
    address public owner;
    address public lmPoolDeployer;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
    }

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));
        require(getPool[token0][token1][fee] == address(0));
        pool = address(new ApexMockCLPool(address(this), token0, token1, fee));
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;
    }

    function setFeeProtocol(address pool, uint32 feeProtocol0, uint32 feeProtocol1) external onlyOwner {
        feeProtocols[pool] = FeeProtocol({token0: feeProtocol0, token1: feeProtocol1});
        ApexMockCLPool(pool).setFeeProtocol(feeProtocol0, feeProtocol1);
    }

    function collectProtocol(address pool, address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        onlyOwner
        returns (uint128 amount0, uint128 amount1)
    {
        return ApexMockCLPool(pool).collectProtocol(recipient, amount0Requested, amount1Requested);
    }

    function setLmPoolDeployer(address lmPoolDeployer_) external onlyOwner {
        lmPoolDeployer = lmPoolDeployer_;
    }

    function setLmPool(address pool, address lmPool) external {
        require(msg.sender == lmPoolDeployer, "Not LM pool deployer");
        ApexMockCLPool(pool).setLmPool(lmPool);
    }
}

contract ApexControllerEmissionsTest is Test {
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    ApexController internal controller;
    ClassicFactory internal classicFactory;
    ClassicChef internal classicChef;
    CLMasterChef internal clChef;
    ApexVault internal vault;
    FeeCenter internal feeCenter;
    address internal feeCenterImplementation;
    address internal feeCenterProxyAdmin;
    FeeReceiver internal feeReceiverImplementation;
    ApexMockVeNFT internal veNFT;
    ApexMockCLPositionManager internal clNfp;
    ApexMockCLFeeFactory internal clFactory;
    ApexMockCLPool internal clPool;
    ApexEmissionMockERC20 internal apex;
    ApexEmissionMockERC20 internal tokenA;
    ApexEmissionMockERC20 internal tokenB;
    ApexEmissionMockERC20 internal feeToken;
    address internal classicPair;

    address internal treasury = address(0xA9E7);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        apex = new ApexEmissionMockERC20("Apex", "APEX");
        tokenA = new ApexEmissionMockERC20("Apex Token A", "APXA");
        tokenB = new ApexEmissionMockERC20("Apex Token B", "APXB");
        feeToken = new ApexEmissionMockERC20("Fee Token", "FEE");
        veNFT = new ApexMockVeNFT();
        veNFT.setToken(address(apex));
        clNfp = new ApexMockCLPositionManager();
        clFactory = new ApexMockCLFeeFactory();

        controller = _deployControllerProxy(address(this));
        clFactory.setOwner(address(controller));
        classicFactory = new ClassicFactory(controller);
        classicChef = new ClassicChef(address(apex), address(controller));
        clChef = new CLMasterChef(address(apex), address(controller), address(clNfp));
        vault = _deployVaultProxy(address(veNFT), address(controller));
        feeReceiverImplementation = new FeeReceiver();
        feeCenter = _deployFeeCenterProxy(address(controller), address(vault), address(feeReceiverImplementation));
        _initializeController(
            address(this),
            treasury,
            address(apex),
            address(classicFactory),
            address(classicChef),
            address(clChef),
            address(vault),
            address(feeCenter)
        );
        controller.grantRole(controller.VAULT_OPERATOR(), address(feeCenter));
        controller.setVaultRewardToken(address(feeToken), true);
        address token0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address token1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);
        clPool = new ApexMockCLPool(address(clFactory), token0, token1, 2500);
        clFactory.setPool(token0, token1, 2500, address(clPool));
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));
        controller.setLmPoolDeployer(lmPoolDeployer);
        classicPair = classicFactory.createPair(address(tokenA), address(tokenB), false);
    }

    function testAssignCreatorFeesCLSettlesOldFeesAndPreservesPoolState() public {
        clPool.initialize(1 << 96);
        controller.overrideCLProtocolFee(address(clPool), 300, 300);
        clPool.seedProtocolFees(3 ether, 6 ether);
        controller.assignCreatorFees(address(clPool), alice, 1500);
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(tokenB.balanceOf(alice), 0);
        assertEq(tokenA.balanceOf(address(feeCenter)) + tokenB.balanceOf(address(feeCenter)), 9 ether);
        (uint160 price,,,,, uint32 packed,) = clPool.slot0();
        assertEq(price, 1 << 96);
        assertEq(uint16(packed), 1800);
        assertEq(packed >> 16, 1800);
        (address launcher,,, uint16 base,, bool gauged) = controller.launcherPoolConfig(address(clPool));
        assertEq(launcher, address(0));
        assertEq(base, 300);
        assertFalse(gauged);
        assertEq(controller.launchers(false).length, 0);
        assertEq(controller.launcherPoolsByLauncher(alice).length, 0);
        assertEq(controller.launcherPools().length, 1);
        assertEq(controller.registeredCLFarmsLength(), 0);

        clPool.seedProtocolFees(18 ether, 36 ether);
        vm.prank(bob);
        controller.collectLauncherCLProtocolFees(address(clPool));
        assertEq(ApexEmissionMockERC20(clPool.token0()).balanceOf(alice), 15 ether);
        assertEq(ApexEmissionMockERC20(clPool.token1()).balanceOf(alice), 30 ether);
        vm.prank(alice);
        vm.expectRevert();
        controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);
    }

    function testAssignCreatorFeesRotationAndRemovalSettlePreviousRecipient() public {
        clPool.initialize(1 << 96);
        controller.assignCreatorFees(address(clPool), alice, 1500);
        clPool.seedProtocolFees(25 ether, 50 ether);
        controller.assignCreatorFees(address(clPool), bob, 500);
        assertEq(ApexEmissionMockERC20(clPool.token0()).balanceOf(alice), 15 ether);
        clPool.seedProtocolFees(15 ether, 30 ether);
        controller.assignCreatorFees(address(clPool), address(0), 0);
        assertEq(ApexEmissionMockERC20(clPool.token0()).balanceOf(bob), 5 ether);
        assertEq(feeCenter.creatorFeeConfig(address(clPool)).recipient, address(0));
        assertEq(uint16(clPool.feeProtocol()), 1000);
        assertEq(controller.launcherPools().length, 1);
        clPool.seedProtocolFees(10 ether, 20 ether);
        controller.collectLauncherCLProtocolFees(address(clPool));
        assertEq(ApexEmissionMockERC20(clPool.token0()).balanceOf(bob), 5 ether);
    }

    function testAssignCreatorFeesOnlyAdminIncludingAuthorizedLaunchers() public {
        controller.configureLauncher(alice, bob, 500, 1500, false, IApexController.LauncherPermission.BOTH, true);
        vm.prank(alice);
        vm.expectRevert();
        controller.assignCreatorFees(classicPair, bob, 1500);
        controller.grantRole(controller.FEE_OPERATOR(), bob);
        vm.prank(bob);
        vm.expectRevert();
        controller.assignCreatorFees(classicPair, bob, 1500);
    }

    function testAssignCreatorFeesRejectsInvalidPoolsAndSplits() public {
        vm.expectRevert();
        controller.assignCreatorFees(address(0), alice, 1500);
        vm.expectRevert();
        controller.assignCreatorFees(address(tokenA), alice, 1500);
        vm.expectRevert();
        controller.assignCreatorFees(address(clPool), alice, 1500); // uninitialized
        clPool.initialize(1 << 96);
        ApexMockCLPool fake = new ApexMockCLPool(address(clFactory), clPool.token0(), clPool.token1(), clPool.fee());
        fake.initialize(1 << 96);
        vm.expectRevert();
        controller.assignCreatorFees(address(fake), alice, 1500);
        vm.expectRevert(ApexErrors.ZERO_ADDRESS.selector);
        controller.assignCreatorFees(address(clPool), address(0), 1);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.assignCreatorFees(address(clPool), alice, 0);
        vm.expectRevert(ApexErrors.FEE_TOO_HIGH.selector);
        controller.assignCreatorFees(address(clPool), alice, 9001);
        controller.overrideCLProtocolFee(address(clPool), 300, 500);
        vm.expectRevert(ApexErrors.INVALID_PROTOCOL_FEE.selector);
        controller.assignCreatorFees(address(clPool), alice, 1500);
        assertEq(controller.launcherPools().length, 0);
    }

    function testAssignCreatorFeesPreservesLauncherAttributionAndBase() public {
        controller.configureLauncher(alice, alice, 500, 1500, false, IApexController.LauncherPermission.CL, true);
        vm.prank(alice);
        address pool = controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);
        controller.assignCreatorFees(pool, bob, 1500);
        (address launcher,,, uint16 base,,) = controller.launcherPoolConfig(pool);
        assertEq(launcher, alice);
        assertEq(base, 1500);
        assertEq(uint16(ApexMockCLPool(pool).feeProtocol()), 3000);
        assertEq(controller.launcherPoolsByLauncher(alice).length, 1);
        assertEq(controller.launcherPoolsByLauncher(bob).length, 0);
    }

    function testAssignCreatorFeesGaugedCLPreservesAllocationAndDeactivationBase() public {
        clPool.initialize(1 << 96);
        controller.activateCLFarm(address(clPool), 123);
        clPool.seedProtocolFees(100 ether, 200 ether);
        controller.assignCreatorFees(address(clPool), alice, 1500);
        assertTrue(controller.isFarmActive(address(clPool)));
        assertEq(controller.totalAllocPoint(), 123);
        assertEq(uint16(clPool.feeProtocol()), 10000);
        assertEq(controller.activeLauncherPools().length, 1);
        assertEq(tokenA.balanceOf(alice), 0);
        clPool.seedProtocolFees(100 ether, 200 ether);
        controller.collectLauncherCLProtocolFees(address(clPool));
        assertEq(ApexEmissionMockERC20(clPool.token0()).balanceOf(alice), 15 ether);
        controller.deactivateCLFarm(address(clPool));
        assertEq(uint16(clPool.feeProtocol()), 3500);
        assertEq(controller.activeLauncherPools().length, 0);
        controller.activateCLFarm(address(clPool), 123);
        assertEq(uint16(clPool.feeProtocol()), 10000);
        controller.assignCreatorFees(address(clPool), address(0), 0);
        assertEq(uint16(clPool.feeProtocol()), 10000);
        controller.deactivateCLFarm(address(clPool));
        assertEq(uint16(clPool.feeProtocol()), 2000);
    }

    function testAssignCreatorFeesClassicSettlesHistoricalFeesAndPaysNewShare() public {
        _addLiquidity(classicPair, alice, 1000 ether, 1000 ether);
        ClassicPool pair = ClassicPool(classicPair);
        ApexEmissionMockERC20 t0 = ApexEmissionMockERC20(pair.token0());
        t0.mint(classicPair, 100 ether);
        pair.swap(0, pair.getAmountOut(100 ether, pair.token0()), bob, "");
        address creator = address(0xC0FFEE);
        controller.assignCreatorFees(classicPair, creator, 1500);
        assertEq(t0.balanceOf(creator), 0);
        assertGt(t0.balanceOf(address(feeCenter)), 0);
        assertEq(pair.protocolFee(), 350000);
        t0.mint(classicPair, 100 ether);
        pair.swap(0, pair.getAmountOut(100 ether, pair.token0()), bob, "");
        (uint256 amount0,) = controller.collectLauncherClassicProtocolFees(classicPair);
        assertGt(amount0, 0);
        assertEq(t0.balanceOf(creator), amount0 * 1500 / 3500);
        controller.assignCreatorFees(classicPair, address(0), 0);
        assertEq(pair.protocolFee(), 200000);
    }

    function testAssignCreatorFeesClassicRejectsExternalReceiverAndFractionalBps() public {
        controller.overrideClassicFeeReceiver(classicPair, alice);
        vm.expectRevert();
        controller.assignCreatorFees(classicPair, bob, 1500);
        controller.overrideClassicFeeReceiver(classicPair, address(feeCenter));
        controller.overrideClassicProtocolFee(classicPair, 30001);
        vm.expectRevert(ApexErrors.INVALID_PROTOCOL_FEE.selector);
        controller.assignCreatorFees(classicPair, bob, 1500);
    }

    function testAssignCreatorFeesGaugedClassicPreservesAllocationAndDeactivationBase() public {
        controller.activateClassicFarm(classicPair, 123);
        controller.assignCreatorFees(classicPair, alice, 1500);
        assertEq(ClassicPool(classicPair).protocolFee(), 1000000);
        assertEq(controller.totalAllocPoint(), 123);
        controller.deactivateClassicFarm(classicPair);
        assertEq(ClassicPool(classicPair).protocolFee(), 350000);
        assertEq(ClassicPool(classicPair).feeReceiver(), address(feeCenter));
    }

    function testFeeReceiverCanNotifyMultipleVaultBalancesAtomically() public {
        controller.setVaultRewardToken(address(tokenA), true);
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](2);
        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 3_000});
        configs[1] = ApexVault.UserConfig({rewardToken: address(tokenA), bps: 3_000});
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 4_000);
        vm.stopPrank();

        address compoundReceiver = controller.addFeeReceiver(address(apex));
        address feeReceiver = controller.addFeeReceiver(address(feeToken));
        address tokenAReceiver = controller.addFeeReceiver(address(tokenA));
        apex.mint(compoundReceiver, 30 ether);
        feeToken.mint(feeReceiver, 20 ether);
        tokenA.mint(tokenAReceiver, 10 ether);

        address[] memory receivers = new address[](3);
        receivers[0] = compoundReceiver;
        receivers[1] = feeReceiver;
        receivers[2] = tokenAReceiver;
        bool[] memory isCompound = new bool[](3);
        isCompound[0] = true;

        uint256[] memory amounts = controller.notifyFeeReceiverVaultBalances(receivers, isCompound);
        assertEq(amounts[0], 30 ether);
        assertEq(amounts[1], 20 ether);
        assertEq(amounts[2], 10 ether);
        (, uint256 compoundFinish,,,) = vault.rewardData(address(veNFT));
        (, uint256 feeFinish,,,) = vault.rewardData(address(feeToken));
        (, uint256 tokenAFinish,,,) = vault.rewardData(address(tokenA));
        assertEq(compoundFinish, feeFinish);
        assertEq(feeFinish, tokenAFinish);
    }

    function testFeeReceiverBatchNotificationRejectsInvalidAssortments() public {
        address receiver = controller.addFeeReceiver(address(feeToken));
        address[] memory receivers = new address[](1);
        receivers[0] = receiver;
        bool[] memory compounds = new bool[](0);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.notifyFeeReceiverVaultBalances(receivers, compounds);

        feeToken.mint(receiver, 2 ether);
        receivers = new address[](2);
        receivers[0] = receiver;
        receivers[1] = receiver;
        compounds = new bool[](2);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.notifyFeeReceiverVaultBalances(receivers, compounds);
    }

    function testAssignmentUpgradePreservesRewardTokenSwapGuard() public {
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.TOKEN_SWAP_FORBIDDEN.selector, address(apex)));
        controller.executeFeeReceiverSwap(address(1), address(apex), address(2), 1, 0, "");
    }

    function testUngaugedProtocolFeeDefaultsAreTwentyPercent() public view {
        assertEq(controller.clGlobalProtocolFee(), 2_000);
        assertEq(classicFactory.protocolFee(), 200_000);
        assertEq(ClassicPool(classicPair).protocolFee(), 200_000);
    }

    function testAdminCanConfigureUngaugedProtocolFeePolicy() public {
        controller.setClassicGlobalProtocolFee(250_000);
        controller.setCLGlobalProtocolFee(3_000);

        assertEq(controller.clGlobalProtocolFee(), 3_000);
        assertEq(classicFactory.protocolFee(), 250_000);

        controller.setClassicGlobalProtocolFee(0);
        controller.setCLGlobalProtocolFee(0);
        assertEq(classicFactory.protocolFee(), 0);
        assertEq(controller.clGlobalProtocolFee(), 0);
    }

    function testUngaugedProtocolFeePolicyRejectsInvalidValuesAndUnauthorizedCallers() public {
        vm.expectRevert(ApexErrors.INVALID_PROTOCOL_FEE.selector);
        controller.setClassicGlobalProtocolFee(1_000_001);

        vm.expectRevert(ApexErrors.INVALID_PROTOCOL_FEE.selector);
        controller.setCLGlobalProtocolFee(10_001);

        vm.startPrank(alice);
        vm.expectRevert();
        controller.setClassicGlobalProtocolFee(200_000);
        vm.expectRevert();
        controller.setCLGlobalProtocolFee(2_000);
        vm.stopPrank();
    }

    function testLauncherConfigurationCreatesAndSnapshotsClassicPoolCreatorFee() public {
        address creator = address(0xC0FFEE);
        ApexEmissionMockERC20 tokenC = new ApexEmissionMockERC20("Launcher Token", "LCH");

        controller.configureLauncher(
            alice, creator, 500, 1_500, false, IApexController.LauncherPermission.CLASSIC, true
        );

        vm.prank(alice);
        address pair = controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);

        assertEq(classicFactory.getPair(address(tokenA), address(tokenC), false), pair);
        assertEq(ClassicPool(pair).feeReceiver(), address(feeCenter));
        IFeeCenter.CreatorFeeConfig memory config = feeCenter.creatorFeeConfig(pair);
        assertEq(config.recipient, creator);
        assertEq(config.feeBps, 500);
        assertEq(config.poolKind, uint8(IApexController.PoolKind.CLASSIC));

        controller.configureLauncher(
            alice, address(0xBEEF), 300, 1_700, false, IApexController.LauncherPermission.CLASSIC, true
        );
        config = feeCenter.creatorFeeConfig(pair);
        assertEq(config.recipient, creator);
        assertEq(config.feeBps, 500);
        assertEq(ClassicPool(pair).protocolFee(), 200_000);
        (,,, uint16 veGigaFeeBps,, bool gauged) = controller.launcherPoolConfig(pair);
        assertEq(veGigaFeeBps, 1_500);
        assertFalse(gauged);
    }

    function testLauncherClassicPoolRejectsUnauthorizedWrongKindAndExistingPool() public {
        ApexEmissionMockERC20 tokenC = new ApexEmissionMockERC20("Launcher Token", "LCH");
        controller.configureLauncher(
            alice, address(0xC0FFEE), 500, 1_500, false, IApexController.LauncherPermission.CL, true
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, alice));
        controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);

        controller.configureLauncher(
            alice, address(0xC0FFEE), 500, 1_500, false, IApexController.LauncherPermission.CLASSIC, true
        );
        vm.prank(alice);
        controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);

        vm.prank(alice);
        vm.expectRevert(ApexErrors.PAIR_EXISTS.selector);
        controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, bob));
        controller.createLauncherClassicPool(address(tokenA), address(tokenB), true);
    }

    function testLauncherConfigurationRequiresAdminAndActiveLauncher() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.configureLauncher(
            alice, address(0xC0FFEE), 500, 1_500, false, IApexController.LauncherPermission.CLASSIC, true
        );

        controller.configureLauncher(
            alice, address(0xC0FFEE), 500, 1_500, false, IApexController.LauncherPermission.CLASSIC, false
        );
        ApexEmissionMockERC20 tokenC = new ApexEmissionMockERC20("Launcher Token", "LCH");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, alice));
        controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);

        vm.expectRevert(ApexErrors.FEE_TOO_HIGH.selector);
        controller.configureLauncher(
            alice, address(0xC0FFEE), 10_001, 0, false, IApexController.LauncherPermission.CLASSIC, true
        );
    }

    function testPermissionlessClassicCreatorCollectionPaysFivePercentOfGrossFees() public {
        address creator = address(0xC0FFEE);
        ApexEmissionMockERC20 tokenC = new ApexEmissionMockERC20("Launcher Token", "LCH");
        controller.configureLauncher(
            alice, creator, 500, 1_500, false, IApexController.LauncherPermission.CLASSIC, true
        );
        vm.prank(alice);
        address pair = controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);

        _addLiquidity(pair, alice, 1_000 ether, 1_000 ether);
        address tokenIn = ClassicPool(pair).token0();
        ApexEmissionMockERC20(tokenIn).mint(pair, 100 ether);
        uint256 amountOut = ClassicPool(pair).getAmountOut(100 ether, tokenIn);
        if (tokenIn == ClassicPool(pair).token0()) {
            ClassicPool(pair).swap(0, amountOut, bob, "");
        } else {
            ClassicPool(pair).swap(amountOut, 0, bob, "");
        }

        vm.prank(bob);
        (uint256 amount0, uint256 amount1) = controller.collectLauncherClassicProtocolFees(pair);

        assertEq(ApexEmissionMockERC20(ClassicPool(pair).token0()).balanceOf(creator), amount0 / 4);
        assertEq(ApexEmissionMockERC20(ClassicPool(pair).token1()).balanceOf(creator), amount1 / 4);
        assertEq(ClassicPool(pair).balanceOf(address(feeCenter)), 0);
    }

    function testClassicCreatorFeeSurvivesGaugeActivationAndDeactivation() public {
        address creator = address(0xC0FFEE);
        ApexEmissionMockERC20 tokenC = new ApexEmissionMockERC20("Launcher Token", "LCH");
        controller.configureLauncher(
            alice, creator, 500, 1_500, false, IApexController.LauncherPermission.CLASSIC, true
        );
        vm.prank(alice);
        address pair = controller.createLauncherClassicPool(address(tokenA), address(tokenC), false);
        _addLiquidity(pair, alice, 1_000 ether, 1_000 ether);

        controller.activateClassicFarm(pair, 1000);
        assertEq(ClassicPool(pair).protocolFee(), 1_000_000);
        address tokenIn = ClassicPool(pair).token0();
        ApexEmissionMockERC20(tokenIn).mint(pair, 100 ether);
        uint256 amountOut = ClassicPool(pair).getAmountOut(100 ether, tokenIn);
        ClassicPool(pair).swap(0, amountOut, bob, "");

        (uint256 amount0, uint256 amount1) = controller.collectLauncherClassicProtocolFees(pair);
        assertEq(ApexEmissionMockERC20(ClassicPool(pair).token0()).balanceOf(creator), amount0 / 20);
        assertEq(ApexEmissionMockERC20(ClassicPool(pair).token1()).balanceOf(creator), amount1 / 20);

        controller.deactivateClassicFarm(pair);
        assertEq(ClassicPool(pair).protocolFee(), 200_000);
        assertEq(ClassicPool(pair).feeReceiver(), address(feeCenter));
        assertEq(feeCenter.creatorFeeConfig(pair).recipient, creator);
    }

    function testLauncherConfigurationCreatesAndInitializesCLPool() public {
        address creator = address(0xC0FFEE);
        controller.configureLauncher(alice, creator, 500, 1_500, false, IApexController.LauncherPermission.CL, true);

        vm.prank(alice);
        address pool = controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);

        assertEq(clFactory.getPool(address(tokenA), address(feeToken), 3000), pool);
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(pool);
        assertEq(feeProtocol0, 2_000);
        assertEq(feeProtocol1, 2_000);
        (uint160 sqrtPriceX96,,,,,,) = ApexMockCLPool(pool).slot0();
        assertEq(sqrtPriceX96, 1 << 96);
        IFeeCenter.CreatorFeeConfig memory config = feeCenter.creatorFeeConfig(pool);
        assertEq(config.recipient, creator);
        assertEq(config.feeBps, 500);
        assertEq(config.poolKind, uint8(IApexController.PoolKind.CL));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.POOL_EXISTS.selector, pool));
        controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);
    }

    function testPermissionlessCLCreatorCollectionPaysFivePercentOfGrossFeesAcrossGaugeTransition() public {
        address creator = address(0xC0FFEE);
        controller.configureLauncher(alice, creator, 500, 1_500, false, IApexController.LauncherPermission.CL, true);
        vm.prank(alice);
        address poolAddress = controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);
        ApexMockCLPool pool = ApexMockCLPool(poolAddress);

        pool.seedProtocolFees(20 ether, 40 ether);
        controller.activateCLFarm(poolAddress, 1000);
        assertEq(ApexEmissionMockERC20(pool.token0()).balanceOf(creator), 5 ether);
        assertEq(ApexEmissionMockERC20(pool.token1()).balanceOf(creator), 10 ether);

        pool.seedProtocolFees(100 ether, 200 ether);
        vm.prank(bob);
        controller.collectLauncherCLProtocolFees(poolAddress);
        assertEq(ApexEmissionMockERC20(pool.token0()).balanceOf(creator), 10 ether);
        assertEq(ApexEmissionMockERC20(pool.token1()).balanceOf(creator), 20 ether);

        controller.deactivateCLFarm(poolAddress);
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(poolAddress);
        assertEq(feeProtocol0, 2_000);
        assertEq(feeProtocol1, 2_000);
        assertEq(feeCenter.creatorFeeConfig(poolAddress).recipient, creator);
    }

    function testLauncherPoolFeeSplitUpdateSettlesOldTermsBeforeRotating() public {
        address oldCreator = address(0xC0FFEE);
        address newCreator = address(0xCAFE);
        controller.configureLauncher(alice, oldCreator, 500, 1_500, false, IApexController.LauncherPermission.CL, true);
        vm.prank(alice);
        address poolAddress = controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);
        ApexMockCLPool pool = ApexMockCLPool(poolAddress);

        pool.seedProtocolFees(20 ether, 40 ether);
        controller.updateLauncherPoolFeeSplit(poolAddress, newCreator, 300, 1_700);
        assertEq(ApexEmissionMockERC20(pool.token0()).balanceOf(oldCreator), 5 ether);
        assertEq(ApexEmissionMockERC20(pool.token1()).balanceOf(oldCreator), 10 ether);

        pool.seedProtocolFees(20 ether, 40 ether);
        controller.collectLauncherCLProtocolFees(poolAddress);
        assertEq(ApexEmissionMockERC20(pool.token0()).balanceOf(newCreator), 3 ether);
        assertEq(ApexEmissionMockERC20(pool.token1()).balanceOf(newCreator), 6 ether);
    }

    function testMultipleLaunchersKeepIndependentClassicAndCLCreatorFeeTerms() public {
        address creatorA = address(0xC0FFEE);
        address creatorB = address(0xBEEF);

        controller.configureLauncher(alice, creatorA, 500, 1_500, false, IApexController.LauncherPermission.BOTH, true);
        controller.configureLauncher(bob, creatorB, 300, 1_700, false, IApexController.LauncherPermission.BOTH, true);

        _assertLauncherClassicSplit(alice, creatorA, 500, "Classic A", "CLA");
        _assertLauncherClassicSplit(bob, creatorB, 300, "Classic B", "CLB");
        _assertLauncherCLSplit(alice, creatorA, 500, "CL A", "CLA-CL");
        _assertLauncherCLSplit(bob, creatorB, 300, "CL B", "CLB-CL");
    }

    function testStartGaugedCreatesClassicAndCLFarmWithFixedGaugedSplitAndZeroWeight() public {
        address creator = address(0xC0FFEE);
        ApexEmissionMockERC20 classicToken = new ApexEmissionMockERC20("Gauged Classic", "GCL");
        ApexEmissionMockERC20 clToken = new ApexEmissionMockERC20("Gauged CL", "GCL-CL");
        controller.configureLauncher(alice, creator, 500, 500, true, IApexController.LauncherPermission.BOTH, true);

        vm.startPrank(alice);
        address pair = controller.createLauncherClassicPool(address(tokenA), address(classicToken), false);
        address pool = controller.createLauncherCLPool(address(feeToken), address(clToken), 100, 1 << 96);
        vm.stopPrank();

        assertTrue(controller.isFarmRegistered(pair));
        assertTrue(controller.isFarmActive(pair));
        assertEq(ClassicPool(pair).protocolFee(), 1_000_000);
        assertEq(ClassicPool(pair).feeReceiver(), address(feeCenter));
        (, uint256 classicAllocPoint,,,) = classicChef.poolInfo(classicChef.pidOf(pair));
        assertEq(classicAllocPoint, 0);

        assertTrue(controller.isFarmRegistered(pool));
        assertTrue(controller.isFarmActive(pool));
        assertNotEq(ApexMockCLPool(pool).lmPool(), address(0));
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(pool);
        assertEq(feeProtocol0, 10_000);
        assertEq(feeProtocol1, 10_000);
        (uint256 clAllocPoint,,,,,) = clChef.poolInfo(clChef.v3PoolAddressPid(pool));
        assertEq(clAllocPoint, 0);
        assertEq(controller.activeLauncherPools().length, 2);

        controller.activateClassicFarm(pair, 1_000);
        controller.deactivateClassicFarm(pair);
        controller.deactivateCLFarm(pool);

        assertEq(ClassicPool(pair).protocolFee(), 100_000);
        (feeProtocol0, feeProtocol1) = clFactory.feeProtocols(pool);
        assertEq(feeProtocol0, 1_000);
        assertEq(feeProtocol1, 1_000);
        assertEq(controller.activeLauncherPools().length, 0);
    }

    function testLauncherConfigurationIsFullyEnumerableAndTyped() public {
        controller.configureLauncher(
            alice, address(0xA11CE), 500, 1_500, false, IApexController.LauncherPermission.BOTH, true
        );
        controller.configureLauncher(bob, address(0xB0B), 300, 700, false, IApexController.LauncherPermission.CL, false);

        address[] memory allLaunchers = controller.launchers(false);
        address[] memory activeLaunchers = controller.launchers(true);
        assertEq(allLaunchers.length, 2);
        assertEq(activeLaunchers.length, 1);
        assertEq(activeLaunchers[0], alice);

        (,,,, IApexController.LauncherPermission permission, bool active, bool configured) =
            controller.launcherConfig(bob);
        assertEq(uint8(permission), uint8(IApexController.LauncherPermission.CL));
        assertFalse(active);
        assertTrue(configured);

        ApexEmissionMockERC20 pairedToken = new ApexEmissionMockERC20("Enumerable", "ENUM");
        vm.prank(alice);
        address pool = controller.createLauncherClassicPool(address(tokenA), address(pairedToken), false);

        assertEq(controller.launcherPools().length, 1);
        assertEq(controller.launcherPoolsByLauncher(alice)[0], pool);
        (
            address launcher,
            address recipient,
            uint16 creatorFeeBps,
            uint16 veGigaFeeBps,
            IApexController.PoolKind poolKind,
            bool gauged
        ) = controller.launcherPoolConfig(pool);
        assertEq(launcher, alice);
        assertEq(recipient, address(0xA11CE));
        assertEq(creatorFeeBps, 500);
        assertEq(veGigaFeeBps, 1_500);
        assertEq(uint8(poolKind), uint8(IApexController.PoolKind.CLASSIC));
        assertFalse(gauged);

        controller.configureLauncher(
            bob, address(0xB0B), 300, 700, false, IApexController.LauncherPermission.NONE, false
        );
        assertEq(controller.launchers(true).length, 1);
        (,,,, permission, active, configured) = controller.launcherConfig(bob);
        assertEq(uint8(permission), uint8(IApexController.LauncherPermission.NONE));
        assertFalse(active);
        assertTrue(configured);
    }

    function testLauncherPoolFeeSplitCanRemoveAndRestoreCreatorWithoutLosingBasePolicy() public {
        address creator = address(0xC0FFEE);
        controller.configureLauncher(alice, creator, 500, 1_500, false, IApexController.LauncherPermission.CL, true);
        vm.prank(alice);
        address poolAddress = controller.createLauncherCLPool(address(tokenA), address(feeToken), 3000, 1 << 96);
        ApexMockCLPool pool = ApexMockCLPool(poolAddress);

        pool.seedProtocolFees(20 ether, 40 ether);
        controller.updateLauncherPoolFeeSplit(poolAddress, address(0), 0, 1_000);
        assertEq(ApexEmissionMockERC20(pool.token0()).balanceOf(creator), 5 ether);
        assertEq(ApexEmissionMockERC20(pool.token1()).balanceOf(creator), 10 ether);
        assertEq(feeCenter.creatorFeeConfig(poolAddress).recipient, address(0));
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(poolAddress);
        assertEq(feeProtocol0, 1_000);
        assertEq(feeProtocol1, 1_000);

        vm.prank(bob);
        controller.collectLauncherCLProtocolFees(poolAddress);
        controller.updateLauncherPoolFeeSplit(poolAddress, address(0xCAFE), 200, 800);
        assertEq(feeCenter.creatorFeeConfig(poolAddress).recipient, address(0xCAFE));
        assertEq(feeCenter.creatorFeeConfig(poolAddress).feeBps, 200);
    }

    function testLauncherFeeSplitRejectsAmbiguousRecipientAndOverAllocation() public {
        vm.expectRevert(ApexErrors.ZERO_ADDRESS.selector);
        controller.configureLauncher(alice, address(0), 500, 1_500, false, IApexController.LauncherPermission.CL, true);

        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.configureLauncher(
            alice, address(0xCAFE), 0, 2_000, false, IApexController.LauncherPermission.CL, true
        );

        vm.expectRevert(ApexErrors.FEE_TOO_HIGH.selector);
        controller.configureLauncher(
            alice, address(0xCAFE), 500, 9_501, false, IApexController.LauncherPermission.CL, true
        );

        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.configureLauncher(
            alice, address(0xCAFE), 500, 1_500, false, IApexController.LauncherPermission.NONE, true
        );
    }

    function testFarmDeactivationRestoresConfiguredUngaugedProtocolFeePolicy() public {
        controller.setClassicGlobalProtocolFee(250_000);
        controller.setCLGlobalProtocolFee(3_000);

        controller.activateClassicFarm(classicPair, 0);
        controller.activateCLFarm(address(clPool), 0);
        controller.deactivateClassicFarm(classicPair);
        controller.deactivateCLFarm(address(clPool));

        assertEq(ClassicPool(classicPair).protocolFee(), 250_000);
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(address(clPool));
        assertEq(feeProtocol0, 3_000);
        assertEq(feeProtocol1, 3_000);
    }

    function testInitializeProtocolRejectsWrongCLFactoryOwner() public {
        ApexController freshController = _deployControllerProxy(address(this));
        ApexMockCLFeeFactory wrongCLFactory = new ApexMockCLFeeFactory();
        wrongCLFactory.setOwner(address(0xBAD));
        ClassicFactory freshClassicFactory = new ClassicFactory(freshController);
        ClassicChef freshClassicChef = new ClassicChef(address(apex), address(freshController));
        CLMasterChef freshCLChef = new CLMasterChef(address(apex), address(freshController), address(clNfp));
        ApexVault freshVault = _deployVaultProxy(address(veNFT), address(freshController));
        FeeCenter freshFeeCenter =
            _deployFeeCenterProxy(address(freshController), address(freshVault), address(feeReceiverImplementation));

        freshController.initialize(IApexController.InitParams({admin: address(this), treasury: treasury}));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(wrongCLFactory)));
        _initializeFreshController(
            freshController,
            address(apex),
            address(freshClassicFactory),
            address(freshClassicChef),
            address(freshCLChef),
            address(freshVault),
            address(freshFeeCenter),
            address(wrongCLFactory)
        );
    }

    function testInitializeProtocolRejectsWrongFeeCenterController() public {
        ApexController freshController = _deployControllerProxy(address(this));
        ApexMockCLFeeFactory freshCLFactory = new ApexMockCLFeeFactory();
        freshCLFactory.setOwner(address(freshController));
        ClassicFactory freshClassicFactory = new ClassicFactory(freshController);
        ClassicChef freshClassicChef = new ClassicChef(address(apex), address(freshController));
        CLMasterChef freshCLChef = new CLMasterChef(address(apex), address(freshController), address(clNfp));
        ApexVault freshVault = _deployVaultProxy(address(veNFT), address(freshController));
        FeeCenter wrongFeeCenter =
            _deployFeeCenterProxy(address(0xBAD), address(freshVault), address(feeReceiverImplementation));

        freshController.initialize(IApexController.InitParams({admin: address(this), treasury: treasury}));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(wrongFeeCenter)));
        _initializeFreshController(
            freshController,
            address(apex),
            address(freshClassicFactory),
            address(freshClassicChef),
            address(freshCLChef),
            address(freshVault),
            address(wrongFeeCenter),
            address(freshCLFactory)
        );
    }

    function testInitializeProtocolRejectsWrongFeeCenterVault() public {
        ApexController freshController = _deployControllerProxy(address(this));
        ApexMockCLFeeFactory freshCLFactory = new ApexMockCLFeeFactory();
        freshCLFactory.setOwner(address(freshController));
        ClassicFactory freshClassicFactory = new ClassicFactory(freshController);
        ClassicChef freshClassicChef = new ClassicChef(address(apex), address(freshController));
        CLMasterChef freshCLChef = new CLMasterChef(address(apex), address(freshController), address(clNfp));
        ApexVault freshVault = _deployVaultProxy(address(veNFT), address(freshController));
        FeeCenter wrongFeeCenter =
            _deployFeeCenterProxy(address(freshController), address(0xBAD), address(feeReceiverImplementation));

        freshController.initialize(IApexController.InitParams({admin: address(this), treasury: treasury}));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(wrongFeeCenter)));
        _initializeFreshController(
            freshController,
            address(apex),
            address(freshClassicFactory),
            address(freshClassicChef),
            address(freshCLChef),
            address(freshVault),
            address(wrongFeeCenter),
            address(freshCLFactory)
        );
    }

    function testRebalanceEmissionsSplitsGlobalAmountAcrossClassicAndClWeights() public {
        controller.activateClassicFarm(classicPair, 0);
        controller.activateCLFarm(address(clPool), 0);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 3000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 7000
        });
        _sortEmissionWeights(weights);

        apex.mint(address(controller), 300 ether);
        apex.mint(address(controller), 700 ether);
        controller.rebalanceEmissions(1_000 ether, 10 days, weights);

        assertEq(classicChef.totalAllocPoint(), 3000);
        assertEq(clChef.totalAllocPoint(), 7000);
        (uint256 classicRewardPerSecond,) = controller.getLatestPeriodInfo(classicPair);
        (uint256 clRewardPerSecond,) = controller.getLatestPeriodInfo(address(clPool));
        assertEq(classicRewardPerSecond, (uint256(300 ether) * controller.REWARD_PRECISION()) / 10 days);
        assertApproxEqAbs(clRewardPerSecond, (uint256(700 ether) * controller.REWARD_PRECISION()) / 10 days, 1);
    }

    function testClassicChefAccruesRewardsFromControllerRebalanceEmissions() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);

        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 50 ether, 1);

        vm.prank(alice);
        classicChef.deposit(classicPid, 0);

        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
    }

    function testClassicChefDoesNotBackpayBeforeFirstRebalance() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 10);

        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 10 ether, 1);
    }

    function testClassicChefStopsAccruingAtEmissionWindowEnd() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 150);

        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 100 ether, 1);

        vm.prank(alice);
        classicChef.harvest(classicPid);

        assertApproxEqAbs(apex.balanceOf(alice), 100 ether, 1);
        assertLe(controller.rewardLiability(), 1);
    }

    function testRebalanceEmissionsRollsOnlyUnelapsedRewardsIntoNewWindow() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 200 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 40);
        controller.rebalanceEmissions(100 ether, 100, weights);

        (uint256 rewardPerSecond, uint256 endTime) = controller.getLatestPeriodInfo(classicPair);
        assertEq(rewardPerSecond, (uint256(160 ether) * controller.REWARD_PRECISION()) / 100);
        assertEq(endTime, block.timestamp + 100);

        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        classicChef.harvest(classicPid);

        assertApproxEqAbs(apex.balanceOf(alice), 200 ether, 2);
        assertLe(controller.rewardLiability(), 2);
    }

    function testExpiredWindowDoesNotRollStaleRewardsIntoNewRate() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 200 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 150);
        controller.rebalanceEmissions(100 ether, 100, weights);

        (uint256 rewardPerSecond,) = controller.getLatestPeriodInfo(classicPair);
        assertEq(rewardPerSecond, (uint256(100 ether) * controller.REWARD_PRECISION()) / 100);

        vm.warp(block.timestamp + 50);
        vm.prank(alice);
        classicChef.harvest(classicPid);

        assertApproxEqAbs(apex.balanceOf(alice), 150 ether, 2);
        assertApproxEqAbs(controller.rewardLiability(), 50 ether, 2);
    }

    function testFuzzClassicChefNeverAccruesPastFundedWindow(uint96 _amount, uint32 _duration, uint32 _elapsed) public {
        uint256 amount = bound(uint256(_amount), 1 ether, 1_000_000 ether);
        uint256 duration = bound(uint256(_duration), 1, 30 days);
        uint256 elapsed = bound(uint256(_elapsed), 0, duration * 3);

        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), amount);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(amount, duration, weights);

        vm.warp(block.timestamp + elapsed);
        uint256 rewardPerSecond = (amount * controller.REWARD_PRECISION()) / duration;
        uint256 expected = ((elapsed < duration ? elapsed : duration) * rewardPerSecond) / controller.REWARD_PRECISION();
        uint256 pending = classicChef.pendingReward(classicPid, alice);
        assertApproxEqAbs(pending, expected, 1);
        assertLe(pending, amount);
    }

    function testFuzzClassicChefFullWindowLiabilityDustIsBounded(uint96 _amount, uint32 _duration) public {
        uint256 amount = bound(uint256(_amount), 1, 1_000_000 ether);
        uint256 duration = bound(uint256(_duration), 1, 30 days);

        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), amount);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(amount, duration, weights);

        vm.warp(block.timestamp + duration);
        vm.prank(alice);
        classicChef.harvest(classicPid);

        uint256 paid = apex.balanceOf(alice);
        assertLe(paid, amount, "classic overpaid");
        assertLe(amount - paid, 2, "classic dust exceeded raw-unit bound");
        assertLe(controller.rewardLiability(), 2, "classic liability dust exceeded bound");
    }

    function testRebalanceEmissionsWithZeroAmountKeepsCurrentRate() public {
        address stablePair = classicFactory.createPair(address(tokenA), address(tokenB), true);
        controller.activateClassicFarm(classicPair, 0);
        controller.activateClassicFarm(stablePair, 0);
        apex.mint(address(controller), 200 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        _addLiquidity(stablePair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        ClassicPool(stablePair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        uint256 stablePid = classicChef.pidOf(stablePair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        classicChef.deposit(stablePid, ClassicPool(stablePair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] =
            IApexController.EmissionWeight({kind: IApexController.PoolKind.CLASSIC, pool: stablePair, allocPoint: 0});
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 10);

        weights[0] =
            IApexController.EmissionWeight({kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 0});
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: stablePair, allocPoint: 1000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(0, 90, weights);

        vm.warp(block.timestamp + 10);

        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 10 ether, 1);
        assertApproxEqAbs(classicChef.pendingReward(stablePid, alice), 10 ether, 1);
        assertEq(controller.latestPeriodRewardPerSecond(), (uint256(100 ether) * controller.REWARD_PRECISION()) / 100);
    }

    function testRebalanceEmissionsMassUpdatesBeforeChangingAllocPoints() public {
        address stablePair = classicFactory.createPair(address(tokenA), address(tokenB), true);
        controller.activateClassicFarm(classicPair, 0);
        controller.activateClassicFarm(stablePair, 0);
        apex.mint(address(controller), 2_000 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        _addLiquidity(stablePair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        ClassicPool(stablePair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        uint256 stablePid = classicChef.pidOf(stablePair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        classicChef.deposit(stablePid, ClassicPool(stablePair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 9000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: stablePair, allocPoint: 1000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(1_000 ether, 100, weights);
        vm.warp(block.timestamp + 10);

        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: stablePair, allocPoint: 9000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(1_000 ether, 100, weights);

        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 90 ether, 1);
        assertApproxEqAbs(classicChef.pendingReward(stablePid, alice), 10 ether, 1);
    }

    function testDeactivateClassicFarmDoesNotRetroactivelyOverpayUnchangedFarm() public {
        address stablePair = classicFactory.createPair(address(tokenA), address(tokenB), true);
        controller.activateClassicFarm(classicPair, 1000);
        controller.activateClassicFarm(stablePair, 1000);
        apex.mint(address(controller), 400 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        _addLiquidity(stablePair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        ClassicPool(stablePair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        uint256 stablePid = classicChef.pidOf(stablePair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        classicChef.deposit(stablePid, ClassicPool(stablePair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: stablePair, allocPoint: 1000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(400 ether, 20, weights);

        vm.warp(block.timestamp + 10);
        controller.deactivateClassicFarm(stablePair);
        vm.warp(block.timestamp + 10);

        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 300 ether, 1);
        assertApproxEqAbs(classicChef.pendingReward(stablePid, alice), 100 ether, 1);
    }

    function testDeactivateClassicFarmRedistributesRemainingWindowToCLFarm() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateClassicFarm(classicPair, 1000);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 400 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        clNfp.mintPosition(bob, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        vm.prank(bob);
        clNfp.safeTransferFrom(bob, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(400 ether, 20, weights);

        vm.warp(block.timestamp + 10);
        controller.deactivateClassicFarm(classicPair);
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        classicChef.harvest(classicPid);
        vm.prank(bob);
        clChef.harvest(1, bob);

        assertApproxEqAbs(apex.balanceOf(alice), 100 ether, 1);
        assertApproxEqAbs(apex.balanceOf(bob), 300 ether, 1);
        assertLe(controller.rewardLiability(), 1);
    }

    function testDeactivateOnlyClassicFarmRevertsDuringLiveEmissionWindow() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        vm.expectRevert(ApexErrors.ZERO_AMOUNT.selector);
        controller.deactivateClassicFarm(classicPair);

        assertEq(controller.totalAllocPoint(), 1000);
        assertApproxEqAbs(classicChef.pendingReward(classicPid, alice), 50 ether, 1);
        assertEq(controller.rewardLiability(), 100 ether);
    }

    function testStopAllEmissionsReleasesUnelapsedWindowAndAllowsClassicDeactivation() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        controller.stopAllEmissions();
        controller.deactivateClassicFarm(classicPair);

        assertEq(controller.totalAllocPoint(), 0);
        assertEq(controller.latestPeriodEndTime(), block.timestamp);
        assertEq(controller.latestPeriodRewardPerSecond(), 0);
        assertApproxEqAbs(controller.rewardLiability(), 50 ether, 1);

        vm.prank(alice);
        classicChef.harvest(classicPid);

        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
        assertLe(controller.rewardLiability(), 1);
    }

    function testDeactivateCLFarmRedistributesRemainingWindowToClassicFarm() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateClassicFarm(classicPair, 1000);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 400 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        clNfp.mintPosition(bob, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 classicPid = classicChef.pidOf(classicPair);
        classicChef.deposit(classicPid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        vm.prank(bob);
        clNfp.safeTransferFrom(bob, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(400 ether, 20, weights);

        vm.warp(block.timestamp + 10);
        controller.deactivateCLFarm(address(clPool));
        vm.warp(block.timestamp + 10);

        vm.prank(alice);
        classicChef.harvest(classicPid);
        vm.prank(bob);
        clChef.harvest(1, bob);

        assertApproxEqAbs(apex.balanceOf(alice), 300 ether, 1);
        assertApproxEqAbs(apex.balanceOf(bob), 100 ether, 1);
        assertLe(controller.rewardLiability(), 1);
    }

    function testDeactivateOnlyCLFarmRevertsDuringLiveEmissionWindow() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 100 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        vm.expectRevert(ApexErrors.ZERO_AMOUNT.selector);
        controller.deactivateCLFarm(address(clPool));

        assertEq(controller.totalAllocPoint(), 1000);
        assertEq(controller.rewardLiability(), 100 ether);
    }

    function testStopAllEmissionsReleasesUnelapsedWindowAndAllowsCLDeactivation() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 100 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        controller.stopAllEmissions();
        controller.deactivateCLFarm(address(clPool));

        assertEq(controller.totalAllocPoint(), 0);
        assertEq(controller.latestPeriodEndTime(), block.timestamp);
        assertEq(controller.latestPeriodRewardPerSecond(), 0);
        assertApproxEqAbs(controller.rewardLiability(), 50 ether, 1);

        vm.prank(alice);
        clChef.harvest(1, alice);

        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
        assertLe(controller.rewardLiability(), 1);
    }

    function testRebalanceEmissionsCanShiftLeftoverAcrossClassicAndCLWithoutNewFunding() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateClassicFarm(classicPair, 0);
        controller.activateCLFarm(address(clPool), 0);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        classicChef.deposit(classicChef.pidOf(classicPair), ClassicPool(classicPair).balanceOf(alice));
        clNfp.safeTransferFrom(alice, address(clChef), 1);
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] =
            IApexController.EmissionWeight({kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 0});
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);

        weights[0] =
            IApexController.EmissionWeight({kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 0});
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        _sortEmissionWeights(weights);
        controller.rebalanceEmissions(0, 50, weights);
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        clChef.harvest(1, alice);

        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
        assertEq(apex.balanceOf(address(controller)), 50 ether);
        assertEq(controller.rewardLiability(), 50 ether);
    }

    function testRebalanceEmissionsRequiresFullReplacementWeights() public {
        address stablePair = classicFactory.createPair(address(tokenA), address(tokenB), true);
        controller.activateClassicFarm(classicPair, 1000);
        controller.activateClassicFarm(stablePair, 1000);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        vm.expectRevert(
            abi.encodeWithSelector(ApexErrors.ALLOC_POINT_MISMATCH.selector, address(controller), 1000, 2000)
        );
        controller.rebalanceEmissions(100 ether, 100, weights);
    }

    function testRebalanceEmissionsRejectsDuplicatePools() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        weights[1] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.rebalanceEmissions(100 ether, 100, weights);
    }

    function testRebalanceEmissionsRequiresFundingExistingLiability() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        classicChef.deposit(classicChef.pidOf(classicPair), ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);
        apex.mint(address(controller), 50 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ApexErrors.INSUFFICIENT_REWARD_BALANCE.selector, address(controller), 200 ether, 150 ether
            )
        );
        controller.rebalanceEmissions(100 ether, 100, weights);

        apex.mint(address(controller), 50 ether);
        controller.rebalanceEmissions(100 ether, 100, weights);

        assertEq(controller.rewardLiability(), 200 ether);
    }

    function testRebalanceEmissionsPullsAndSplitsVestedEmissionCenterWhenControllerIsShort() public {
        controller.activateClassicFarm(classicPair, 1000);
        EmissionCenter center = new EmissionCenter(address(controller), uint64(block.timestamp), uint64(100));
        apex.mint(address(center), 200 ether);
        controller.setEmissionCenter(address(center));
        vm.warp(block.timestamp + 50);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        controller.rebalanceEmissions(95 ether, 100, weights);

        assertEq(controller.emissionCenter(), address(center));
        assertEq(center.released(address(apex)), 100 ether);
        assertEq(apex.balanceOf(address(controller)), 95 ether);
        assertEq(apex.balanceOf(treasury), 5 ether);
        assertEq(controller.rewardLiability(), 95 ether);
    }

    function testRebalanceEmissionsStillRevertsWhenVestedEmissionCenterIsInsufficient() public {
        controller.activateClassicFarm(classicPair, 1000);
        EmissionCenter center = new EmissionCenter(address(controller), uint64(block.timestamp), uint64(100));
        apex.mint(address(center), 100 ether);
        controller.setEmissionCenter(address(center));
        vm.warp(block.timestamp + 50);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ApexErrors.INSUFFICIENT_REWARD_BALANCE.selector, address(controller), 100 ether, 47.5 ether
            )
        );
        controller.rebalanceEmissions(100 ether, 100, weights);
    }

    function testEmissionCenterReleaseRequiresApexControllerCaller() public {
        EmissionCenter center = new EmissionCenter(address(controller), uint64(block.timestamp), uint64(100));
        apex.mint(address(center), 200 ether);
        vm.warp(block.timestamp + 50);

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(this)));
        center.release(address(apex));
    }

    function testReleaseAndSplitEmissionsCanBeCalledByEmissionOperator() public {
        EmissionCenter center = new EmissionCenter(address(controller), uint64(block.timestamp), uint64(100));
        apex.mint(address(center), 200 ether);
        controller.setEmissionCenter(address(center));
        vm.warp(block.timestamp + 50);

        controller.releaseAndSplitEmissions();

        assertEq(center.released(address(apex)), 100 ether);
        assertEq(apex.balanceOf(address(controller)), 95 ether);
        assertEq(apex.balanceOf(treasury), 5 ether);
    }

    function testSetEmissionCenterRequiresAdminAndContractAddress() public {
        EmissionCenter center = new EmissionCenter(address(controller), uint64(block.timestamp), uint64(100));

        vm.prank(alice);
        vm.expectRevert();
        controller.setEmissionCenter(address(center));

        vm.expectRevert(ApexErrors.ZERO_ADDRESS.selector);
        controller.setEmissionCenter(alice);

        controller.setEmissionCenter(address(center));
        assertEq(controller.emissionCenter(), address(center));

        controller.setEmissionCenter(address(0));
        assertEq(controller.emissionCenter(), address(0));
    }

    function testActivateClassicFarmRoutesFeesToFeeCenter() public {
        controller.activateClassicFarm(classicPair, 1000);

        (, uint256 allocPoint,,,) = classicChef.poolInfo(classicChef.pidOf(classicPair));
        assertEq(allocPoint, 1000);
        assertEq(ClassicPool(classicPair).protocolFee(), 1_000_000);
        assertEq(ClassicPool(classicPair).feeReceiver(), address(feeCenter));
        assertTrue(controller.isFarmRegistered(classicPair));
        assertTrue(controller.isFarmActive(classicPair));
        assertEq(controller.registeredClassicFarmsLength(), 1);
        assertEq(controller.registeredClassicFarmAt(0), classicPair);
        assertEq(controller.registeredCLFarmsLength(), 0);
    }

    function testCollectClassicProtocolFeesBurnsFeeCenterLpIntoTokens() public {
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);
        controller.activateClassicFarm(classicPair, 1000);

        uint256 amountIn = 100 ether;
        tokenA.mint(classicPair, amountIn);
        uint256 amountOut = ClassicPool(classicPair).getAmountOut(amountIn, address(tokenA));
        if (address(tokenA) == ClassicPool(classicPair).token0()) {
            ClassicPool(classicPair).swap(0, amountOut, bob, "");
        } else {
            ClassicPool(classicPair).swap(amountOut, 0, bob, "");
        }

        (uint256 amount0, uint256 amount1) = controller.collectClassicProtocolFees(classicPair);

        assertGt(amount0 + amount1, 0);
        assertEq(ClassicPool(classicPair).balanceOf(address(feeCenter)), 0);
        assertGt(tokenA.balanceOf(address(feeCenter)) + tokenB.balanceOf(address(feeCenter)), 0);
    }

    function testFeeCenterCreatesReceiversAndSplitsRawFeesEqually() public {
        address tokenAReceiver = controller.addFeeReceiver(address(tokenA));
        address feeTokenReceiver = controller.addFeeReceiver(address(feeToken));

        tokenB.mint(address(feeCenter), 100 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenB);
        controller.pushAndSplitFees(tokens);

        assertEq(tokenB.balanceOf(tokenAReceiver), 50 ether);
        assertEq(tokenB.balanceOf(feeTokenReceiver), 50 ether);
        assertEq(feeCenter.receiverForOutput(address(tokenA)), tokenAReceiver);
        assertEq(feeCenter.activeReceiversLength(), 2);
    }

    function testFeeCenterSplitsRawFeesUsingExplicitAprWeights() public {
        address tokenAReceiver = controller.addFeeReceiver(address(tokenA));
        address feeTokenReceiver = controller.addFeeReceiver(address(feeToken));

        tokenB.mint(address(feeCenter), 101 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenB);
        address[] memory receivers = new address[](2);
        receivers[0] = tokenAReceiver;
        receivers[1] = feeTokenReceiver;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 7_500;
        weights[1] = 2_500;

        controller.pushAndSplitFeesWeighted(tokens, receivers, weights);

        assertEq(tokenB.balanceOf(tokenAReceiver), 75.75 ether);
        assertEq(tokenB.balanceOf(feeTokenReceiver), 25.25 ether);
        assertEq(tokenB.balanceOf(address(feeCenter)), 0);
    }

    function testFeeCenterWeightedSplitSupportsFourReceiversAndApportionsTinyBalances() public {
        address[] memory receivers = new address[](4);
        receivers[0] = controller.addFeeReceiver(address(tokenA));
        receivers[1] = controller.addFeeReceiver(address(feeToken));
        receivers[2] = controller.addFeeReceiver(address(apex));
        receivers[3] = controller.addFeeReceiver(address(tokenB));

        uint16[] memory weights = new uint16[](4);
        weights[0] = 4_000;
        weights[1] = 3_000;
        weights[2] = 2_000;
        weights[3] = 1_000;
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenB);
        tokenB.mint(address(feeCenter), 3);

        controller.pushAndSplitFeesWeighted(tokens, receivers, weights);

        assertEq(tokenB.balanceOf(receivers[0]), 1);
        assertEq(tokenB.balanceOf(receivers[1]), 1);
        assertEq(tokenB.balanceOf(receivers[2]), 1);
        assertEq(tokenB.balanceOf(receivers[3]), 0);
        assertEq(tokenB.balanceOf(address(feeCenter)), 0);
    }

    function testFeeCenterWeightedSplitRejectsInvalidReceiverSetsAndWeights() public {
        address tokenAReceiver = controller.addFeeReceiver(address(tokenA));
        address feeTokenReceiver = controller.addFeeReceiver(address(feeToken));
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenB);
        address[] memory receivers = new address[](2);
        receivers[0] = tokenAReceiver;
        receivers[1] = feeTokenReceiver;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6_000;
        weights[1] = 3_999;

        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.pushAndSplitFeesWeighted(tokens, receivers, weights);

        weights[0] = 10_000;
        weights[1] = 0;
        vm.expectRevert(ApexErrors.ZERO_AMOUNT.selector);
        controller.pushAndSplitFeesWeighted(tokens, receivers, weights);

        uint16[] memory shortWeights = new uint16[](1);
        shortWeights[0] = 10_000;
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.pushAndSplitFeesWeighted(tokens, receivers, shortWeights);

        weights[0] = 6_000;
        weights[1] = 4_000;
        receivers[1] = tokenAReceiver;
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.pushAndSplitFeesWeighted(tokens, receivers, weights);

        receivers[1] = feeTokenReceiver;
        controller.removeFeeReceiver(address(feeToken));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, feeTokenReceiver));
        controller.pushAndSplitFeesWeighted(tokens, receivers, weights);
    }

    function testFeeCenterRemovesReceiverFromActiveSplits() public {
        address tokenAReceiver = controller.addFeeReceiver(address(tokenA));
        address feeTokenReceiver = controller.addFeeReceiver(address(feeToken));

        controller.removeFeeReceiver(address(tokenA));
        tokenB.mint(address(feeCenter), 100 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenB);
        controller.pushAndSplitFees(tokens);

        assertEq(feeCenter.receiverForOutput(address(tokenA)), address(0));
        assertFalse(feeCenter.isReceiverActive(tokenAReceiver));
        assertEq(feeCenter.activeReceiversLength(), 1);
        assertEq(tokenB.balanceOf(tokenAReceiver), 0);
        assertEq(tokenB.balanceOf(feeTokenReceiver), 100 ether);
    }

    function testFeeCenterAndReceiverCommandsOnlyAcceptParentCalls() public {
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(this)));
        feeCenter.addReceiver(address(feeToken));

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(this)));
        feeCenter.setCreatorFeeConfig(classicPair, alice, 500, uint8(IApexController.PoolKind.CLASSIC));

        address receiver = controller.addFeeReceiver(address(feeToken));
        feeToken.mint(receiver, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(this)));
        FeeReceiver(receiver).notifyVault(1 ether);
    }

    function testApexVaultRejectsMinRemainingLockAboveVeMaxTime() public {
        uint256 maxTime = veNFT.MAXTIME();
        ApexVault implementation = new ApexVault();
        bytes memory initData =
            abi.encodeCall(ApexVault.initialize, (address(veNFT), address(controller), maxTime + 1, 7 days));
        vm.expectRevert(ApexErrors.INVALID_DURATION.selector);
        new TransparentUpgradeableProxy(address(implementation), address(this), initData);

        vm.expectRevert(ApexErrors.INVALID_DURATION.selector);
        controller.setVaultConfig(maxTime + 1, 7 days);
    }

    function testApexVaultAcceptsMinRemainingLockAtVeMaxTime() public {
        uint256 maxTime = veNFT.MAXTIME();
        ApexVault implementation = new ApexVault();
        bytes memory initData =
            abi.encodeCall(ApexVault.initialize, (address(veNFT), address(controller), maxTime, 7 days));
        ApexVault maxVault =
            ApexVault(address(new TransparentUpgradeableProxy(address(implementation), address(this), initData)));

        assertEq(maxVault.minRemainingLock(), maxTime);
        controller.setVaultConfig(maxTime, 7 days);
        assertEq(vault.minRemainingLock(), maxTime);
    }

    function testFeeReceiverCanSwapAndNotifyVault() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        ApexMockSwapper swapper = new ApexMockSwapper();
        swapper.setAmountOut(90 ether);
        controller.setFeeSwapper(address(swapper), true);

        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);

        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, receiver));
        (uint256 spent, uint256 received) =
            controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 90 ether, data);

        assertEq(spent, 100 ether);
        assertEq(received, 90 ether);
        assertEq(swapper.lastCaller(), receiver);
        assertEq(tokenA.allowance(receiver, address(swapper)), 0);

        controller.notifyFeeReceiverVaultBalance(receiver);

        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingReward(1, address(feeToken)), 90 ether, 1e15);
        assertEq(feeToken.balanceOf(address(vault)), 90 ether);
    }

    function testFeeReceiverSwapRejectsUnapprovedTarget() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);
        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, receiver));

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(swapper)));
        controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 90 ether, data);
    }

    function testFeeReceiverSwapAlwaysRejectsGigaInput() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        swapper.setAmountOut(90 ether);
        controller.setFeeSwapper(address(swapper), true);
        address receiver = controller.addFeeReceiver(address(feeToken));
        apex.mint(receiver, 100 ether);
        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(apex), address(feeToken), 100 ether, receiver));

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.TOKEN_SWAP_FORBIDDEN.selector, address(apex)));
        controller.executeFeeReceiverSwap(receiver, address(apex), address(swapper), 100 ether, 90 ether, data);

        assertEq(apex.balanceOf(receiver), 100 ether);
        assertEq(apex.allowance(receiver, address(swapper)), 0);
    }

    function testFeeReceiverSwapRejectsCallerWithoutOperatorRole() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        swapper.setAmountOut(90 ether);
        controller.setFeeSwapper(address(swapper), true);
        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);
        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, receiver));

        vm.prank(alice);
        vm.expectRevert();
        controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 90 ether, data);
    }

    function testFeeReceiverSwapRejectsZeroMinimumOutput() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        controller.setFeeSwapper(address(swapper), true);
        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);
        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, receiver));

        vm.expectRevert(ApexErrors.ZERO_AMOUNT.selector);
        controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 0, data);
    }

    function testFeeReceiverSwapRevertsWhenCalldataSendsOutputElsewhere() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        swapper.setAmountOut(90 ether);
        controller.setFeeSwapper(address(swapper), true);
        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);
        bytes memory data = abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, bob));

        vm.expectRevert(ApexErrors.INSUFFICIENT_OUTPUT_AMOUNT.selector);
        controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 90 ether, data);

        assertEq(tokenA.balanceOf(receiver), 100 ether);
        assertEq(tokenA.balanceOf(address(swapper)), 0);
        assertEq(feeToken.balanceOf(bob), 0);
        assertEq(tokenA.allowance(receiver, address(swapper)), 0);
    }

    function testFeeReceiverSwapRevertsWhenOutputIsBelowMinimum() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        swapper.setAmountOut(89 ether);
        controller.setFeeSwapper(address(swapper), true);
        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);
        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, receiver));

        vm.expectRevert(ApexErrors.INSUFFICIENT_OUTPUT_AMOUNT.selector);
        controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 90 ether, data);

        assertEq(tokenA.balanceOf(receiver), 100 ether);
        assertEq(feeToken.balanceOf(receiver), 0);
        assertEq(tokenA.allowance(receiver, address(swapper)), 0);
    }

    function testFeeReceiverSwapBubblesTargetRevert() public {
        ApexMockSwapper swapper = new ApexMockSwapper();
        swapper.setShouldRevert(true);
        controller.setFeeSwapper(address(swapper), true);
        address receiver = controller.addFeeReceiver(address(feeToken));
        tokenA.mint(receiver, 100 ether);
        bytes memory data =
            abi.encodeCall(ApexMockSwapper.swap, (address(tokenA), address(feeToken), 100 ether, receiver));

        vm.expectRevert(MockSwapFailed.selector);
        controller.executeFeeReceiverSwap(receiver, address(tokenA), address(swapper), 100 ether, 90 ether, data);

        assertEq(tokenA.balanceOf(receiver), 100 ether);
        assertEq(tokenA.allowance(receiver, address(swapper)), 0);
    }

    function testCannotWhitelistNonContractSwapper() public {
        address nonContract = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.INVALID_TARGET.selector, nonContract));
        controller.setFeeSwapper(nonContract, true);
    }

    function testApexVaultCompoundOnlyConfigStreamsAndRelocks() public {
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](0);

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 10_000);
        vm.stopPrank();

        apex.mint(address(this), 70 ether);
        apex.approve(address(vault), 70 ether);
        controller.notifyVaultCompoundReward(70 ether);

        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingCompound(1), 70 ether, 1e15);
        assertEq(vault.pendingReward(1, address(apex)), 0);
        assertEq(apex.balanceOf(alice), 0);
        (uint16 compoundBps, uint256 compoundWeight) = vault.compoundConfigOf(1);
        assertEq(compoundBps, 10_000);
        assertEq(compoundWeight, 100 ether);

        uint256 compounded = controller.compoundVault(1);

        assertApproxEqAbs(compounded, 70 ether, 1e15);
        assertApproxEqAbs(veNFT.weights(1), 170 ether, 1e15);
        assertEq(vault.pendingCompound(1), 0);
    }

    function testApexVaultMixedConfigSplitsClaimableAndCompoundRewards() public {
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](1);
        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 7_000});

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 3_000);
        vm.stopPrank();

        _notifyVaultReward(70 ether);
        apex.mint(address(this), 30 ether);
        apex.approve(address(vault), 30 ether);
        controller.notifyVaultCompoundReward(30 ether);

        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingReward(1, address(feeToken)), 70 ether, 1e15);
        assertApproxEqAbs(vault.pendingCompound(1), 30 ether, 1e15);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        vm.prank(alice);
        vault.claim(1, tokens);

        assertApproxEqAbs(feeToken.balanceOf(alice), 70 ether, 1e15);
        assertEq(apex.balanceOf(alice), 0);

        assertApproxEqAbs(controller.compoundVault(1), 30 ether, 1e15);
        assertApproxEqAbs(veNFT.weights(1), 130 ether, 1e15);
    }

    function testApexVaultSetUserConfigClaimsAndCompoundsOldConfig() public {
        controller.setVaultRewardToken(address(tokenA), true);
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](1);
        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 7_000});

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 3_000);
        vm.stopPrank();

        _notifyVaultReward(70 ether);
        apex.mint(address(this), 30 ether);
        apex.approve(address(vault), 30 ether);
        controller.notifyVaultCompoundReward(30 ether);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vault.setUserConfig(1, _singleUserConfig(address(tokenA)));

        assertApproxEqAbs(feeToken.balanceOf(alice), 70 ether, 1e15);
        assertEq(vault.pendingReward(1, address(feeToken)), 0);
        assertEq(vault.pendingCompound(1), 0);
        assertApproxEqAbs(veNFT.weights(1), 130 ether, 1e15);

        (, uint256 tokenAWeight) = vault.userConfigOf(1, address(tokenA));
        assertApproxEqAbs(tokenAWeight, 130 ether, 1e15);
    }

    function testApexVaultExpiredCompoundRewardsGoToTreasury() public {
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](0);

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 10_000);
        vm.stopPrank();

        apex.mint(address(this), 70 ether);
        apex.approve(address(vault), 70 ether);
        controller.notifyVaultCompoundReward(70 ether);

        vm.warp(block.timestamp + 27 weeks);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        assertEq(vault.flushInactive(tokenIds), 1);
        assertApproxEqAbs(apex.balanceOf(treasury), 70 ether, 1e15);
        assertEq(vault.pendingCompound(1), 0);
    }

    function testApexVaultZeroWeightRewardsSweepToTreasuryAndNewStakerStartsFresh() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(70 ether);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vault.unstake(1);
        assertApproxEqAbs(feeToken.balanceOf(alice), 10 ether, 1e15);

        vm.warp(block.timestamp + 3 days);

        veNFT.mint(bob, 2, 100 ether);
        vm.startPrank(bob);
        veNFT.approve(address(vault), 2);
        vault.stake(2, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        assertApproxEqAbs(vault.unallocatedReward(address(feeToken)), 30 ether, 1e15);
        assertApproxEqAbs(controller.sweepVaultUnallocated(address(feeToken)), 30 ether, 1e15);
        assertApproxEqAbs(feeToken.balanceOf(treasury), 30 ether, 1e15);

        vm.warp(block.timestamp + 3 days);
        assertApproxEqAbs(vault.pendingReward(2, address(feeToken)), 30 ether, 1e15);
    }

    function testApexVaultCompoundZeroWeightRewardsSweepToTreasury() public {
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](0);

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 10_000);
        vm.stopPrank();

        apex.mint(address(this), 70 ether);
        apex.approve(address(vault), 70 ether);
        controller.notifyVaultCompoundReward(70 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vault.unstake(1);
        assertApproxEqAbs(veNFT.weights(1), 110 ether, 1e15);

        vm.warp(block.timestamp + 6 days);

        assertApproxEqAbs(vault.unallocatedReward(address(veNFT)), 60 ether, 1e15);
        assertApproxEqAbs(controller.sweepVaultUnallocated(address(veNFT)), 60 ether, 1e15);
        assertApproxEqAbs(apex.balanceOf(treasury), 60 ether, 1e15);
    }

    function testFeeReceiverCanNotifyVaultCompoundRewardsOnlyForLockToken() public {
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](0);

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, 10_000);
        vm.stopPrank();

        address receiver = controller.addFeeReceiver(address(apex));
        apex.mint(receiver, 42 ether);
        controller.notifyFeeReceiverVaultCompoundBalance(receiver);

        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingCompound(1), 42 ether, 1e15);
        assertApproxEqAbs(controller.compoundVault(1), 42 ether, 1e15);
        assertApproxEqAbs(veNFT.weights(1), 142 ether, 1e15);

        address feeReceiver = controller.addFeeReceiver(address(feeToken));
        feeToken.mint(feeReceiver, 1 ether);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.notifyFeeReceiverVaultCompoundBalance(feeReceiver);
    }

    function testApexVaultTreatsVeTokenAsCompoundOnly() public {
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.setVaultRewardToken(address(apex), true);

        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        apex.mint(address(this), 1 ether);
        apex.approve(address(vault), 1 ether);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        controller.notifyVaultReward(address(apex), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(apex);
        vm.prank(alice);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        vault.claim(1, tokens);
    }

    function testFeeCenterReceiverImplementationUpgradeAffectsNewAndExistingReceivers() public {
        address receiver = controller.addFeeReceiver(address(feeToken));
        FeeReceiver newImplementation = new FeeReceiver();

        controller.setFeeReceiverImplementation(address(newImplementation));

        assertEq(feeCenter.implementation(), address(newImplementation));
        assertEq(FeeReceiver(receiver).outputToken(), address(feeToken));
    }

    function testFeeCenterProxyAdminOwnerCanUpgradeFeeCenter() public {
        address receiver = controller.addFeeReceiver(address(feeToken));
        FeeCenter implementation = new FeeCenter();
        ProxyAdmin proxyAdmin = ProxyAdmin(feeCenterProxyAdmin);

        assertEq(proxyAdmin.owner(), address(this));
        assertEq(FeeReceiver(receiver).outputToken(), address(feeToken));

        bytes32 implementationBefore = vm.load(address(feeCenter), ERC1967_IMPLEMENTATION_SLOT);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(feeCenter))), address(implementation), ""
        );
        bytes32 implementationAfter = vm.load(address(feeCenter), ERC1967_IMPLEMENTATION_SLOT);

        assertNotEq(implementationAfter, implementationBefore);
        assertEq(implementationAfter, bytes32(uint256(uint160(address(implementation)))));
        assertEq(feeCenter.apexController(), address(controller));
        assertEq(FeeReceiver(receiver).outputToken(), address(feeToken));
    }

    function testActivateCLFarmRegistersPoolAndSetsFullProtocolFee() public {
        controller.activateCLFarm(address(clPool), 1000);

        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(address(clPool));
        (uint256 allocPoint,,,,,) = clChef.poolInfo(clChef.v3PoolAddressPid(address(clPool)));
        assertEq(allocPoint, 1000);
        assertEq(feeProtocol0, 10_000);
        assertEq(feeProtocol1, 10_000);
        assertNotEq(clPool.lmPool(), address(0));
        assertTrue(controller.isFarmRegistered(address(clPool)));
        assertTrue(controller.isFarmActive(address(clPool)));
        assertEq(controller.registeredCLFarmsLength(), 1);
        assertEq(controller.registeredCLFarmAt(0), address(clPool));
        assertEq(controller.registeredClassicFarmsLength(), 0);
    }

    function testActivateCLFarmRejectsNonCanonicalPool() public {
        ApexMockCLPool fakePool = new ApexMockCLPool(address(0xFAc7), clPool.token0(), clPool.token1(), clPool.fee());

        vm.expectRevert(abi.encodeWithSelector(ApexErrors.INVALID_POOL.selector, address(fakePool)));
        controller.activateCLFarm(address(fakePool), 1000);
    }

    function testRebalanceEmissionsRequiresFundedClassicChef() public {
        controller.activateClassicFarm(classicPair, 1000);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        vm.expectRevert(
            abi.encodeWithSelector(ApexErrors.INSUFFICIENT_REWARD_BALANCE.selector, address(controller), 100 ether, 0)
        );
        controller.rebalanceEmissions(100 ether, 100, weights);
    }

    function testRebalanceEmissionsWithZeroAmountAndNoLeftoverClearsRate() public {
        controller.activateClassicFarm(classicPair, 1000);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        controller.rebalanceEmissions(0, 100, weights);

        assertEq(controller.rewardLiability(), 0);
        assertEq(controller.latestPeriodRewardPerSecond(), 0);
        assertEq(controller.latestPeriodEndTime(), block.timestamp);
    }

    function testClassicZeroStakeIntervalForfeitsUnclaimableEmissions() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        controller.rebalanceEmissions(100 ether, 100, weights);
        assertEq(controller.rewardLiability(), 100 ether);

        vm.warp(block.timestamp + 100);
        controller.rebalanceEmissions(0, 100, weights);

        assertEq(controller.rewardLiability(), 0);
        assertEq(apex.balanceOf(address(controller)), 100 ether);
    }

    function testCLZeroLmLiquidityIntervalForfeitsUnclaimableEmissions() public {
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 100 ether);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });

        controller.rebalanceEmissions(100 ether, 100, weights);
        assertEq(controller.rewardLiability(), 100 ether);

        vm.warp(block.timestamp + 100);
        controller.rebalanceEmissions(0, 100, weights);

        assertEq(controller.rewardLiability(), 0);
        assertEq(apex.balanceOf(address(controller)), 100 ether);
    }

    function testRebalanceEmissionsRequiresFundedCLChef() public {
        controller.activateCLFarm(address(clPool), 1000);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });

        vm.expectRevert(
            abi.encodeWithSelector(ApexErrors.INSUFFICIENT_REWARD_BALANCE.selector, address(controller), 100 ether, 0)
        );
        controller.rebalanceEmissions(100 ether, 100, weights);
    }

    function testCLChefPaysStakedNftByLiquidityRangeAccounting() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 100 ether);

        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });

        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        clChef.harvest(1, alice);

        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
    }

    function testCLChefRollsRemainingWindowIntoNewPeriodAndStopsAtEnd() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 200 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);
        controller.rebalanceEmissions(100 ether, 100, weights);

        (uint256 rewardPerSecond, uint256 endTime) = controller.getLatestPeriodInfo(address(clPool));
        assertEq(rewardPerSecond, (uint256(200 ether) * controller.REWARD_PRECISION()) / 100);
        assertEq(endTime, block.timestamp + 100);
        assertEq(controller.latestPeriodEndTime(), block.timestamp + 100);

        vm.warp(block.timestamp + 150);

        vm.prank(alice);
        uint256 paid = clChef.harvest(1, alice);

        assertApproxEqAbs(paid, 200 ether, 1);
        assertApproxEqAbs(apex.balanceOf(alice), 200 ether, 1);
        assertEq(controller.rewardLiability(), 0);
    }

    function testFuzzCLChefFiniteEndTimeAccruesNearUint32Limit(uint32 _startOffset, uint32 _elapsed) public {
        _startOffset = uint32(bound(_startOffset, 2 days, 30 days));
        _elapsed = uint32(bound(_elapsed, 1, _min(_startOffset - 1 days, 1_000_000)));
        uint256 startTime = uint256(type(uint32).max) - _startOffset;
        vm.warp(startTime);

        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 1_000_000 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(1_000_000 ether, _startOffset - 1 days, weights);

        vm.warp(startTime + _elapsed);

        vm.prank(alice);
        uint256 paid = clChef.harvest(1, alice);

        uint256 expected =
            (uint256(_elapsed) * ((uint256(1_000_000 ether) * controller.REWARD_PRECISION()) / (_startOffset - 1 days)))
                / controller.REWARD_PRECISION();
        assertApproxEqAbs(paid, expected, 1);
    }

    function testFuzzCLChefFullWindowLiabilityDustIsBounded(uint96 _amount, uint32 _duration) public {
        uint256 amount = bound(uint256(_amount), 1, 1_000_000 ether);
        uint256 duration = bound(uint256(_duration), 1, 30 days);

        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), amount);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(amount, duration, weights);

        vm.warp(block.timestamp + duration);
        vm.prank(alice);
        uint256 paid = clChef.harvest(1, alice);

        assertLe(paid, amount, "cl overpaid");
        assertLe(amount - paid, 2, "cl dust exceeded raw-unit bound");
        assertLe(controller.rewardLiability(), 2, "cl liability dust exceeded bound");
    }

    function testRebalanceEmissionsRejectsWindowPastUint32Max() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        vm.warp(uint256(type(uint32).max) - 10);
        vm.expectRevert(ApexErrors.INVALID_DURATION.selector);
        controller.rebalanceEmissions(100 ether, 11, weights);
    }

    function testPayRewardShortPaysWhenReserveIsLowerThanRequested() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 100 ether);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.prank(address(classicChef));
        uint256 paid = controller.payReward(classicPair, alice, 150 ether);

        assertEq(paid, 100 ether);
        assertEq(apex.balanceOf(alice), 100 ether);
        assertEq(controller.rewardLiability(), 0);
    }

    function testCLWithdrawReturnsNftWhenRewardBalanceIsShort() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 100 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });

        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);
        deal(address(apex), address(controller), 10 ether);

        vm.prank(alice);
        uint256 paid = clChef.withdraw(1, alice);

        assertEq(paid, 10 ether);
        assertEq(apex.balanceOf(alice), 10 ether);
        assertEq(clNfp.ownerOf(1), alice);
        assertEq(controller.rewardLiability(), 90 ether);
    }

    function testCLMevResistanceSlashesEarlyHarvestAndReleasesReserve() public {
        controller.activateCLFarm(address(clPool), 1000);
        controller.setCLMevResistanceWindow(100);
        apex.mint(address(controller), 100 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        vm.prank(alice);
        uint256 earlyPaid = clChef.harvest(1, alice);

        assertEq(earlyPaid, 0);
        assertEq(apex.balanceOf(alice), 0);
        assertApproxEqAbs(controller.rewardLiability(), 50 ether, 1);

        vm.warp(block.timestamp + 50);
        vm.prank(alice);
        uint256 maturePaid = clChef.harvest(1, alice);

        assertApproxEqAbs(maturePaid, 50 ether, 1);
        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
        assertEq(controller.rewardLiability(), 0);
    }

    function testCLMevResistanceDoesNotTrapWithdrawInsideWindow() public {
        controller.activateCLFarm(address(clPool), 1000);
        controller.setCLMevResistanceWindow(100);
        apex.mint(address(controller), 100 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        vm.prank(alice);
        uint256 paid = clChef.withdraw(1, alice);

        assertEq(paid, 0);
        assertEq(apex.balanceOf(alice), 0);
        assertEq(clNfp.ownerOf(1), alice);
        assertApproxEqAbs(controller.rewardLiability(), 50 ether, 1);
    }

    function testDeactivateClassicFarmRestoresDefaultFeesAndBlocksRebalance() public {
        controller.activateClassicFarm(classicPair, 1000);
        controller.deactivateClassicFarm(classicPair);

        (, uint256 allocPoint,,,) = classicChef.poolInfo(classicChef.pidOf(classicPair));
        assertEq(allocPoint, 0);
        assertEq(ClassicPool(classicPair).protocolFee(), 200_000);
        assertEq(ClassicPool(classicPair).feeReceiver(), classicFactory.feeReceiver());
        assertFalse(controller.isFarmActive(classicPair));

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });

        vm.expectRevert(abi.encodeWithSignature("FARM_INACTIVE(address)", classicPair));
        controller.rebalanceEmissions(100 ether, 100, weights);
    }

    function testClassicFarmCanReactivateWithoutDuplicateRegistrationOrPid() public {
        controller.activateClassicFarm(classicPair, 1000);
        uint256 pid = classicChef.pidOf(classicPair);

        controller.deactivateClassicFarm(classicPair);
        controller.activateClassicFarm(classicPair, 2500);

        (, uint256 allocPoint,,,) = classicChef.poolInfo(pid);
        assertEq(classicChef.pidOf(classicPair), pid);
        assertEq(allocPoint, 2500);
        assertEq(classicChef.poolLength(), 1);
        assertEq(controller.registeredClassicFarmsLength(), 1);
        assertEq(controller.registeredClassicFarmAt(0), classicPair);
        assertTrue(controller.isFarmRegistered(classicPair));
        assertTrue(controller.isFarmActive(classicPair));
        assertEq(ClassicPool(classicPair).protocolFee(), 1_000_000);
        assertEq(ClassicPool(classicPair).feeReceiver(), address(feeCenter));
    }

    function testClassicFarmDeactivationWipesCustomFeeConfigByDesign() public {
        controller.overrideClassicProtocolFee(classicPair, 300_000);
        controller.overrideClassicFeeReceiver(classicPair, address(0xBEEF));
        assertEq(ClassicPool(classicPair).protocolFee(), 300_000);
        assertEq(ClassicPool(classicPair).feeReceiver(), address(0xBEEF));

        controller.activateClassicFarm(classicPair, 1000);
        assertEq(ClassicPool(classicPair).protocolFee(), 1_000_000);
        assertEq(ClassicPool(classicPair).feeReceiver(), address(feeCenter));

        controller.deactivateClassicFarm(classicPair);
        assertEq(ClassicPool(classicPair).protocolFee(), 200_000);
        assertEq(ClassicPool(classicPair).feeReceiver(), classicFactory.feeReceiver());
    }

    function testClassicFarmCanReactivateAfterExpiredWindowAndEarnAgain() public {
        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), 200 ether);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 pid = classicChef.pidOf(classicPair);
        classicChef.deposit(pid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        controller.stopAllEmissions();
        controller.deactivateClassicFarm(classicPair);
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        classicChef.harvest(pid);
        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);

        controller.activateClassicFarm(classicPair, 1000);
        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        classicChef.harvest(pid);
        assertApproxEqAbs(apex.balanceOf(alice), 100 ether, 2);
    }

    function testDeactivateCLFarmRestoresDefaultFeesAndKeepsLmPool() public {
        controller.activateCLFarm(address(clPool), 1000);
        address lmPool = clPool.lmPool();

        controller.deactivateCLFarm(address(clPool));

        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(address(clPool));
        (uint256 allocPoint,,,,,) = clChef.poolInfo(clChef.v3PoolAddressPid(address(clPool)));
        assertEq(allocPoint, 0);
        assertEq(feeProtocol0, 2000);
        assertEq(feeProtocol1, 2000);
        assertEq(clPool.lmPool(), lmPool);
        assertFalse(controller.isFarmActive(address(clPool)));
    }

    function testCLFarmCanReactivateWithoutDuplicateRegistrationOrPid() public {
        controller.activateCLFarm(address(clPool), 1000);
        uint256 pid = clChef.v3PoolAddressPid(address(clPool));
        address lmPool = clPool.lmPool();

        controller.deactivateCLFarm(address(clPool));
        controller.activateCLFarm(address(clPool), 2500);

        (uint256 allocPoint,,,,,) = clChef.poolInfo(pid);
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(address(clPool));
        assertEq(clChef.v3PoolAddressPid(address(clPool)), pid);
        assertEq(clPool.lmPool(), lmPool);
        assertEq(allocPoint, 2500);
        assertEq(clChef.poolLength(), 1);
        assertEq(controller.registeredCLFarmsLength(), 1);
        assertEq(controller.registeredCLFarmAt(0), address(clPool));
        assertTrue(controller.isFarmRegistered(address(clPool)));
        assertTrue(controller.isFarmActive(address(clPool)));
        assertEq(feeProtocol0, 10_000);
        assertEq(feeProtocol1, 10_000);
    }

    function testCLFarmDeactivationWipesCustomFeeConfigByDesign() public {
        controller.overrideCLProtocolFee(address(clPool), 2500, 4000);
        (uint32 feeProtocol0, uint32 feeProtocol1) = clFactory.feeProtocols(address(clPool));
        assertEq(feeProtocol0, 2500);
        assertEq(feeProtocol1, 4000);

        controller.activateCLFarm(address(clPool), 1000);
        (feeProtocol0, feeProtocol1) = clFactory.feeProtocols(address(clPool));
        assertEq(feeProtocol0, 10_000);
        assertEq(feeProtocol1, 10_000);

        controller.deactivateCLFarm(address(clPool));
        (feeProtocol0, feeProtocol1) = clFactory.feeProtocols(address(clPool));
        assertEq(feeProtocol0, 2000);
        assertEq(feeProtocol1, 2000);
    }

    function testCLFarmCanReactivateAfterExpiredWindowAndEarnAgain() public {
        controller.setCLMevResistanceWindow(0);
        controller.activateCLFarm(address(clPool), 1000);
        apex.mint(address(controller), 200 ether);
        clNfp.mintPosition(alice, 1, clPool.token0(), clPool.token1(), clPool.fee(), -60, 60, 100);

        vm.prank(alice);
        clNfp.safeTransferFrom(alice, address(clChef), 1);

        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CL, pool: address(clPool), allocPoint: 1000
        });
        controller.rebalanceEmissions(100 ether, 100, weights);

        vm.warp(block.timestamp + 50);
        controller.stopAllEmissions();
        controller.deactivateCLFarm(address(clPool));
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        clChef.harvest(1, alice);
        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);

        controller.activateCLFarm(address(clPool), 1000);
        controller.rebalanceEmissions(100 ether, 100, weights);
        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        clChef.harvest(1, alice);
        assertApproxEqAbs(apex.balanceOf(alice), 100 ether, 2);
    }

    function testApexVaultDistributesOnlyPostStakeRewards() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(100 ether);
        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingReward(1, address(feeToken)), 100 ether, 1e15);

        veNFT.mint(bob, 2, 100 ether);
        vm.startPrank(bob);
        veNFT.approve(address(vault), 2);
        vault.stake(2, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        assertEq(vault.pendingReward(2, address(feeToken)), 0);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);

        vm.prank(alice);
        vault.claim(1, tokens);

        assertApproxEqAbs(feeToken.balanceOf(alice), 100 ether, 1e15);
        assertEq(feeToken.balanceOf(bob), 0);
    }

    function testApexVaultUnstakeClaimsRewardsAndReturnsVeNFT() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(100 ether);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vault.unstake(1);

        assertEq(veNFT.ownerOf(1), alice);
        assertApproxEqAbs(feeToken.balanceOf(alice), 100 ether, 1e15);
        assertEq(vault.pendingReward(1, address(feeToken)), 0);
        assertEq(vault.positionOwner(1), address(0));
    }

    function testApexVaultCanClaimAccruedRewardAfterTokenIsDisabled() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(100 ether);
        vm.warp(block.timestamp + 7 days);
        controller.setVaultRewardToken(address(feeToken), false);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        vm.prank(alice);
        vault.claim(1, tokens);

        assertApproxEqAbs(feeToken.balanceOf(alice), 100 ether, 1e15);
    }

    function testApexVaultCanReuseConfigAfterReset() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vault.setUserConfig(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        (uint16 bps, uint256 weight) = vault.userConfigOf(1, address(feeToken));
        assertEq(bps, 10_000);
        assertEq(weight, 100 ether);
    }

    function testApexVaultAcceptsExactUniqueFullAllocation() public {
        controller.setVaultRewardToken(address(tokenA), true);
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](2);
        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 6_000});
        configs[1] = ApexVault.UserConfig({rewardToken: address(tokenA), bps: 4_000});

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs);
        vm.stopPrank();

        (, uint256 feeWeight) = vault.userConfigOf(1, address(feeToken));
        (, uint256 tokenAWeight) = vault.userConfigOf(1, address(tokenA));
        assertEq(feeWeight, 60 ether);
        assertEq(tokenAWeight, 40 ether);
    }

    function testApexVaultRewardTokenEnumerationDoesNotDuplicateOnReenable() public {
        ApexEmissionMockERC20 rewardToken = new ApexEmissionMockERC20("Reward Token", "RWD");
        uint256 lengthBefore = vault.rewardTokensLength();

        controller.setVaultRewardToken(address(rewardToken), true);
        assertEq(vault.rewardTokensLength(), lengthBefore + 1);
        assertEq(vault.rewardTokenAt(lengthBefore), address(rewardToken));
        assertTrue(vault.isRewardToken(address(rewardToken)));

        controller.setVaultRewardToken(address(rewardToken), false);
        assertEq(vault.rewardTokensLength(), lengthBefore + 1);
        assertFalse(vault.isRewardToken(address(rewardToken)));

        controller.setVaultRewardToken(address(rewardToken), true);
        assertEq(vault.rewardTokensLength(), lengthBefore + 1);
        assertEq(vault.rewardTokenAt(lengthBefore), address(rewardToken));
        assertTrue(vault.isRewardToken(address(rewardToken)));
    }

    function testApexVaultRejectsDuplicateRewardTokensInConfig() public {
        veNFT.mint(alice, 1, 100 ether);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](2);
        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 5_000});
        configs[1] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 5_000});

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        vault.stake(1, configs);
        vm.stopPrank();
    }

    function testApexVaultRejectsConfigThatIsNotExactlyFullAllocation() public {
        veNFT.mint(alice, 1, 100 ether);

        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](1);
        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 9_999});
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        vault.stake(1, configs);

        configs[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 10_001});
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        vault.stake(1, configs);
        vm.stopPrank();
    }

    function testApexVaultRejectsZeroDisabledAndTooManyConfigEntries() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);

        ApexVault.UserConfig[] memory zeroBps = new ApexVault.UserConfig[](1);
        zeroBps[0] = ApexVault.UserConfig({rewardToken: address(feeToken), bps: 0});
        vm.expectRevert(ApexErrors.ZERO_AMOUNT.selector);
        vault.stake(1, zeroBps);

        ApexVault.UserConfig[] memory disabledToken = new ApexVault.UserConfig[](1);
        disabledToken[0] = ApexVault.UserConfig({rewardToken: address(tokenA), bps: 10_000});
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_AUTHORIZED.selector, address(tokenA)));
        vault.stake(1, disabledToken);

        ApexVault.UserConfig[] memory tooManyEntries = new ApexVault.UserConfig[](17);
        vm.expectRevert(ApexErrors.INVALID_ASSORTMENT.selector);
        vault.stake(1, tooManyEntries);
        vm.stopPrank();
    }

    function testApexVaultFlushInactiveStopsFutureEarnings() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(70 ether);
        vm.warp(block.timestamp + 5 weeks);

        veNFT.mint(bob, 2, 100 ether);
        vm.startPrank(bob);
        veNFT.approve(address(vault), 2);
        vault.stake(2, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        uint256[] memory pagedTokenIds = vault.activePositionIds(1, type(uint256).max);
        assertEq(pagedTokenIds.length, 1);
        assertEq(pagedTokenIds[0], 2);

        assertTrue(vault.isFlushable(1));
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        assertEq(vault.flushInactive(tokenIds), 1);

        assertFalse(vault.positionActive(1));
        assertEq(vault.activePositionsLength(), 1);
        assertEq(vault.activePositionIds(0, 10)[0], 2);

        _notifyVaultReward(70 ether);
        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingReward(1, address(feeToken)), 70 ether, 1e15);
        assertApproxEqAbs(vault.pendingReward(2, address(feeToken)), 70 ether, 1e15);
    }

    function testApexVaultOwnerCanReactivateFlushedPosition() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        vm.warp(block.timestamp + 5 weeks);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        assertEq(vault.flushInactive(tokenIds), 1);

        vm.prank(alice);
        vault.extendLock(1, 26 weeks);

        assertTrue(vault.positionActive(1));
        assertEq(vault.activePositionsLength(), 1);

        (uint16 bps, uint256 weight) = vault.userConfigOf(1, address(feeToken));
        assertEq(bps, 10_000);
        assertEq(weight, 100 ether);
    }

    function testApexVaultClaimAndExtendPaysAndReactivatesFlushedPosition() public {
        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(70 ether);
        vm.warp(block.timestamp + 5 weeks);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        assertEq(vault.flushInactive(tokenIds), 1);
        assertFalse(vault.positionActive(1));

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        vm.prank(alice);
        vault.claimAndExtendLock(1, tokens);

        assertApproxEqAbs(feeToken.balanceOf(alice), 70 ether, 1e15);
        assertTrue(vault.positionActive(1));
        assertEq(vault.activePositionsLength(), 1);
        assertFalse(vault.isFlushable(1));
        assertEq(veNFT.lockEnd(1), block.timestamp + 26 weeks);

        (uint16 bps, uint256 weight) = vault.userConfigOf(1, address(feeToken));
        assertEq(bps, 10_000);
        assertEq(weight, 100 ether);

        _notifyVaultReward(40 ether);
        vm.warp(block.timestamp + 7 days);

        assertApproxEqAbs(vault.pendingReward(1, address(feeToken)), 40 ether, 1e15);
    }

    function testApexControllerRolesAreEnumerable() public {
        bytes32 feeOperator = controller.FEE_OPERATOR();

        assertEq(controller.getRoleMemberCount(feeOperator), 1);
        assertEq(controller.getRoleMember(feeOperator, 0), address(this));

        controller.grantRole(feeOperator, alice);
        assertEq(controller.getRoleMemberCount(feeOperator), 2);
        assertTrue(controller.hasRole(feeOperator, alice));

        controller.revokeRole(feeOperator, alice);
        assertEq(controller.getRoleMemberCount(feeOperator), 1);
        assertFalse(controller.hasRole(feeOperator, alice));
    }

    function testDefaultAdminCanRotateTreasuryAndVaultSweepsUseNewTreasury() public {
        controller.setTreasury(bob);
        assertEq(controller.treasury(), bob);

        veNFT.mint(alice, 1, 100 ether);
        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, _singleUserConfig(address(feeToken)));
        vm.stopPrank();

        _notifyVaultReward(70 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vault.unstake(1);
        vm.warp(block.timestamp + 3 days);

        assertApproxEqAbs(controller.sweepVaultUnallocated(address(feeToken)), 30 ether, 1e15);
        assertApproxEqAbs(feeToken.balanceOf(bob), 30 ether, 1e15);
        assertEq(feeToken.balanceOf(treasury), 0);
    }

    function testTreasuryRotationRequiresDefaultAdminAndRejectsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert();
        controller.setTreasury(bob);

        vm.expectRevert(ApexErrors.ZERO_ADDRESS.selector);
        controller.setTreasury(address(0));

        assertEq(controller.treasury(), treasury);
    }

    function testApexControllerProxyAdminOwnerCanUpgrade() public {
        ApexController implementation = new ApexController();
        ProxyAdmin proxyAdmin = ProxyAdmin(_proxyAdmin(address(controller)));

        assertEq(proxyAdmin.owner(), address(this));

        bytes32 implementationBefore = vm.load(address(controller), ERC1967_IMPLEMENTATION_SLOT);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(controller))), address(implementation), ""
        );
        bytes32 implementationAfter = vm.load(address(controller), ERC1967_IMPLEMENTATION_SLOT);

        assertNotEq(implementationAfter, implementationBefore);
        assertEq(implementationAfter, bytes32(uint256(uint160(address(implementation)))));
        assertEq(controller.treasury(), treasury);
    }

    function testApexControllerUpgradeRequiresProxyAdminOwner() public {
        ApexController implementation = new ApexController();
        ProxyAdmin proxyAdmin = ProxyAdmin(_proxyAdmin(address(controller)));

        vm.prank(alice);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(controller))), address(implementation), ""
        );
    }

    function _deployControllerProxy(address admin) internal returns (ApexController controller_) {
        ApexController implementation = new ApexController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, "");
        controller_ = ApexController(address(proxy));
    }

    function _deployFeeCenterProxy(address controller_, address vault_, address receiverImplementation)
        internal
        returns (FeeCenter feeCenter_)
    {
        FeeCenter implementation = new FeeCenter();
        bytes memory initData = abi.encodeCall(FeeCenter.initialize, (controller_, vault_, receiverImplementation));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        feeCenterImplementation = address(implementation);
        feeCenterProxyAdmin = _proxyAdmin(address(proxy));
        feeCenter_ = FeeCenter(address(proxy));
    }

    function _deployVaultProxy(address veNFT_, address controller_) internal returns (ApexVault vault_) {
        ApexVault implementation = new ApexVault();
        bytes memory initData = abi.encodeCall(ApexVault.initialize, (veNFT_, controller_, 22 weeks, 7 days));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        vault_ = ApexVault(address(proxy));
    }

    function _singleUserConfig(address rewardToken) internal pure returns (ApexVault.UserConfig[] memory configs) {
        configs = new ApexVault.UserConfig[](1);
        configs[0] = ApexVault.UserConfig({rewardToken: rewardToken, bps: 10_000});
    }

    function _sortEmissionWeights(IApexController.EmissionWeight[] memory weights) internal pure {
        for (uint256 i = 1; i < weights.length; ++i) {
            IApexController.EmissionWeight memory key = weights[i];
            uint256 j = i;
            while (j != 0 && weights[j - 1].pool > key.pool) {
                weights[j] = weights[j - 1];
                --j;
            }
            weights[j] = key;
        }
    }

    function _notifyVaultReward(uint256 amount) internal {
        feeToken.mint(address(this), amount);
        feeToken.approve(address(vault), amount);
        controller.notifyVaultReward(address(feeToken), amount);
    }

    function _initializeController(
        address admin,
        address treasury_,
        address rewardToken,
        address _classicFactory,
        address classicChef_,
        address clMasterChef,
        address apexVault,
        address feeCenter_
    ) internal {
        controller.initialize(IApexController.InitParams({admin: admin, treasury: treasury_}));
        controller.initializeProtocol(
            IApexController.ProtocolParams({
                rewardToken: rewardToken,
                classicFactory: _classicFactory,
                clFactory: address(clFactory),
                classicChef: classicChef_,
                clMasterChef: clMasterChef,
                apexVault: apexVault,
                feeCenter: feeCenter_
            })
        );
    }

    function _initializeFreshController(
        ApexController controller_,
        address rewardToken,
        address _classicFactory,
        address classicChef_,
        address clMasterChef,
        address apexVault,
        address feeCenter_,
        address clFactory_
    ) internal {
        controller_.initializeProtocol(
            IApexController.ProtocolParams({
                rewardToken: rewardToken,
                classicFactory: _classicFactory,
                clFactory: clFactory_,
                classicChef: classicChef_,
                clMasterChef: clMasterChef,
                apexVault: apexVault,
                feeCenter: feeCenter_
            })
        );
    }

    function _assertLauncherClassicSplit(
        address caller,
        address creator,
        uint16 creatorFeeBps,
        string memory name,
        string memory symbol
    ) internal {
        ApexEmissionMockERC20 pairedToken = new ApexEmissionMockERC20(name, symbol);
        vm.prank(caller);
        address pool = controller.createLauncherClassicPool(address(tokenA), address(pairedToken), false);
        _addLiquidity(pool, caller, 1_000 ether, 1_000 ether);

        address tokenIn = ClassicPool(pool).token0();
        ApexEmissionMockERC20(tokenIn).mint(pool, 100 ether);
        uint256 amountOut = ClassicPool(pool).getAmountOut(100 ether, tokenIn);
        ClassicPool(pool).swap(0, amountOut, caller, "");
        (uint256 amount0, uint256 amount1) = controller.collectLauncherClassicProtocolFees(pool);

        assertEq(ApexEmissionMockERC20(ClassicPool(pool).token0()).balanceOf(creator), amount0 * creatorFeeBps / 2_000);
        assertEq(ApexEmissionMockERC20(ClassicPool(pool).token1()).balanceOf(creator), amount1 * creatorFeeBps / 2_000);
        IFeeCenter.CreatorFeeConfig memory config = feeCenter.creatorFeeConfig(pool);
        assertEq(config.recipient, creator);
        assertEq(config.feeBps, creatorFeeBps);
    }

    function _assertLauncherCLSplit(
        address caller,
        address creator,
        uint16 creatorFeeBps,
        string memory name,
        string memory symbol
    ) internal {
        ApexEmissionMockERC20 pairedToken = new ApexEmissionMockERC20(name, symbol);
        vm.prank(caller);
        address pool = controller.createLauncherCLPool(address(feeToken), address(pairedToken), 100, 1 << 96);
        ApexMockCLPool(pool).seedProtocolFees(20 ether, 40 ether);
        controller.collectLauncherCLProtocolFees(pool);

        assertEq(
            ApexEmissionMockERC20(ApexMockCLPool(pool).token0()).balanceOf(creator),
            20 ether * uint256(creatorFeeBps) / 2_000
        );
        assertEq(
            ApexEmissionMockERC20(ApexMockCLPool(pool).token1()).balanceOf(creator),
            40 ether * uint256(creatorFeeBps) / 2_000
        );
        IFeeCenter.CreatorFeeConfig memory config = feeCenter.creatorFeeConfig(pool);
        assertEq(config.recipient, creator);
        assertEq(config.feeBps, creatorFeeBps);
    }

    function _addLiquidity(address pair, address to, uint256 amount0, uint256 amount1) internal {
        ApexEmissionMockERC20(ClassicPool(pair).token0()).mint(pair, amount0);
        ApexEmissionMockERC20(ClassicPool(pair).token1()).mint(pair, amount1);
        ClassicPool(pair).mint(to);
    }

    function _min(uint32 a, uint32 b) internal pure returns (uint32) {
        return a < b ? a : b;
    }

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT))));
    }
}
