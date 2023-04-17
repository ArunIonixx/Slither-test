// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {ICreatorCore} from "../../manifold/creator-core/core/ICreatorCore.sol";
import {IERC165} from "../../openzeppelin/utils/introspection/IERC165.sol";
import {IRoyaltyEngine} from "../interfaces/IRoyaltyEngine.sol";

abstract contract RoyaltyEngine is IRoyaltyEngine {

    bytes4 private constant ROYALTIES_CREATORCORE_INTERFACE_ID = 0xbb3bafd6;
    bytes4 private constant _INTERFACE_ID_ROYALTIES_EIP2981 = 0x2a55205a;
    bytes4 private constant _INTERFACE_ID_ROYALTIES_RARIBLE = 0xb7799584;
    bytes4 private constant _INTERFACE_ID_ROYALTIES_FOUNDATION = 0xd5a06d4c;

    /// @notice Get the Royalty Fee details for the tokenID
    /// @param tokenContract The NFT Contract address
    /// @param tokenId The NFT tokenId
    function getRoyalty(
        address tokenContract,
        uint256 tokenId
    )
        external
        view
        override
        returns (
            address payable[] memory recipients,
            uint256[] memory bps // Royalty amount denominated in basis points
        )
    {
        if (
            IERC165(tokenContract).supportsInterface(
                ROYALTIES_CREATORCORE_INTERFACE_ID
            )
        ) {
            (recipients, bps) = ICreatorCore(tokenContract).getRoyalties(
                tokenId
            );
        } else if (
            IERC165(tokenContract).supportsInterface(
                _INTERFACE_ID_ROYALTIES_RARIBLE
            )
        ) {
            recipients = ICreatorCore(tokenContract).getFeeRecipients(tokenId);
            bps = ICreatorCore(tokenContract).getFeeBps(tokenId);
        } else if (
            IERC165(tokenContract).supportsInterface(
                _INTERFACE_ID_ROYALTIES_FOUNDATION
            )
        ) {
            (recipients, bps) = ICreatorCore(tokenContract).getFees(tokenId);
        } 
    }
}