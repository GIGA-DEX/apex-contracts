// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.9.0;

interface ILmPoolDeployer {
    function parameters() external view returns (address pool, address masterChef);

    function deploy(address pool) external returns (address lmPool);
}
