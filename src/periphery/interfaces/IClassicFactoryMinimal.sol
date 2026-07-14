// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

interface IClassicFactoryMinimal {
    function getPair(address _tokenA, address _tokenB, bool _stable) external view returns (address _pair);
}
