// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBrownFiFactory} from "../core/interfaces/IBrownFi.sol";
import {IClassicChef} from "../core/interfaces/IClassicChef.sol";
import {IBrownfiV3Router} from "./interfaces/IBrownfiV3Router.sol";

/// @title Apex BrownFi liquidity router
/// @notice BrownFi V3 deposits and withdrawals, with optional atomic ClassicChef staking.
/// @dev Immutable periphery; token amounts assume standard, non-rebasing ERC20s without transfer fees.
contract BrownfiRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant WITHDRAW_CALLBACK_REMOVE_LIQUIDITY = 0;
    uint8 public constant WITHDRAW_CALLBACK_REMOVE_LIQUIDITY_ETH = 1;

    IBrownfiV3Router public immutable brownfiRouter;
    IBrownFiFactory public immutable brownfiFactory;
    IClassicChef public immutable classicChef;
    address public immutable WETH9;

    struct AddLiquidityParams {
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 minLiquidity;
        address to;
        uint256 deadline;
        bytes updateData;
    }

    struct AddLiquidityETHParams {
        address token;
        uint256 amountTokenDesired;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        uint256 minLiquidity;
        address to;
        uint256 deadline;
        bytes updateData;
    }

    struct RemoveLiquidityParams {
        address tokenA;
        address tokenB;
        uint256 liquidity;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityETHParams {
        address token;
        uint256 liquidity;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        address to;
        uint256 deadline;
    }

    error InvalidAddress();
    error PairMissing();
    error NotChef();
    error InvalidCallback();
    error ETHTransferFailed();
    error UnsupportedToken();

    event RemoveLiquidityFromStake(
        address indexed account,
        address indexed pair,
        uint256 indexed pid,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB
    );

    constructor(address brownfiRouter_, address classicChef_) {
        if (brownfiRouter_ == address(0) || classicChef_ == address(0)) revert InvalidAddress();
        brownfiRouter = IBrownfiV3Router(brownfiRouter_);
        brownfiFactory = IBrownFiFactory(brownfiRouter.factory());
        WETH9 = brownfiRouter.WETH();
        if (address(brownfiFactory) == address(0) || WETH9 == address(0)) revert InvalidAddress();
        classicChef = IClassicChef(classicChef_);
    }

    receive() external payable {
        if (msg.sender != address(brownfiRouter)) revert InvalidAddress();
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        return _addLiquidity(params, false);
    }

    function addLiquidityAndStake(AddLiquidityParams calldata params)
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        return _addLiquidity(params, true);
    }

    function addLiquidityETH(AddLiquidityETHParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        return _addLiquidityETH(params, false);
    }

    function addLiquidityETHAndStake(AddLiquidityETHParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        return _addLiquidityETH(params, true);
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = _pairFor(params.tokenA, params.tokenB);
        _pullExact(pair, params.liquidity);
        return _removeLiquidity(pair, params);
    }

    function removeLiquidityETH(RemoveLiquidityETHParams calldata params)
        external
        nonReentrant
        returns (uint256 amountToken, uint256 amountETH)
    {
        address pair = _pairFor(params.token, WETH9);
        _pullExact(pair, params.liquidity);
        return _removeLiquidityETH(pair, params);
    }

    /// @notice Called by ClassicChef after debiting the user's stake and sending LP here.
    /// @dev Users call Chef.withdrawToAndCall(pid, liquidity, this, data).
    /// data = abi.encode(uint8 action, RemoveLiquidityParams or RemoveLiquidityETHParams).
    function onClassicChefWithdraw(address account, uint256 pid, uint256 amount, bytes calldata data)
        external
        nonReentrant
    {
        if (msg.sender != address(classicChef)) revert NotChef();
        if (amount == 0) revert InvalidCallback();
        uint8 action = abi.decode(data, (uint8));
        address pair;
        uint256 amountA;
        uint256 amountB;
        if (action == WITHDRAW_CALLBACK_REMOVE_LIQUIDITY) {
            (, RemoveLiquidityParams memory params) = abi.decode(data, (uint8, RemoveLiquidityParams));
            pair = _pairFor(params.tokenA, params.tokenB);
            if (params.liquidity != amount || classicChef.pidOf(pair) != pid) revert InvalidCallback();
            (amountA, amountB) = _removeLiquidity(pair, params);
        } else if (action == WITHDRAW_CALLBACK_REMOVE_LIQUIDITY_ETH) {
            (, RemoveLiquidityETHParams memory params) = abi.decode(data, (uint8, RemoveLiquidityETHParams));
            pair = _pairFor(params.token, WETH9);
            if (params.liquidity != amount || classicChef.pidOf(pair) != pid) revert InvalidCallback();
            (amountA, amountB) = _removeLiquidityETH(pair, params);
        } else {
            revert InvalidCallback();
        }
        emit RemoveLiquidityFromStake(account, pair, pid, amount, amountA, amountB);
    }

    function _addLiquidity(AddLiquidityParams calldata p, bool stake)
        internal
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        address pair = _pairFor(p.tokenA, p.tokenB);
        _checkRecipient(p.to, pair, p.tokenA, p.tokenB);
        uint256 pid = stake ? classicChef.pidOf(pair) : 0;
        _pull(p.tokenA, p.amountADesired);
        _pull(p.tokenB, p.amountBDesired);
        (amountA, amountB, liquidity) = _mint(p, stake ? address(this) : p.to);
        _refund(p.tokenA, p.amountADesired - amountA);
        _refund(p.tokenB, p.amountBDesired - amountB);
        if (stake) _stake(pair, pid, liquidity, p.to);
    }

    function _mint(AddLiquidityParams calldata p, address to) internal returns (uint256, uint256, uint256) {
        return brownfiRouter.addLiquidity(
            p.tokenA,
            p.tokenB,
            p.amountADesired,
            p.amountBDesired,
            p.amountAMin,
            p.amountBMin,
            p.minLiquidity,
            to,
            p.deadline,
            p.updateData
        );
    }

    function _addLiquidityETH(AddLiquidityETHParams calldata p, bool stake)
        internal
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        address pair = _pairFor(p.token, WETH9);
        _checkRecipient(p.to, pair, p.token, WETH9);
        uint256 pid = stake ? classicChef.pidOf(pair) : 0;
        _pull(p.token, p.amountTokenDesired);
        (amountToken, amountETH, liquidity) = _mintETH(p, stake ? address(this) : p.to);
        _refund(p.token, p.amountTokenDesired - amountToken);
        if (stake) _stake(pair, pid, liquidity, p.to);
        if (msg.value > amountETH) {
            (bool success,) = msg.sender.call{value: msg.value - amountETH}("");
            if (!success) revert ETHTransferFailed();
        }
    }

    function _mintETH(AddLiquidityETHParams calldata p, address to) internal returns (uint256, uint256, uint256) {
        return brownfiRouter.addLiquidityETH{value: msg.value}(
            p.token,
            p.amountTokenDesired,
            p.amountTokenMin,
            p.amountETHMin,
            p.minLiquidity,
            to,
            p.deadline,
            p.updateData
        );
    }

    function _removeLiquidity(address pair, RemoveLiquidityParams memory p)
        internal
        returns (uint256 amountA, uint256 amountB)
    {
        _checkRecipient(p.to, pair, p.tokenA, p.tokenB);
        IERC20(pair).forceApprove(address(brownfiRouter), p.liquidity);
        (amountA, amountB) = brownfiRouter.removeLiquidity(
            p.tokenA, p.tokenB, p.liquidity, p.amountAMin, p.amountBMin, p.to, p.deadline
        );
        IERC20(pair).forceApprove(address(brownfiRouter), 0);
    }

    function _removeLiquidityETH(address pair, RemoveLiquidityETHParams memory p)
        internal
        returns (uint256 amountToken, uint256 amountETH)
    {
        _checkRecipient(p.to, pair, p.token, WETH9);
        IERC20(pair).forceApprove(address(brownfiRouter), p.liquidity);
        (amountToken, amountETH) =
            brownfiRouter.removeLiquidityETH(p.token, p.liquidity, p.amountTokenMin, p.amountETHMin, p.to, p.deadline);
        IERC20(pair).forceApprove(address(brownfiRouter), 0);
    }

    function _pairFor(address tokenA, address tokenB) internal view returns (address pair) {
        pair = brownfiFactory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairMissing();
    }

    function _stake(address pair, uint256 pid, uint256 liquidity, address to) internal {
        IERC20(pair).forceApprove(address(classicChef), liquidity);
        classicChef.depositFor(pid, liquidity, to);
        IERC20(pair).forceApprove(address(classicChef), 0);
    }

    function _pull(address token, uint256 amount) internal {
        _pullExact(token, amount);
        IERC20(token).forceApprove(address(brownfiRouter), amount);
    }

    function _pullExact(address token, uint256 amount) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) != balance + amount) revert UnsupportedToken();
    }

    function _refund(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(brownfiRouter), 0);
        if (amount != 0) IERC20(token).safeTransfer(msg.sender, amount);
    }

    function _checkRecipient(address to, address pair, address tokenA, address tokenB) internal view {
        if (
            to == address(0) || to == address(this) || to == address(classicChef) || to == address(brownfiRouter)
                || to == address(brownfiFactory) || to == pair || to == tokenA || to == tokenB
        ) revert InvalidAddress();
    }
}
