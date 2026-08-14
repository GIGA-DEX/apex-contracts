// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {FeeReceiver} from "./FeeReceiver.sol";
import {IApexController} from "./interfaces/IApexController.sol";
import {IClassicPool} from "./interfaces/IClassicPool.sol";
import {IFeeCenter} from "./interfaces/IFeeCenter.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";
import {FeeCenterStorage} from "./storage/FeeCenterStorage.sol";

contract FeeCenter is IFeeCenter, IBeacon, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    event ReceiverImplementationSet(address indexed implementation);
    event ReceiverCreated(address indexed outputToken, address indexed receiver);
    event ReceiverRemoved(address indexed outputToken, address indexed receiver);
    event SwapperSet(address indexed swapper, bool indexed status);
    event FeesSplit(address indexed token, uint256 amount);
    event ReceiverFeesSplit(address indexed token, address indexed receiver, uint256 amount);
    event ClassicFeesRealized(address indexed pair, uint256 liquidity, uint256 amount0, uint256 amount1);

    constructor() {
        _disableInitializers();
    }

    function initialize(address _apexController, address _vault, address _implementation) external initializer {
        require(
            _apexController != address(0) && _vault != address(0) && _implementation != address(0),
            ApexErrors.ZERO_ADDRESS()
        );
        require(_implementation.code.length != 0, ApexErrors.ZERO_ADDRESS());
        __ReentrancyGuard_init();

        FeeCenterStorage.Layout storage s = FeeCenterStorage.layout();
        s.apexController = _apexController;
        s.vault = _vault;
        s.implementation = _implementation;

        emit ReceiverImplementationSet(_implementation);
    }

    modifier onlyApexController() {
        require(msg.sender == FeeCenterStorage.layout().apexController, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    modifier onlyReceiver() {
        require(
            FeeCenterStorage.layout().receiverOutput[msg.sender] != address(0), ApexErrors.NOT_AUTHORIZED(msg.sender)
        );
        _;
    }

    function setReceiverImplementation(address _implementation) external onlyApexController {
        require(_implementation != address(0) && _implementation.code.length != 0, ApexErrors.ZERO_ADDRESS());
        FeeCenterStorage.layout().implementation = _implementation;

        emit ReceiverImplementationSet(_implementation);
    }

    function addReceiver(address _outputToken) external onlyApexController returns (address receiver) {
        FeeCenterStorage.Layout storage s = FeeCenterStorage.layout();
        require(_outputToken != address(0), ApexErrors.ZERO_ADDRESS());
        require(s.receiverForOutput[_outputToken] == address(0), ApexErrors.POOL_EXISTS(_outputToken));

        bytes memory initData =
            abi.encodeWithSelector(FeeReceiver.initialize.selector, address(this), s.vault, _outputToken);
        receiver = address(new BeaconProxy(address(this), initData));

        s.receiverForOutput[_outputToken] = receiver;
        s.receiverOutput[receiver] = _outputToken;
        s.activeReceivers.add(receiver);

        emit ReceiverCreated(_outputToken, receiver);
    }

    function removeReceiver(address _outputToken) external onlyApexController returns (address receiver) {
        FeeCenterStorage.Layout storage s = FeeCenterStorage.layout();
        receiver = s.receiverForOutput[_outputToken];
        require(receiver != address(0), ApexErrors.ZERO_ADDRESS());

        delete s.receiverForOutput[_outputToken];
        s.activeReceivers.remove(receiver);

        emit ReceiverRemoved(_outputToken, receiver);
    }

    function setSwapper(address _swapper, bool _status) external onlyApexController {
        require(_swapper != address(0), ApexErrors.ZERO_ADDRESS());
        if (_status) require(_swapper.code.length != 0, ApexErrors.INVALID_TARGET(_swapper));
        FeeCenterStorage.layout().isSwapper[_swapper] = _status;

        emit SwapperSet(_swapper, _status);
    }

    function pushAndSplitFees(address[] calldata _tokens) external onlyApexController {
        FeeCenterStorage.Layout storage s = FeeCenterStorage.layout();
        uint256 receiverCount = s.activeReceivers.length();
        require(receiverCount != 0, ApexErrors.ZERO_AMOUNT());

        for (uint256 i; i < _tokens.length; ++i) {
            address token = _tokens[i];
            require(token != address(0), ApexErrors.ZERO_ADDRESS());

            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) continue;

            uint256 remaining = amount;
            for (uint256 j; j < receiverCount; ++j) {
                address receiver = s.activeReceivers.at(j);
                uint256 share = j == receiverCount - 1 ? remaining : amount / receiverCount;
                if (share != 0) {
                    remaining -= share;
                    IERC20(token).safeTransfer(receiver, share);
                    emit ReceiverFeesSplit(token, receiver, share);
                }
            }

            emit FeesSplit(token, amount);
        }
    }

    function realizeClassicFees(address _pair)
        external
        onlyApexController
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(_pair != address(0), ApexErrors.ZERO_ADDRESS());
        uint256 liquidity = IERC20(_pair).balanceOf(address(this));
        if (liquidity == 0) return (0, 0);

        IERC20(_pair).safeTransfer(_pair, liquidity);
        (amount0, amount1) = IClassicPool(_pair).burn(address(this));

        emit ClassicFeesRealized(_pair, liquidity, amount0, amount1);
    }

    function executeReceiverSwap(
        address _receiver,
        address _tokenIn,
        address _target,
        uint256 _amount,
        uint256 _minAmountOut,
        bytes calldata _data
    ) external onlyApexController nonReentrant returns (uint256 spent, uint256 received) {
        FeeCenterStorage.Layout storage s = FeeCenterStorage.layout();
        require(s.receiverOutput[_receiver] != address(0), ApexErrors.NOT_AUTHORIZED(_receiver));
        require(s.isSwapper[_target], ApexErrors.NOT_AUTHORIZED(_target));
        return FeeReceiver(_receiver).executeSwap(_tokenIn, _target, _amount, _minAmountOut, _data);
    }

    function notifyReceiverVault(address _receiver, uint256 _amount) external onlyApexController {
        require(FeeCenterStorage.layout().receiverOutput[_receiver] != address(0), ApexErrors.NOT_AUTHORIZED(_receiver));
        FeeReceiver(_receiver).notifyVault(_amount);
    }

    function notifyReceiverVaultBalance(address _receiver) external onlyApexController returns (uint256 amount) {
        require(FeeCenterStorage.layout().receiverOutput[_receiver] != address(0), ApexErrors.NOT_AUTHORIZED(_receiver));
        return FeeReceiver(_receiver).notifyVaultBalance();
    }

    function notifyReceiverVaultCompound(address _receiver, uint256 _amount) external onlyApexController {
        require(FeeCenterStorage.layout().receiverOutput[_receiver] != address(0), ApexErrors.NOT_AUTHORIZED(_receiver));
        FeeReceiver(_receiver).notifyVaultCompound(_amount);
    }

    function notifyReceiverVaultCompoundBalance(address _receiver)
        external
        onlyApexController
        returns (uint256 amount)
    {
        require(FeeCenterStorage.layout().receiverOutput[_receiver] != address(0), ApexErrors.NOT_AUTHORIZED(_receiver));
        return FeeReceiver(_receiver).notifyVaultCompoundBalance();
    }

    function rescueReceiverToken(address _receiver, address _token, address _to, uint256 _amount)
        external
        onlyApexController
    {
        require(FeeCenterStorage.layout().receiverOutput[_receiver] != address(0), ApexErrors.NOT_AUTHORIZED(_receiver));
        FeeReceiver(_receiver).rescueToken(_token, _to, _amount);
    }

    function notifyVaultReward(address _token, uint256 _amount) external onlyReceiver {
        FeeCenterStorage.Layout storage s = FeeCenterStorage.layout();
        require(s.receiverOutput[msg.sender] == _token, ApexErrors.NOT_AUTHORIZED(msg.sender));
        IApexController(s.apexController).notifyVaultRewardFrom(msg.sender, _token, _amount);
    }

    function notifyVaultCompoundReward(uint256 _amount) external onlyReceiver {
        IApexController(FeeCenterStorage.layout().apexController).notifyVaultCompoundRewardFrom(msg.sender, _amount);
    }

    function activeReceiversLength() external view returns (uint256) {
        return FeeCenterStorage.layout().activeReceivers.length();
    }

    function activeReceiverAt(uint256 _index) external view returns (address) {
        return FeeCenterStorage.layout().activeReceivers.at(_index);
    }

    function activeReceivers() external view returns (address[] memory) {
        return FeeCenterStorage.layout().activeReceivers.values();
    }

    function isReceiverActive(address _receiver) external view returns (bool) {
        return FeeCenterStorage.layout().activeReceivers.contains(_receiver);
    }

    function apexController() external view returns (address) {
        return FeeCenterStorage.layout().apexController;
    }

    function vault() external view returns (address) {
        return FeeCenterStorage.layout().vault;
    }

    function receiverForOutput(address _outputToken) external view returns (address) {
        return FeeCenterStorage.layout().receiverForOutput[_outputToken];
    }

    function receiverOutput(address _receiver) external view returns (address) {
        return FeeCenterStorage.layout().receiverOutput[_receiver];
    }

    function isSwapper(address _swapper) external view returns (bool) {
        return FeeCenterStorage.layout().isSwapper[_swapper];
    }

    // Beacon compatibility: FeeReceiver BeaconProxy instances call this through the FeeCenter proxy.
    // Never remove this function or change its meaning during FeeCenter upgrades.
    function implementation() external view override returns (address) {
        return FeeCenterStorage.layout().implementation;
    }
}
