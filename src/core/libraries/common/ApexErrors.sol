// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ApexErrors {
    error NOT_AUTHORIZED(address caller);
    error ZERO_ADDRESS();
    error INVALID_ASSORTMENT();
    error INVALID_DURATION();
    error INVALID_POOL(address pool);
    error INVALID_TARGET(address target);
    error FARM_INACTIVE(address pool);
    error FARM_ACTIVE(address pool);
    error LENGTH_MISMATCH();
    error PAIR_EXISTS();
    error POOL_EXISTS(address pool);
    error NOT_PAIR(address pair);
    error NOT_TOKEN_OWNER(uint256 tokenId);
    error POSITION_EXISTS(uint256 tokenId);
    error FEE_TOO_HIGH();
    error ZERO_FEE();
    error ZERO_AMOUNT();
    error INVALID_PROTOCOL_FEE();
    error NO_REWARDS();
    error OVERFLOW();
    error SAFE_TRANSFER_FAILED();
    error UNSTABLE_RATIO();
    error K();
    error INSUFFICIENT_LIQUIDITY_MINTED();
    error INSUFFICIENT_LIQUIDITY_BURNED();
    error INSUFFICIENT_OUTPUT_AMOUNT();
    error INSUFFICIENT_INPUT_AMOUNT();
    error INSUFFICIENT_LIQUIDITY();
    error INVALID_TRANSFER();
    error SKIM_DISABLED();
    error INSUFFICIENT_REWARD_BALANCE(address chef, uint256 required, uint256 balance);
    error ALLOC_POINT_MISMATCH(address chef, uint256 expected, uint256 actual);
    error INCONSISTENT_AMOUNT();
    error INSUFFICIENT_AMOUNT();
    error NOT_EMPTY();
}
