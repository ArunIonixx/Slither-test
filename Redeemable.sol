// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {SafeMath} from "../../openzeppelin/utils/math/SafeMath.sol";
import {IERC721, IERC165} from "../../openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "../../openzeppelin/token/ERC1155/IERC1155.sol";
import "../../openzeppelin/utils/introspection/ERC165Checker.sol";
import {IERC721CreatorCore} from "../../manifold/creator-core/core/IERC721CreatorCore.sol";
import {IERC1155CreatorCore} from "../../manifold/creator-core/core/IERC1155CreatorCore.sol";
import "../../manifold/libraries-solidity/access/AdminControlUpgradeable.sol";
import {IAdminControl} from "../../manifold/libraries-solidity/access/IAdminControl.sol";
import "../../openzeppelin-upgradeable/access/IAccessControlUpgradeable.sol";
import "../../manifold/royalty-registry/specs/INiftyGateway.sol";
import "../../manifold/royalty-registry/specs/IFoundation.sol";

interface ERC721 {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface ERC1155 {
    function uri(uint256 tokenId) external view returns (string memory);
}

contract Redeemable is AdminControlUpgradeable {
    using SafeMath for uint256;

    // Total No.of token quantity limt in this contract
    uint256 public immutable MAX_CAP;

    // Interface ID constants
    bytes4 constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 constant ERC1155_INTERFACE_ID = 0xd9b67a26;

    /// @notice The details to be provided to RedeemDetails
    /// @param newCollectionAddress New Collection token contract address
    /// @param tokenHoldingAddress Address to hold the old collection - nft token
    /// @param clientName Name of the client
    struct RedeemDetails {
        address newCollectionAddress;
        address tokenHoldingAddress;
        string clientName;
    }

    /// @notice The details to be provided to Redeemer
    /// @param CollectionAddress NFT Collection address
    /// @param tokenId New minted tokenId
    /// @param quantity the number of tokens
    /// @param owneraddress the owner of the tokenId
    /// @param status Status that token is redeemed or not

    struct Redeemer {
        address CollectionAddress;
        uint256 tokenId;
        uint256 quantity;
        address owneraddress;
        bool status;
    }

    //tokenIds of redeemed details
    struct NftIds {
        uint256 tokenIds;
        address CollectionAddress;
    }

    // tokenIds of redeemed details mapped against the wallet Address
    mapping(address => NftIds[]) public TokenList;

    // storing the RedeemDetails against the redeemCollection Address
    mapping(address => RedeemDetails) public RedeemDetailsList;

    // storing the RedeemerDetails against the Collection Address and tokenId
    mapping(address => mapping(uint256 => Redeemer)) public RedeemerDetailsList;

    // Event log to emit when the redeemCollections is given
    event RedeemedDetails(
        address redeemCollectionAddress,
        address newCollectionAddress,
        address tokenHoldingAddress,
        string clientName
    );

    // Event log to emit when the token is redeemed
    event RedeemerDetails(
        address CollectionAddress,
        uint256[] tokenId,
        uint256 quantity,
        address owneraddress,
        bool status
    );

    // Event log to emit when transfer is success or failed
    event Transferred(
        address collectionAddress,
        uint256 tokenId,
        address previousOwner,
        address HoldingAddress
    );

    /// @param maxCap Total No.of token quantity limt for minting in this contract
    constructor(uint256 maxCap) {
        require(maxCap > 5, "MaxCap should not be less than 5.");
        MAX_CAP = maxCap;
    }

    /// @notice Create a Redeem functionality for the collection Address
    /// @param redeemCollectionAddress Order struct consists of the listedtoken details
    /// @param list list struct consists of the
    function createRedeem(
        address redeemCollectionAddress,
        RedeemDetails memory list
    ) external {
        require(
            isAdmin(msg.sender) ||
                _isCollectionAdmin(redeemCollectionAddress, msg.sender) ||
                _isCollectionOwner(redeemCollectionAddress, msg.sender),
            "sender should be a Mojito Admin or a Collection Admin or a Collection Owner"
        );
        require(
            redeemCollectionAddress != list.newCollectionAddress,
            "Redeemable and Unredeemable Collection Addresses should not be the same"
        );

        RedeemDetailsList[redeemCollectionAddress] = list;

        emit RedeemedDetails(
            redeemCollectionAddress,
            list.newCollectionAddress,
            list.tokenHoldingAddress,
            list.clientName
        );
    }

    //Redeem an NFT From the List.

    function redeem(
        address redeemCollectionAddress,
        uint256 tokenId,
        address claimer,
        uint256 quantity,
        string memory tokenURI
    ) external  returns (uint256[] memory nftTokenId) {
        require(
            RedeemDetailsList[redeemCollectionAddress].newCollectionAddress !=
                address(0),
            "Mentioned address doesn't have any proper details. Please create and update the details if necessary"
        );
        require(
            isAdmin(msg.sender) ||
                _isCollectionAdmin(redeemCollectionAddress, msg.sender) ||
                _isCollectionOwner(redeemCollectionAddress, msg.sender) ||
                IERC721(redeemCollectionAddress).ownerOf(tokenId) == msg.sender,
            "sender should be a Mojito Admin or a Collection Admin or a Collection Owner or token Owner"
        );
        require(
            !RedeemerDetailsList[redeemCollectionAddress][tokenId].status,
            "Given tokenId is already redeemed"
        );

        NftIds memory nftList = NftIds(tokenId, redeemCollectionAddress);
        TokenList[
            RedeemDetailsList[redeemCollectionAddress].tokenHoldingAddress
        ].push(nftList);

        emit Transferred(
            redeemCollectionAddress,
            tokenId,
            claimer,
            RedeemDetailsList[redeemCollectionAddress].tokenHoldingAddress
        );

        bool transfer;
        // transfer token from customer wallet to our tokenHolding address
        transfer = _tokenTransaction(
            redeemCollectionAddress,
            tokenId,
            claimer,
            RedeemDetailsList[redeemCollectionAddress].tokenHoldingAddress,
            quantity
        );
        
        string[] memory baseuri = new string[](1);
        if (bytes(tokenURI).length == 0) {
            baseuri[0] = getbaseURL(redeemCollectionAddress, tokenId);
        } else {
            baseuri[0] = tokenURI;
        }

        // mint token to the customer
        nftTokenId = _tokenMint(
            RedeemDetailsList[redeemCollectionAddress].newCollectionAddress,
            claimer,
            quantity,
            baseuri
        );

        for (uint256 i = 0; i < nftTokenId.length; i++) {
            NftIds memory nftId = NftIds(
                nftTokenId[i],
                RedeemDetailsList[redeemCollectionAddress].newCollectionAddress
            );
            TokenList[claimer].push(nftId);
            RedeemerDetailsList
            [RedeemDetailsList[redeemCollectionAddress].newCollectionAddress]
            [nftTokenId[i]] = Redeemer(
                RedeemDetailsList[redeemCollectionAddress].newCollectionAddress,
                nftTokenId[i],
                quantity,
                claimer,
                true
                );
              }

        emit RedeemerDetails(
            RedeemDetailsList[redeemCollectionAddress].newCollectionAddress,
            nftTokenId,
            quantity,
            claimer,
            true
        );

        

        return nftTokenId;
    }

    //Update newCollectionAddress

    function updateNewCollectionAddress(
        address redeemCollectionAddress,
        address newCollectionAddress,
        address tokenHoldingAddress,
        string memory clientName
    ) external {
        require(
            RedeemDetailsList[redeemCollectionAddress].newCollectionAddress !=
                address(0),
            "Mentioned address doesn't have any proper details. Please create and update the details if necessary"
        );
        require(
            isAdmin(msg.sender) ||
                _isCollectionAdmin(redeemCollectionAddress, msg.sender) ||
                _isCollectionOwner(redeemCollectionAddress, msg.sender),
            "sender should be a Mojito Admin or a Collection Admin or a Collection Owner"
        );
        RedeemDetailsList[redeemCollectionAddress]
            .tokenHoldingAddress = tokenHoldingAddress;
        RedeemDetailsList[redeemCollectionAddress].clientName = clientName;
        RedeemDetailsList[redeemCollectionAddress]
            .newCollectionAddress = newCollectionAddress;
    }

    //Remove newCollectionAddress

    function removeCollectionAddress(address redeemCollectionAddress) external {
        require(
            isAdmin(msg.sender) ||
                _isCollectionAdmin(redeemCollectionAddress, msg.sender) ||
                _isCollectionOwner(redeemCollectionAddress, msg.sender),
            "sender should be a Mojito Admin or a Collection Admin or a Collection Owner"
        );
        require(
            RedeemDetailsList[redeemCollectionAddress].newCollectionAddress !=
                address(0),
            "invalid redeemCollectionAddress"
        );
        delete (RedeemDetailsList[redeemCollectionAddress]);
    }

    // Get Redeem Status for the token ID against the Collection Address

    function getRedeemStatus(address collectionAddress, uint256 tokenId)
        external
        view
        returns (bool status)
    {
        status = RedeemerDetailsList[collectionAddress][tokenId].status;
        return (status);
    }

    // Get Redeem Token ID for Wallet Address

    function getRedeem(address walletAddress)
        external
        view
        returns (NftIds[] memory list)
    {
        list = TokenList[walletAddress];

        return (list);
    }

    function getbaseURL(address collectionAddress, uint256 tokenId)
        internal
        view
        returns (string memory uri)
    {
        if (IERC165(collectionAddress).supportsInterface(ERC721_INTERFACE_ID)) {
            uri = ERC721(collectionAddress).tokenURI(tokenId);
        } else if (
            IERC165(collectionAddress).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            uri = ERC1155(collectionAddress).uri(tokenId);
        }
        return uri;
    }

    // transfer function

    function _tokenTransaction(
        address tokenContract,
        uint256 tokenId,
        address tokenOwner,
        address receiver,
        uint256 quantity
    ) internal returns (bool status) {
        if (IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID)) {
            require(
                IERC721(tokenContract).ownerOf(tokenId) == tokenOwner,
                "maker is not the owner"
            );

            IERC721(tokenContract).safeTransferFrom(
                tokenOwner,
                receiver,
                tokenId
            );
            status = true;
        } else if (
            IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            uint256 ownerBalance = IERC1155(tokenContract).balanceOf(
                tokenOwner,
                tokenId
            );
            require(
                quantity <= ownerBalance && quantity > 0,
                "Insufficeint token balance"
            );

            IERC1155(tokenContract).safeTransferFrom(
                tokenOwner,
                receiver,
                tokenId,
                quantity,
                "0x"
            );
            status = true;
        }

        return status;
    }

