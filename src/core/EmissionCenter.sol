// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {ApexErrors} from "./libraries/common/ApexErrors.sol";

contract EmissionCenter is VestingWallet {
    address public immutable apexController;

    constructor(address controller, uint64 startTimestamp, uint64 durationSeconds)
        VestingWallet(controller, startTimestamp, durationSeconds)
    {
        apexController = controller;
    }

    modifier onlyApexController() {
        require(msg.sender == apexController, ApexErrors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    function release() public override onlyApexController {
        super.release();
    }

    function release(address token) public override onlyApexController {
        super.release(token);
    }

    /// @notice Releases the currently vested ERC-20 amount and reports the exact amount sent.
    /// @dev The controller uses the return value for its fixed emission split without balance-delta assumptions.
    function releaseVested(address token) external onlyApexController returns (uint256 releasedAmount) {
        releasedAmount = releasable(token);
        super.release(token);
    }
}
