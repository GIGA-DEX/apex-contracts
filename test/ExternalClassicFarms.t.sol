// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ApexControllerEmissionsTest, ApexEmissionMockERC20} from "./ApexControllerEmissions.t.sol";
import {IBrownFiPairConfig} from "../src/core/interfaces/IBrownFi.sol";
import {IApexController} from "../src/core/interfaces/IApexController.sol";

contract ExternalFarmMockFactory is IBrownFiPairConfig {
    address public feeTo;
    address public pair;
    uint32 public feeSplit;

    function configure(address pair_, address recipient, uint32 split) external {
        pair = pair_;
        feeTo = recipient;
        feeSplit = split;
    }

    function pairConfig() external view returns (address) {
        return address(this);
    }

    function getPair(address, address) external view returns (address) {
        return pair;
    }

    function getConfig(address) external view returns (Config memory config) {
        config.feeSplit = feeSplit;
    }
}

contract ExternalFarmMockPair is ApexEmissionMockERC20 {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    constructor(address factory_, address token0_, address token1_) ApexEmissionMockERC20("External LP", "EXT") {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
    }

    // Deliberately no Apex mintFee(), protocolFee(), or fee setters.
    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 lp = balanceOf(address(this));
        amount0 = ApexEmissionMockERC20(token0).balanceOf(address(this)) * lp / totalSupply();
        amount1 = ApexEmissionMockERC20(token1).balanceOf(address(this)) * lp / totalSupply();
        _burn(address(this), lp);
        ApexEmissionMockERC20(token0).transfer(to, amount0);
        ApexEmissionMockERC20(token1).transfer(to, amount1);
    }
}

