// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IApexController} from "./interfaces/IApexController.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";

interface IClassicChefWithdrawReceiver {
    function onClassicChefWithdraw(address account, uint256 pid, uint256 amount, bytes calldata data) external;
}

/// @notice JoeV2/Sushi-style ERC20 LP MasterChef adapted to Apex controller emissions.
contract ClassicChef is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accRewardPerShare;
        uint256 totalStaked;
    }

    uint256 public constant ACC_PRECISION = 1e24;
    uint256 public constant REWARD_PRECISION = 1e12;

    IERC20 public immutable rewardToken;
    address public immutable apexController;

    PoolInfo[] public poolInfo;
    mapping(uint256 pid => mapping(address user => UserInfo info)) public userInfo;
    mapping(address lpToken => uint256 pidPlusOne) public lpTokenPid;

    uint256 public totalAllocPoint;

    event Add(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken);
    event Set(uint256 indexed pid, uint256 allocPoint);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdatePool(uint256 indexed pid, uint256 lastRewardTime, uint256 lpSupply, uint256 accRewardPerShare);

    modifier onlyApexController() {
        require(msg.sender == apexController, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    constructor(address _rewardToken, address _apexController) {
        require(_rewardToken != address(0) && _apexController != address(0), ApexErrors.ZERO_ADDRESS());
        rewardToken = IERC20(_rewardToken);
        apexController = _apexController;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, IERC20 _lpToken) public onlyApexController {
        address lpToken = address(_lpToken);
        require(lpToken != address(0), ApexErrors.ZERO_ADDRESS());
        require(lpTokenPid[lpToken] == 0, ApexErrors.POOL_EXISTS(lpToken));

        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTime: block.timestamp,
                accRewardPerShare: 0,
                totalStaked: 0
            })
        );
        uint256 pid = poolInfo.length - 1;
        lpTokenPid[lpToken] = pid + 1;

        emit Add(pid, _allocPoint, _lpToken);
    }

    function set(uint256 _pid, uint256 _allocPoint) public onlyApexController {
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.allocPoint = _allocPoint;

        emit Set(_pid, _allocPoint);
    }

    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        _depositFor(_pid, _amount, msg.sender);
    }

    function depositFor(uint256 _pid, uint256 _amount, address _account) public nonReentrant {
        require(_account != address(0), ApexErrors.ZERO_ADDRESS());
        _depositFor(_pid, _amount, _account);
    }

    function _depositFor(uint256 _pid, uint256 _amount, address _account) internal {
        PoolInfo storage pool = _updatePool(_pid);
        UserInfo storage user = userInfo[_pid][_account];

        _harvest(_pid, _account, pool, user);

        user.amount += _amount;
        pool.totalStaked += _amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;
        pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposit(_account, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        _withdrawTo(_pid, _amount, msg.sender);
    }

    function withdrawTo(uint256 _pid, uint256 _amount, address _to) public nonReentrant {
        require(_to != address(0), ApexErrors.ZERO_ADDRESS());
        _withdrawTo(_pid, _amount, _to);
    }

    function withdrawToAndCall(uint256 _pid, uint256 _amount, address _to, bytes calldata _data) external nonReentrant {
        require(_to != address(0), ApexErrors.ZERO_ADDRESS());
        _withdrawTo(_pid, _amount, _to);
        IClassicChefWithdrawReceiver(_to).onClassicChefWithdraw(msg.sender, _pid, _amount, _data);
    }

    function _withdrawTo(uint256 _pid, uint256 _amount, address _to) internal {
        PoolInfo storage pool = _updatePool(_pid);
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, ApexErrors.INSUFFICIENT_LIQUIDITY());

        _harvest(_pid, msg.sender, pool, user);

        user.amount -= _amount;
        pool.totalStaked -= _amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;
        pool.lpToken.safeTransfer(_to, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = _updatePool(_pid);
        UserInfo storage user = userInfo[_pid][msg.sender];

        _harvest(_pid, msg.sender, pool, user);
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / ACC_PRECISION;
    }

    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        require(amount != 0, ApexErrors.ZERO_AMOUNT());

        user.amount = 0;
        user.rewardDebt = 0;
        pool.totalStaked -= amount;
        pool.lpToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accRewardPerShare = pool.accRewardPerShare;
        (uint256 rewardPerSecond, uint256 endTime) =
            IApexController(apexController).getLatestPeriodInfo(address(pool.lpToken));
        uint256 rewardTo = block.timestamp < endTime ? block.timestamp : endTime;
        if (rewardTo > pool.lastRewardTime && pool.totalStaked != 0 && rewardPerSecond != 0) {
            uint256 elapsed = rewardTo - pool.lastRewardTime;
            uint256 reward = (elapsed * rewardPerSecond) / REWARD_PRECISION;
            accRewardPerShare += (reward * ACC_PRECISION) / pool.totalStaked;
        }

        return (user.amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        _updatePool(_pid);
    }

    function _updatePool(uint256 _pid) internal returns (PoolInfo storage pool) {
        pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) return pool;

        (uint256 rewardPerSecond, uint256 endTime) =
            IApexController(apexController).getLatestPeriodInfo(address(pool.lpToken));
        uint256 rewardTo = block.timestamp < endTime ? block.timestamp : endTime;
        if (pool.totalStaked == 0) {
            if (rewardPerSecond != 0 && rewardTo > pool.lastRewardTime) {
                // release elapsed emissions that no staker can ever claim
                uint256 skippedReward = ((rewardTo - pool.lastRewardTime) * rewardPerSecond) / REWARD_PRECISION;
                if (skippedReward != 0) {
                    IApexController(apexController).forfeitReward(address(pool.lpToken), skippedReward);
                }
            }
            pool.lastRewardTime = block.timestamp;
            emit UpdatePool(_pid, pool.lastRewardTime, pool.totalStaked, pool.accRewardPerShare);
            return pool;
        }
        if (rewardPerSecond == 0 || rewardTo <= pool.lastRewardTime) {
            pool.lastRewardTime = block.timestamp;
            emit UpdatePool(_pid, pool.lastRewardTime, pool.totalStaked, pool.accRewardPerShare);
            return pool;
        }

        uint256 elapsed = rewardTo - pool.lastRewardTime;
        uint256 reward = (elapsed * rewardPerSecond) / REWARD_PRECISION;
        pool.accRewardPerShare += (reward * ACC_PRECISION) / pool.totalStaked;
        pool.lastRewardTime = block.timestamp;

        emit UpdatePool(_pid, pool.lastRewardTime, pool.totalStaked, pool.accRewardPerShare);
    }

    // Apex controller helpers keep operator actions address-based while public farm UX stays pid-based.
    function addPool(address _lpToken, uint256 _allocPoint) external {
        add(_allocPoint, IERC20(_lpToken));
    }

    function setPoolAllocPoint(address _lpToken, uint256 _allocPoint) external {
        set(pidOf(_lpToken), _allocPoint);
    }

    function pidOf(address _lpToken) public view returns (uint256 pid) {
        uint256 pidPlusOne = lpTokenPid[_lpToken];
        require(pidPlusOne != 0, ApexErrors.INVALID_POOL(_lpToken));
        pid = pidPlusOne - 1;
    }

    function _harvest(uint256 _pid, address _account, PoolInfo storage _pool, UserInfo storage _user) internal {
        uint256 pending = (_user.amount * _pool.accRewardPerShare) / ACC_PRECISION - _user.rewardDebt;
        if (pending != 0) {
            uint256 paid = IApexController(apexController).payReward(address(_pool.lpToken), _account, pending);
            emit Harvest(_account, _pid, paid);
        }
    }
}
