// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

import {ApexVault} from "../src/core/ApexVault.sol";
import {FeeCenter} from "../src/core/FeeCenter.sol";
import {FeeReceiver} from "../src/core/FeeReceiver.sol";
import {IVotingEscrow} from "../src/core/interfaces/IVotingEscrow.sol";
import {ApexErrors} from "../src/core/libraries/common/ApexErrors.sol";

contract VaultFuzzERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol) {
        _tokenDecimals = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract VaultFuzzVeNFT is ERC721 {
    uint256 public constant MAXTIME = 26 weeks;

    IERC20 public immutable token;
    mapping(uint256 _tokenId => uint256 _weight) public weights;
    mapping(uint256 _tokenId => uint256 _end) public lockEnd;

    constructor(IERC20 _token) ERC721("VeApexToken", "veTOKEN") {
        token = _token;
    }

    function mint(address _to, uint256 _tokenId, uint256 _weight) external {
        weights[_tokenId] = _weight;
        lockEnd[_tokenId] = block.timestamp + MAXTIME;
        _mint(_to, _tokenId);
    }

    function balanceOfNFT(uint256 _tokenId) external view returns (uint256) {
        return weights[_tokenId];
    }

    function locked(uint256 _tokenId) external view returns (IVotingEscrow.LockedBalance memory) {
        return IVotingEscrow.LockedBalance({
            amount: int128(uint128(weights[_tokenId])), end: lockEnd[_tokenId], isPermanent: false
        });
    }

    function depositFor(uint256 _tokenId, uint256 _value) external {
        weights[_tokenId] += _value;
    }

    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external {
        lockEnd[_tokenId] = block.timestamp + _lockDuration;
    }

    function setLockEnd(uint256 _tokenId, uint256 _end) external {
        lockEnd[_tokenId] = _end;
    }
}

contract ApexVaultMathFuzzTest is Test {
    uint256 internal constant MIN_DEPOSIT_AMOUNT = 10_000;
    uint256 internal constant MAX_ALLOCATIONS = 16;
    uint256 internal constant MAX_APEX_WEIGHT = 1_000_000_000e18;
    uint256 internal constant DEFAULT_DURATION = 7 days;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    ApexVault internal vault;
    VaultFuzzVeNFT internal veNFT;
    VaultFuzzERC20 internal apex;

    function setUp() public {
        apex = new VaultFuzzERC20("Apex", "APEX", 18);
        veNFT = new VaultFuzzVeNFT(IERC20(address(apex)));
        vault = _deployVaultProxy(address(veNFT), address(this), DEFAULT_DURATION);
    }

    function testVaultRejectsBelowMinimumLockWeight() public {
        VaultFuzzERC20 rewardToken = _newRewardToken(18);
        veNFT.mint(alice, 1, MIN_DEPOSIT_AMOUNT - 1);

        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](1);
        configs[0] = ApexVault.UserConfig({rewardToken: address(rewardToken), bps: 10_000});

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vm.expectRevert(ApexErrors.INSUFFICIENT_AMOUNT.selector);
        vault.stake(1, configs);
        vm.stopPrank();
    }

    function testFuzzMinimumLockWeightSupportsOneBpSplits(uint8 _allocationCount) public {
        uint256 allocationCount = bound(_allocationCount, 1, MAX_ALLOCATIONS);
        veNFT.mint(alice, 1, MIN_DEPOSIT_AMOUNT);

        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](allocationCount);
        for (uint256 i; i < allocationCount; ++i) {
            VaultFuzzERC20 rewardToken = _newRewardToken(18);
            uint16 bps = i == allocationCount - 1 ? uint16(10_000 - i) : 1;
            configs[i] = ApexVault.UserConfig({rewardToken: address(rewardToken), bps: bps});
        }

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs);
        vm.stopPrank();

        for (uint256 i; i < allocationCount; ++i) {
            (, uint256 weight) = vault.userConfigOf(1, configs[i].rewardToken);
            assertGt(weight, 0, "nonzero bps produced zero weight");
        }
    }

    function testMinimumLockWeightSupportsClaimableAndCompoundOneBpSplits() public {
        uint256 claimableCount = MAX_ALLOCATIONS;
        veNFT.mint(alice, 1, MIN_DEPOSIT_AMOUNT);

        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](claimableCount);
        for (uint256 i; i < claimableCount; ++i) {
            VaultFuzzERC20 rewardToken = _newRewardToken(18);
            configs[i] = ApexVault.UserConfig({rewardToken: address(rewardToken), bps: 1});
        }

        vm.startPrank(alice);
        veNFT.approve(address(vault), 1);
        vault.stake(1, configs, uint16(10_000 - claimableCount));
        vm.stopPrank();

        for (uint256 i; i < claimableCount; ++i) {
            (, uint256 weight) = vault.userConfigOf(1, configs[i].rewardToken);
            assertEq(weight, 1, "one bp claimable split should receive one raw unit");
        }
        (, uint256 compoundWeight) = vault.compoundConfigOf(1);
        assertEq(compoundWeight, MIN_DEPOSIT_AMOUNT - claimableCount);
    }

    function testFuzzSingleUserLowDecimalStreamDustIsBounded(
        uint8 _decimals,
        uint256 _amount,
        uint256 _weight,
        uint32 _elapsed
    ) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        _amount = bound(_amount, 1, type(uint128).max);
        _weight = bound(_weight, MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);
        uint256 elapsed = bound(_elapsed, 0, DEFAULT_DURATION);

        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, _weight, address(rewardToken));
        _notify(rewardToken, _amount);

        vm.warp(block.timestamp + elapsed);
        uint256 pending = vault.pendingReward(1, address(rewardToken));
        uint256 expected = (_amount * elapsed) / DEFAULT_DURATION;

        assertLe(pending, expected, "vault overpaid");
        assertLe(expected - pending, 3, "single user stream dust above bounded raw units");
    }

    function testFuzzSingleUserFullPeriodDustIsBounded(uint8 _decimals, uint256 _amount, uint256 _weight) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        _amount = bound(_amount, 1, type(uint128).max);
        _weight = bound(_weight, MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);

        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, _weight, address(rewardToken));
        _notify(rewardToken, _amount);

        vm.warp(block.timestamp + DEFAULT_DURATION);
        uint256 pending = vault.pendingReward(1, address(rewardToken));

        assertLe(pending, _amount, "vault overpaid full period");
        assertLe(_amount - pending, 1, "full period dust above one raw unit");
    }

    function testOneRawUnitLowDecimalRewardStreamsAtPeriodEnd() public {
        VaultFuzzERC20 rewardToken = _newRewardToken(0);
        _stake(alice, 1, MAX_APEX_WEIGHT, address(rewardToken));
        _notify(rewardToken, 1);

        vm.warp(block.timestamp + DEFAULT_DURATION - 1);
        assertEq(vault.pendingReward(1, address(rewardToken)), 0, "raw unit vested too early");

        vm.warp(block.timestamp + 1);
        assertEq(vault.pendingReward(1, address(rewardToken)), 1, "final raw unit was lost");
    }

    function testFuzzRepeatedNotifyAddsToExistingStreamWithoutMaterialDust(
        uint8 _decimals,
        uint256 _firstAmount,
        uint256 _secondAmount,
        uint256 _weight,
        uint32 _warpBeforeSecond
    ) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        _firstAmount = bound(_firstAmount, 1, type(uint128).max / 2);
        _secondAmount = bound(_secondAmount, 1, type(uint128).max / 2);
        _weight = bound(_weight, MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);
        uint256 warpBeforeSecond = bound(_warpBeforeSecond, 0, DEFAULT_DURATION - 1);

        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, _weight, address(rewardToken));
        _notify(rewardToken, _firstAmount);

        vm.warp(block.timestamp + warpBeforeSecond);
        _notify(rewardToken, _secondAmount);

        vm.warp(block.timestamp + DEFAULT_DURATION);
        uint256 pending = vault.pendingReward(1, address(rewardToken));
        uint256 totalNotified = _firstAmount + _secondAmount;

        assertLe(pending, totalNotified, "vault overpaid after rolling notify");
        assertLe(totalNotified - pending, 3, "rolling notify dust too large");
    }

    function testFuzzTwoUsersNeverClaimMoreThanNotified(
        uint8 _decimals,
        uint256 _amount,
        uint256 _aliceWeight,
        uint256 _bobWeight
    ) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        _amount = bound(_amount, 1, type(uint128).max);
        _aliceWeight = bound(_aliceWeight, MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);
        _bobWeight = bound(_bobWeight, MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT - _aliceWeight + MIN_DEPOSIT_AMOUNT);

        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, _aliceWeight, address(rewardToken));
        _stake(bob, 2, _bobWeight, address(rewardToken));
        _notify(rewardToken, _amount);

        vm.warp(block.timestamp + DEFAULT_DURATION);
        uint256 alicePending = vault.pendingReward(1, address(rewardToken));
        uint256 bobPending = vault.pendingReward(2, address(rewardToken));

        assertLe(alicePending + bobPending, _amount, "vault overpaid split rewards");
        assertLe(_amount - alicePending - bobPending, 3, "split dust too large");
    }

    function testFuzzRepeatedForcedSettlementDustIsRawUnitBounded(
        uint8 _decimals,
        uint128 _amount,
        uint32 _steps,
        uint128 _aliceWeight,
        uint128 _bobWeight
    ) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        uint256 amount = bound(uint256(_amount), 1, type(uint96).max);
        uint256 steps = bound(uint256(_steps), 1, 100);
        uint256 aliceWeight = bound(uint256(_aliceWeight), MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);
        uint256 bobWeight = bound(uint256(_bobWeight), MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);

        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, aliceWeight, address(rewardToken));
        _stake(bob, 2, bobWeight, address(rewardToken));
        _notify(rewardToken, amount);

        uint256 elapsed;
        for (uint256 i; i < steps; ++i) {
            uint256 nextElapsed = ((i + 1) * DEFAULT_DURATION) / steps;
            skip(nextElapsed - elapsed);
            elapsed = nextElapsed;
            _claim(alice, 1, address(rewardToken));
            _claim(bob, 2, address(rewardToken));
        }

        uint256 paid = rewardToken.balanceOf(alice) + rewardToken.balanceOf(bob);
        uint256 leftover = rewardToken.balanceOf(address(vault));

        assertLe(paid, amount, "vault overpaid repeated settlements");
        assertEq(paid + leftover, amount, "vault lost tokens");
        assertLe(leftover, 5 * steps + 5, "settlement dust exceeded raw-unit bound");
    }

    function testRepeatedForcedSettlementBtcDecimalsDustIsNotDisplayBtc() public {
        VaultFuzzERC20 rewardToken = _newRewardToken(8);
        uint256 oneBtc = 100_000_000;
        uint256 steps = 100;
        _stake(alice, 1, MAX_APEX_WEIGHT, address(rewardToken));
        _stake(bob, 2, MAX_APEX_WEIGHT - 1, address(rewardToken));
        _notify(rewardToken, oneBtc);

        uint256 elapsed;
        for (uint256 i; i < steps; ++i) {
            uint256 nextElapsed = ((i + 1) * DEFAULT_DURATION) / steps;
            skip(nextElapsed - elapsed);
            elapsed = nextElapsed;
            _claim(alice, 1, address(rewardToken));
            _claim(bob, 2, address(rewardToken));
        }

        assertLe(rewardToken.balanceOf(address(vault)), 2 * steps + 3, "BTC-decimal dust is raw units only");
    }

    function testFuzzAttackerCannotDustDoSVictimByClaimingOften(
        uint8 _decimals,
        uint128 _amount,
        uint32 _steps,
        uint128 _victimWeight,
        uint128 _attackerWeight
    ) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        uint256 amount = bound(uint256(_amount), 1, type(uint96).max);
        uint256 steps = bound(uint256(_steps), 1, 100);
        uint256 victimWeight = bound(uint256(_victimWeight), MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);
        uint256 attackerWeight = bound(uint256(_attackerWeight), MIN_DEPOSIT_AMOUNT, MAX_APEX_WEIGHT);

        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, victimWeight, address(rewardToken));
        _stake(bob, 2, attackerWeight, address(rewardToken));
        _notify(rewardToken, amount);

        uint256 elapsed;
        for (uint256 i; i < steps; ++i) {
            uint256 nextElapsed = ((i + 1) * DEFAULT_DURATION) / steps;
            skip(nextElapsed - elapsed);
            elapsed = nextElapsed;
            _claim(bob, 2, address(rewardToken));
        }

        uint256 victimPending = vault.pendingReward(1, address(rewardToken));
        uint256 expectedVictim = (amount * victimWeight) / (victimWeight + attackerWeight);

        assertLe(victimPending, expectedVictim, "victim overpaid");
        assertLe(expectedVictim - victimPending, steps + 3, "attacker-created victim dust too large");
    }

    function testFuzzExtremeProtocolDomainDoesNotOverflow(
        uint8 _decimals,
        uint128 _amount,
        uint32 _duration,
        uint32 _elapsed
    ) public {
        _decimals = uint8(bound(_decimals, 0, 18));
        uint256 amount = bound(uint256(_amount), 1, type(uint128).max);
        uint256 duration = bound(uint256(_duration), 1, 365 days);
        uint256 elapsed = bound(uint256(_elapsed), 0, duration);

        vault = _deployVaultProxy(address(veNFT), address(this), duration);
        VaultFuzzERC20 rewardToken = _newRewardToken(_decimals);
        _stake(alice, 1, MAX_APEX_WEIGHT, address(rewardToken));
        _notify(rewardToken, amount);

        vm.warp(block.timestamp + elapsed);
        assertLe(vault.pendingReward(1, address(rewardToken)), amount, "overflow domain overpaid");
    }

    function testFuzzFeeCenterEqualSplitConservesEveryRawUnit(uint256 _amount, uint8 _receiverCount) public {
        _amount = bound(_amount, 1, type(uint128).max);
        uint256 receiverCount = bound(_receiverCount, 1, 16);

        FeeCenter feeCenter = _deployFeeCenterProxy(address(this), address(vault), address(new FeeReceiver()));
        address[] memory receivers = new address[](receiverCount);
        for (uint256 i; i < receiverCount; ++i) {
            VaultFuzzERC20 output = new VaultFuzzERC20("Output", "OUT", 18);
            receivers[i] = feeCenter.addReceiver(address(output));
        }

        VaultFuzzERC20 feeToken = _newRewardToken(0);
        feeToken.mint(address(feeCenter), _amount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        feeCenter.pushAndSplitFees(tokens);

        uint256 received;
        for (uint256 i; i < receiverCount; ++i) {
            received += feeToken.balanceOf(receivers[i]);
        }
        assertEq(received, _amount, "split lost raw units");
        assertEq(feeToken.balanceOf(address(feeCenter)), 0, "dust left in FeeCenter");
    }

    function _newRewardToken(uint8 _decimals) internal returns (VaultFuzzERC20) {
        VaultFuzzERC20 rewardToken = new VaultFuzzERC20("Reward", "RWD", _decimals);
        vault.setRewardToken(address(rewardToken), true);
        return rewardToken;
    }

    function _stake(address _owner, uint256 _tokenId, uint256 _weight, address _rewardToken) internal {
        veNFT.mint(_owner, _tokenId, _weight);
        ApexVault.UserConfig[] memory configs = new ApexVault.UserConfig[](1);
        configs[0] = ApexVault.UserConfig({rewardToken: _rewardToken, bps: 10_000});
        vm.startPrank(_owner);
        veNFT.approve(address(vault), _tokenId);
        vault.stake(_tokenId, configs);
        vm.stopPrank();
    }

    function _claim(address _owner, uint256 _tokenId, address _rewardToken) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = _rewardToken;
        vm.prank(_owner);
        vault.claim(_tokenId, tokens);
    }

    function _notify(VaultFuzzERC20 _rewardToken, uint256 _amount) internal {
        _rewardToken.mint(address(this), _amount);
        _rewardToken.approve(address(vault), _amount);
        vault.notifyRewardAmount(address(this), address(_rewardToken), _amount);
    }

    function _deployVaultProxy(address _veNFT, address _controller, uint256 _duration)
        internal
        returns (ApexVault vault_)
    {
        ApexVault implementation = new ApexVault();
        bytes memory initData = abi.encodeCall(ApexVault.initialize, (_veNFT, _controller, 22 weeks, _duration));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        vault_ = ApexVault(address(proxy));
    }

    function _deployFeeCenterProxy(address _controller, address _vault, address _receiverImplementation)
        internal
        returns (FeeCenter feeCenter_)
    {
        FeeCenter implementation = new FeeCenter();
        bytes memory initData = abi.encodeCall(FeeCenter.initialize, (_controller, _vault, _receiverImplementation));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        feeCenter_ = FeeCenter(address(proxy));
    }
}
