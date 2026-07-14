// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ApexErrors} from "./libraries/common/ApexErrors.sol";

contract ApexToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor(address _recipient, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        require(_recipient != address(0), ApexErrors.ZERO_ADDRESS());
        require(bytes(_name).length != 0, "ApexToken name is empty");
        require(bytes(_symbol).length != 0, "ApexToken symbol is empty");
        _mint(_recipient, INITIAL_SUPPLY);
    }
}
