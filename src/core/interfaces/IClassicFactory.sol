// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IClassicFactory {
    event PairCreated(
        address indexed token0, address indexed token1, bool indexed stable, address pair, uint256 length
    );
    event SetFee(uint256 indexed fee);
    event SetPairFee(address indexed pair, uint256 indexed fee);
    event SetProtocolFee(uint256 indexed protocolFee);
    event SetPairProtocolFee(address indexed pair, uint256 indexed protocolFee);
    event SetPairFeeReceiver(address indexed pair, address indexed feeReceiver);
    event SetFeeReceiver(address indexed caller, address indexed feeReceiver);
    event SkimStatus(address indexed pair, bool indexed status);

    function allPairsLength() external view returns (uint256 length);

    function isPair(address pair) external view returns (bool);

    function pairCodeHash() external view returns (bytes32);

    function getPair(address tokenA, address tokenB, bool stable) external view returns (address pair);

    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);

    function allPairs(uint256 index) external view returns (address pair);

    function pairFee(address pair) external view returns (uint256 fee);

    function protocolFee() external view returns (uint256 fee);

    function setPairFee(address pair, uint256 fee) external;

    function setFee(uint256 fee) external;

    function feeReceiver() external view returns (address);

    function setPairFeeReceiver(address pair, address feeReceiver) external;

    function setPairProtocolFee(address pair, uint256 protocolFee) external;

    function skimEnabled(address pair) external view returns (bool);

    function setSkimEnabled(address pair, bool status) external;

    function setFeeReceiver(address feeReceiver) external;

    function setProtocolFee(uint256 protocolFee) external;
}
