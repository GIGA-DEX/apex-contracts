// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.9.0;

import "./pool/ICLPoolImmutables.sol";
import "./pool/ICLPoolState.sol";
import "./pool/ICLPoolDerivedState.sol";
import "./pool/ICLPoolActions.sol";
import "./pool/ICLPoolOwnerActions.sol";
import "./pool/ICLPoolEvents.sol";

/// @title The interface for an Apex CL pool
/// @notice An Apex CL pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface ICLPool is
    ICLPoolImmutables,
    ICLPoolState,
    ICLPoolDerivedState,
    ICLPoolActions,
    ICLPoolOwnerActions,
    ICLPoolEvents
{
    /// @notice Set the lmPool used for range-based farming rewards
    function setLmPool(address lmPool) external;
}
