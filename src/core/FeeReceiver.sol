// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IApexVault} from "./interfaces/IApexVault.sol";
import {IFeeCenter} from "./interfaces/IFeeCenter.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";
import {FeeReceiverStorage} from "./storage/FeeReceiverStorage.sol";

contract FeeReceiver is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    event SwapExecuted(address indexed tokenIn, address indexed target, uint256 spent, uint256 received);
    event VaultNotified(address indexed outputToken, uint256 amount);
    event VaultCompoundNotified(address indexed outputToken, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    modifier onlyFeeCenter() {
        require(msg.sender == FeeReceiverStorage.layout().feeCenter, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    function initialize(address _feeCenter, address _vault, address _outputToken) external initializer {
        require(
            _feeCenter != address(0) && _vault != address(0) && _outputToken != address(0), ApexErrors.ZERO_ADDRESS()
        );
        __ReentrancyGuard_init();

        FeeReceiverStorage.Layout storage s = FeeReceiverStorage.layout();
        s.feeCenter = _feeCenter;
        s.vault = _vault;
        s.outputToken = _outputToken;
    }

    function executeSwap(
        address _tokenIn,
        address _target,
        uint256 _amount,
        uint256 _minAmountOut,
        bytes calldata _data
    ) external onlyFeeCenter nonReentrant returns (uint256 spent, uint256 received) {
        address outputToken_ = FeeReceiverStorage.layout().outputToken;
        require(_tokenIn != address(0) && _tokenIn != outputToken_ && _target != address(0), ApexErrors.ZERO_ADDRESS());
        require(_amount != 0 && _minAmountOut != 0, ApexErrors.ZERO_AMOUNT());

        uint256 inputBefore = IERC20(_tokenIn).balanceOf(address(this));
        uint256 outputBefore = IERC20(outputToken_).balanceOf(address(this));

        IERC20(_tokenIn).forceApprove(_target, _amount);
        _target.functionCall(_data);
        IERC20(_tokenIn).forceApprove(_target, 0);

        spent = inputBefore - IERC20(_tokenIn).balanceOf(address(this));
        received = IERC20(outputToken_).balanceOf(address(this)) - outputBefore;
        require(spent != 0 && received >= _minAmountOut, ApexErrors.INSUFFICIENT_OUTPUT_AMOUNT());

        emit SwapExecuted(_tokenIn, _target, spent, received);
    }

    function notifyVault(uint256 _amount) public onlyFeeCenter nonReentrant {
        require(_amount != 0, ApexErrors.ZERO_AMOUNT());

        FeeReceiverStorage.Layout storage s = FeeReceiverStorage.layout();
        IERC20(s.outputToken).forceApprove(s.vault, _amount);
        IFeeCenter(s.feeCenter).notifyVaultReward(s.outputToken, _amount);
        IERC20(s.outputToken).forceApprove(s.vault, 0);

        emit VaultNotified(s.outputToken, _amount);
    }

    function notifyVaultBalance() external onlyFeeCenter returns (uint256 amount) {
        amount = IERC20(FeeReceiverStorage.layout().outputToken).balanceOf(address(this));
        notifyVault(amount);
    }

    function notifyVaultCompound(uint256 _amount) public onlyFeeCenter nonReentrant {
        require(_amount != 0, ApexErrors.ZERO_AMOUNT());

        FeeReceiverStorage.Layout storage s = FeeReceiverStorage.layout();
        require(s.outputToken == IApexVault(s.vault).veNFT().token(), ApexErrors.INVALID_ASSORTMENT());
        IERC20(s.outputToken).forceApprove(s.vault, _amount);
        IFeeCenter(s.feeCenter).notifyVaultCompoundReward(_amount);
        IERC20(s.outputToken).forceApprove(s.vault, 0);

        emit VaultCompoundNotified(s.outputToken, _amount);
    }

    function notifyVaultCompoundBalance() external onlyFeeCenter returns (uint256 amount) {
        amount = IERC20(FeeReceiverStorage.layout().outputToken).balanceOf(address(this));
        notifyVaultCompound(amount);
    }

    function rescueToken(address _token, address _to, uint256 _amount) external onlyFeeCenter nonReentrant {
        require(_token != address(0) && _to != address(0), ApexErrors.ZERO_ADDRESS());
        require(_amount != 0, ApexErrors.ZERO_AMOUNT());

        IERC20(_token).safeTransfer(_to, _amount);

        emit TokenRescued(_token, _to, _amount);
    }

    function feeCenter() external view returns (address) {
        return FeeReceiverStorage.layout().feeCenter;
    }

    function vault() external view returns (address) {
        return FeeReceiverStorage.layout().vault;
    }

    function outputToken() external view returns (address) {
        return FeeReceiverStorage.layout().outputToken;
    }
}
