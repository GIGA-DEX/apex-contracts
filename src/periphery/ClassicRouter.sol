// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IClassicFactory} from "../core/interfaces/IClassicFactory.sol";
import {IClassicChef} from "../core/interfaces/IClassicChef.sol";
import {IClassicPool} from "../core/interfaces/IClassicPool.sol";
import {ApexErrors} from "../core/libraries/common/ApexErrors.sol";

interface IClassicRouterWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title Apex Classic liquidity router
/// @notice User-facing periphery for Classic stable and volatile LP minting/burning.
contract ClassicRouter {
    using SafeERC20 for IERC20;

    uint8 public constant WITHDRAW_CALLBACK_REMOVE_LIQUIDITY = 0;
    uint8 public constant WITHDRAW_CALLBACK_REMOVE_LIQUIDITY_ETH = 1;

    address public immutable classicFactory;
    address public immutable classicChef;
    address public immutable WETH9;

    struct AddLiquidityParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
        uint256 deadline;
    }

    struct AddLiquidityETHParams {
        address token;
        bool stable;
        uint256 amountTokenDesired;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 liquidity;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityETHParams {
        address token;
        bool stable;
        uint256 liquidity;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        address to;
        uint256 deadline;
    }

    event RemoveLiquidityFromStake(
        address indexed account,
        address indexed pair,
        uint256 indexed pid,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB
    );
    event RemoveLiquidityETHFromStake(
        address indexed account,
        address indexed pair,
        uint256 indexed pid,
        uint256 liquidity,
        uint256 amountToken,
        uint256 amountETH
    );

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "ClassicRouter: expired");
        _;
    }

    constructor(address classicFactory_, address WETH9_, address classicChef_) {
        require(
            classicFactory_ != address(0) && WETH9_ != address(0) && classicChef_ != address(0),
            ApexErrors.ZERO_ADDRESS()
        );
        classicFactory = classicFactory_;
        classicChef = classicChef_;
        WETH9 = WETH9_;
    }

    receive() external payable {
        require(msg.sender == WETH9, "ClassicRouter: not WETH9");
    }

    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair) {
        pair = _pairFor(tokenA, tokenB, stable);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        require(amountA != 0, "ClassicRouter: insufficient amount");
        require(reserveA != 0 && reserveB != 0, "ClassicRouter: insufficient liquidity");
        amountB = amountA * reserveB / reserveA;
    }

    function getReserves(address tokenA, address tokenB, bool stable)
        public
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        address pair = IClassicFactory(classicFactory).getPair(tokenA, tokenB, stable);
        require(pair != address(0), "ClassicRouter: pair missing");
        (address token0,) = _sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IClassicPool(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        address pair = _pairFor(params.tokenA, params.tokenB, params.stable);
        (amountA, amountB) = _addLiquidity(
            pair,
            params.tokenA,
            params.tokenB,
            params.amountADesired,
            params.amountBDesired,
            params.amountAMin,
            params.amountBMin
        );
        IERC20(params.tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(params.tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IClassicPool(pair).mint(params.to);
    }

    function addLiquidityETH(AddLiquidityETHParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        address pair = _pairFor(params.token, WETH9, params.stable);
        (amountToken, amountETH) = _addLiquidity(
            pair, params.token, WETH9, params.amountTokenDesired, msg.value, params.amountTokenMin, params.amountETHMin
        );
        IERC20(params.token).safeTransferFrom(msg.sender, pair, amountToken);
        IClassicRouterWETH9(WETH9).deposit{value: amountETH}();
        IERC20(WETH9).safeTransfer(pair, amountETH);
        liquidity = IClassicPool(pair).mint(params.to);

        if (msg.value > amountETH) _safeTransferETH(msg.sender, msg.value - amountETH);
    }

    function addLiquidityAndStake(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        address pair = _pairFor(params.tokenA, params.tokenB, params.stable);
        (amountA, amountB) = _addLiquidity(
            pair,
            params.tokenA,
            params.tokenB,
            params.amountADesired,
            params.amountBDesired,
            params.amountAMin,
            params.amountBMin
        );
        IERC20(params.tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(params.tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IClassicPool(pair).mint(address(this));
        _stakeLiquidity(pair, liquidity, params.to);
    }

    function addLiquidityETHAndStake(AddLiquidityETHParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        address pair = _pairFor(params.token, WETH9, params.stable);
        (amountToken, amountETH) = _addLiquidity(
            pair, params.token, WETH9, params.amountTokenDesired, msg.value, params.amountTokenMin, params.amountETHMin
        );
        IERC20(params.token).safeTransferFrom(msg.sender, pair, amountToken);
        IClassicRouterWETH9(WETH9).deposit{value: amountETH}();
        IERC20(WETH9).safeTransfer(pair, amountETH);
        liquidity = IClassicPool(pair).mint(address(this));
        _stakeLiquidity(pair, liquidity, params.to);

        if (msg.value > amountETH) _safeTransferETH(msg.sender, msg.value - amountETH);
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = IClassicFactory(classicFactory).getPair(params.tokenA, params.tokenB, params.stable);
        require(pair != address(0), "ClassicRouter: pair missing");

        IERC20(pair).safeTransferFrom(msg.sender, pair, params.liquidity);
        (uint256 amount0, uint256 amount1) = IClassicPool(pair).burn(params.to);
        (address token0,) = _sortTokens(params.tokenA, params.tokenB);
        (amountA, amountB) = params.tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= params.amountAMin, "ClassicRouter: insufficient A amount");
        require(amountB >= params.amountBMin, "ClassicRouter: insufficient B amount");
    }

    function removeLiquidityETH(RemoveLiquidityETHParams calldata params)
        external
        ensure(params.deadline)
        returns (uint256 amountToken, uint256 amountETH)
    {
        address pair = IClassicFactory(classicFactory).getPair(params.token, WETH9, params.stable);
        require(pair != address(0), "ClassicRouter: pair missing");

        IERC20(pair).safeTransferFrom(msg.sender, pair, params.liquidity);
        (uint256 amount0, uint256 amount1) = IClassicPool(pair).burn(address(this));
        (address token0,) = _sortTokens(params.token, WETH9);
        (amountToken, amountETH) = params.token == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountToken >= params.amountTokenMin, "ClassicRouter: insufficient token amount");
        require(amountETH >= params.amountETHMin, "ClassicRouter: insufficient ETH amount");

        IERC20(params.token).safeTransfer(params.to, amountToken);
        IClassicRouterWETH9(WETH9).withdraw(amountETH);
        _safeTransferETH(params.to, amountETH);
    }

    function onClassicChefWithdraw(address account, uint256 pid, uint256 amount, bytes calldata data) external {
        require(msg.sender == classicChef, "ClassicRouter: not chef");
        require(amount != 0, ApexErrors.ZERO_AMOUNT());

        uint8 action = _callbackAction(data);
        if (action == WITHDRAW_CALLBACK_REMOVE_LIQUIDITY) {
            (, RemoveLiquidityParams memory params) = abi.decode(data, (uint8, RemoveLiquidityParams));
            (address pair, uint256 amountA, uint256 amountB) = _removeLiquidityFromStake(pid, amount, params);
            emit RemoveLiquidityFromStake(account, pair, pid, amount, amountA, amountB);
        } else if (action == WITHDRAW_CALLBACK_REMOVE_LIQUIDITY_ETH) {
            (, RemoveLiquidityETHParams memory params) = abi.decode(data, (uint8, RemoveLiquidityETHParams));
            (address pair, uint256 amountToken, uint256 amountETH) = _removeLiquidityETHFromStake(pid, amount, params);
            emit RemoveLiquidityETHFromStake(account, pair, pid, amount, amountToken, amountETH);
        } else {
            revert("ClassicRouter: invalid callback action");
        }
    }

    function _addLiquidity(
        address pair,
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _reservesForPair(pair, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "ClassicRouter: insufficient B amount");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal <= amountADesired, "ClassicRouter: excessive A amount");
                require(amountAOptimal >= amountAMin, "ClassicRouter: insufficient A amount");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _removeLiquidityFromStake(uint256 pid, uint256 amount, RemoveLiquidityParams memory params)
        internal
        returns (address pair, uint256 amountA, uint256 amountB)
    {
        require(params.deadline >= block.timestamp, "ClassicRouter: expired");
        require(params.liquidity == amount, "ClassicRouter: liquidity mismatch");

        pair = IClassicFactory(classicFactory).getPair(params.tokenA, params.tokenB, params.stable);
        require(pair != address(0), "ClassicRouter: pair missing");
        require(IClassicChef(classicChef).pidOf(pair) == pid, "ClassicRouter: pid mismatch");

        IERC20(pair).safeTransfer(pair, amount);
        (uint256 amount0, uint256 amount1) = IClassicPool(pair).burn(params.to);
        (address token0,) = _sortTokens(params.tokenA, params.tokenB);
        (amountA, amountB) = params.tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= params.amountAMin, "ClassicRouter: insufficient A amount");
        require(amountB >= params.amountBMin, "ClassicRouter: insufficient B amount");
    }

    function _removeLiquidityETHFromStake(uint256 pid, uint256 amount, RemoveLiquidityETHParams memory params)
        internal
        returns (address pair, uint256 amountToken, uint256 amountETH)
    {
        require(params.deadline >= block.timestamp, "ClassicRouter: expired");
        require(params.liquidity == amount, "ClassicRouter: liquidity mismatch");

        pair = IClassicFactory(classicFactory).getPair(params.token, WETH9, params.stable);
        require(pair != address(0), "ClassicRouter: pair missing");
        require(IClassicChef(classicChef).pidOf(pair) == pid, "ClassicRouter: pid mismatch");

        IERC20(pair).safeTransfer(pair, amount);
        (uint256 amount0, uint256 amount1) = IClassicPool(pair).burn(address(this));
        (address token0,) = _sortTokens(params.token, WETH9);
        (amountToken, amountETH) = params.token == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountToken >= params.amountTokenMin, "ClassicRouter: insufficient token amount");
        require(amountETH >= params.amountETHMin, "ClassicRouter: insufficient ETH amount");

        IERC20(params.token).safeTransfer(params.to, amountToken);
        IClassicRouterWETH9(WETH9).withdraw(amountETH);
        _safeTransferETH(params.to, amountETH);
    }

    function _callbackAction(bytes calldata data) internal pure returns (uint8 action) {
        require(data.length >= 32, "ClassicRouter: invalid callback data");
        assembly ("memory-safe") {
            action := calldataload(data.offset)
        }
    }

    function _pairFor(address tokenA, address tokenB, bool stable) internal returns (address pair) {
        pair = IClassicFactory(classicFactory).getPair(tokenA, tokenB, stable);
        if (pair == address(0)) pair = IClassicFactory(classicFactory).createPair(tokenA, tokenB, stable);
    }

    function _reservesForPair(address pair, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = _sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IClassicPool(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _stakeLiquidity(address pair, uint256 liquidity, address to) internal {
        uint256 pid = IClassicChef(classicChef).pidOf(pair);
        IERC20(pair).forceApprove(classicChef, liquidity);
        IClassicChef(classicChef).depositFor(pid, liquidity, to);
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, ApexErrors.INVALID_ASSORTMENT());
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ApexErrors.ZERO_ADDRESS());
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, "ClassicRouter: ETH transfer failed");
    }
}
