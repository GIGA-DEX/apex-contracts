// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev BrownFi V3's read-only integration surface. Fee configuration stays with BrownFi.
interface IBrownFiFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function feeTo() external view returns (address);
    function pairConfig() external view returns (address);
}

interface IBrownFiPair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IBrownFiPairConfig {
    struct Config {
        uint256 kB;
        uint256 kQ;
        uint64 lambda;
        uint32 fee;
        uint32 feeSplit;
        uint32 compress;
        uint32 sSell;
        uint32 sBuy;
        uint32 fixS;
        uint32 disThreshold;
        uint32 sBound;
        uint32 pythWeight;
        uint32 gamma;
    }

    function getConfig(address pair) external view returns (Config memory);
}
