// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CLEnumerable} from "./CLEnumerable.sol";
import {IApexController} from "./interfaces/IApexController.sol";
import {ILmPool} from "./interfaces/ILmPool.sol";
import {ILmPoolDeployer} from "./interfaces/ILmPoolDeployer.sol";
import {ICLMasterChef} from "./interfaces/ICLMasterChef.sol";
import {ICLNonfungiblePositionManager} from "./interfaces/ICLNonfungiblePositionManager.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";

contract CLMasterChef is ICLMasterChef, IERC721Receiver, ReentrancyGuard, CLEnumerable {
    using SafeERC20 for IERC20;

    struct PoolInfo {
        uint256 allocPoint;
        ICLPool clPool;
        address token0;
        address token1;
        uint24 fee;
        uint256 totalLiquidity;
    }

    struct UserPositionInfo {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 rewardGrowthInside;
        uint256 reward;
        address user;
        uint256 pid;
        uint40 lastLiquidityChange;
    }

    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    uint256 public constant REWARD_PRECISION = 1e12;
    uint256 public constant Q128 = 0x100000000000000000000000000000000;
    uint32 public constant DEFAULT_MEV_RESISTANCE_WINDOW = 120;

    IERC20 public immutable rewardToken;
    address public immutable apexController;
    address public immutable WETH;
    ICLNonfungiblePositionManager public immutable positionManager;

    uint256 public poolLength;
    mapping(uint256 pid => PoolInfo info) public poolInfo;
    mapping(uint256 tokenId => UserPositionInfo info) public userPositionInfos;
    mapping(address token0 => mapping(address token1 => mapping(uint24 fee => uint256 pid))) public v3PoolPid;
    mapping(address pool => uint256 pid) public v3PoolAddressPid;

    address public override lmPoolDeployer;
    bool public emergency;
    uint32 public mevResistanceWindow;
    uint256 public totalAllocPoint;

    event AddPool(uint256 indexed pid, uint256 allocPoint, ICLPool indexed clPool, ILmPool indexed lmPool);
    event SetPool(uint256 indexed pid, uint256 allocPoint);
    event LmPoolDeployerSet(address indexed lmPoolDeployer);
    event EmergencySet(bool emergency);
    event MevResistanceWindowSet(uint32 window);
    event MevResistanceRewardSlashed(
        address indexed user, uint256 indexed pid, uint256 indexed tokenId, uint256 amount
    );
    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 indexed tokenId,
        uint256 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event Withdraw(address indexed user, address to, uint256 indexed pid, uint256 indexed tokenId);
    event Harvest(address indexed user, address to, uint256 indexed pid, uint256 indexed tokenId, uint256 reward);
    event UpdateLiquidity(
        address indexed user,
        uint256 indexed pid,
        uint256 indexed tokenId,
        int128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    modifier onlyApexController() {
        require(msg.sender == apexController, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    modifier onlyValidPid(uint256 _pid) {
        require(_pid != 0 && _pid <= poolLength, ApexErrors.INVALID_POOL(address(0)));
        _;
    }

    constructor(address rewardToken_, address apexController_, address positionManager_) {
        require(
            rewardToken_ != address(0) && apexController_ != address(0) && positionManager_ != address(0),
            ApexErrors.ZERO_ADDRESS()
        );
        rewardToken = IERC20(rewardToken_);
        apexController = apexController_;
        positionManager = ICLNonfungiblePositionManager(positionManager_);
        WETH = ICLNonfungiblePositionManager(positionManager_).WETH9();
        mevResistanceWindow = DEFAULT_MEV_RESISTANCE_WINDOW;
    }

    function nonfungiblePositionManager() external view override returns (address) {
        return address(positionManager);
    }

    function setLMPoolDeployer(address _lmPoolDeployer) public override onlyApexController {
        _setLMPoolDeployer(_lmPoolDeployer);
    }

    function setLmPoolDeployer(address _lmPoolDeployer) external override onlyApexController {
        _setLMPoolDeployer(_lmPoolDeployer);
    }

    function setEmergency(bool _emergency) external override onlyApexController {
        emergency = _emergency;
        emit EmergencySet(_emergency);
    }

    function setMevResistanceWindow(uint32 _window) external override onlyApexController {
        mevResistanceWindow = _window;
        emit MevResistanceWindowSet(_window);
    }

    function addPool(address _pool, uint256 _allocPoint) external override onlyApexController {
        _add(_allocPoint, ICLPool(_pool), false);
    }

    function add(uint256 _allocPoint, ICLPool _clPool, bool _withUpdate) external onlyApexController {
        _add(_allocPoint, _clPool, _withUpdate);
    }

    function setPoolAllocPoint(address _pool, uint256 _allocPoint) external override onlyApexController {
        uint256 pid = v3PoolAddressPid[_pool];
        require(pid != 0, ApexErrors.INVALID_POOL(_pool));
        _set(pid, _allocPoint, false);
    }

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyApexController onlyValidPid(_pid) {
        _set(_pid, _allocPoint, _withUpdate);
    }

    function getLatestPeriodInfoByPid(uint256 _pid)
        public
        view
        onlyValidPid(_pid)
        returns (uint256 rewardPerSecond, uint256 endTime)
    {
        return IApexController(apexController).getLatestPeriodInfo(address(poolInfo[_pid].clPool));
    }

    function getLatestPeriodInfo(address _pool)
        external
        view
        override
        returns (uint256 rewardPerSecond, uint256 endTime)
    {
        return IApexController(apexController).getLatestPeriodInfo(_pool);
    }

    function forfeitReward(address _pool, uint256 _amount) external override returns (uint256 forfeited) {
        uint256 pid = v3PoolAddressPid[_pool];
        require(pid != 0, ApexErrors.INVALID_POOL(_pool));
        require(msg.sender == address(poolInfo[pid].clPool.lmPool()), ApexErrors.NOT_AUTHORIZED(msg.sender));
        forfeited = IApexController(apexController).forfeitReward(_pool, _amount);
    }

    function pendingReward(uint256 _tokenId) external view returns (uint256 reward) {
        UserPositionInfo memory positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.pid == 0) return 0;

        ILmPool lmPool = ILmPool(poolInfo[positionInfo.pid].clPool.lmPool());
        if (address(lmPool) != address(0)) {
            uint256 rewardGrowthInside = lmPool.getRewardGrowthInside(positionInfo.tickLower, positionInfo.tickUpper);
            uint256 rewardGrowthInsideDelta;
            unchecked {
                rewardGrowthInsideDelta = rewardGrowthInside - positionInfo.rewardGrowthInside;
            }
            reward = (rewardGrowthInsideDelta * positionInfo.liquidity) / Q128;
        }
        reward += positionInfo.reward;
        if (_insideMevWindow(positionInfo)) return 0;
    }

    function onERC721Received(address, address _from, uint256 _tokenId, bytes calldata _data)
        external
        override
        nonReentrant
        returns (bytes4)
    {
        require(msg.sender == address(positionManager), ApexErrors.NOT_AUTHORIZED(msg.sender));

        PositionData memory position = _position(_tokenId);
        require(position.liquidity != 0, ApexErrors.ZERO_AMOUNT());
        uint256 pid = v3PoolPid[position.token0][position.token1][position.fee];
        require(pid != 0, ApexErrors.INVALID_POOL(address(0)));

        PoolInfo storage pool = poolInfo[pid];
        ILmPool lmPool = ILmPool(pool.clPool.lmPool());
        require(address(lmPool) != address(0), ApexErrors.ZERO_ADDRESS());

        address user;
        if (_data.length == 0) {
            user = _from;
        } else {
            require(_from == address(positionManager) && _data.length == 32, ApexErrors.INVALID_TRANSFER());
            user = abi.decode(_data, (address));
        }
        require(user != address(0), ApexErrors.ZERO_ADDRESS());

        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        positionInfo.tickLower = position.tickLower;
        positionInfo.tickUpper = position.tickUpper;
        positionInfo.user = user;
        positionInfo.pid = pid;

        lmPool.accumulateReward(uint32(block.timestamp));
        _updateLiquidityOperation(positionInfo, _tokenId);
        positionInfo.lastLiquidityChange = uint40(block.timestamp);

        addToken(user, _tokenId);
        emit Deposit(user, pid, _tokenId, position.liquidity, position.tickLower, position.tickUpper);
        return IERC721Receiver.onERC721Received.selector;
    }

    function harvest(uint256 _tokenId, address _to) external nonReentrant returns (uint256 reward) {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_tokenId));
        require(positionInfo.liquidity != 0 || positionInfo.reward != 0, ApexErrors.ZERO_AMOUNT());
        reward = _harvest(positionInfo, _tokenId, _to, true);
    }

    function withdraw(uint256 _tokenId, address _to) external nonReentrant returns (uint256 reward) {
        require(_to != address(0) && _to != address(this), ApexErrors.INVALID_TRANSFER());
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_tokenId));

        reward = _harvest(positionInfo, _tokenId, _to, true);
        uint256 pid = positionInfo.pid;
        PoolInfo storage pool = poolInfo[pid];
        ILmPool lmPool = ILmPool(pool.clPool.lmPool());
        if (address(lmPool) != address(0) && !emergency && positionInfo.liquidity != 0) {
            int128 liquidityDelta = -int128(positionInfo.liquidity);
            lmPool.updatePosition(positionInfo.tickLower, positionInfo.tickUpper, liquidityDelta);
            emit UpdateLiquidity(
                msg.sender, pid, _tokenId, liquidityDelta, positionInfo.tickLower, positionInfo.tickUpper
            );
        }
        pool.totalLiquidity -= positionInfo.liquidity;

        delete userPositionInfos[_tokenId];
        removeToken(msg.sender, _tokenId);
        positionManager.safeTransferFrom(address(this), _to, _tokenId);
        emit Withdraw(msg.sender, _to, pid, _tokenId);
    }

    function updateLiquidity(uint256 _tokenId) external nonReentrant {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        require(positionInfo.pid != 0, ApexErrors.INVALID_POOL(address(0)));
        _harvest(positionInfo, _tokenId, address(0), false);
        _updateLiquidityOperation(positionInfo, _tokenId);
    }

    function increaseLiquidity(ICLNonfungiblePositionManager.IncreaseLiquidityParams calldata _params)
        external
        payable
        nonReentrant
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        UserPositionInfo storage positionInfo = userPositionInfos[_params.tokenId];
        require(positionInfo.pid != 0, ApexErrors.INVALID_POOL(address(0)));
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_params.tokenId));
        PoolInfo memory pool = poolInfo[positionInfo.pid];

        _pay(pool.token0, _params.amount0Desired);
        _pay(pool.token1, _params.amount1Desired);
        if (pool.token0 != WETH && pool.token1 != WETH && msg.value != 0) revert ApexErrors.INCONSISTENT_AMOUNT();

        (liquidity, amount0, amount1) = positionManager.increaseLiquidity{value: msg.value}(_params);

        uint256 token0Left = _params.amount0Desired - amount0;
        uint256 token1Left = _params.amount1Desired - amount1;
        if (token0Left != 0) _refund(pool.token0, token0Left);
        if (token1Left != 0) _refund(pool.token1, token1Left);

        _harvest(positionInfo, _params.tokenId, positionInfo.user, true);
        _updateLiquidityOperation(positionInfo, _params.tokenId);
        if (liquidity != 0) positionInfo.lastLiquidityChange = uint40(block.timestamp);
    }

    function decreaseLiquidity(ICLNonfungiblePositionManager.DecreaseLiquidityParams calldata _params)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        UserPositionInfo storage positionInfo = userPositionInfos[_params.tokenId];
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_params.tokenId));

        (amount0, amount1) = positionManager.decreaseLiquidity(_params);
        _harvest(positionInfo, _params.tokenId, positionInfo.user, true);
        _updateLiquidityOperation(positionInfo, _params.tokenId);
        if (_params.liquidity != 0) positionInfo.lastLiquidityChange = uint40(block.timestamp);
    }

    function collect(ICLNonfungiblePositionManager.CollectParams calldata _params)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        UserPositionInfo storage positionInfo = userPositionInfos[_params.tokenId];
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_params.tokenId));

        ICLNonfungiblePositionManager.CollectParams memory params = _params;
        if (params.recipient == address(0)) params.recipient = address(this);
        (amount0, amount1) = positionManager.collect(params);
    }

    function collectTo(ICLNonfungiblePositionManager.CollectParams calldata _params, address _to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        UserPositionInfo storage positionInfo = userPositionInfos[_params.tokenId];
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_params.tokenId));

        ICLNonfungiblePositionManager.CollectParams memory params = _params;
        if (params.recipient == address(0)) params.recipient = address(this);
        (amount0, amount1) = positionManager.collect(params);

        if (params.recipient == address(this)) {
            PoolInfo memory pool = poolInfo[positionInfo.pid];
            address to = _to == address(0) ? msg.sender : _to;
            _transferToken(pool.token0, to);
            _transferToken(pool.token1, to);
        }
    }

    function unwrapWETH9(uint256 _amountMinimum, address _recipient) external nonReentrant {
        uint256 balanceWETH = IERC20(WETH).balanceOf(address(this));
        if (balanceWETH < _amountMinimum) revert ApexErrors.INSUFFICIENT_AMOUNT();

        if (balanceWETH != 0) {
            IWETH9(WETH).withdraw(balanceWETH);
            _safeTransferETH(_recipient, balanceWETH);
        }
    }

    function sweepToken(address _token, uint256 _amountMinimum, address _recipient) external nonReentrant {
        uint256 balance = _sweepableBalance(_token);
        if (balance < _amountMinimum) revert ApexErrors.INSUFFICIENT_AMOUNT();
        if (balance != 0) IERC20(_token).safeTransfer(_recipient, balance);
    }

    function burn(uint256 _tokenId) external nonReentrant {
        UserPositionInfo memory positionInfo = userPositionInfos[_tokenId];
        require(positionInfo.user == msg.sender, ApexErrors.NOT_TOKEN_OWNER(_tokenId));
        if (positionInfo.reward != 0 || positionInfo.liquidity != 0) revert ApexErrors.NOT_EMPTY();

        delete userPositionInfos[_tokenId];
        removeToken(msg.sender, _tokenId);
        positionManager.burn(_tokenId);
        emit Withdraw(msg.sender, address(0), positionInfo.pid, _tokenId);
    }

    function multicall(bytes[] calldata _data) external payable returns (bytes[] memory results) {
        results = new bytes[](_data.length);
        for (uint256 i; i < _data.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(_data[i]);
            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }

    function massUpdatePools() external onlyApexController {
        _massUpdatePools();
    }

    function _massUpdatePools() internal {
        uint32 currentTime = uint32(block.timestamp);
        for (uint256 pid = 1; pid <= poolLength; ++pid) {
            PoolInfo memory pool = poolInfo[pid];
            ILmPool lmPool = ILmPool(pool.clPool.lmPool());
            if (pool.allocPoint != 0 && address(lmPool) != address(0)) {
                lmPool.accumulateReward(currentTime);
            }
        }
    }

    function updatePools(uint256[] calldata _pids) external onlyApexController {
        uint32 currentTime = uint32(block.timestamp);
        for (uint256 i; i < _pids.length; ++i) {
            uint256 pid = _pids[i];
            PoolInfo memory pool = poolInfo[pid];
            ILmPool lmPool = ILmPool(pool.clPool.lmPool());
            if (pool.allocPoint != 0 && address(lmPool) != address(0)) {
                lmPool.accumulateReward(currentTime);
            }
        }
    }

    function _add(uint256 _allocPoint, ICLPool _clPool, bool _withUpdate) internal {
        require(address(_clPool) != address(0), ApexErrors.ZERO_ADDRESS());
        require(lmPoolDeployer != address(0), ApexErrors.ZERO_ADDRESS());
        if (_withUpdate) _massUpdatePools();

        ILmPool lmPool = ILmPool(ILmPoolDeployer(lmPoolDeployer).deploy(address(_clPool)));

        totalAllocPoint += _allocPoint;
        address token0 = _clPool.token0();
        address token1 = _clPool.token1();
        uint24 fee = _clPool.fee();
        require(v3PoolPid[token0][token1][fee] == 0, ApexErrors.POOL_EXISTS(address(_clPool)));
        require(v3PoolAddressPid[address(_clPool)] == 0, ApexErrors.POOL_EXISTS(address(_clPool)));

        if (IERC20(token0).allowance(address(this), address(positionManager)) == 0) {
            IERC20(token0).forceApprove(address(positionManager), type(uint256).max);
        }
        if (IERC20(token1).allowance(address(this), address(positionManager)) == 0) {
            IERC20(token1).forceApprove(address(positionManager), type(uint256).max);
        }

        unchecked {
            poolLength++;
        }
        poolInfo[poolLength] = PoolInfo({
            allocPoint: _allocPoint, clPool: _clPool, token0: token0, token1: token1, fee: fee, totalLiquidity: 0
        });
        v3PoolPid[token0][token1][fee] = poolLength;
        v3PoolAddressPid[address(_clPool)] = poolLength;

        emit AddPool(poolLength, _allocPoint, _clPool, lmPool);
    }

    function _setLMPoolDeployer(address _lmPoolDeployer) internal {
        require(_lmPoolDeployer != address(0), ApexErrors.ZERO_ADDRESS());
        lmPoolDeployer = _lmPoolDeployer;
        emit LmPoolDeployerSet(_lmPoolDeployer);
    }

    function _set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) internal {
        PoolInfo storage pool = poolInfo[_pid];
        ILmPool lmPool = ILmPool(pool.clPool.lmPool());
        if (address(lmPool) != address(0)) {
            lmPool.accumulateReward(uint32(block.timestamp));
        }
        if (_withUpdate) _massUpdatePools();

        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.allocPoint = _allocPoint;
        emit SetPool(_pid, _allocPoint);
    }

    function _harvest(UserPositionInfo storage _positionInfo, uint256 _tokenId, address _to, bool _slashMevReward)
        internal
        returns (uint256 reward)
    {
        PoolInfo memory pool = poolInfo[_positionInfo.pid];
        ILmPool lmPool = ILmPool(pool.clPool.lmPool());
        if (address(lmPool) != address(0) && !emergency) {
            lmPool.accumulateReward(uint32(block.timestamp));
            uint256 rewardGrowthInside = lmPool.getRewardGrowthInside(_positionInfo.tickLower, _positionInfo.tickUpper);
            uint256 rewardGrowthInsideDelta;
            unchecked {
                rewardGrowthInsideDelta = rewardGrowthInside - _positionInfo.rewardGrowthInside;
            }
            reward = (rewardGrowthInsideDelta * _positionInfo.liquidity) / Q128;
            _positionInfo.rewardGrowthInside = rewardGrowthInside;
        }

        reward += _positionInfo.reward;
        if (reward == 0) return 0;

        if (_slashMevReward && _insideMevWindow(_positionInfo)) {
            _positionInfo.reward = 0;
            uint256 forfeited = IApexController(apexController).forfeitReward(address(pool.clPool), reward);
            emit MevResistanceRewardSlashed(_positionInfo.user, _positionInfo.pid, _tokenId, forfeited);
            return 0;
        }

        if (_to == address(0)) {
            _positionInfo.reward = reward;
            return reward;
        }

        _positionInfo.reward = 0;
        reward = IApexController(apexController).payReward(address(pool.clPool), _to, reward);
        emit Harvest(_positionInfo.user, _to, _positionInfo.pid, _tokenId, reward);
    }

    function _insideMevWindow(UserPositionInfo memory _positionInfo) internal view returns (bool) {
        uint256 window = mevResistanceWindow;
        return window != 0 && block.timestamp < uint256(_positionInfo.lastLiquidityChange) + window;
    }

    function _updateLiquidityOperation(UserPositionInfo storage _positionInfo, uint256 _tokenId) internal {
        PositionData memory position = _position(_tokenId);
        PoolInfo storage pool = poolInfo[_positionInfo.pid];
        if (_positionInfo.liquidity == position.liquidity) return;

        int128 liquidityDelta = int128(position.liquidity) - int128(_positionInfo.liquidity);
        pool.totalLiquidity = pool.totalLiquidity - _positionInfo.liquidity + position.liquidity;
        _positionInfo.liquidity = position.liquidity;
        _positionInfo.tickLower = position.tickLower;
        _positionInfo.tickUpper = position.tickUpper;

        ILmPool lmPool = ILmPool(pool.clPool.lmPool());
        require(address(lmPool) != address(0), ApexErrors.ZERO_ADDRESS());
        lmPool.updatePosition(position.tickLower, position.tickUpper, liquidityDelta);
        _positionInfo.rewardGrowthInside = lmPool.getRewardGrowthInside(position.tickLower, position.tickUpper);
        emit UpdateLiquidity(
            _positionInfo.user, _positionInfo.pid, _tokenId, liquidityDelta, position.tickLower, position.tickUpper
        );
    }

    function _pay(address _token, uint256 _amount) internal {
        if (_token == WETH && msg.value != 0) {
            if (msg.value != _amount) revert ApexErrors.INCONSISTENT_AMOUNT();
        } else {
            if (_amount != 0) IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
    }

    function _refund(address _token, uint256 _amount) internal {
        if (_token == WETH && msg.value != 0) {
            positionManager.refundETH();
            _safeTransferETH(msg.sender, address(this).balance);
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    function _transferToken(address _token, address _to) internal {
        uint256 balance = _sweepableBalance(_token);
        if (balance == 0) return;
        if (_token == WETH) {
            IWETH9(WETH).withdraw(balance);
            _safeTransferETH(_to, balance);
        } else {
            IERC20(_token).safeTransfer(_to, balance);
        }
    }

    function _sweepableBalance(address _token) internal view returns (uint256 balance) {
        balance = IERC20(_token).balanceOf(address(this));
    }

    function _safeTransferETH(address _to, uint256 _value) internal {
        (bool success,) = _to.call{value: _value}("");
        require(success, ApexErrors.SAFE_TRANSFER_FAILED());
    }

    function _position(uint256 _tokenId) internal view returns (PositionData memory position) {
        (
            ,,
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,,,,
        ) = positionManager.positions(_tokenId);
    }

    receive() external payable {
        require(msg.sender == address(positionManager) || msg.sender == WETH, ApexErrors.NOT_AUTHORIZED(msg.sender));
    }
}
