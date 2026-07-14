// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IClassicFactory} from "./interfaces/IClassicFactory.sol";
import {IClassicPool} from "./interfaces/IClassicPool.sol";
import {IClassicPoolCallee} from "./interfaces/IClassicPoolCallee.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";

contract ClassicPool is IClassicPool, ERC20, ReentrancyGuard {
    struct Observation {
        uint256 timestamp;
        uint256 reserve0Cumulative;
        uint256 reserve1Cumulative;
    }

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 internal constant MINIMUM_K = 10 ** 9;
    uint256 internal constant FEE_DENOM = 1_000_000;
    uint256 internal constant PERIOD_SIZE = 1800;

    Observation[] public observations;

    address public immutable factory;
    address public token0;
    address public token1;
    address public feeReceiver;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public reserve0CumulativeLast;
    uint256 public reserve1CumulativeLast;
    uint256 public kLast;
    uint256 public protocolFee;
    uint256 public fee;

    uint256 internal decimals0;
    uint256 internal decimals1;
    bool public stable;

    string internal _apexName;
    string internal _apexSymbol;

    modifier onlyFactory() {
        require(msg.sender == factory, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    constructor() ERC20("", "") {
        factory = msg.sender;
    }

    function initialize(address token0_, address token1_, bool stable_) external onlyFactory {
        token0 = token0_;
        token1 = token1_;
        stable = stable_;

        string memory symbol0 = IERC20Metadata(token0_).symbol();
        string memory symbol1 = IERC20Metadata(token1_).symbol();

        if (stable_) {
            _apexName = string.concat("Apex Stable AMM - ", symbol0, "/", symbol1);
            _apexSymbol = string.concat("Apex-sAMM-", symbol0, "/", symbol1);
        } else {
            _apexName = string.concat("Apex Volatile AMM - ", symbol0, "/", symbol1);
            _apexSymbol = string.concat("Apex-vAMM-", symbol0, "/", symbol1);
        }

        observations.push(Observation(block.timestamp, 0, 0));

        decimals0 = 10 ** IERC20Metadata(token0_).decimals();
        decimals1 = 10 ** IERC20Metadata(token1_).decimals();
    }

    function getReserves() public view returns (uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_) {
        reserve0_ = reserve0;
        reserve1_ = reserve1;
        blockTimestampLast_ = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) {
            revert ApexErrors.SAFE_TRANSFER_FAILED();
        }
    }

    function _update(uint256 balance0, uint256 balance1, uint112 reserve0_, uint112 reserve1_) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, ApexErrors.OVERFLOW());

        uint256 blockTimestamp = block.timestamp;
        uint256 timeElapsed;

        unchecked {
            timeElapsed = blockTimestamp - uint256(blockTimestampLast);
            if (timeElapsed > 0 && reserve0_ != 0 && reserve1_ != 0) {
                reserve0CumulativeLast += reserve0_ * timeElapsed;
                reserve1CumulativeLast += reserve1_ * timeElapsed;
            }
        }

        Observation memory point = lastObservation();
        timeElapsed = blockTimestamp - point.timestamp;
        if (timeElapsed > PERIOD_SIZE) {
            observations.push(Observation(blockTimestamp, reserve0CumulativeLast, reserve1CumulativeLast));
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(blockTimestamp);
        emit Sync(reserve0, reserve1);
    }

    function _mintFee(uint112 reserve0_, uint112 reserve1_) private returns (bool feeOn) {
        address cachedFeeReceiver = feeReceiver;
        uint256 cachedKLast = kLast;
        feeOn = cachedFeeReceiver != address(0);

        if (feeOn) {
            uint256 cachedProtocolFee = protocolFee;
            if (cachedKLast != 0) {
                if (stable) {
                    uint256 k = _k(reserve0_, reserve1_);
                    if (k > cachedKLast) {
                        uint256 fourthRootE18 = Math.sqrt(Math.mulDiv(Math.sqrt(cachedKLast), 1e36, Math.sqrt(k)));
                        uint256 numerator = cachedProtocolFee * (1e18 - fourthRootE18) * 1e18;
                        uint256 denominator = (FEE_DENOM * 1e18) - (cachedProtocolFee * (1e18 - fourthRootE18));
                        uint256 feeAsLiquidity = (totalSupply() * numerator) / denominator / 1e18;

                        if (feeAsLiquidity > 0) {
                            _mint(cachedFeeReceiver, feeAsLiquidity);
                        }
                    }
                } else {
                    uint256 rootK = Math.sqrt(_k(reserve0_, reserve1_));
                    uint256 rootKLast = Math.sqrt(cachedKLast);
                    if (rootK > rootKLast) {
                        uint256 diffK = rootK - rootKLast;
                        uint256 dueToProtocol = (diffK * cachedProtocolFee) / FEE_DENOM;
                        uint256 dueToLp = rootKLast + diffK - dueToProtocol;
                        uint256 feeAsLiquidity = (totalSupply() * dueToProtocol) / dueToLp;

                        if (feeAsLiquidity > 0) {
                            _mint(cachedFeeReceiver, feeAsLiquidity);
                        }
                    }
                }
            }
        } else if (cachedKLast != 0) {
            kLast = _k(reserve0, reserve1);
        }
    }

    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        uint256 balance0 = IERC20Metadata(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Metadata(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        bool feeOn = _mintFee(reserve0_, reserve1_);
        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
            if (stable) {
                require(_k(amount0, amount1) >= MINIMUM_K, ApexErrors.K());
                require(((amount0 * 1e18) / decimals0 == (amount1 * 1e18) / decimals1), ApexErrors.UNSTABLE_RATIO());
            }
        } else {
            liquidity = Math.min((amount0 * totalSupply_) / reserve0_, (amount1 * totalSupply_) / reserve1_);
        }
        require(liquidity != 0, ApexErrors.INSUFFICIENT_LIQUIDITY_MINTED());
        _mint(to, liquidity);

        _update(balance0, balance1, reserve0_, reserve1_);
        if (feeOn) kLast = _k(reserve0, reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        address token0_ = token0;
        address token1_ = token1;
        uint256 balance0 = IERC20Metadata(token0_).balanceOf(address(this));
        uint256 balance1 = IERC20Metadata(token1_).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(reserve0_, reserve1_);
        uint256 totalSupply_ = totalSupply();
        amount0 = (liquidity * balance0) / totalSupply_;
        amount1 = (liquidity * balance1) / totalSupply_;
        require(amount0 != 0 && amount1 != 0, ApexErrors.INSUFFICIENT_LIQUIDITY_BURNED());

        _burn(address(this), liquidity);
        _safeTransfer(token0_, to, amount0);
        _safeTransfer(token1_, to, amount1);

        balance0 = IERC20Metadata(token0_).balanceOf(address(this));
        balance1 = IERC20Metadata(token1_).balanceOf(address(this));
        _update(balance0, balance1, reserve0_, reserve1_);
        if (feeOn) kLast = _k(reserve0, reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        require(amount0Out != 0 || amount1Out != 0, ApexErrors.INSUFFICIENT_OUTPUT_AMOUNT());

        (uint112 reserve0_, uint112 reserve1_,) = getReserves();
        require(amount0Out < reserve0_ && amount1Out < reserve1_, ApexErrors.INSUFFICIENT_LIQUIDITY());

        uint256 amount0In;
        uint256 amount1In;
        uint256 balance0;
        uint256 balance1;

        {
            address token0_ = token0;
            address token1_ = token1;

            require(to != token0_ && to != token1_, ApexErrors.INVALID_TRANSFER());
            if (amount0Out > 0) _safeTransfer(token0_, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(token1_, to, amount1Out);
            if (data.length > 0) {
                IClassicPoolCallee(to).hook(msg.sender, amount0Out, amount1Out, data);
            }

            balance0 = IERC20Metadata(token0_).balanceOf(address(this));
            balance1 = IERC20Metadata(token1_).balanceOf(address(this));

            unchecked {
                amount0In = balance0 > reserve0_ - amount0Out ? balance0 - (reserve0_ - amount0Out) : 0;
                amount1In = balance1 > reserve1_ - amount1Out ? balance1 - (reserve1_ - amount1Out) : 0;
            }
            require(amount0In != 0 || amount1In != 0, ApexErrors.INSUFFICIENT_INPUT_AMOUNT());

            uint256 balance0Adjusted = balance0 - ((amount0In * fee) / FEE_DENOM);
            uint256 balance1Adjusted = balance1 - ((amount1In * fee) / FEE_DENOM);
            require(_k(balance0Adjusted, balance1Adjusted) >= _k(reserve0_, reserve1_), ApexErrors.K());
        }

        _update(balance0, balance1, reserve0_, reserve1_);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function skim(address to) external nonReentrant {
        require(IClassicFactory(factory).skimEnabled(address(this)), ApexErrors.SKIM_DISABLED());
        address token0_ = token0;
        address token1_ = token1;
        _safeTransfer(token0_, to, IERC20Metadata(token0_).balanceOf(address(this)) - reserve0);
        _safeTransfer(token1_, to, IERC20Metadata(token1_).balanceOf(address(this)) - reserve1);
    }

    function sync() external nonReentrant {
        _update(
            IERC20Metadata(token0).balanceOf(address(this)),
            IERC20Metadata(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }

    function setFeeReceiver(address feeReceiver_) external onlyFactory {
        feeReceiver = feeReceiver_;
    }

    function setProtocolFee(uint256 protocolFee_) external onlyFactory {
        protocolFee = protocolFee_;
    }

    function setFee(uint256 fee_) external onlyFactory {
        fee = fee_;
    }

    function mintFee() external nonReentrant {
        uint112 reserve0_ = reserve0;
        uint112 reserve1_ = reserve1;
        bool feeOn = _mintFee(reserve0_, reserve1_);
        if (feeOn) kLast = _k(reserve0_, reserve1_);
    }

    function _k(uint256 x, uint256 y) internal view returns (uint256) {
        if (stable) {
            uint256 scaledX = (x * 1e18) / decimals0;
            uint256 scaledY = (y * 1e18) / decimals1;
            uint256 a = (scaledX * scaledY) / 1e18;
            uint256 b = ((scaledX * scaledX) / 1e18) + ((scaledY * scaledY) / 1e18);
            return (a * b) / 1e18;
        }
        return x * y;
    }

    function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (x0 * ((((y * y) / 1e18) * y) / 1e18)) / 1e18 + (((((x0 * x0) / 1e18) * x0) / 1e18) * y) / 1e18;
    }

    function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (3 * x0 * ((y * y) / 1e18)) / 1e18 + ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    function _getY(uint256 x0, uint256 xy, uint256 y) internal pure returns (uint256) {
        for (uint256 i = 0; i < 255; ++i) {
            uint256 yPrev = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > yPrev) {
                if (y - yPrev <= 1) return y;
            } else {
                if (yPrev - y <= 1) return y;
            }
        }
        return y;
    }

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut) {
        (uint256 reserve0_, uint256 reserve1_) = (reserve0, reserve1);
        amountIn -= (amountIn * fee) / FEE_DENOM;

        return _getAmountOut(amountIn, tokenIn, reserve0_, reserve1_) - 1;
    }

    function _getAmountOut(uint256 amountIn, address tokenIn, uint256 reserve0_, uint256 reserve1_)
        internal
        view
        returns (uint256)
    {
        if (stable) {
            uint256 xy = _k(reserve0_, reserve1_);
            reserve0_ = (reserve0_ * 1e18) / decimals0;
            reserve1_ = (reserve1_ * 1e18) / decimals1;
            (uint256 stableReserveA, uint256 stableReserveB) =
                tokenIn == token0 ? (reserve0_, reserve1_) : (reserve1_, reserve0_);
            amountIn = tokenIn == token0 ? (amountIn * 1e18) / decimals0 : (amountIn * 1e18) / decimals1;
            uint256 y = stableReserveB - _getY(amountIn + stableReserveA, xy, stableReserveB);
            return (y * (tokenIn == token0 ? decimals1 : decimals0)) / 1e18;
        }

        (uint256 reserveA, uint256 reserveB) = tokenIn == token0 ? (reserve0_, reserve1_) : (reserve1_, reserve0_);
        return (amountIn * reserveB) / (reserveA + amountIn);
    }

    function metadata()
        external
        view
        returns (
            uint256 decimals0_,
            uint256 decimals1_,
            uint256 reserve0_,
            uint256 reserve1_,
            bool stable_,
            address token0_,
            address token1_
        )
    {
        return (decimals0, decimals1, reserve0, reserve1, stable, token0, token1);
    }

    function name() public view override returns (string memory) {
        return _apexName;
    }

    function symbol() public view override returns (string memory) {
        return _apexSymbol;
    }

    function observationLength() external view returns (uint256) {
        return observations.length;
    }

    function lastObservation() public view returns (Observation memory) {
        return observations[observations.length - 1];
    }

    function currentCumulativePrices()
        public
        view
        returns (uint256 reserve0Cumulative, uint256 reserve1Cumulative, uint256 blockTimestamp)
    {
        blockTimestamp = block.timestamp;
        reserve0Cumulative = reserve0CumulativeLast;
        reserve1Cumulative = reserve1CumulativeLast;

        (uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_) = getReserves();
        if (blockTimestampLast_ != uint32(blockTimestamp)) {
            uint256 timeElapsed = blockTimestamp - uint256(blockTimestampLast_);
            reserve0Cumulative += reserve0_ * timeElapsed;
            reserve1Cumulative += reserve1_ * timeElapsed;
        }
    }

    function current(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        Observation memory observation = lastObservation();
        (uint256 reserve0Cumulative, uint256 reserve1Cumulative,) = currentCumulativePrices();
        if (block.timestamp == observation.timestamp) {
            observation = observations[observations.length - 2];
        }

        uint256 timeElapsed = block.timestamp - observation.timestamp;
        uint256 reserve0Average = (reserve0Cumulative - observation.reserve0Cumulative) / timeElapsed;
        uint256 reserve1Average = (reserve1Cumulative - observation.reserve1Cumulative) / timeElapsed;
        amountOut = _getAmountOut(amountIn, tokenIn, reserve0Average, reserve1Average);
    }

    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256 amountOut) {
        uint256[] memory prices_ = sample(tokenIn, amountIn, granularity, 1);
        uint256 priceAverageCumulative;
        for (uint256 i = 0; i < prices_.length; ++i) {
            priceAverageCumulative += prices_[i];
        }
        return priceAverageCumulative / granularity;
    }

    function prices(address tokenIn, uint256 amountIn, uint256 points) external view returns (uint256[] memory) {
        return sample(tokenIn, amountIn, points, 1);
    }

    function sample(address tokenIn, uint256 amountIn, uint256 points, uint256 window)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory prices_ = new uint256[](points);
        uint256 length = observations.length - 1;
        uint256 i = length - (points * window);
        uint256 nextIndex;
        uint256 index;

        for (; i < length; i += window) {
            nextIndex = i + window;
            uint256 timeElapsed = observations[nextIndex].timestamp - observations[i].timestamp;
            uint256 reserve0Average =
                (observations[nextIndex].reserve0Cumulative - observations[i].reserve0Cumulative) / timeElapsed;
            uint256 reserve1Average =
                (observations[nextIndex].reserve1Cumulative - observations[i].reserve1Cumulative) / timeElapsed;
            prices_[index] = _getAmountOut(amountIn, tokenIn, reserve0Average, reserve1Average);
            unchecked {
                index = index + 1;
            }
        }
        return prices_;
    }
}
