// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts-3/utils/Strings.sol";

import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/INonfungibleTokenPositionDescriptor.sol";

/// @notice Minimal ERC721 metadata for Giga CL position NFTs.
/// @dev This intentionally avoids SVG/art generation; position actions are surfaced by NFP events.
contract SimplePositionDescriptor is INonfungibleTokenPositionDescriptor {
    using Strings for uint256;

    function tokenURI(INonfungiblePositionManager positionManager, uint256 tokenId)
        external
        pure
        override
        returns (string memory)
    {
        positionManager;

        return string(
            abi.encodePacked(
                "data:application/json;utf8,",
                '{"name":"Giga Position #',
                tokenId.toString(),
                '","description":"Giga concentrated liquidity position NFT. Position activity is available from ',
                'NonfungiblePositionManager events."}'
            )
        );
    }
}