    // Minting function

    function _tokenMint(
        address tokenContract,
        address claimer,
        uint256 quantity,
        string[] memory uris
    ) internal returns (uint256[] memory nftTokenId) {
        //ERC721
        if (IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID)) {
              nftTokenId = IERC721CreatorCore(tokenContract).mintExtensionBatch(claimer, uris);
        }
        //ERC1155
        else if (
            IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            require(quantity > 0, "Need to mint at least 1 token.");
            require(quantity <= MAX_CAP, "Cannot exceed MAXCAP.");

            address[] memory to = new address[](1);
            uint256[] memory quantityNew = new uint256[](1);
            to[0] = claimer;
            quantityNew[0] = quantity;

            nftTokenId = IERC1155CreatorCore(tokenContract).mintExtensionNew(
                to,
                quantityNew,
                uris
            );
        }

        return nftTokenId;
    }

    /**
     * @notice Update extension's baseURI
     * @dev Can only be done by Admin
     */
    function setBaseURI(address redeemcollectionaddress, string memory baseURI)
        external
    {
        require(
            isAdmin(msg.sender) ||
                _isCollectionAdmin(redeemcollectionaddress, msg.sender) ||
                _isCollectionOwner(redeemcollectionaddress, msg.sender),
            "sender should be a Mojito Admin or a Collection Admin or a Collection Owner"
        );

        address tokenContract = RedeemDetailsList[redeemcollectionaddress]
            .newCollectionAddress;

        if (IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID)) {
            IERC721CreatorCore(tokenContract).setBaseTokenURIExtension(
                baseURI
            );
        } else if (
            IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            IERC1155CreatorCore(tokenContract).setBaseTokenURIExtension(
                baseURI,
                false
            );
        }
    }

    /**
     * @notice checks the admin role of caller
     * @param collectionAddress contract address
     * @param collectionAdmin admin address of the collection.
     **/
    function _isCollectionAdmin(
        address collectionAddress,
        address collectionAdmin
    ) internal view returns (bool state) {
        if (
            ERC165Checker.supportsInterface(
                collectionAddress,
                type(IAdminControl).interfaceId
            ) && IAdminControl(collectionAddress).isAdmin(collectionAdmin)
        ) {
            state = true;
            return state;
        }
    }

    /**
     * @notice checks the Owner role of caller
     * @param collectionAddress contract address
     * @param collectionAdmin admin address of the collection.
     **/
    function _isCollectionOwner(
        address collectionAddress,
        address collectionAdmin
    ) internal view returns (bool collectionOwner) {
        try OwnableUpgradeable(collectionAddress).owner() returns (
            address isOwner
        ) {
            if (isOwner == collectionAdmin) return true;
        } catch {}

        try
            IAccessControlUpgradeable(collectionAddress).hasRole(
                0x00,
                collectionAdmin
            )
        returns (bool hasRole) {
            if (hasRole) return true;
        } catch {}

        // Nifty Gateway overrides
        try
            INiftyBuilderInstance(collectionAddress).niftyRegistryContract()
        returns (address niftyRegistry) {
            try
                INiftyRegistry(niftyRegistry).isValidNiftySender(
                    collectionAdmin
                )
            returns (bool valid) {
                return valid;
            } catch {}
        } catch {}

        // Foundation overrides
        try
            IFoundationTreasuryNode(collectionAddress).getFoundationTreasury()
        returns (address payable foundationTreasury) {
            try
                IFoundationTreasury(foundationTreasury).isAdmin(collectionAdmin)
            returns (bool) {
                return collectionOwner;
            } catch {}
        } catch {}

        // Superrare & OpenSea & Rarible overrides
        // Tokens already support Ownable overrides

        return false;
    }
}
