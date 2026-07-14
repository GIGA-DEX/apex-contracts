// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./LmPool.sol";
import "./interfaces/ICLFactory.sol";
import "./interfaces/ICLPool.sol";
import "./interfaces/ILmPoolDeployer.sol";

contract LmPoolDeployer is ILmPoolDeployer {
    struct Parameters {
        address pool;
        address masterChef;
    }

    Parameters public override parameters;
    address public immutable masterChef;

    event NewLMPool(address indexed pool, address indexed lmPool);

    modifier onlyMasterChef() {
        require(msg.sender == masterChef, "Not MC");
        _;
    }

    constructor(address masterChef_) {
        masterChef = masterChef_;
    }

    function deploy(address pool) external override onlyMasterChef returns (address lmPool) {
        parameters = Parameters({pool: pool, masterChef: masterChef});
        lmPool = address(new LmPool{salt: keccak256(abi.encode(pool, masterChef, block.timestamp))}());
        delete parameters;

        address factory = ICLPool(pool).factory();
        ICLFactory(factory).setLmPool(pool, lmPool);
        emit NewLMPool(pool, lmPool);
    }
}
