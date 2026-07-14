// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./interfaces/ICLPoolDeployer.sol";

import "./CLPool.sol";

contract CLPoolDeployer is ICLPoolDeployer {
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc ICLPoolDeployer
    Parameters public override parameters;

    address public immutable factoryAddressSetter;
    address public factoryAddress;

    /// @notice Emitted when factory address is set
    event SetFactoryAddress(address indexed factory);

    modifier onlyFactory() {
        require(msg.sender == factoryAddress, "only factory can call deploy");
        _;
    }

    constructor() {
        factoryAddressSetter = msg.sender;
    }

    function setFactoryAddress(address _factoryAddress) external {
        require(msg.sender == factoryAddressSetter, "not factory address setter");
        require(factoryAddress == address(0), "already initialized");
        require(_factoryAddress != address(0), "zero factory address");

        factoryAddress = _factoryAddress;

        emit SetFactoryAddress(_factoryAddress);
    }

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// @param factory The contract address of the Apex CL factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The spacing between usable ticks
    function deploy(address factory, address token0, address token1, uint24 fee, int24 tickSpacing)
        external
        override
        onlyFactory
        returns (address pool)
    {
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        pool = address(new CLPool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters;
    }
}
