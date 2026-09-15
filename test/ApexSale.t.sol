// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";

import {ApexSale} from "../src/core/ApexSale.sol";
import {VeApexToken} from "../src/core/VeApexToken.sol";
import {IVotingEscrow} from "../src/core/interfaces/IVotingEscrow.sol";

contract ApexSaleTestToken is ERC20 {
    uint8 internal immutable tokenDecimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        tokenDecimals = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract ApexSaleFeeOnTransferToken is ApexSaleTestToken {
    address internal constant FEE_SINK = address(0xFEE);

    constructor() ApexSaleTestToken("Fee Global Dollar", "feeUSDG", 6) {}

    function _update(address _from, address _to, uint256 _value) internal override {
        if (_from != address(0) && _to != address(0)) {
            uint256 fee = _value / 100;
            super._update(_from, FEE_SINK, fee);
            _value -= fee;
        }
        super._update(_from, _to, _value);
    }
}

contract ApexSaleV2Mock is ApexSale {
    function versionMarker() external pure returns (uint256) {
        return 2;
    }
}

contract ApexSaleTest is Test {
    bytes32 internal constant ERC1967_ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    uint256 internal constant MAX_TOTAL = 400_000e6;
    uint256 internal constant MAX_USER = 100_000e6;
    uint64 internal constant PRODUCTION_START_TIME = 1_787_752_800;
    uint64 internal constant PRODUCTION_END_TIME = 1_787_839_200;
    uint256 internal constant TEST_POINTS_ENTITLEMENT = 15_000_000 ether;
    uint256 internal constant TEST_AIRDROP_ENTITLEMENT = 3_000_000 ether;
    address internal constant LIVE_SALE = 0xF0972BD13b705A9F2CE1eeA823C099f106B5fFD4;
    address internal constant LIVE_SALE_IMPLEMENTATION = 0xD7611A38620A4893F43956Ea5B531EcdE2D4bA2c;
    address internal constant LIVE_SALE_PROXY_ADMIN = 0x85FB3aefAcEeDE03A4aE9557e9772E433dd1096e;
    address internal constant LIVE_SAFE = 0x72f4DF3580935c179E2eC61c04122731E7fcd4A6;

    ApexSaleTestToken internal usdg;
    ApexSaleTestToken internal giga;
    VeApexToken internal veGiga;
    ApexSale internal sale;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal dave = address(0xDA7E);
    address internal eve = address(0xE7E);
    address internal frank = address(0xF4A4);
    address internal treasury = address(0x7EA5);
    uint64 internal startTime;
    uint64 internal endTime;

    event Contributed(
        address indexed contributor,
        uint256 usdgAmount,
        uint256 baseGigaAllocation,
        uint256 cumulativeUsdg,
        uint256 cumulativeBaseGigaAllocation,
        uint256 totalUsdg,
        uint256 totalBaseGigaAllocation
    );

    function setUp() public {
        usdg = new ApexSaleTestToken("Global Dollar", "USDG", 6);
        giga = new ApexSaleTestToken("GIGA", "GIGA", 18);

        VeApexToken veImplementation = new VeApexToken();
        bytes memory veInitData =
            abi.encodeCall(VeApexToken.initialize, (address(giga), address(0), address(this), "veGIGA", "veGIGA"));
        veGiga =
            VeApexToken(address(new TransparentUpgradeableProxy(address(veImplementation), address(this), veInitData)));

        startTime = PRODUCTION_START_TIME;
        endTime = PRODUCTION_END_TIME;
        sale = _deploySale(address(usdg), address(giga), address(veGiga));

        _prepareContributor(alice, usdg, sale);
        _prepareContributor(bob, usdg, sale);
    }

    function testImplementationCannotBeInitialized() public {
        ApexSale implementation = new ApexSale();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_params(address(usdg), address(giga), address(veGiga)));
    }

    function testInitializeRejectsWrongVeToken() public {
        ApexSaleTestToken otherGiga = new ApexSaleTestToken("Other", "OTHER", 18);
        ApexSale implementation = new ApexSale();
        bytes memory initData =
            abi.encodeCall(ApexSale.initialize, (_params(address(usdg), address(otherGiga), address(veGiga))));
        vm.expectRevert(ApexSale.InvalidTokenConfiguration.selector);
        new TransparentUpgradeableProxy(address(implementation), address(this), initData);
    }

    function testContributeForwardsUsdGAndStoresEnumerableAllocation() public {
        vm.warp(startTime);
        uint256 treasuryBalanceBefore = usdg.balanceOf(treasury);

        vm.expectEmit(true, false, false, true, address(sale));
        emit Contributed(alice, 1_000e6, 50_000 ether, 1_000e6, 50_000 ether, 1_000e6, 50_000 ether);
        vm.prank(alice);
        uint256 allocationAdded = sale.contribute(1_000e6);
        vm.prank(alice);
        sale.contribute(500e6);

        assertEq(allocationAdded, 50_000 ether);
        assertEq(usdg.balanceOf(treasury) - treasuryBalanceBefore, 1_500e6);
        assertEq(usdg.balanceOf(address(sale)), 0);
        assertEq(sale.contributionOf(alice), 1_500e6);
        assertEq(sale.baseAllocationOf(alice), 75_000 ether);
        assertEq(sale.totalContributed(), 1_500e6);
        assertEq(sale.totalBaseAllocation(), 75_000 ether);
        assertEq(sale.participantCount(), 1);
        assertEq(sale.participantAt(0), alice);
    }

    function testProductionLaunchToMixedClaimsEndToEnd() public {
        _prepareContributor(carol, usdg, sale);
        _prepareContributor(dave, usdg, sale);
        _prepareContributor(eve, usdg, sale);

        assertEq(sale.startTime(), PRODUCTION_START_TIME);
        assertEq(sale.endTime(), PRODUCTION_END_TIME);
        assertEq(sale.endTime() - sale.startTime(), 24 hours);
        assertEq(sale.maxTotalContribution(), 400_000e6);
        assertEq(sale.maxContributionPerAccount(), 100_000e6);
        assertEq(sale.gigaPerUsdg(), 50 ether);
        assertFalse(sale.claimsEnabled());

        vm.warp(startTime);
        uint256 launchBlock = block.number;
        vm.prank(alice);
        sale.contribute(100_000e6);
        vm.prank(bob);
        sale.contribute(40_000e6);
        vm.prank(carol);
        sale.contribute(100_000e6);
        vm.prank(bob);
        sale.contribute(60_000e6);
        vm.prank(dave);
        sale.contribute(99_999e6);
        vm.prank(eve);
        sale.contribute(1e6);

        assertEq(block.number, launchBlock);
        assertEq(usdg.balanceOf(treasury), 400_000e6);
        assertEq(usdg.balanceOf(address(sale)), 0);
        assertEq(sale.totalContributed(), 400_000e6);
        assertEq(sale.totalBaseAllocation(), 20_000_000 ether);
        assertEq(sale.maximumGigaLiability(), 30_000_000 ether);
        assertEq(sale.participantCount(), 5);
        assertEq(sale.participantAt(0), alice);
        assertEq(sale.participantAt(1), bob);
        assertEq(sale.participantAt(2), carol);
        assertEq(sale.participantAt(3), dave);
        assertEq(sale.participantAt(4), eve);

        vm.prank(frank);
        vm.expectRevert(ApexSale.ContributionCapExceeded.selector);
        sale.contribute(1);
        assertEq(sale.totalContributed(), 400_000e6);

        vm.expectRevert(ApexSale.SaleNotEnded.selector);
        sale.unpauseClaims();
        vm.prank(alice);
        vm.expectRevert(ApexSale.ClaimsNotEnabled.selector);
        sale.claim(ApexSale.ClaimOption.LIQUID);

        vm.warp(endTime);
        _configureClaims();
        vm.expectRevert(abi.encodeWithSelector(ApexSale.InsufficientGigaFunding.selector, 0, 48_000_000 ether));
        sale.unpauseClaims();
        giga.mint(address(sale), 48_000_000 ether);
        sale.unpauseClaims();

        vm.prank(alice);
        sale.claim(ApexSale.ClaimOption.LIQUID);
        sale.pauseClaims();
        vm.prank(bob);
        vm.expectRevert(ApexSale.ClaimsNotEnabled.selector);
        sale.claim(ApexSale.ClaimOption.LOCKED);
        sale.unpauseClaims();

        vm.prank(bob);
        (uint256 bobAmount, uint256 bobTokenId) = sale.claim(ApexSale.ClaimOption.LOCKED);
        vm.prank(carol);
        sale.claim(ApexSale.ClaimOption.LIQUID);
        vm.prank(dave);
        (uint256 daveAmount, uint256 daveTokenId) = sale.claim(ApexSale.ClaimOption.LOCKED);
        vm.prank(eve);
        (uint256 eveAmount, uint256 eveTokenId) = sale.claim(ApexSale.ClaimOption.LOCKED);

        assertEq(giga.balanceOf(alice), 5_000_000 ether);
        assertEq(giga.balanceOf(carol), 5_000_000 ether);
        _assertVeLock(bobTokenId, bob, bobAmount, 7_500_000 ether);
        _assertVeLock(daveTokenId, dave, daveAmount, 7_499_925 ether);
        _assertVeLock(eveTokenId, eve, eveAmount, 75 ether);
        assertEq(sale.totalClaimedBaseAllocation(), 20_000_000 ether);
        assertEq(sale.totalGigaDistributed(), 25_000_000 ether);
        assertEq(sale.outstandingMaximumGiga(), 0);
        assertEq(sale.gigaFundingDeficit(), 0);
        assertEq(giga.balanceOf(address(sale)), 23_000_000 ether);

        sale.recoverToken(address(giga), treasury, 5_000_000 ether);
        vm.warp(sale.pointsClaimEndTime());
        sale.recoverToken(address(giga), treasury, 18_000_000 ether);
        assertEq(giga.balanceOf(address(sale)), 0);
        assertEq(giga.balanceOf(treasury), 23_000_000 ether);
    }

    function testFeeOnTransferUsdgRevertsWithoutRecordingAllocation() public {
        ApexSaleFeeOnTransferToken feeUsdg = new ApexSaleFeeOnTransferToken();
        ApexSale feeSale = _deploySale(address(feeUsdg), address(giga), address(veGiga));
        _prepareContributor(alice, feeUsdg, feeSale);
        vm.warp(startTime);

        vm.prank(alice);
        vm.expectRevert(ApexSale.ContributionNotReceived.selector);
        feeSale.contribute(100e6);

        assertEq(feeUsdg.balanceOf(alice), MAX_USER);
        assertEq(feeUsdg.balanceOf(treasury), 0);
        assertEq(feeSale.totalContributed(), 0);
        assertEq(feeSale.baseAllocationOf(alice), 0);
        assertEq(feeSale.participantCount(), 0);
    }

    function testFuzzMixedClaimsConserveFundedGiga(
        uint96 _aliceRawContribution,
        uint96 _bobRawContribution,
        bool _aliceLocks,
        bool _bobLocks
    ) public {
        uint256 aliceContribution = bound(uint256(_aliceRawContribution), 1, MAX_USER);
        uint256 bobContribution = bound(uint256(_bobRawContribution), 1, MAX_USER);
        _contribute(alice, aliceContribution);
        _contribute(bob, bobContribution);

        uint256 totalBase = sale.totalBaseAllocation();
        uint256 maximumFunding = sale.maximumGigaLiability() + TEST_POINTS_ENTITLEMENT + TEST_AIRDROP_ENTITLEMENT;
        _fundAndEnableClaims();

        vm.prank(alice);
        (uint256 aliceAmount,) = sale.claim(_aliceLocks ? ApexSale.ClaimOption.LOCKED : ApexSale.ClaimOption.LIQUID);
        vm.prank(bob);
        (uint256 bobAmount,) = sale.claim(_bobLocks ? ApexSale.ClaimOption.LOCKED : ApexSale.ClaimOption.LIQUID);

        assertEq(sale.totalClaimedBaseAllocation(), totalBase);
        assertEq(sale.totalGigaDistributed(), aliceAmount + bobAmount);
        assertEq(giga.balanceOf(address(sale)), maximumFunding - aliceAmount - bobAmount);
        assertEq(sale.outstandingMaximumGiga(), 0);
        assertEq(sale.gigaFundingDeficit(), 0);
        assertLe(aliceAmount + bobAmount, maximumFunding);
    }

    function testContributionBoundariesAndCaps() public {
        vm.prank(alice);
        vm.expectRevert(ApexSale.SaleNotActive.selector);
        sale.contribute(1e6);

        vm.warp(startTime);
        vm.prank(alice);
        vm.expectRevert(ApexSale.UserContributionCapExceeded.selector);
        sale.contribute(MAX_USER + 1);

        sale.setContributionCaps(10_000e6, 0);
        vm.prank(alice);
        vm.expectRevert(ApexSale.ContributionCapExceeded.selector);
        sale.contribute(10_000e6 + 1);

        vm.warp(endTime);
        vm.prank(alice);
        vm.expectRevert(ApexSale.SaleNotActive.selector);
        sale.contribute(1e6);
    }

    function testSameBlockContributionsCannotExceedTotalCap() public {
        sale.setContributionCaps(150e6, 100e6);
        vm.warp(startTime);
        uint256 executionBlock = block.number;

        vm.prank(alice);
        sale.contribute(100e6);

        vm.prank(bob);
        vm.expectRevert(ApexSale.ContributionCapExceeded.selector);
        sale.contribute(51e6);

        vm.prank(bob);
        sale.contribute(50e6);

        assertEq(block.number, executionBlock);
        assertEq(sale.totalContributed(), 150e6);
        assertEq(sale.contributionOf(bob), 50e6);
    }

    function testSaleEndCanChangeOnlyBeforeCurrentEnd() public {
        uint64 extendedEnd = endTime + 2 days;
        sale.setSaleEnd(extendedEnd);
        assertEq(sale.endTime(), extendedEnd);

        vm.warp(extendedEnd);
        vm.expectRevert(ApexSale.SaleAlreadyEnded.selector);
        sale.setSaleEnd(extendedEnd + 1 days);
    }

    function testRateIsHardcodedAtTwoCentsPerGiga() public view {
        assertEq(sale.GIGA_PER_USDG(), 50 ether);
        assertEq(sale.gigaPerUsdg(), 50 ether);
        assertEq(sale.previewBaseAllocation(2e6), 100 ether);
    }

    function testClaimsRequireEndAndWorstCaseFunding() public {
        _contribute(alice, 100e6);
        uint256 saleRequired = 7_500 ether;
        uint256 required = saleRequired + TEST_POINTS_ENTITLEMENT + TEST_AIRDROP_ENTITLEMENT;
        assertEq(sale.maximumGigaLiability(), saleRequired);

        vm.expectRevert(ApexSale.SaleNotEnded.selector);
        sale.unpauseClaims();

        vm.warp(endTime);
        _configureClaims();
        giga.mint(address(sale), required - 1);
        vm.expectRevert(abi.encodeWithSelector(ApexSale.InsufficientGigaFunding.selector, required - 1, required));
        sale.unpauseClaims();

        giga.mint(address(sale), 1);
        sale.unpauseClaims();
        assertTrue(sale.claimsEnabled());
        assertTrue(sale.claimsActivated());
        assertEq(uint256(sale.state()), uint256(ApexSale.SaleState.CLAIMING));
        assertEq(sale.gigaFundingDeficit(), 0);
    }

    function testLiquidClaimTransfersBaseAllocationAndCannotRepeat() public {
        _contribute(alice, 100e6);
        _fundAndEnableClaims();

        vm.prank(alice);
        (uint256 amount, uint256 veTokenId) = sale.claim(ApexSale.ClaimOption.LIQUID);

        assertEq(amount, 5_000 ether);
        assertEq(veTokenId, 0);
        assertEq(giga.balanceOf(alice), amount);
        assertTrue(sale.hasClaimed(alice));
        assertEq(sale.totalClaimedBaseAllocation(), amount);
        assertEq(sale.totalGigaDistributed(), amount);

        vm.prank(alice);
        vm.expectRevert(ApexSale.AlreadyClaimed.selector);
        sale.claim(ApexSale.ClaimOption.LOCKED);
    }

    function testLockedClaimCreatesFiftyPercentBonusMaxLockForUser() public {
        _contribute(alice, 100e6);
        _fundAndEnableClaims();

        vm.prank(alice);
        (uint256 amount, uint256 veTokenId) = sale.claim(ApexSale.ClaimOption.LOCKED);

        assertEq(amount, 7_500 ether);
        assertEq(veGiga.ownerOf(veTokenId), alice);
        IVotingEscrow.LockedBalance memory lock = veGiga.locked(veTokenId);
        assertEq(uint256(uint128(lock.amount)), amount);
        assertGt(lock.end, block.timestamp + 25 weeks);
        assertLe(lock.end, block.timestamp + veGiga.MAXTIME());
        assertEq(giga.balanceOf(alice), 0);
        assertEq(giga.allowance(address(sale), address(veGiga)), 0);
    }

    function testProductionLaneBudgetsUseTrueFiftyPercentSubtractivePremium() public view {
        assertEq(sale.previewMappedClaim(15_000_000 ether, ApexSale.ClaimOption.LIQUID), 10_000_000 ether);
        assertEq(sale.previewMappedClaim(15_000_000 ether, ApexSale.ClaimOption.LOCKED), 15_000_000 ether);
        assertEq(sale.previewMappedClaim(3_000_000 ether, ApexSale.ClaimOption.LIQUID), 2_000_000 ether);
        assertEq(sale.previewMappedClaim(3_000_000 ether, ApexSale.ClaimOption.LOCKED), 3_000_000 ether);
        assertEq(sale.POINTS_ALLOCATION_CAP(), 15_000_000 ether);
        assertEq(sale.AIRDROP_ALLOCATION_CAP(), 3_000_000 ether);
        assertEq(sale.LOCKED_CLAIM_BPS(), 15_000);
    }

    function testConfigureClaimLanesIsImmutableAndFixesExactDeadlines() public {
        vm.warp(endTime);
        uint64 claimStart = endTime + 1 days;
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = 15_000_000 ether;
        sale.fillPointsMapping(accounts, amounts);
        amounts[0] = 3_000_000 ether;
        sale.fillAirdropMapping(accounts, amounts);

        sale.configureClaimLanes(claimStart);

        assertEq(sale.claimStartTime(), claimStart);
        assertEq(sale.saleClaimEndTime(), claimStart + 180 days);
        assertEq(sale.pointsClaimEndTime(), claimStart + 30 days);
        assertEq(sale.airdropClaimEndTime(), claimStart + 7 days);
        assertEq(sale.pointsTotalEntitlement(), 15_000_000 ether);
        assertEq(sale.airdropTotalEntitlement(), 3_000_000 ether);
        assertEq(sale.pointsRecipientCount(), 1);
        assertEq(sale.pointsRecipientAt(0), alice);
        assertEq(sale.pointsAllocationOf(alice), 15_000_000 ether);
        assertEq(sale.airdropRecipientCount(), 1);
        assertEq(sale.airdropRecipientAt(0), alice);
        assertEq(sale.airdropAllocationOf(alice), 3_000_000 ether);
        assertEq(sale.maximumClaimLiability(), 18_000_000 ether);

        vm.expectRevert(ApexSale.ClaimLanesAlreadyConfigured.selector);
        sale.configureClaimLanes(claimStart);
        vm.expectRevert(ApexSale.ClaimLanesAlreadyConfigured.selector);
        sale.fillPointsMapping(accounts, amounts);
    }

    function testConfigureClaimLanesRejectsUnauthorizedInvalidAndOverCapInputs() public {
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = 1 ether;

        vm.expectRevert(ApexSale.SaleNotEnded.selector);
        sale.fillPointsMapping(accounts, amounts);
        vm.warp(endTime);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        sale.fillPointsMapping(accounts, amounts);

        uint256[] memory emptyAmounts = new uint256[](0);
        vm.expectRevert(ApexSale.InvalidArrayLength.selector);
        sale.fillPointsMapping(accounts, emptyAmounts);

        amounts[0] = 15_000_000 ether + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ApexSale.LaneAllocationCapExceeded.selector,
                ApexSale.ClaimLane.POINTS,
                15_000_000 ether + 1,
                15_000_000 ether
            )
        );
        sale.fillPointsMapping(accounts, amounts);

        amounts[0] = 15_000_000 ether;
        sale.fillPointsMapping(accounts, amounts);
        vm.expectRevert(
            abi.encodeWithSelector(ApexSale.AllocationAlreadySet.selector, ApexSale.ClaimLane.POINTS, alice)
        );
        sale.fillPointsMapping(accounts, amounts);

        vm.expectRevert(abi.encodeWithSelector(ApexSale.LaneAllocationEmpty.selector, ApexSale.ClaimLane.AIRDROP));
        sale.configureClaimLanes(endTime);

        amounts[0] = 3_000_000 ether;
        sale.fillAirdropMapping(accounts, amounts);
        vm.expectRevert(ApexSale.InvalidSaleWindow.selector);
        sale.configureClaimLanes(endTime - 1);
    }

    function testAirdropFinalizesAtActualSignupTotalBelowThreeMillionCap() public {
        vm.warp(endTime);
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = TEST_POINTS_ENTITLEMENT;
        sale.fillPointsMapping(accounts, amounts);
        amounts[0] = 1_520_000 ether;
        sale.fillAirdropMapping(accounts, amounts);

        sale.configureClaimLanes(endTime);

        assertEq(sale.airdropTotalEntitlement(), 1_520_000 ether);
        assertEq(sale.maximumClaimLiability(), 16_520_000 ether);
        assertEq(sale.gigaFundingDeficit(), 16_520_000 ether);
        vm.expectRevert(ApexSale.ClaimLanesAlreadyConfigured.selector);
        sale.fillAirdropMapping(accounts, amounts);
    }

    function testSupplementalAirdropSupportsPriorRecipientsAndRequiresFunding() public {
        vm.warp(endTime);
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = frank;
        amounts[0] = TEST_POINTS_ENTITLEMENT;
        sale.fillPointsMapping(accounts, amounts);
        accounts = new address[](2);
        amounts = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = frank;
        amounts[0] = 10_000 ether;
        amounts[1] = 1_510_000 ether;
        sale.fillAirdropMapping(accounts, amounts);
        sale.configureClaimLanes(endTime);
        giga.mint(address(sale), sale.maximumClaimLiability());
        sale.unpauseClaims();

        vm.prank(alice);
        (uint256 originalLiquidAmount,) = sale.claimAirdrop(ApexSale.ClaimOption.LIQUID);
        assertEq(originalLiquidAmount, 6_666.666666666666666666 ether);
        assertTrue(sale.hasClaimedAirdrop(alice));

        accounts = new address[](2);
        amounts = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        amounts[0] = 330_000 ether;
        amounts[1] = 330_000 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                ApexSale.InsufficientGigaFunding.selector, 16_513_333.333333333333333334 ether, 17_170_000 ether
            )
        );
        sale.configureSupplementalAirdrop(accounts, amounts);
        assertFalse(sale.supplementalAirdropConfigured());

        giga.mint(address(sale), 660_000 ether);
        sale.configureSupplementalAirdrop(accounts, amounts);
        assertTrue(sale.supplementalAirdropConfigured());
        assertEq(sale.airdropRecipientCount(), 2);
        assertEq(sale.supplementalAirdropRecipientCount(), 2);
        assertEq(sale.supplementalAirdropRecipientAt(0), alice);
        assertEq(sale.supplementalAirdropRecipientAt(1), bob);
        assertEq(sale.primaryAirdropAllocationOf(alice), 10_000 ether);
        assertEq(sale.supplementalAirdropAllocationOf(alice), 330_000 ether);
        assertEq(sale.airdropAllocationOf(alice), 340_000 ether);
        assertEq(sale.airdropAllocationOf(bob), 330_000 ether);
        assertEq(sale.airdropTotalEntitlement(), 2_180_000 ether);
        assertFalse(sale.hasClaimedAirdrop(alice));
        assertFalse(sale.hasClaimedAirdrop(bob));

        vm.expectRevert(ApexSale.SupplementalAirdropAlreadyConfigured.selector);
        sale.configureSupplementalAirdrop(accounts, amounts);

        vm.prank(alice);
        (uint256 liquidAmount,) = sale.claimAirdrop(ApexSale.ClaimOption.LIQUID);
        assertEq(liquidAmount, 220_000 ether);
        assertTrue(sale.hasClaimedSupplementalAirdrop(alice));
        assertTrue(sale.hasClaimedAirdrop(alice));
        vm.prank(bob);
        (uint256 lockedAmount, uint256 tokenId) = sale.claimAirdrop(ApexSale.ClaimOption.LOCKED);
        _assertVeLock(tokenId, bob, lockedAmount, 330_000 ether);
    }

    function testSupplementalAirdropRejectsUnconfiguredAndExpiredLanes() public {
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = 1 ether;
        vm.expectRevert(ApexSale.ClaimLanesNotConfigured.selector);
        sale.configureSupplementalAirdrop(accounts, amounts);

        vm.warp(endTime);
        _fillDefaultClaimMappings();
        sale.configureClaimLanes(endTime);
        vm.warp(sale.airdropClaimEndTime());
        vm.expectRevert(abi.encodeWithSelector(ApexSale.ClaimWindowClosed.selector, ApexSale.ClaimLane.AIRDROP));
        sale.configureSupplementalAirdrop(accounts, amounts);
    }

    function testThreeIndependentLanesUseAdditiveAndSubtractiveClaimAmounts() public {
        _contribute(alice, 100e6);
        vm.warp(endTime);

        uint256 alicePoints = 1_500 ether;
        uint256 bobPoints = 3_000 ether;
        uint256 aliceAirdrop = 150 ether;
        address[] memory pointsAccounts = new address[](3);
        uint256[] memory pointsAmounts = new uint256[](3);
        pointsAccounts[0] = alice;
        pointsAccounts[1] = bob;
        pointsAccounts[2] = frank;
        pointsAmounts[0] = alicePoints;
        pointsAmounts[1] = bobPoints;
        pointsAmounts[2] = TEST_POINTS_ENTITLEMENT - alicePoints - bobPoints;
        sale.fillPointsMapping(pointsAccounts, pointsAmounts);

        address[] memory airdropAccounts = new address[](2);
        uint256[] memory airdropAmounts = new uint256[](2);
        airdropAccounts[0] = alice;
        airdropAccounts[1] = frank;
        airdropAmounts[0] = aliceAirdrop;
        airdropAmounts[1] = TEST_AIRDROP_ENTITLEMENT - aliceAirdrop;
        sale.fillAirdropMapping(airdropAccounts, airdropAmounts);
        sale.configureClaimLanes(endTime);
        giga.mint(address(sale), sale.maximumClaimLiability());
        sale.unpauseClaims();

        vm.prank(alice);
        (uint256 saleAmount,) = sale.claim(ApexSale.ClaimOption.LIQUID);
        assertEq(saleAmount, 5_000 ether);
        vm.prank(alice);
        (uint256 alicePointsAmount,) = sale.claimPoints(ApexSale.ClaimOption.LIQUID);
        assertEq(alicePointsAmount, 1_000 ether);
        vm.prank(alice);
        (uint256 airdropAmount, uint256 airdropTokenId) = sale.claimAirdrop(ApexSale.ClaimOption.LOCKED);
        _assertVeLock(airdropTokenId, alice, airdropAmount, 150 ether);
        vm.prank(bob);
        (uint256 bobPointsAmount, uint256 bobTokenId) = sale.claimPoints(ApexSale.ClaimOption.LOCKED);
        _assertVeLock(bobTokenId, bob, bobPointsAmount, 3_000 ether);

        assertEq(giga.balanceOf(alice), 6_000 ether);
        assertTrue(sale.hasClaimed(alice));
        assertTrue(sale.hasClaimedPoints(alice));
        assertTrue(sale.hasClaimedAirdrop(alice));
        assertTrue(sale.hasClaimedPoints(bob));
        assertEq(sale.totalPointsEntitlementClaimed(), alicePoints + bobPoints);
        assertEq(sale.totalAirdropEntitlementClaimed(), aliceAirdrop);
        assertEq(sale.totalGigaDistributed(), 9_150 ether);
        assertEq(sale.outstandingClaimLiability(), 17_995_350 ether);
        assertEq(giga.balanceOf(address(sale)), 17_998_350 ether);
    }

    function testMappedClaimsRejectUnallocatedAccountsAndCannotRepeat() public {
        vm.warp(endTime);
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = TEST_POINTS_ENTITLEMENT;
        sale.fillPointsMapping(accounts, amounts);
        amounts[0] = TEST_AIRDROP_ENTITLEMENT;
        sale.fillAirdropMapping(accounts, amounts);
        sale.configureClaimLanes(endTime);
        giga.mint(address(sale), sale.maximumClaimLiability());
        sale.unpauseClaims();

        vm.prank(bob);
        vm.expectRevert(ApexSale.NoAllocation.selector);
        sale.claimPoints(ApexSale.ClaimOption.LOCKED);

        vm.prank(alice);
        sale.claimPoints(ApexSale.ClaimOption.LOCKED);

        vm.prank(alice);
        vm.expectRevert(ApexSale.AlreadyClaimed.selector);
        sale.claimPoints(ApexSale.ClaimOption.LIQUID);

        vm.prank(alice);
        sale.claimAirdrop(ApexSale.ClaimOption.LIQUID);
    }

    function testBatchedMappingsAreEnumerableAndRunningTotalsMatch() public {
        vm.warp(endTime);
        address[] memory accounts = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        amounts[0] = 5_000_000 ether;
        amounts[1] = 10_000_000 ether;
        sale.fillPointsMapping(accounts, amounts);
        amounts[0] = 1_000_000 ether;
        amounts[1] = 2_000_000 ether;
        sale.fillAirdropMapping(accounts, amounts);

        assertEq(sale.pointsRecipientCount(), 2);
        assertEq(sale.pointsRecipientAt(0), alice);
        assertEq(sale.pointsRecipientAt(1), bob);
        assertEq(sale.pointsAllocationOf(alice), 5_000_000 ether);
        assertEq(sale.pointsAllocationOf(bob), 10_000_000 ether);
        assertEq(sale.pointsTotalEntitlement(), TEST_POINTS_ENTITLEMENT);
        assertEq(sale.airdropRecipientCount(), 2);
        assertEq(sale.airdropAllocationOf(alice), 1_000_000 ether);
        assertEq(sale.airdropAllocationOf(bob), 2_000_000 ether);
        assertEq(sale.airdropTotalEntitlement(), TEST_AIRDROP_ENTITLEMENT);
        assertEq(sale.maximumClaimLiability(), 18_000_000 ether);
        assertEq(sale.gigaFundingDeficit(), 18_000_000 ether);
    }

    function testClaimWindowsCloseExactlyAndReleaseExpiredLiability() public {
        _contribute(alice, 100e6);
        vm.warp(endTime);
        uint256 entitlement = 150 ether;
        address[] memory accounts = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = frank;
        amounts[0] = entitlement;
        amounts[1] = TEST_POINTS_ENTITLEMENT - entitlement;
        sale.fillPointsMapping(accounts, amounts);
        amounts[1] = TEST_AIRDROP_ENTITLEMENT - entitlement;
        sale.fillAirdropMapping(accounts, amounts);
        sale.configureClaimLanes(endTime);
        giga.mint(address(sale), sale.maximumClaimLiability());
        sale.unpauseClaims();

        assertEq(sale.outstandingClaimLiability(), 18_007_500 ether);
        vm.warp(sale.airdropClaimEndTime());
        assertFalse(sale.claimLaneOpen(ApexSale.ClaimLane.AIRDROP));
        assertTrue(sale.claimLaneOpen(ApexSale.ClaimLane.POINTS));
        assertTrue(sale.claimLaneOpen(ApexSale.ClaimLane.SALE));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ApexSale.ClaimWindowClosed.selector, ApexSale.ClaimLane.AIRDROP));
        sale.claimAirdrop(ApexSale.ClaimOption.LOCKED);
        assertEq(sale.outstandingClaimLiability(), 15_007_500 ether);

        vm.warp(sale.pointsClaimEndTime());
        assertFalse(sale.claimLaneOpen(ApexSale.ClaimLane.POINTS));
        assertTrue(sale.claimLaneOpen(ApexSale.ClaimLane.SALE));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ApexSale.ClaimWindowClosed.selector, ApexSale.ClaimLane.POINTS));
        sale.claimPoints(ApexSale.ClaimOption.LOCKED);
        assertEq(sale.outstandingClaimLiability(), 7_500 ether);

        vm.warp(sale.saleClaimEndTime());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ApexSale.ClaimWindowClosed.selector, ApexSale.ClaimLane.SALE));
        sale.claim(ApexSale.ClaimOption.LOCKED);
        assertEq(sale.outstandingClaimLiability(), 0);
        assertEq(uint256(sale.state()), uint256(ApexSale.SaleState.ENDED));
        assertFalse(sale.claimsEnabled());

        uint256 expiredReserve = giga.balanceOf(address(sale));
        sale.recoverToken(address(giga), treasury, expiredReserve);
        assertEq(giga.balanceOf(address(sale)), 0);
    }

    function testClaimsCannotOpenBeforeConfigurationOrConfiguredStart() public {
        vm.warp(endTime);
        vm.expectRevert(ApexSale.ClaimLanesNotConfigured.selector);
        sale.unpauseClaims();

        uint64 claimStart = endTime + 1 days;
        _fillDefaultClaimMappings();
        sale.configureClaimLanes(claimStart);
        giga.mint(address(sale), sale.maximumClaimLiability());

        vm.expectRevert(abi.encodeWithSelector(ApexSale.ClaimWindowNotOpen.selector, ApexSale.ClaimLane.SALE));
        sale.unpauseClaims();
        vm.warp(claimStart);
        sale.unpauseClaims();
        assertTrue(sale.claimsEnabled());
    }

    function testRecoveryCannotUndercollateralizeOutstandingClaims() public {
        _contribute(alice, 100e6);
        _contribute(bob, 100e6);
        _fundAndEnableClaims();

        vm.prank(alice);
        sale.claim(ApexSale.ClaimOption.LIQUID);

        assertEq(sale.outstandingMaximumGiga(), 7_500 ether);
        assertEq(sale.outstandingClaimLiability(), 18_007_500 ether);
        sale.recoverToken(address(giga), treasury, 2_500 ether);
        assertEq(giga.balanceOf(address(sale)), 18_007_500 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ApexSale.InsufficientGigaFunding.selector, 18_007_499 ether, 18_007_500 ether)
        );
        sale.recoverToken(address(giga), treasury, 1 ether);
    }

    function testContributionAndClaimPausesAreIndependent() public {
        vm.warp(startTime);
        sale.pause();
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sale.contribute(1e6);
        assertEq(sale.contributionOf(alice), 0);

        sale.unpause();
        vm.prank(alice);
        sale.contribute(100e6);
        _fundAndEnableClaims();

        sale.pauseClaims();
        vm.prank(alice);
        vm.expectRevert(ApexSale.ClaimsNotEnabled.selector);
        sale.claim(ApexSale.ClaimOption.LIQUID);
        assertFalse(sale.hasClaimed(alice));
        assertEq(sale.baseAllocationOf(alice), 5_000 ether);

        sale.unpauseClaims();
        sale.pause();
        vm.prank(alice);
        sale.claim(ApexSale.ClaimOption.LIQUID);
        assertTrue(sale.hasClaimed(alice));
    }

    function testClaimsCanPauseAndResumeWithFundingRechecked() public {
        _contribute(alice, 100e6);
        _contribute(bob, 100e6);
        _fundAndEnableClaims();

        vm.prank(alice);
        sale.claim(ApexSale.ClaimOption.LIQUID);
        sale.pauseClaims();

        assertFalse(sale.claimsEnabled());
        assertTrue(sale.claimsActivated());
        vm.prank(bob);
        vm.expectRevert(ApexSale.ClaimsNotEnabled.selector);
        sale.claim(ApexSale.ClaimOption.LIQUID);

        sale.recoverToken(address(giga), treasury, 2_500 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ApexSale.InsufficientGigaFunding.selector, 18_007_499 ether, 18_007_500 ether)
        );
        sale.recoverToken(address(giga), treasury, 1 ether);

        sale.unpauseClaims();
        vm.prank(bob);
        sale.claim(ApexSale.ClaimOption.LOCKED);
    }

    function testOwnershipCannotBeRenouncedAndStillTransfersInTwoSteps() public {
        vm.expectRevert(ApexSale.OwnershipRenunciationDisabled.selector);
        sale.renounceOwnership();

        sale.transferOwnership(alice);
        assertEq(sale.owner(), address(this));
        vm.prank(alice);
        sale.acceptOwnership();
        assertEq(sale.owner(), alice);
    }

    function testUpgradePreservesEveryAllocationRecord() public {
        _contribute(alice, 100e6);
        _contribute(bob, 200e6);

        ApexSaleV2Mock implementationV2 = new ApexSaleV2Mock();
        ProxyAdmin(_proxyAdmin(address(sale)))
            .upgradeAndCall(ITransparentUpgradeableProxy(payable(address(sale))), address(implementationV2), "");
        ApexSaleV2Mock upgraded = ApexSaleV2Mock(address(sale));

        assertEq(upgraded.versionMarker(), 2);
        assertEq(upgraded.contributionOf(alice), 100e6);
        assertEq(upgraded.baseAllocationOf(alice), 5_000 ether);
        assertEq(upgraded.contributionOf(bob), 200e6);
        assertEq(upgraded.baseAllocationOf(bob), 10_000 ether);
        assertEq(upgraded.totalContributed(), 300e6);
        assertEq(upgraded.totalBaseAllocation(), 15_000 ether);
        assertEq(upgraded.participantCount(), 2);
        assertEq(upgraded.participantAt(0), alice);
        assertEq(upgraded.participantAt(1), bob);
    }

    function testRobinhoodForkUpgradePreservesAllLiveSaleRecords() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        ApexSale liveSale = ApexSale(LIVE_SALE);
        assertEq(_implementationOf(LIVE_SALE), LIVE_SALE_IMPLEMENTATION);
        assertEq(_proxyAdmin(LIVE_SALE), LIVE_SALE_PROXY_ADMIN);
        assertEq(ProxyAdmin(LIVE_SALE_PROXY_ADMIN).owner(), LIVE_SAFE);
        assertEq(liveSale.participantCount(), 169);
        assertEq(liveSale.totalContributed(), 267_266_995_424);
        assertEq(liveSale.totalBaseAllocation(), 13_363_349_771_200_000_000_000_000);

        ApexSale newImplementation = new ApexSale();
        vm.prank(LIVE_SAFE);
        ProxyAdmin(LIVE_SALE_PROXY_ADMIN)
            .upgradeAndCall(ITransparentUpgradeableProxy(payable(LIVE_SALE)), address(newImplementation), bytes(""));

        assertEq(_implementationOf(LIVE_SALE), address(newImplementation));
        assertEq(liveSale.owner(), LIVE_SAFE);
        assertEq(liveSale.participantCount(), 169);
        assertEq(liveSale.totalContributed(), 267_266_995_424);
        assertEq(liveSale.totalBaseAllocation(), 13_363_349_771_200_000_000_000_000);
        assertEq(liveSale.totalClaimedBaseAllocation(), 0);
        assertEq(liveSale.totalGigaDistributed(), 0);
        assertEq(liveSale.claimStartTime(), 0);
        assertEq(liveSale.maximumGigaLiability(), 20_045_024_656_800_000_000_000_000);

        uint256 contributionSum;
        uint256 allocationSum;
        for (uint256 i; i < liveSale.participantCount(); ++i) {
            address participant = liveSale.participantAt(i);
            uint256 contribution = liveSale.contributionOf(participant);
            uint256 allocation = liveSale.baseAllocationOf(participant);
            assertGt(contribution, 0);
            assertGt(allocation, 0);
            assertFalse(liveSale.hasClaimed(participant));
            contributionSum += contribution;
            allocationSum += allocation;
        }
        assertEq(contributionSum, liveSale.totalContributed());
        assertEq(allocationSum, liveSale.totalBaseAllocation());

        uint64 configuredStart = uint64(block.timestamp + 1 days);
        address[] memory accounts = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        accounts[0] = alice;
        amounts[0] = 15_000_000 ether;
        vm.prank(LIVE_SAFE);
        liveSale.fillPointsMapping(accounts, amounts);
        amounts[0] = 3_000_000 ether;
        vm.prank(LIVE_SAFE);
        liveSale.fillAirdropMapping(accounts, amounts);
        vm.prank(LIVE_SAFE);
        liveSale.configureClaimLanes(configuredStart);

        assertEq(liveSale.saleClaimEndTime(), configuredStart + 180 days);
        assertEq(liveSale.pointsClaimEndTime(), configuredStart + 30 days);
        assertEq(liveSale.airdropClaimEndTime(), configuredStart + 7 days);
        assertEq(liveSale.maximumClaimLiability(), 38_045_024_656_800_000_000_000_000);
    }

    function _contribute(address _account, uint256 _amount) internal {
        vm.warp(startTime);
        vm.prank(_account);
        sale.contribute(_amount);
    }

    function _fundAndEnableClaims() internal {
        vm.warp(endTime);
        _configureClaims();
        giga.mint(address(sale), sale.maximumClaimLiability());
        sale.unpauseClaims();
    }

    function _configureClaims() internal {
        if (sale.claimStartTime() != 0) return;
        _fillDefaultClaimMappings();
        sale.configureClaimLanes(endTime);
    }

    function _fillDefaultClaimMappings() internal {
        address[] memory accounts = new address[](1);
        uint256[] memory entitlements = new uint256[](1);
        accounts[0] = frank;
        entitlements[0] = TEST_POINTS_ENTITLEMENT;
        sale.fillPointsMapping(accounts, entitlements);
        entitlements[0] = TEST_AIRDROP_ENTITLEMENT;
        sale.fillAirdropMapping(accounts, entitlements);
    }

    function _prepareContributor(address _account, ApexSaleTestToken _usdg, ApexSale _sale) internal {
        _usdg.mint(_account, MAX_USER);
        vm.prank(_account);
        _usdg.approve(address(_sale), type(uint256).max);
    }

    function _assertVeLock(uint256 _tokenId, address _owner, uint256 _actualAmount, uint256 _expectedAmount)
        internal
        view
    {
        assertEq(_actualAmount, _expectedAmount);
        assertEq(veGiga.ownerOf(_tokenId), _owner);
        IVotingEscrow.LockedBalance memory lock = veGiga.locked(_tokenId);
        assertEq(uint256(uint128(lock.amount)), _expectedAmount);
        assertGt(lock.end, block.timestamp + 25 weeks);
        assertLe(lock.end, block.timestamp + veGiga.MAXTIME());
    }

    function _deploySale(address _usdg, address _giga, address _veGiga) internal returns (ApexSale deployedSale) {
        ApexSale implementation = new ApexSale();
        bytes memory initData = abi.encodeCall(ApexSale.initialize, (_params(_usdg, _giga, _veGiga)));
        deployedSale =
            ApexSale(address(new TransparentUpgradeableProxy(address(implementation), address(this), initData)));
    }

    function _params(address _usdg, address _giga, address _veGiga)
        internal
        view
        returns (ApexSale.InitParams memory params)
    {
        params = ApexSale.InitParams({
            owner: address(this),
            usdg: _usdg,
            giga: _giga,
            veGiga: _veGiga,
            treasury: treasury,
            startTime: startTime,
            endTime: endTime,
            maxTotalContribution: MAX_TOTAL,
            maxContributionPerAccount: MAX_USER
        });
    }

    function _proxyAdmin(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, ERC1967_ADMIN_SLOT))));
    }

    function _implementationOf(address _proxy) internal view returns (address) {
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(_proxy, implementationSlot))));
    }
}
