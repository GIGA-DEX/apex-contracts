// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

import {
    ApexEmissionMockERC20,
    ApexMockCLFeeFactory,
    ApexMockCLPool,
    ApexMockCLPositionManager,
    ApexMockVeNFT
} from "../ApexControllerEmissions.t.sol";
import {ApexController} from "../../src/core/ApexController.sol";
import {ApexVault} from "../../src/core/ApexVault.sol";
import {ClassicChef} from "../../src/core/ClassicChef.sol";
import {ClassicFactory} from "../../src/core/ClassicFactory.sol";
import {ClassicPool} from "../../src/core/ClassicPool.sol";
import {CLMasterChef} from "../../src/core/CLMasterChef.sol";
import {EmissionCenter} from "../../src/core/EmissionCenter.sol";
import {FeeCenter} from "../../src/core/FeeCenter.sol";
import {FeeReceiver} from "../../src/core/FeeReceiver.sol";
import {IApexController} from "../../src/core/interfaces/IApexController.sol";

contract SymbolicEmissionsTest is Test {
    uint256 internal constant MAX_SYMBOLIC_EMISSION = 1_000_000 ether;

    ApexController internal controller;
    ClassicFactory internal classicFactory;
    ClassicChef internal classicChef;
    CLMasterChef internal clChef;
    ApexVault internal vault;
    FeeCenter internal feeCenter;
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
        feeCenter = _deployFeeCenterProxy(address(controller), address(vault), address(new FeeReceiver()));
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

    function fuzzOnly_classicEmissionCannotPayMoreThanFundedWindow(uint96 _amount, uint24 _duration, uint24 _elapsed)
        public
    {
        _classicEmissionCannotPayMoreThanFundedWindow(_amount, _duration, _elapsed);
    }

    function testFuzz_classicEmissionCannotPayMoreThanFundedWindow(uint96 _amount, uint24 _duration, uint24 _elapsed)
        public
    {
        _classicEmissionCannotPayMoreThanFundedWindow(_amount, _duration, _elapsed);
    }

    function fuzzOnly_rebalanceLiabilityNeverExceedsControllerBalance(uint96 _amount, uint24 _duration) public {
        _rebalanceLiabilityNeverExceedsControllerBalance(_amount, _duration);
    }

    function testFuzz_rebalanceLiabilityNeverExceedsControllerBalance(uint96 _amount, uint24 _duration) public {
        _rebalanceLiabilityNeverExceedsControllerBalance(_amount, _duration);
    }

    function fuzzOnly_emissionCenterReleaseSplitConservesReleasedTokens(uint96 _amount, uint24 _elapsed) public {
        _emissionCenterReleaseSplitConservesReleasedTokens(_amount, _elapsed);
    }

    function testFuzz_emissionCenterReleaseSplitConservesReleasedTokens(uint96 _amount, uint24 _elapsed) public {
        _emissionCenterReleaseSplitConservesReleasedTokens(_amount, _elapsed);
    }

    function _classicEmissionCannotPayMoreThanFundedWindow(uint96 _amount, uint24 _duration, uint24 _elapsed) internal {
        uint256 amount = _boundEmissionAmount(_amount);
        uint256 duration = _boundDuration(_duration);
        uint256 elapsed = bound(uint256(_elapsed), 0, duration * 2);

        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), amount);
        _addLiquidity(classicPair, alice, 1_000 ether, 1_000 ether);

        vm.startPrank(alice);
        ClassicPool(classicPair).approve(address(classicChef), type(uint256).max);
        uint256 pid = classicChef.pidOf(classicPair);
        classicChef.deposit(pid, ClassicPool(classicPair).balanceOf(alice));
        vm.stopPrank();

        IApexController.EmissionWeight[] memory weights = _singleClassicWeight(1000);
        controller.rebalanceEmissions(amount, duration, weights);

        vm.warp(block.timestamp + elapsed);
        uint256 pending = classicChef.pendingReward(pid, alice);

        assertLe(pending, amount, "classic farm over-accrued funded window");
    }

    function _rebalanceLiabilityNeverExceedsControllerBalance(uint96 _amount, uint24 _duration) internal {
        uint256 amount = _boundEmissionAmount(_amount);
        uint256 duration = _boundDuration(_duration);

        controller.activateClassicFarm(classicPair, 1000);
        apex.mint(address(controller), amount);

        IApexController.EmissionWeight[] memory weights = _singleClassicWeight(1000);
        controller.rebalanceEmissions(amount, duration, weights);

        assertLe(controller.rewardLiability(), apex.balanceOf(address(controller)), "liability exceeds funded balance");
        assertLe(controller.latestPeriodRewardPerSecond(), amount * controller.REWARD_PRECISION(), "bad emission rate");
    }

    function _emissionCenterReleaseSplitConservesReleasedTokens(uint96 _amount, uint24 _elapsed) internal {
        uint256 amount = _boundEmissionAmount(_amount);
        uint256 elapsed = bound(uint256(_elapsed), 0, 100);

        EmissionCenter center = new EmissionCenter(address(controller), uint64(block.timestamp), uint64(100));
        apex.mint(address(center), amount);
        controller.setEmissionCenter(address(center));

        vm.warp(block.timestamp + elapsed);
        uint256 controllerBefore = apex.balanceOf(address(controller));
        uint256 treasuryBefore = apex.balanceOf(treasury);

        controller.releaseAndSplitEmissions();
        uint256 controllerDelta = apex.balanceOf(address(controller)) - controllerBefore;
        uint256 treasuryDelta = apex.balanceOf(treasury) - treasuryBefore;
        uint256 released = controllerDelta + treasuryDelta;

        assertEq(controllerDelta + treasuryDelta, released, "release split lost tokens");
        assertEq(treasuryDelta, released / 20, "treasury split must be five percent");
        assertEq(controllerDelta, released - treasuryDelta, "controller split mismatch");
        assertEq(center.released(address(apex)), released, "vesting release accounting mismatch");
    }

    function _singleClassicWeight(uint256 _allocPoint)
        internal
        view
        returns (IApexController.EmissionWeight[] memory weights)
    {
        weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight({
            kind: IApexController.PoolKind.CLASSIC, pool: classicPair, allocPoint: _allocPoint
        });
    }

    function _deployControllerProxy(address admin) internal returns (ApexController controller_) {
        ApexController implementation = new ApexController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(implementation), admin, "");
        controller_ = ApexController(address(proxy));
    }

    function _deployVaultProxy(address veNFT_, address controller_) internal returns (ApexVault vault_) {
        ApexVault implementation = new ApexVault();
        bytes memory initData = abi.encodeCall(ApexVault.initialize, (veNFT_, controller_, 22 weeks, 7 days));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        vault_ = ApexVault(address(proxy));
    }

    function _deployFeeCenterProxy(address controller_, address vault_, address receiverImplementation)
        internal
        returns (FeeCenter feeCenter_)
    {
        FeeCenter implementation = new FeeCenter();
        bytes memory initData = abi.encodeCall(FeeCenter.initialize, (controller_, vault_, receiverImplementation));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        feeCenter_ = FeeCenter(address(proxy));
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

    function _addLiquidity(address pair, address to, uint256 amount0, uint256 amount1) internal {
        tokenA.mint(pair, amount0);
        tokenB.mint(pair, amount1);
        ClassicPool(pair).mint(to);
    }

    function _boundEmissionAmount(uint96 _amount) internal pure returns (uint256) {
        return 1 + (uint256(_amount) % MAX_SYMBOLIC_EMISSION);
    }

    function _boundDuration(uint24 _duration) internal pure returns (uint256) {
        return 1 + (uint256(_duration) % 30 days);
    }
}
