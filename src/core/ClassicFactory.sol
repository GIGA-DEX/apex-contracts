// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IApexController} from "./interfaces/IApexController.sol";
import {IClassicFactory} from "./interfaces/IClassicFactory.sol";
import {IClassicPool} from "./interfaces/IClassicPool.sol";
import {ClassicPool} from "./ClassicPool.sol";
import {ApexErrors} from "./libraries/common/ApexErrors.sol";

contract ClassicFactory is IClassicFactory {
    bytes32 public immutable pairCodeHash;
    IApexController public immutable apexController;

    uint256 public constant MAX_FEE = 500_000;
    uint256 public constant FEE_DENOM = 1_000_000;
    uint256 public constant DEFAULT_PROTOCOL_FEE = FEE_DENOM / 10;

    address public feeReceiver;
    uint256 public fee;
    uint256 public protocolFee;

    mapping(address token0 => mapping(address token1 => mapping(bool stable => address pair))) public getPair;
    address[] public allPairs;
    mapping(address pair => bool isPair) public isPair;
    mapping(address pair => bool skimEnabled) public skimEnabled;

    mapping(address pair => uint256 fee) private _pairFee;

    constructor(IApexController apexController_) {
        require(address(apexController_) != address(0), ApexErrors.ZERO_ADDRESS());

        apexController = apexController_;
        pairCodeHash = keccak256(type(ClassicPool).creationCode);

        fee = 3000;
        protocolFee = DEFAULT_PROTOCOL_FEE;

        emit SetFee(fee);
        emit SetProtocolFee(protocolFee);
    }

    modifier onlyApexController() {
        require(msg.sender == address(apexController), ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function setFee(uint256 fee_) external onlyApexController {
        require(fee_ != 0, ApexErrors.ZERO_FEE());
        require(fee_ <= MAX_FEE, ApexErrors.FEE_TOO_HIGH());
        fee = fee_;

        emit SetFee(fee_);
    }

    function setPairFee(address pair, uint256 fee_) external onlyApexController {
        require(fee_ <= MAX_FEE, ApexErrors.FEE_TOO_HIGH());
        require(isPair[pair], ApexErrors.NOT_PAIR(pair));

        uint256 resolvedFee = fee_ == 0 ? fee : fee_;
        IClassicPool(pair).setFee(resolvedFee);
        _pairFee[pair] = resolvedFee;

        emit SetPairFee(pair, resolvedFee);
    }

    function pairFee(address pair) public view returns (uint256 feeForPair) {
        return _pairFee[pair];
    }

    function setFeeReceiver(address feeReceiver_) external onlyApexController {
        require(feeReceiver_ != address(0), ApexErrors.ZERO_ADDRESS());
        feeReceiver = feeReceiver_;

        emit SetFeeReceiver(msg.sender, feeReceiver_);
    }

    function setProtocolFee(uint256 protocolFee_) external onlyApexController {
        require(protocolFee_ <= FEE_DENOM, ApexErrors.INVALID_PROTOCOL_FEE());
        protocolFee = protocolFee_;

        emit SetProtocolFee(protocolFee_);
    }

    function setPairProtocolFee(address pair, uint256 protocolFee_) external onlyApexController {
        require(protocolFee_ <= FEE_DENOM, ApexErrors.INVALID_PROTOCOL_FEE());
        require(isPair[pair], ApexErrors.NOT_PAIR(pair));
        IClassicPool(pair).setProtocolFee(protocolFee_);

        emit SetPairProtocolFee(pair, protocolFee_);
    }

    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair) {
        require(feeReceiver != address(0), ApexErrors.ZERO_ADDRESS());
        require(tokenA != tokenB, ApexErrors.INVALID_ASSORTMENT());
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ApexErrors.ZERO_ADDRESS());
        require(getPair[token0][token1][stable] == address(0), ApexErrors.PAIR_EXISTS());

        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));
        pair = address(new ClassicPool{salt: salt}());

        IClassicPool(pair).initialize(token0, token1, stable);
        IClassicPool(pair).setFee(fee);
        _pairFee[pair] = fee;

        IClassicPool(pair).setFeeReceiver(feeReceiver);
        IClassicPool(pair).setProtocolFee(protocolFee);

        getPair[token0][token1][stable] = pair;
        getPair[token1][token0][stable] = pair;
        allPairs.push(pair);
        isPair[pair] = true;

        emit PairCreated(token0, token1, stable, pair, allPairs.length);
    }

    function setPairFeeReceiver(address pair, address pairFeeReceiver) external onlyApexController {
        require(isPair[pair], ApexErrors.NOT_PAIR(pair));
        require(pairFeeReceiver != address(0), ApexErrors.ZERO_ADDRESS());
        IClassicPool(pair).setFeeReceiver(pairFeeReceiver);

        emit SetPairFeeReceiver(pair, pairFeeReceiver);
    }

    function setSkimEnabled(address pair, bool status) external onlyApexController {
        require(isPair[pair], ApexErrors.NOT_PAIR(pair));
        skimEnabled[pair] = skimEnabled[pair] != status ? status : skimEnabled[pair];

        emit SkimStatus(pair, status);
    }
}