contract ExternalClassicFarmsTest is ApexControllerEmissionsTest {
    ExternalFarmMockFactory internal externalFactory;
    ExternalFarmMockPair internal externalPair;

    function testExternalFarmActivationAndEmissionsLeaveFeesToOffchainCoordination() public {
        _externalFarm();
        externalFactory.configure(address(externalPair), bob, 20_000_000);
        controller.activateClassicFarm(address(externalPair), 1000);
        apex.mint(address(controller), 100 ether);
        controller.rebalanceEmissions(100 ether, 100, _weights(1000));
        assertEq(externalFactory.feeTo(), bob);
        assertEq(externalFactory.feeSplit(), 20_000_000);
        externalFactory.configure(address(externalPair), alice, 0);
        controller.rebalanceEmissions(0, 100, _weights(1000));
        assertEq(externalFactory.feeTo(), alice);
        assertEq(externalFactory.feeSplit(), 0);
        controller.stopAllEmissions();
        controller.deactivateClassicFarm(address(externalPair));
    }

    function testExternalFarmActivationStillValidatesFactoryAndCanonicalPair() public {
        _externalFarm();
        controller.setExternalClassicFactory(address(externalFactory), false);
        vm.expectRevert();
        controller.activateClassicFarm(address(externalPair), 1000);
        controller.setExternalClassicFactory(address(externalFactory), true);
        externalFactory.configure(bob, bob, 0);
        vm.expectRevert();
        controller.activateClassicFarm(address(externalPair), 1000);
    }

    function _externalFarm() internal {
        externalFactory = new ExternalFarmMockFactory();
        externalPair = new ExternalFarmMockPair(address(externalFactory), address(tokenA), address(tokenB));
        externalFactory.configure(address(externalPair), address(feeCenter), 100_000_000);
        controller.setExternalClassicFactory(address(externalFactory), true);
        controller.registerExternalClassicFarm(address(externalFactory), address(externalPair));
    }

    function _weights(uint256 allocation) internal view returns (IApexController.EmissionWeight[] memory weights) {
        weights = new IApexController.EmissionWeight[](1);
        weights[0] = IApexController.EmissionWeight(IApexController.PoolKind.CLASSIC, address(externalPair), allocation);
    }

    function testExternalFarmRegistrationRejectsUntrustedAndSpoofedPairs() public {
        _externalFarm();
        ExternalFarmMockPair fake = new ExternalFarmMockPair(address(externalFactory), address(tokenA), address(tokenB));
        vm.expectRevert();
        controller.registerExternalClassicFarm(address(externalFactory), address(fake));
        vm.expectRevert();
        controller.registerClassicFarm(address(fake));
        vm.expectRevert();
        controller.registerExternalClassicFarm(address(externalFactory), address(externalPair));
        controller.setExternalClassicFactory(address(externalFactory), false);
        vm.expectRevert();
        controller.registerExternalClassicFarm(address(externalFactory), address(fake));
        assertEq(classicChef.poolLength(), 1);
        assertTrue(controller.isFarmRegistered(address(externalPair)));
        assertFalse(controller.isFarmActive(address(externalPair)));
        assertEq(controller.externalClassicFarmFactory(address(externalPair)), address(externalFactory));
    }

    function testExternalFarmOnlyAdminMayConfigureOrRegister() public {
        _externalFarm();
        vm.prank(alice);
        vm.expectRevert();
        controller.setExternalClassicFactory(address(externalFactory), false);
        vm.prank(alice);
        vm.expectRevert();
        controller.registerExternalClassicFarm(address(externalFactory), address(externalPair));
    }

    function testExternalFarmRebalanceStillValidatesFactoryAndCanonicalPair() public {
        _externalFarm();
        externalFactory.configure(address(externalPair), address(feeCenter), 20_000_000);
        controller.activateClassicFarm(address(externalPair), 1000);
        apex.mint(address(controller), 100 ether);
        controller.setExternalClassicFactory(address(externalFactory), false);
        vm.expectRevert();
        controller.rebalanceEmissions(100 ether, 100, _weights(1000));
        controller.setExternalClassicFactory(address(externalFactory), true);
        externalFactory.configure(bob, bob, 100_000_000);
        vm.expectRevert();
        controller.rebalanceEmissions(100 ether, 100, _weights(1000));
        externalFactory.configure(address(externalPair), bob, 0);
        controller.rebalanceEmissions(100 ether, 100, _weights(1000));
        controller.stopAllEmissions();
        controller.deactivateClassicFarm(address(externalPair));
        assertFalse(controller.isFarmActive(address(externalPair)));
        assertEq(externalFactory.feeTo(), bob);
    }

    function testExternalFarmEarnsAndExitsAfterFeeChangeAndRevocation() public {
        _externalFarm();
        controller.activateClassicFarm(address(externalPair), 1000);
        externalPair.mint(alice, 10 ether);
        vm.startPrank(alice);
        externalPair.approve(address(classicChef), type(uint256).max);
        classicChef.deposit(0, 10 ether);
        vm.stopPrank();
        apex.mint(address(controller), 100 ether);
        controller.rebalanceEmissions(100 ether, 100, _weights(1000));
        vm.warp(block.timestamp + 50);
        externalFactory.configure(address(externalPair), bob, 0);
        controller.setExternalClassicFactory(address(externalFactory), false);
        controller.stopAllEmissions();
        controller.deactivateClassicFarm(address(externalPair));
        vm.prank(alice);
        classicChef.withdraw(0, 10 ether);
        assertApproxEqAbs(apex.balanceOf(alice), 50 ether, 1);
        assertEq(externalPair.balanceOf(alice), 10 ether);
        vm.expectRevert();
        controller.activateClassicFarm(address(externalPair), 1000);
        controller.setExternalClassicFactory(address(externalFactory), true);
        externalFactory.configure(address(externalPair), address(feeCenter), 100_000_000);
        controller.activateClassicFarm(address(externalPair), 1000);
        assertEq(classicChef.poolLength(), 1);
    }

    function testExternalFarmCollectionRedeemsLpWithoutApexHooksAfterRevocation() public {
        _externalFarm();
        externalPair.mint(address(feeCenter), 10 ether);
        tokenA.mint(address(externalPair), 20 ether);
        tokenB.mint(address(externalPair), 30 ether);
        controller.setExternalClassicFactory(address(externalFactory), false);
        (uint256 amount0, uint256 amount1) = controller.collectClassicProtocolFees(address(externalPair));
        assertEq(amount0, 20 ether);
        assertEq(amount1, 30 ether);
        assertEq(tokenA.balanceOf(address(feeCenter)), amount0);
        assertEq(tokenB.balanceOf(address(feeCenter)), amount1);
        assertEq(externalPair.balanceOf(address(feeCenter)), 0);
    }

    function testExternalFarmAndNativeClassicShareEmissionDenominator() public {
        _externalFarm();
        controller.activateClassicFarm(classicPair, 1000);
        controller.activateClassicFarm(address(externalPair), 3000);
        IApexController.EmissionWeight[] memory weights = new IApexController.EmissionWeight[](2);
        weights[0] = IApexController.EmissionWeight(IApexController.PoolKind.CLASSIC, classicPair, 1000);
        weights[1] = IApexController.EmissionWeight(IApexController.PoolKind.CLASSIC, address(externalPair), 3000);
        if (classicPair > address(externalPair)) (weights[0], weights[1]) = (weights[1], weights[0]);
        apex.mint(address(controller), 100 ether);
        controller.rebalanceEmissions(100 ether, 100, weights);
        (uint256 nativeRate,) = controller.getLatestPeriodInfo(classicPair);
        (uint256 externalRate,) = controller.getLatestPeriodInfo(address(externalPair));
        assertEq(externalRate, nativeRate * 3);
        externalFactory.configure(address(externalPair), bob, 0);
        for (uint256 i; i < 2; ++i) {
            if (weights[i].pool == address(externalPair)) weights[i].allocPoint = 0;
        }
        controller.rebalanceEmissions(0, 100, weights);
        assertEq(controller.farmAllocPoint(address(externalPair)), 0);
    }
}
