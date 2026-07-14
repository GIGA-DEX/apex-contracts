// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

abstract contract CLEnumerable {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;

    function tokenOfOwnerByIndex(address owner, uint256 index) public view returns (uint256) {
        require(index < _balances[owner], "Enumerable: owner index out of bounds");
        return _ownedTokens[owner][index];
    }

    function balanceOf(address owner) public view returns (uint256) {
        require(owner != address(0), "Enumerable: address zero is not a valid owner");
        return _balances[owner];
    }

    function addToken(address from, uint256 tokenId) internal {
        _ownedTokens[from][_balances[from]] = tokenId;
        _ownedTokensIndex[tokenId] = _balances[from];
        unchecked {
            _balances[from] += 1;
        }
    }

    function removeToken(address from, uint256 tokenId) internal {
        uint256 lastTokenIndex = _balances[from] - 1;
        uint256 tokenIndex = _ownedTokensIndex[tokenId];
        require(tokenId == _ownedTokens[from][tokenIndex], "Invalid tokenId");

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastTokenIndex];
            _ownedTokens[from][tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }

        delete _ownedTokensIndex[tokenId];
        delete _ownedTokens[from][lastTokenIndex];
        unchecked {
            _balances[from] -= 1;
        }
    }
}
