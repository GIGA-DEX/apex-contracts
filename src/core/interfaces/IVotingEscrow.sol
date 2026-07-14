// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    function token() external view returns (address);

    function MAXTIME() external view returns (uint256);

    function ownerOf(uint256 _tokenId) external view returns (address);

    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external;

    function balanceOfNFT(uint256 _tokenId) external view returns (uint256);

    function locked(uint256 _tokenId) external view returns (LockedBalance memory);

    function depositFor(uint256 _tokenId, uint256 _value) external;

    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external;

    function setArtProxy(address _artProxy) external;
}
