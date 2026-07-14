// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

import {ApexVault} from "../../src/core/ApexVault.sol";
import {FeeCenter} from "../../src/core/FeeCenter.sol";
import {FeeReceiver} from "../../src/core/FeeReceiver.sol";
import {IVotingEscrow} from "../../src/core/interfaces/IVotingEscrow.sol";

contract SymbolicERC20 is ERC20 {
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

contract SymbolicVeNFT is ERC721 {
    uint256 public constant MAXTIME = 26 weeks;

    IERC20 public immutable token;
    mapping(uint256 tokenId => uint256 weight) public weights;
    mapping(uint256 tokenId => uint256 end) public lockEnd;

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
}

contract SymbolicVaultAndFeesTest is Test {
    uint256 internal constant MIN_DEPOSIT_AMOUNT = 10_000;
    uint256 internal constant MAX_APEX_WEIGHT = 1_000_000_000e18;
    uint256 internal constant DEFAULT_DURATION = 7 days;
    uint256 internal constant MAX_SYMBOLIC_REWARD = 1_000_000_000 ether;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    ApexVault internal vault;
    SymbolicVeNFT internal veNFT;
    SymbolicERC20 internal apex;

    function setUp() public {
        apex = new SymbolicERC20("Apex", "APEX", 18);
        veNFT = new SymbolicVeNFT(IERC20(address(apex)));
        vault = _deployVaultProxy(address(veNFT), address(this), DEFAULT_DURATION);
    }

    function fuzzOnly_vaultSingleUserCannotReceiveMoreThanNotified(uint96 _amount, uint64 _weight, uint32 _elapsed)
        public
    {
        _vaultSingleUserCannotReceiveMoreThanNotified(_amount, _weight, _elapsed);
    }

    function testFuzz_vaultSingleUserCannotReceiveMoreThanNotified(uint96 _amount, uint64 _weight, uint32 _elapsed)
        public
    {
        _vaultSingleUserCannotReceiveMoreThanNotified(_amount, _weight, _elapsed);
    }

    function fuzzOnly_vaultTwoUsersCannotReceiveMoreThanNotified(uint96 _amount, uint64 _aliceWeight, uint64 _bobWeight)
        public
    {
        _vaultTwoUsersCannotReceiveMoreThanNotified(_amount, _aliceWeight, _bobWeight);
    }

    function testFuzz_vaultTwoUsersCannotReceiveMoreThanNotified(uint96 _amount, uint64 _aliceWeight, uint64 _bobWeight)
        public
    {
        _vaultTwoUsersCannotReceiveMoreThanNotified(_amount, _aliceWeight, _bobWeight);
    }

    function fuzzOnly_vaultClaimConservesRewardTokens(uint96 _amount, uint64 _aliceWeight, uint64 _bobWeight) public {
        _vaultClaimConservesRewardTokens(_amount, _aliceWeight, _bobWeight);
    }

    function testFuzz_vaultClaimConservesRewardTokens(uint96 _amount, uint64 _aliceWeight, uint64 _bobWeight) public {
        _vaultClaimConservesRewardTokens(_amount, _aliceWeight, _bobWeight);
    }

    function fuzzOnly_feeCenterSplitConservesRawFees(uint96 _amount, uint8 _receiverCount) public {
        _feeCenterSplitConservesRawFees(_amount, _receiverCount);
    }

    function testFuzz_feeCenterSplitConservesRawFees(uint96 _amount, uint8 _receiverCount) public {
        _feeCenterSplitConservesRawFees(_amount, _receiverCount);
    }

    function _vaultSingleUserCannotReceiveMoreThanNotified(uint96 _amount, uint64 _weight, uint32 _elapsed) internal {
        uint256 amount = _boundNonzero(_amount, MAX_SYMBOLIC_REWARD);
        uint256 weight = _boundWeight(_weight);
        uint256 elapsed = bound(uint256(_elapsed), 0, DEFAULT_DURATION);
        SymbolicERC20 rewardToken = _newRewardToken(18);

        _stake(alice, 1, weight, address(rewardToken));
        _notify(rewardToken, amount);

        vm.warp(block.timestamp + elapsed);
        uint256 pending = vault.pendingReward(1, address(rewardToken));

        assertLe(pending, amount, "vault pending exceeds notified amount");
    }

    function _vaultTwoUsersCannotReceiveMoreThanNotified(uint96 _amount, uint64 _aliceWeight, uint64 _bobWeight)
        internal
    {
        uint256 amount = _boundNonzero(_amount, MAX_SYMBOLIC_REWARD);
        uint256 aliceWeight = _boundWeight(_aliceWeight);
        uint256 bobWeight = _boundWeight(_bobWeight);
        SymbolicERC20 rewardToken = _newRewardToken(18);

        _stake(alice, 1, aliceWeight, address(rewardToken));
        _stake(bob, 2, bobWeight, address(rewardToken));
        _notify(rewardToken, amount);

        vm.warp(block.timestamp + DEFAULT_DURATION);

        uint256 alicePending = vault.pendingReward(1, address(rewardToken));
        uint256 bobPending = vault.pendingReward(2, address(rewardToken));
        assertLe(alicePending + bobPending, amount, "vault over-allocates reward stream");
    }

    function _vaultClaimConservesRewardTokens(uint96 _amount, uint64 _aliceWeight, uint64 _bobWeight) internal {
        uint256 amount = _boundNonzero(_amount, MAX_SYMBOLIC_REWARD);
        uint256 aliceWeight = _boundWeight(_aliceWeight);
        uint256 bobWeight = _boundWeight(_bobWeight);
        SymbolicERC20 rewardToken = _newRewardToken(18);

        _stake(alice, 1, aliceWeight, address(rewardToken));
        _stake(bob, 2, bobWeight, address(rewardToken));
        _notify(rewardToken, amount);

        vm.warp(block.timestamp + DEFAULT_DURATION);
        _claim(alice, 1, address(rewardToken));
        _claim(bob, 2, address(rewardToken));

        uint256 paid = rewardToken.balanceOf(alice) + rewardToken.balanceOf(bob);
        uint256 leftover = rewardToken.balanceOf(address(vault));

        assertLe(paid, amount, "vault paid more than notified");
        assertEq(paid + leftover, amount, "vault lost reward tokens");
    }

    function _feeCenterSplitConservesRawFees(uint96 _amount, uint8 _receiverCount) internal {
        uint256 amount = _boundNonzero(_amount, type(uint96).max);
        uint256 receiverCount = bound(uint256(_receiverCount), 1, 4);
        FeeCenter feeCenter = _deployFeeCenterProxy(address(this), address(vault), address(new FeeReceiver()));
        address[] memory receivers = new address[](receiverCount);

        for (uint256 i; i < receiverCount; ++i) {
            SymbolicERC20 output = new SymbolicERC20("Output", "OUT", 18);
            receivers[i] = feeCenter.addReceiver(address(output));
        }

        SymbolicERC20 feeToken = new SymbolicERC20("Fee", "FEE", 18);
        feeToken.mint(address(feeCenter), amount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);
        feeCenter.pushAndSplitFees(tokens);

        uint256 received;
        for (uint256 i; i < receiverCount; ++i) {
            received += feeToken.balanceOf(receivers[i]);
        }

        assertEq(received, amount, "fee split lost raw units");
        assertEq(feeToken.balanceOf(address(feeCenter)), 0, "fee center retained split dust");
    }

    function _newRewardToken(uint8 _decimals) internal returns (SymbolicERC20 rewardToken) {
        rewardToken = new SymbolicERC20("Reward", "RWD", _decimals);
        vault.setRewardToken(address(rewardToken), true);
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

    function _notify(SymbolicERC20 _rewardToken, uint256 _amount) internal {
        _rewardToken.mint(address(this), _amount);
        _rewardToken.approve(address(vault), _amount);
        vault.notifyRewardAmount(address(this), address(_rewardToken), _amount);
    }

    function _claim(address _owner, uint256 _tokenId, address _rewardToken) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = _rewardToken;
        vm.prank(_owner);
        vault.claim(_tokenId, tokens);
    }

    function _boundWeight(uint64 _weight) internal pure returns (uint256) {
        return MIN_DEPOSIT_AMOUNT + (uint256(_weight) % (MAX_APEX_WEIGHT - MIN_DEPOSIT_AMOUNT + 1));
    }

    function _boundNonzero(uint256 _value, uint256 _max) internal pure returns (uint256) {
        return 1 + (_value % _max);
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
