// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IApexController} from "./interfaces/IApexController.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";
import {ApexVaultStorage} from "./storage/ApexVaultStorage.sol";

contract ApexVault is Initializable, IERC721Receiver, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserConfig {
        address rewardToken;
        uint16 bps;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant PRECISION = 1e27;
    uint256 public constant MAX_ALLOCATIONS = 16;
    uint256 public constant MIN_DEPOSIT_AMOUNT = 1 ether;
    uint256 internal constant WEEK = 1 weeks;

    event VaultInitialized(address indexed veNFT, address indexed apexController);
    event VaultConfigSet(uint256 minRemainingLock, uint256 rewardDuration);
    event RewardTokenSet(address indexed token, bool status);
    event Staked(address indexed owner, uint256 indexed tokenId);
    event Unstaked(address indexed owner, uint256 indexed tokenId);
    event UserConfigSet(address indexed owner, uint256 indexed tokenId);
    event RewardNotified(address indexed token, uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event CompoundNotified(uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event Compounded(address indexed owner, uint256 indexed tokenId, uint256 amount);
    event CompoundForfeited(address indexed owner, uint256 indexed tokenId, uint256 amount);
    event Claimed(address indexed owner, uint256 indexed tokenId, address indexed token, uint256 amount);
    event InactiveFlushed(address indexed owner, uint256 indexed tokenId);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    // initializer
    function initialize(address _veNFT, address _apexController, uint256 _minRemainingLock, uint256 _rewardDuration)
        external
        initializer
    {
        require(_veNFT != address(0) && _apexController != address(0), ApexErrors.ZERO_ADDRESS());
        __ReentrancyGuard_init();

        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        s.veNFT = IVotingEscrow(_veNFT);
        s.apexController = _apexController;
        require(_rewardDuration != 0, ApexErrors.INVALID_DURATION());
        require(_minRemainingLock <= s.veNFT.MAXTIME(), ApexErrors.INVALID_DURATION());
        s.minRemainingLock = _minRemainingLock;
        s.rewardDuration = _rewardDuration;

        emit VaultConfigSet(_minRemainingLock, _rewardDuration);
        emit VaultInitialized(_veNFT, _apexController);
    }

    // modifiers
    modifier onlyApexController() {
        require(msg.sender == ApexVaultStorage.layout().apexController, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    modifier onlyPositionOwner(uint256 _tokenId) {
        ApexVaultStorage.Position memory position = ApexVaultStorage.layout().positions[_tokenId];
        require(position.staked && position.owner == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_tokenId));
        _;
    }

    // admin
    function setRewardToken(address _token, bool _status) external onlyApexController {
        require(_token != address(0), ApexErrors.ZERO_ADDRESS());
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        require((_token != address(s.veNFT) && _token != s.veNFT.token()) || !_status, ApexErrors.INVALID_ASSORTMENT());
        if (_status) s.rewardTokens.add(_token);
        s.isRewardToken[_token] = _status;
        if (s.rewardData[_token].lastUpdateTime == 0) s.rewardData[_token].lastUpdateTime = block.timestamp;
        emit RewardTokenSet(_token, _status);
    }

    function setVaultConfig(uint256 _minRemainingLock, uint256 _rewardDuration) external onlyApexController {
        require(_rewardDuration != 0, ApexErrors.INVALID_DURATION());
        require(_minRemainingLock <= ApexVaultStorage.layout().veNFT.MAXTIME(), ApexErrors.INVALID_DURATION());
        ApexVaultStorage.layout().minRemainingLock = _minRemainingLock;
        ApexVaultStorage.layout().rewardDuration = _rewardDuration;
        emit VaultConfigSet(_minRemainingLock, _rewardDuration);
    }

    function sweepUnallocated(address _token) external onlyApexController nonReentrant returns (uint256 amount) {
        require(_token != address(0), ApexErrors.ZERO_ADDRESS());
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        bool isCompound = _token == address(s.veNFT);
        require(isCompound || _token != s.veNFT.token(), ApexErrors.INVALID_ASSORTMENT());

        _updateBucket(_token);
        ApexVaultStorage.RewardData storage reward = s.rewardData[_token];
        amount = reward.unallocated;
        require(amount != 0, ApexErrors.ZERO_AMOUNT());
        reward.unallocated = 0;

        address token = isCompound ? s.veNFT.token() : _token;
        address treasury = IApexController(s.apexController).treasury();
        IERC20(token).safeTransfer(treasury, amount);

        emit TokenSwept(token, treasury, amount);
    }

    // MultiRewarder logic
    function notifyRewardAmount(address _from, address _token, uint256 _amount) external onlyApexController {
        require(_from != address(0), ApexErrors.ZERO_ADDRESS());

        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        require(_token != s.veNFT.token(), ApexErrors.INVALID_ASSORTMENT());
        require(s.isRewardToken[_token], ApexErrors.NOT_AUTHORIZED(_token));
        require(_amount != 0, ApexErrors.ZERO_AMOUNT());

        _updateBucket(_token);
        ApexVaultStorage.RewardData storage reward = s.rewardData[_token];
        require(reward.totalWeight != 0, ApexErrors.ZERO_AMOUNT());
        IERC20(_token).safeTransferFrom(_from, address(this), _amount);

        uint256 scaledRewardAmount = Math.mulDiv(_amount, PRECISION, 1);
        if (reward.periodFinish > block.timestamp) {
            scaledRewardAmount += (reward.periodFinish - block.timestamp) * reward.rewardRate + reward.periodRemainder
                + reward.scaledCarry;
        }
        reward.rewardRate = scaledRewardAmount / s.rewardDuration;
        require(reward.rewardRate != 0, ApexErrors.ZERO_AMOUNT());
        reward.periodRemainder = scaledRewardAmount % s.rewardDuration;
        reward.scaledCarry = 0;
        reward.periodFinish = block.timestamp + s.rewardDuration;
        reward.lastUpdateTime = block.timestamp;

        emit RewardNotified(_token, _amount, reward.rewardRate, reward.periodFinish);
    }

    function notifyCompoundAmount(address _from, uint256 _amount) external onlyApexController {
        require(_from != address(0), ApexErrors.ZERO_ADDRESS());
        require(_amount != 0, ApexErrors.ZERO_AMOUNT());

        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        address compoundBucket = address(s.veNFT);
        _updateBucket(compoundBucket);
        ApexVaultStorage.RewardData storage reward = s.rewardData[compoundBucket];
        require(reward.totalWeight != 0, ApexErrors.ZERO_AMOUNT());
        IERC20(s.veNFT.token()).safeTransferFrom(_from, address(this), _amount);

        uint256 scaledRewardAmount = Math.mulDiv(_amount, PRECISION, 1);
        if (reward.periodFinish > block.timestamp) {
            scaledRewardAmount += (reward.periodFinish - block.timestamp) * reward.rewardRate + reward.periodRemainder
                + reward.scaledCarry;
        }
        reward.rewardRate = scaledRewardAmount / s.rewardDuration;
        require(reward.rewardRate != 0, ApexErrors.ZERO_AMOUNT());
        reward.periodRemainder = scaledRewardAmount % s.rewardDuration;
        reward.scaledCarry = 0;
        reward.periodFinish = block.timestamp + s.rewardDuration;
        reward.lastUpdateTime = block.timestamp;

        emit CompoundNotified(_amount, reward.rewardRate, reward.periodFinish);
    }

    // user - vault functions
    function stake(uint256 _tokenId, UserConfig[] calldata _configs) external nonReentrant {
        _stake(_tokenId, _configs, 0);
    }

    function stake(uint256 _tokenId, UserConfig[] calldata _configs, uint16 _compoundBps) external nonReentrant {
        _stake(_tokenId, _configs, _compoundBps);
    }

    function _stake(uint256 _tokenId, UserConfig[] calldata _configs, uint16 _compoundBps) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        require(s.veNFT.ownerOf(_tokenId) == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_tokenId));
        require(!s.positions[_tokenId].staked, ApexErrors.POSITION_EXISTS(_tokenId));

        s.positions[_tokenId] = ApexVaultStorage.Position({owner: msg.sender, staked: true, active: true});
        _applyUserConfig(_tokenId, _configs, _compoundBps);
        s.activePositions.add(_tokenId);
        s.veNFT.safeTransferFrom(msg.sender, address(this), _tokenId);

        emit Staked(msg.sender, _tokenId);
    }

    function unstake(uint256 _tokenId) external nonReentrant onlyPositionOwner(_tokenId) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        _settleAllRewards(_tokenId);
        uint256 compoundAmount = s.rewards[_tokenId][address(s.veNFT)];
        bool weightsRemoved;
        if (compoundAmount != 0) {
            _removeWeights(_tokenId);
            _compoundStored(_tokenId);
            weightsRemoved = true;
        }
        _payConfiguredRewards(_tokenId, msg.sender);
        if (!weightsRemoved) _removeWeights(_tokenId);
        _clearConfig(_tokenId);
        s.activePositions.remove(_tokenId);
        delete s.positions[_tokenId];
        s.veNFT.safeTransferFrom(address(this), msg.sender, _tokenId);

        emit Unstaked(msg.sender, _tokenId);
    }

    function setUserConfig(uint256 _tokenId, UserConfig[] calldata _configs)
        external
        nonReentrant
        onlyPositionOwner(_tokenId)
    {
        _setUserConfig(_tokenId, _configs, 0);
    }

    function setUserConfig(uint256 _tokenId, UserConfig[] calldata _configs, uint16 _compoundBps)
        external
        nonReentrant
        onlyPositionOwner(_tokenId)
    {
        _setUserConfig(_tokenId, _configs, _compoundBps);
    }

    function _setUserConfig(uint256 _tokenId, UserConfig[] calldata _configs, uint16 _compoundBps) internal {
        _settleAllRewards(_tokenId);
        _payConfiguredRewards(_tokenId, msg.sender);
        _removeWeights(_tokenId);
        _compoundStored(_tokenId);
        _clearConfig(_tokenId);
        _applyUserConfig(_tokenId, _configs, _compoundBps);
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        s.positions[_tokenId].active = true;
        s.activePositions.add(_tokenId);
        emit UserConfigSet(msg.sender, _tokenId);
    }

    function claim(uint256 _tokenId, address[] calldata _tokens) external nonReentrant onlyPositionOwner(_tokenId) {
        _claimRewards(_tokenId, _tokens, msg.sender);
    }

    function claimAndExtendLock(uint256 _tokenId, address[] calldata _tokens)
        external
        nonReentrant
        onlyPositionOwner(_tokenId)
    {
        _claimRewards(_tokenId, _tokens, msg.sender);
        _extendLockToMax(_tokenId);
    }

    // user - veNFT passthrough functions
    function extendLock(uint256 _tokenId, uint256 _lockDuration) external nonReentrant onlyPositionOwner(_tokenId) {
        _extendLock(_tokenId, _lockDuration);
    }

    function _extendLock(uint256 _tokenId, uint256 _lockDuration) internal {
        _settleAllRewards(_tokenId);
        _removeWeights(_tokenId);
        _compoundStored(_tokenId);
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        s.veNFT.increaseUnlockTime(_tokenId, _lockDuration);
        _poke(_tokenId);
        s.positions[_tokenId].active = true;
        s.activePositions.add(_tokenId);
    }

    function _extendLockToMax(uint256 _tokenId) internal {
        _settleAllRewards(_tokenId);
        _removeWeights(_tokenId);
        _compoundStored(_tokenId);

        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        uint256 maxLockDuration = s.veNFT.MAXTIME();
        uint256 maxUnlockTime = ((block.timestamp + maxLockDuration) / WEEK) * WEEK;
        IVotingEscrow.LockedBalance memory lock = s.veNFT.locked(_tokenId);
        if (lock.end < maxUnlockTime) {
            s.veNFT.increaseUnlockTime(_tokenId, maxLockDuration);
        }

        _poke(_tokenId);
        s.positions[_tokenId].active = true;
        s.activePositions.add(_tokenId);
    }

    function increaseAmount(uint256 _tokenId, uint256 _amount) external nonReentrant onlyPositionOwner(_tokenId) {
        require(_amount != 0, ApexErrors.ZERO_AMOUNT());

        _settleAllRewards(_tokenId);
        _removeWeights(_tokenId);
        _compoundStored(_tokenId);

        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        IERC20 lockToken = IERC20(s.veNFT.token());
        lockToken.safeTransferFrom(msg.sender, address(this), _amount);
        lockToken.forceApprove(address(s.veNFT), _amount);
        s.veNFT.depositFor(_tokenId, _amount);
        lockToken.forceApprove(address(s.veNFT), 0);

        _poke(_tokenId);
        s.positions[_tokenId].active = true;
        s.activePositions.add(_tokenId);
    }

    function compound(uint256 _tokenId) external onlyApexController nonReentrant returns (uint256 amount) {
        amount = _compoundPosition(_tokenId);
    }

    function compoundMany(uint256[] calldata _tokenIds)
        external
        onlyApexController
        nonReentrant
        returns (uint256 amount)
    {
        for (uint256 i; i < _tokenIds.length; ++i) {
            amount += _compoundPosition(_tokenIds[i]);
        }
    }

    // keeper
    function flushInactive(uint256[] calldata _tokenIds) external nonReentrant returns (uint256 flushed) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        for (uint256 i; i < _tokenIds.length; ++i) {
            uint256 tokenId = _tokenIds[i];
            ApexVaultStorage.Position storage position = s.positions[tokenId];
            if (!position.staked || !position.active || _isEligible(tokenId)) continue;

            _settleAllRewards(tokenId);
            _removeWeights(tokenId);
            _compoundStored(tokenId);
            position.active = false;
            s.activePositions.remove(tokenId);
            emit InactiveFlushed(position.owner, tokenId);
            ++flushed;
        }
    }

    // internal

    // accounting
    // UserConfig bps become reward weights here, and rewardPerWeight accrual is advanced/settled here.
    function _applyUserConfig(uint256 _tokenId, UserConfig[] calldata _configs, uint16 _compoundBps) internal {
        require(
            (_configs.length != 0 || _compoundBps != 0) && _configs.length <= MAX_ALLOCATIONS,
            ApexErrors.INVALID_ASSORTMENT()
        );

        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        {
            uint256 sumBps = _compoundBps;
            address lockToken = s.veNFT.token();
            address compoundBucket = address(s.veNFT);
            for (uint256 i; i < _configs.length; ++i) {
                address rewardToken = _configs[i].rewardToken;
                require(
                    rewardToken != address(0) && rewardToken != compoundBucket && rewardToken != lockToken,
                    ApexErrors.INVALID_ASSORTMENT()
                );
                require(s.isRewardToken[rewardToken], ApexErrors.NOT_AUTHORIZED(rewardToken));
                require(_configs[i].bps != 0, ApexErrors.ZERO_AMOUNT());
                for (uint256 j; j < i; ++j) {
                    require(rewardToken != _configs[j].rewardToken, ApexErrors.INVALID_ASSORTMENT());
                }
                sumBps += _configs[i].bps;
            }
            require(sumBps == BPS, ApexErrors.INVALID_ASSORTMENT());
        }

        IVotingEscrow.LockedBalance memory lock = s.veNFT.locked(_tokenId);
        require(!lock.isPermanent, ApexErrors.INVALID_DURATION());
        require(lock.amount > 0, ApexErrors.ZERO_AMOUNT());
        require(lock.end >= block.timestamp + s.minRemainingLock, ApexErrors.INVALID_DURATION());

        uint256 totalWeight = uint256(uint128(lock.amount));
        require(totalWeight >= MIN_DEPOSIT_AMOUNT, ApexErrors.INSUFFICIENT_AMOUNT());
        uint256 remainingWeight = totalWeight;
        bool hasCompound = _compoundBps != 0;

        for (uint256 i; i < _configs.length; ++i) {
            address rewardToken = _configs[i].rewardToken;
            uint256 weight =
                i == _configs.length - 1 && !hasCompound ? remainingWeight : (totalWeight * _configs[i].bps) / BPS;
            remainingWeight -= weight;

            _updateBucket(rewardToken);
            s.configs[_tokenId][rewardToken] = ApexVaultStorage.Config({bps: _configs[i].bps, weight: weight});
            s.userRewardTokens[_tokenId].push(rewardToken);
            s.userRewardPerWeightPaid[_tokenId][rewardToken] = s.rewardData[rewardToken].rewardPerWeightStored;
            s.rewardData[rewardToken].totalWeight += weight;
        }
        if (hasCompound) {
            address compoundBucket = address(s.veNFT);
            _updateBucket(compoundBucket);
            s.configs[_tokenId][compoundBucket] = ApexVaultStorage.Config({bps: _compoundBps, weight: remainingWeight});
            s.userRewardPerWeightPaid[_tokenId][compoundBucket] = s.rewardData[compoundBucket].rewardPerWeightStored;
            s.rewardData[compoundBucket].totalWeight += remainingWeight;
        }
    }

    function _poke(uint256 _tokenId) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        address[] memory rewardTokens = s.userRewardTokens[_tokenId];
        address compoundBucket = address(s.veNFT);
        IVotingEscrow.LockedBalance memory lock = s.veNFT.locked(_tokenId);
        require(!lock.isPermanent, ApexErrors.INVALID_DURATION());
        require(lock.amount > 0, ApexErrors.ZERO_AMOUNT());
        require(lock.end >= block.timestamp + s.minRemainingLock, ApexErrors.INVALID_DURATION());

        uint256 totalWeight = uint256(uint128(lock.amount));
        require(totalWeight >= MIN_DEPOSIT_AMOUNT, ApexErrors.INSUFFICIENT_AMOUNT());
        uint256 remainingWeight = totalWeight;
        bool hasCompound = s.configs[_tokenId][compoundBucket].bps != 0;

        for (uint256 i; i < rewardTokens.length; ++i) {
            address rewardToken = rewardTokens[i];
            ApexVaultStorage.Config storage config = s.configs[_tokenId][rewardToken];
            uint256 weight =
                i == rewardTokens.length - 1 && !hasCompound ? remainingWeight : (totalWeight * config.bps) / BPS;
            remainingWeight -= weight;

            _updateBucket(rewardToken);
            config.weight = weight;
            s.userRewardPerWeightPaid[_tokenId][rewardToken] = s.rewardData[rewardToken].rewardPerWeightStored;
            s.rewardData[rewardToken].totalWeight += weight;
        }
        ApexVaultStorage.Config storage compoundConfig = s.configs[_tokenId][compoundBucket];
        if (compoundConfig.bps != 0) {
            _updateBucket(compoundBucket);
            compoundConfig.weight = remainingWeight;
            s.userRewardPerWeightPaid[_tokenId][compoundBucket] = s.rewardData[compoundBucket].rewardPerWeightStored;
            s.rewardData[compoundBucket].totalWeight += remainingWeight;
        }
    }

    function _removeWeights(uint256 _tokenId) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        address[] memory rewardTokens = s.userRewardTokens[_tokenId];
        for (uint256 i; i < rewardTokens.length; ++i) {
            address rewardToken = rewardTokens[i];
            ApexVaultStorage.Config storage config = s.configs[_tokenId][rewardToken];
            if (config.weight != 0) {
                s.rewardData[rewardToken].totalWeight -= config.weight;
            }
            config.weight = 0;
        }
        address compoundBucket = address(s.veNFT);
        ApexVaultStorage.Config storage compoundConfig = s.configs[_tokenId][compoundBucket];
        if (compoundConfig.weight != 0) {
            s.rewardData[compoundBucket].totalWeight -= compoundConfig.weight;
            compoundConfig.weight = 0;
        }
    }

    function _settleAllRewards(uint256 _tokenId) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        address[] memory rewardTokens = s.userRewardTokens[_tokenId];
        for (uint256 i; i < rewardTokens.length; ++i) {
            _settleReward(_tokenId, rewardTokens[i]);
        }
        address compoundBucket = address(s.veNFT);
        if (s.configs[_tokenId][compoundBucket].bps != 0) {
            _settleReward(_tokenId, compoundBucket);
        }
    }

    function _claimRewards(uint256 _tokenId, address[] calldata _tokens, address _owner) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        for (uint256 i; i < _tokens.length; ++i) {
            require(_tokens[i] != address(s.veNFT) && _tokens[i] != s.veNFT.token(), ApexErrors.INVALID_ASSORTMENT());
            _settleReward(_tokenId, _tokens[i]);
            _payReward(_tokenId, _tokens[i], _owner);
        }
    }

    function _payReward(uint256 _tokenId, address _token, address _owner) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        uint256 amount = s.rewards[_tokenId][_token];
        if (amount == 0) return;

        s.rewards[_tokenId][_token] = 0;
        IERC20(_token).safeTransfer(_owner, amount);
        emit Claimed(_owner, _tokenId, _token, amount);
    }

    function _payConfiguredRewards(uint256 _tokenId, address _owner) internal {
        address[] memory rewardTokens = ApexVaultStorage.layout().userRewardTokens[_tokenId];
        for (uint256 i; i < rewardTokens.length; ++i) {
            _payReward(_tokenId, rewardTokens[i], _owner);
        }
    }

    function _settleReward(uint256 _tokenId, address _token) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        _updateBucket(_token);

        ApexVaultStorage.Config storage config = s.configs[_tokenId][_token];
        uint256 rewardPerWeight = s.rewardData[_token].rewardPerWeightStored;
        uint256 paid = s.userRewardPerWeightPaid[_tokenId][_token];
        if (config.weight != 0 && rewardPerWeight > paid) {
            s.rewards[_tokenId][_token] += Math.mulDiv(config.weight, rewardPerWeight - paid, PRECISION);
        }
        s.userRewardPerWeightPaid[_tokenId][_token] = rewardPerWeight;
    }

    function _compoundPosition(uint256 _tokenId) internal returns (uint256 amount) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        ApexVaultStorage.Position memory position = s.positions[_tokenId];
        if (!position.staked || !position.active || !_isEligible(_tokenId)) return 0;

        _settleAllRewards(_tokenId);
        amount = s.rewards[_tokenId][address(s.veNFT)];
        if (amount == 0) return 0;

        _removeWeights(_tokenId);
        _compoundStored(_tokenId);
        _poke(_tokenId);
        s.positions[_tokenId].active = true;
        s.activePositions.add(_tokenId);
    }

    function _compoundStored(uint256 _tokenId) internal returns (uint256 amount) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        address compoundBucket = address(s.veNFT);
        amount = s.rewards[_tokenId][compoundBucket];
        if (amount == 0) return 0;

        s.rewards[_tokenId][compoundBucket] = 0;
        IVotingEscrow.LockedBalance memory lock = s.veNFT.locked(_tokenId);
        if (lock.amount <= 0 || lock.end <= block.timestamp) {
            IERC20(s.veNFT.token()).safeTransfer(IApexController(s.apexController).treasury(), amount);
            emit CompoundForfeited(s.positions[_tokenId].owner, _tokenId, amount);
            return 0;
        }

        IERC20 lockToken = IERC20(s.veNFT.token());
        lockToken.forceApprove(address(s.veNFT), amount);
        s.veNFT.depositFor(_tokenId, amount);
        lockToken.forceApprove(address(s.veNFT), 0);

        emit Compounded(s.positions[_tokenId].owner, _tokenId, amount);
    }

    function _updateBucket(address _token) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        ApexVaultStorage.RewardData storage reward = s.rewardData[_token];
        if (reward.lastUpdateTime == 0) {
            reward.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 applicable = block.timestamp < reward.periodFinish ? block.timestamp : reward.periodFinish;
        if (applicable > reward.lastUpdateTime) {
            uint256 scaledReward = (applicable - reward.lastUpdateTime) * reward.rewardRate + reward.scaledCarry;
            if (applicable == reward.periodFinish) {
                scaledReward += reward.periodRemainder;
                reward.periodRemainder = 0;
            }

            uint256 rewardAmount = scaledReward / PRECISION;
            reward.scaledCarry = scaledReward % PRECISION;
            if (rewardAmount != 0) {
                if (reward.totalWeight == 0) {
                    reward.unallocated += rewardAmount;
                } else {
                    reward.rewardPerWeightStored += Math.mulDiv(rewardAmount, PRECISION, reward.totalWeight);
                }
            }
        }
        reward.lastUpdateTime = applicable;
    }

    // position/config housekeeping
    function _clearConfig(uint256 _tokenId) internal {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        address[] memory rewardTokens = s.userRewardTokens[_tokenId];
        for (uint256 i; i < rewardTokens.length; ++i) {
            address rewardToken = rewardTokens[i];
            delete s.configs[_tokenId][rewardToken];
            delete s.userRewardPerWeightPaid[_tokenId][rewardToken];
        }
        address compoundBucket = address(s.veNFT);
        delete s.configs[_tokenId][compoundBucket];
        delete s.userRewardPerWeightPaid[_tokenId][compoundBucket];
        delete s.userRewardTokens[_tokenId];
    }

    function _isEligible(uint256 _tokenId) internal view returns (bool) {
        IVotingEscrow veNFT_ = ApexVaultStorage.layout().veNFT;
        try veNFT_.locked(_tokenId) returns (IVotingEscrow.LockedBalance memory lock) {
            return !lock.isPermanent && lock.amount > 0
                && lock.end >= block.timestamp + ApexVaultStorage.layout().minRemainingLock;
        } catch {
            return false;
        }
    }

    // views
    function pendingReward(uint256 _tokenId, address _rewardToken) external view returns (uint256) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        if (_rewardToken == address(s.veNFT) || _rewardToken == s.veNFT.token() || !s.positions[_tokenId].staked) {
            return 0;
        }
        return _pendingReward(s, _tokenId, _rewardToken);
    }

    function pendingCompound(uint256 _tokenId) external view returns (uint256) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        if (!s.positions[_tokenId].staked) return 0;
        return _pendingReward(s, _tokenId, address(s.veNFT));
    }

    function _pendingReward(ApexVaultStorage.Layout storage s, uint256 _tokenId, address _rewardToken)
        internal
        view
        returns (uint256)
    {
        ApexVaultStorage.Config memory config = s.configs[_tokenId][_rewardToken];
        ApexVaultStorage.RewardData memory reward = s.rewardData[_rewardToken];
        uint256 rewardPerWeight = reward.rewardPerWeightStored;
        uint256 applicable = block.timestamp < reward.periodFinish ? block.timestamp : reward.periodFinish;
        if (applicable > reward.lastUpdateTime) {
            uint256 scaledReward = (applicable - reward.lastUpdateTime) * reward.rewardRate + reward.scaledCarry;
            if (applicable == reward.periodFinish) scaledReward += reward.periodRemainder;

            uint256 rewardAmount = scaledReward / PRECISION;
            if (reward.totalWeight != 0 && rewardAmount != 0) {
                rewardPerWeight += Math.mulDiv(rewardAmount, PRECISION, reward.totalWeight);
            }
        }

        uint256 pending = s.rewards[_tokenId][_rewardToken];
        if (config.weight != 0 && rewardPerWeight > s.userRewardPerWeightPaid[_tokenId][_rewardToken]) {
            pending += Math.mulDiv(
                config.weight, rewardPerWeight - s.userRewardPerWeightPaid[_tokenId][_rewardToken], PRECISION
            );
        }
        return pending;
    }

    function _pendingUnallocated(ApexVaultStorage.RewardData memory _reward) internal view returns (uint256 amount) {
        amount = _reward.unallocated;
        uint256 applicable = block.timestamp < _reward.periodFinish ? block.timestamp : _reward.periodFinish;
        if (_reward.totalWeight == 0 && applicable > _reward.lastUpdateTime) {
            uint256 scaledReward = (applicable - _reward.lastUpdateTime) * _reward.rewardRate + _reward.scaledCarry;
            if (applicable == _reward.periodFinish) scaledReward += _reward.periodRemainder;
            amount += scaledReward / PRECISION;
        }
    }

    function rewardTokensLength() external view returns (uint256) {
        return ApexVaultStorage.layout().rewardTokens.length();
    }

    function rewardTokenAt(uint256 _index) external view returns (address) {
        return ApexVaultStorage.layout().rewardTokens.at(_index);
    }

    function isRewardToken(address _token) external view returns (bool) {
        return ApexVaultStorage.layout().isRewardToken[_token];
    }

    function userRewardTokens(uint256 _tokenId) external view returns (address[] memory) {
        return ApexVaultStorage.layout().userRewardTokens[_tokenId];
    }

    function userConfigOf(uint256 _tokenId, address _rewardToken) external view returns (uint16 bps, uint256 weight) {
        ApexVaultStorage.Config memory config = ApexVaultStorage.layout().configs[_tokenId][_rewardToken];
        return (config.bps, config.weight);
    }

    function compoundConfigOf(uint256 _tokenId) external view returns (uint16 bps, uint256 weight) {
        ApexVaultStorage.Layout storage s = ApexVaultStorage.layout();
        ApexVaultStorage.Config memory config = s.configs[_tokenId][address(s.veNFT)];
        return (config.bps, config.weight);
    }

    function positionActive(uint256 _tokenId) external view returns (bool) {
        return ApexVaultStorage.layout().positions[_tokenId].active;
    }

    function isFlushable(uint256 _tokenId) public view returns (bool) {
        ApexVaultStorage.Position memory position = ApexVaultStorage.layout().positions[_tokenId];
        return position.staked && position.active && !_isEligible(_tokenId);
    }

    function activePositionsLength() external view returns (uint256) {
        return ApexVaultStorage.layout().activePositions.length();
    }

    function activePositionAt(uint256 _index) external view returns (uint256) {
        return ApexVaultStorage.layout().activePositions.at(_index);
    }

    function activePositionIds(uint256 _start, uint256 _count) external view returns (uint256[] memory tokenIds) {
        EnumerableSet.UintSet storage activePositions = ApexVaultStorage.layout().activePositions;
        uint256 length = activePositions.length();
        if (_start >= length) return new uint256[](0);

        uint256 remaining = length - _start;
        uint256 count = _count > remaining ? remaining : _count;
        tokenIds = new uint256[](count);
        for (uint256 i; i < tokenIds.length; ++i) {
            tokenIds[i] = activePositions.at(_start + i);
        }
    }

    function rewardData(address _token)
        external
        view
        returns (
            uint256 rewardRate,
            uint256 periodFinish,
            uint256 lastUpdateTime,
            uint256 rewardPerWeightStored,
            uint256 totalWeight
        )
    {
        ApexVaultStorage.RewardData memory reward = ApexVaultStorage.layout().rewardData[_token];
        return (
            reward.rewardRate,
            reward.periodFinish,
            reward.lastUpdateTime,
            reward.rewardPerWeightStored,
            reward.totalWeight
        );
    }

    function unallocatedReward(address _token) external view returns (uint256) {
        return _pendingUnallocated(ApexVaultStorage.layout().rewardData[_token]);
    }

    function veNFT() external view returns (IVotingEscrow) {
        return ApexVaultStorage.layout().veNFT;
    }

    function apexController() external view returns (address) {
        return ApexVaultStorage.layout().apexController;
    }

    function minRemainingLock() external view returns (uint256) {
        return ApexVaultStorage.layout().minRemainingLock;
    }

    function rewardDuration() external view returns (uint256) {
        return ApexVaultStorage.layout().rewardDuration;
    }

    function positionOwner(uint256 _tokenId) external view returns (address) {
        return ApexVaultStorage.layout().positions[_tokenId].owner;
    }

    // ERC721 receiver
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(ApexVaultStorage.layout().veNFT), ApexErrors.NOT_AUTHORIZED(msg.sender));
        return IERC721Receiver.onERC721Received.selector;
    }
}
