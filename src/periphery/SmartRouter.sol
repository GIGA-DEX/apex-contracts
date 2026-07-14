// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "../core/interfaces/ICLPool.sol";
import "../core/libraries/cl/SafeCast.sol";
import "../core/libraries/cl/TickMath.sol";

import "./base/Multicall.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryPaymentsWithFee.sol";
import "./base/PeripheryValidation.sol";
import "./base/SelfPermit.sol";
import "./interfaces/IClassicFactoryMinimal.sol";
import "./interfaces/IClassicPoolMinimal.sol";
import "./interfaces/ISmartRouter.sol";
import "./libraries/MixedRoute.sol";
import "./libraries/CallbackValidation.sol";
import "./libraries/Path.sol";
import "./libraries/PoolAddress.sol";

/// @title Apex smart router
/// @notice Executes exact-input paths that can include Apex Classic stable/volatile pairs and Apex CL pools.
contract SmartRouter is
    ISmartRouter,
    PeripheryImmutableState,
    PeripheryValidation,
    PeripheryPaymentsWithFee,
    Multicall,
    SelfPermit
{
    using Path for bytes;
    using SafeCast for uint256;

    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    address public immutable classicFactory;
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    constructor(address _deployer, address _factory, address _classicFactory, address _WETH9)
        PeripheryImmutableState(_deployer, _factory, _WETH9)
    {
        classicFactory = _classicFactory;
    }

    function getPool(address _tokenA, address _tokenB, uint24 _fee) private view returns (ICLPool) {
        return ICLPool(PoolAddress.computeAddress(deployer, PoolAddress.getPoolKey(_tokenA, _tokenB, _fee)));
    }

    function getClassicPair(address _tokenIn, address _tokenOut, bool _stable) private view returns (address pair) {
        pair = IClassicFactoryMinimal(classicFactory).getPair(_tokenIn, _tokenOut, _stable);
        require(pair != address(0), "Classic pair missing");
    }

    /// @inheritdoc IPancakeV3SwapCallback
    function pancakeV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data) external override {
        require(_amount0Delta > 0 || _amount1Delta > 0);

        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        require(!MixedRoute.hasClassicFlag(fee), "Invalid CL callback");
        CallbackValidation.verifyCallback(deployer, tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay) = _amount0Delta > 0
            ? (tokenIn < tokenOut, uint256(_amount0Delta))
            : (tokenOut < tokenIn, uint256(_amount1Delta));

        if (isExactInput) {
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else if (data.path.hasMultiplePools()) {
            data.path = data.path.skipToken();
            exactOutputInternal(amountToPay, msg.sender, 0, data);
        } else {
            amountInCached = amountToPay;
            tokenIn = tokenOut;
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        }
    }

    function exactInputSingle(ExactInputSingleParams memory _params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        amountOut = exactInputCL(
            _params.amountIn,
            _params.recipient,
            _params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(_params.tokenIn, _params.fee, _params.tokenOut), payer: msg.sender
            })
        );
        require(amountOut >= _params.amountOutMinimum, "Too little received");
    }

    function exactInput(ExactInputParams memory _params) external payable override returns (uint256 amountOut) {
        address payer = msg.sender;

        while (true) {
            bool hasMultiplePools = _params.path.hasMultiplePools();
            (address tokenIn, address tokenOut, uint24 action) = _params.path.decodeFirstPool();

            _params.amountIn = MixedRoute.hasClassicFlag(action)
                ? exactInputClassic(
                    _params.amountIn,
                    hasMultiplePools ? address(this) : _params.recipient,
                    tokenIn,
                    tokenOut,
                    MixedRoute.stableFromAction(action),
                    payer
                )
                : exactInputCL(
                    _params.amountIn,
                    hasMultiplePools ? address(this) : _params.recipient,
                    0,
                    SwapCallbackData({path: _params.path.getFirstPool(), payer: payer})
                );

            if (hasMultiplePools) {
                payer = address(this);
                _params.path = _params.path.skipToken();
            } else {
                amountOut = _params.amountIn;
                break;
            }
        }

        require(amountOut >= _params.amountOutMinimum, "Too little received");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata _params)
        external
        payable
        override
        returns (uint256 amountIn)
    {
        amountIn = exactOutputInternal(
            _params.amountOut,
            _params.recipient,
            _params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(_params.tokenOut, _params.fee, _params.tokenIn), payer: msg.sender
            })
        );

        require(amountIn <= _params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    function exactOutput(ExactOutputParams calldata _params) external payable override returns (uint256 amountIn) {
        requireCLPath(_params.path);
        exactOutputInternal(
            _params.amountOut, _params.recipient, 0, SwapCallbackData({path: _params.path, payer: msg.sender})
        );

        amountIn = amountInCached;
        require(amountIn <= _params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    function swapExactTokensForTokens(uint256 _amountIn, uint256 _amountOutMin, address[] calldata _path, address _to)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        amountOut = exactInputClassicPath(_amountIn, _path, _to, false, new uint256[](0));
        require(amountOut >= _amountOutMin, "Too little received");
    }

    function exactInputStableSwap(
        address[] calldata _path,
        uint256[] calldata _flags,
        uint256 _amountIn,
        uint256 _amountOutMin,
        address _to
    ) external payable override returns (uint256 amountOut) {
        amountOut = exactInputClassicPath(_amountIn, _path, _to, true, _flags);
        require(amountOut >= _amountOutMin, "Too little received");
    }

    function multicall(uint256 _deadline, bytes[] calldata _data)
        external
        payable
        checkDeadline(_deadline)
        returns (bytes[] memory results)
    {
        return multicall(_data);
    }

    function multicall(bytes32 _previousBlockhash, bytes[] calldata _data)
        external
        payable
        returns (bytes[] memory results)
    {
        require(blockhash(block.number - 1) == _previousBlockhash, "Blockhash");
        return multicall(_data);
    }

    function exactInputCL(
        uint256 _amountIn,
        address _recipient,
        uint160 _sqrtPriceLimitX96,
        SwapCallbackData memory _data
    ) private returns (uint256 amountOut) {
        if (_recipient == address(0)) _recipient = address(this);

        (address tokenIn, address tokenOut, uint24 fee) = _data.path.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee)
            .swap(
                _recipient,
                zeroForOne,
                _amountIn.toInt256(),
                _sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : _sqrtPriceLimitX96,
                abi.encode(_data)
            );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    function exactOutputInternal(
        uint256 _amountOut,
        address _recipient,
        uint160 _sqrtPriceLimitX96,
        SwapCallbackData memory _data
    ) private returns (uint256 amountIn) {
        if (_recipient == address(0)) _recipient = address(this);

        (address tokenOut, address tokenIn, uint24 fee) = _data.path.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0Delta, int256 amount1Delta) = getPool(tokenIn, tokenOut, fee)
            .swap(
                _recipient,
                zeroForOne,
                -_amountOut.toInt256(),
                _sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : _sqrtPriceLimitX96,
                abi.encode(_data)
            );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        if (_sqrtPriceLimitX96 == 0) require(amountOutReceived == _amountOut);
    }

    function exactInputClassic(
        uint256 _amountIn,
        address _recipient,
        address _tokenIn,
        address _tokenOut,
        bool _stable,
        address _payer
    ) private returns (uint256 amountOut) {
        if (_recipient == address(0)) _recipient = address(this);

        address pair = getClassicPair(_tokenIn, _tokenOut, _stable);
        amountOut = IClassicPoolMinimal(pair).getAmountOut(_amountIn, _tokenIn);
        pay(_tokenIn, _payer, pair, _amountIn);

        (uint256 amount0Out, uint256 amount1Out) =
            _tokenIn == IClassicPoolMinimal(pair).token0() ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IClassicPoolMinimal(pair).swap(amount0Out, amount1Out, _recipient, new bytes(0));
    }

    function exactInputClassicPath(
        uint256 _amountIn,
        address[] calldata _path,
        address _to,
        bool _useFlags,
        uint256[] memory _flags
    ) private returns (uint256 amountOut) {
        require(_path.length >= 2, "Invalid path");
        if (_useFlags) require(_flags.length == _path.length - 1, "Flag length mismatch");

        address payer = msg.sender;
        for (uint256 i; i < _path.length - 1; ++i) {
            bool stable = _useFlags ? MixedRoute.stableFromPancakeFlag(_flags[i]) : false;
            _amountIn = exactInputClassic(
                _amountIn, i < _path.length - 2 ? address(this) : _to, _path[i], _path[i + 1], stable, payer
            );
            payer = address(this);
        }
        amountOut = _amountIn;
    }

    function requireCLPath(bytes memory _path) private pure {
        while (true) {
            (,, uint24 action) = _path.decodeFirstPool();
            require(!MixedRoute.hasClassicFlag(action), "Exact output Classic not supported");
            if (_path.hasMultiplePools()) {
                _path = _path.skipToken();
            } else {
                return;
            }
        }
    }
}
