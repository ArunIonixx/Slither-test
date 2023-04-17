// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {SafeMath} from "../../openzeppelin/utils/math/SafeMath.sol";
import {IERC721, IERC165} from "../../openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "../../openzeppelin/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "../../openzeppelin/security/ReentrancyGuard.sol";
import {IERC20} from "../../openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ICreatorCore} from "../../manifold/creator-core/core/ICreatorCore.sol";
import {AdminControl} from "../../manifold/libraries-solidity/access/AdminControl.sol";
import {IERC721CreatorCore} from "../../manifold/creator-core/core/IERC721CreatorCore.sol";
import {IERC1155CreatorCore} from "../../manifold/creator-core/core/IERC1155CreatorCore.sol";
import {Counters} from "../../openzeppelin/utils/Counters.sol";

contract buyListing is ReentrancyGuard, AdminControl {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    /// @notice The metadata for a given Order
    /// @param nftContractAddress the nft contract address
    /// @param nftStartTokenId the Nft token Id listed From
    /// @param nftEndTokenId the NFT token Id listed To
    /// @param minimumPrice the mimimum price of the listed tokens
    /// @param paymentCurrency the payment currency for seller requirement
    /// @param paymentSettlementAddress the settlement address for the listed tokens
    /// @param taxSettlementAddress the address the tax is settled
    /// @param maxCap the total supply for both minting
    /// @param status the status to be minted or transfered
    struct PriceList {
        address nftContractAddress;
        uint64 nftStartTokenId;
        uint64 nftEndTokenId;
        uint256[] minimumPrice;
        address[] paymentCurrency;
        address paymentSettlementAddress;
        address taxSettlementAddress;
        uint64 maxCap;
        Status status;
    }

    /// @notice The details to be provided to buy the token
    /// @param saleId the Id of the created sale
    /// @param tokenOwner the owner of the nft token
    /// @param tokenId the token Id of the owner owns
    /// @param tokenQuantity the token Quantity only required if minting
    /// @param quantity the quantity of tokens for 1155 only
    /// @param paymentToken the type of payment currency that the buyers pays
    /// @param paymentAmount the amount to be paid in the payment currency
    struct BuyList {
        string saleId;
        address tokenOwner;
        uint256 tokenId;
        uint256 tokenQuantity;
        uint256 quantity;
        address paymentToken;
        uint256 paymentAmount;
    }

    // Status shows the preference for mint or transfer
    enum Status {
        mint,
        transfer
    }
    struct Offer {
        // ID for the ERC721 or ERC1155 token
        uint256 tokenId;
        // Address for the ERC721 or ERC1155 contract
        address tokenContract;
        // The  price of the NFT
        uint256 offerPrice;
        // The address that should receive the funds once the NFT is sold.
        address tokenOwner;
        // The address of the buyer
        address maker;
        // The address of the ERC-20 currency to run the sale with.
        // If set to 0x0, the sale will be run in ETH
        address currency;
        //The value of Tax Amount
        uint256 taxAmount;
        //The address for tax settlement.
        address taxSettlementAddress;
    }

    
    // listing the sale details in sale Id
    mapping(string => PriceList) public listings;

    // tokens used to to be compared with maxCap
    mapping(string => uint256) public tokensUsed;

    // validating saleId
    mapping(string => bool) usedSaleId;

    // A mapping of all of the offers .
    mapping(uint256 => Offer) public offers;

    Counters.Counter private offerIdTracker;
    
    // Interface ID constants
    bytes4 constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 constant ERC1155_INTERFACE_ID = 0xd9b67a26;
    bytes4 constant ROYALTIES_CREATORCORE_INTERFACE_ID = 0xbb3bafd6;
    bytes4 private constant INTERFACE_ID_ROYALTIES_EIP2981 = 0x2a55205a;
    bytes4 private constant INTERFACE_ID_ROYALTIES_RARIBLE = 0xb7799584;
    bytes4 private constant INTERFACE_ID_ROYALTIES_FOUNDATION = 0xd5a06d4c;

    // Platform Address
    address payable public platformAddress;

    // Fee percentage to the Platform
    uint256 public platformFeePercentage;

    /// @notice Emitted when sale is created
    /// @param saleList contains the details of sale created
    event saleCreated(PriceList indexed saleList);

    /// @notice Emitted when an Buy Event is completed
    /// @param tokenContract The NFT Contract address
    /// @param buyer Address of the buyer
    /// @param platformAddress Address of the Platform
    /// @param platformFee Fee sent to the Platform Address
    /// @param buyingDetails consist of buyer details
    /// @param tokenId consist of token minted details
    event BuyExecuted(
        address indexed tokenContract,
        address buyer,
        address platformAddress,
        uint256 platformFee,
        BuyList buyingDetails,
        uint256[] tokenId
    );

    /// @notice Emitted when an offer is created
    /// @param offerId The Offer Id 
    /// @param offerInfo The offer related Details
    /// @param quantity The Quantity of NFT Token
    event OfferCreated(
        uint256 indexed offerId,
        Offer offerInfo,
        uint256 quantity
    );
    
    /// @notice Emitted when an offer is Updated
    /// @param offerId The Offer Id 
    /// @param tokenId consist of token minted details
    /// @param tokenContract The NFT Contract address
    /// @param offerPrice The updated Offer price
    event OfferAmountUpdated(
        uint256 indexed offerId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 offerPrice
    );
     
    /// @notice Emitted when an offer is filled by Token Owner.
    /// @param offerId The Offer Id 
    /// @param list The offer related Details 
    /// @param quantity The Quantity of NFT Token
    event OfferClosed(
        uint256 indexed offerId,
        Offer list,
        uint256 quantity
    );
    
    
    /// @notice Emitted when an offer is canceled.
    /// @param offerId The Offer Id 
    /// @param tokenId consist of token minted details
    /// @param tokenContract The NFT Contract address
    /// @param offerPrice The updated Offer price
    event OfferCanceled(
        uint256 indexed offerId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        address tokenOwner,
        uint256 offerPrice
    );

    /// @notice Emitted when an Royalty Payout is executed
    /// @param tokenId The NFT tokenId
    /// @param tokenContract The NFT Contract address
    /// @param recipient Address of the Royalty Recipient
    /// @param amount Amount sent to the royalty recipient address
    event RoyaltyPayout(
        address tokenContract,
        uint256 tokenId,
        address recipient,
        uint256 amount
    );

    /**
     * @notice Require that the specified offer exists
     */
     modifier offerExists(uint256 offerId) {
        require(_exists(offerId), "Offer doesn't exist");
        _;
    }

    /// @param platformAddressArg The Platform Address
    /// @param platformFeePercentageArg The Platform fee percentage
    constructor(address platformAddressArg, uint256 platformFeePercentageArg) {
        require(platformAddressArg != address(0), "Invalid Platform Address");
        require(
            platformFeePercentageArg < 10000,
            "platformFee should not be more than 100 %"
        );
        platformAddress = payable(platformAddressArg);
        platformFeePercentage = platformFeePercentageArg;
    }    
    /**
     * @notice creating a batch sales using batch details .
     * @param list gives the listing details to create a sale
     * @param saleId consist of the id of the listed sale
     */
    function createSale(PriceList calldata list, string calldata saleId)
        external
        adminRequired
        nonReentrant
    {
        // array for paymentCurrency and minimumPrice to be of same length
        require(
            list.paymentCurrency.length == list.minimumPrice.length,
            "should provide equal length in price and payment address"
        );
        // checks for paymentCurrency amount to buy the token should not be zero
        for (uint256 i=0; i < list.paymentCurrency.length; i++) {
            require(
                list.minimumPrice[i] > 0,
                "minimum price should be greater than zero"
            );
        }
        // checks for valuable token start and end id for isting
        if (list.nftStartTokenId > 0 && list.nftEndTokenId > 0) {
            require(
                list.nftEndTokenId > list.nftStartTokenId,
                "listed tokens noes not support"
            );
        }
        // checks to provide maxcap while listing only for minting
        if (list.status == Status.mint) {
            require(list.maxCap != 0, "should provede MAXCAP for minting");
        } else {
            require(list.maxCap == 0, "no MAXCAP required");
        }
        // checks to provide only supported interface for nftContractAddress
        require(
            IERC165(list.nftContractAddress).supportsInterface(
                ERC721_INTERFACE_ID
            ) ||
                IERC165(list.nftContractAddress).supportsInterface(
                    ERC1155_INTERFACE_ID
                ),
            "should provide only supported Nft Address"
        );
        // checks for paymentSettlementAddress should not be zero
        require(
            list.paymentSettlementAddress != address(0),
            "should provide Settlement address"
        );
        // checks for taxSettlelentAddress should not be zero
        require(
            list.taxSettlementAddress != address(0),
            "should provide tax Settlement address"
        );
        // checks for should not use the same saleId
        require(!usedSaleId[saleId], "saleId is already used");

        listings[saleId] = list;

        usedSaleId[saleId] = true;

        emit saleCreated(list);
    }

    /**
     * @notice End an sale, finalizing and paying out the respective parties.
     * @param list gives the listing details to buy the nfts
     */
    function buy(BuyList memory list)
        external
        payable
        nonReentrant
        returns (uint256[] memory nftTokenId)
    {
        // checks for saleId is created for sale
        require(usedSaleId[list.saleId], "unsupported sale");

        // handelling the errors before buying the NFT
        (
            uint256 minimumPrice,
            address paymentToken,
            address tokenContract
        ) = errorHandelling(
                list.saleId,
                list.tokenId,
                list.tokenQuantity,
                list.quantity,
                list.paymentToken,
                list.paymentAmount,
                msg.sender
            );

        // Transferring  the NFT tokens to the buyer
        nftTokenId = _tokenTransaction(
            list.saleId,
            list.tokenOwner,
            tokenContract,
            msg.sender,
            list.tokenId,
            list.tokenQuantity,
            list.quantity,
            listings[list.saleId].status
        );
        // transferring the excess amount given by by buyer as tax to taxSettlementAddress
        uint256 tax;
        if (list.paymentAmount > minimumPrice) {
            tax = (list.paymentAmount - minimumPrice);
            _handlePayment(
                msg.sender,
                payable(listings[list.saleId].taxSettlementAddress),
                paymentToken,
                tax
            );
        }

        uint256 remainingProfit = minimumPrice;

        // PlatformFee Settlement
        uint256 platformFee = 0;
        if (platformAddress != address(0) && platformFeePercentage > 0) {
            platformFee = ((remainingProfit * platformFeePercentage) / 10000);
            remainingProfit = remainingProfit - platformFee;

            _handlePayment(
                msg.sender,
                platformAddress,
                paymentToken,
                platformFee
            );
        }

        // Royalty Fee Payout Settlement
        remainingProfit = royaltyPayout(
            msg.sender,
            list.tokenId,
            nftTokenId,
            tokenContract,
            remainingProfit,
            paymentToken,
            listings[list.saleId].status
        );

        // Transfer the balance to the tokenOwner
        _handlePayment(
            msg.sender,
            payable(listings[list.saleId].paymentSettlementAddress),
            paymentToken,
            remainingProfit
        );
        emit BuyExecuted(
            tokenContract,
            msg.sender,
            platformAddress,
            platformFee,
            list,
            nftTokenId
        );
        return nftTokenId;
    }

    /**
     * @notice Create an Offer.
     * @dev Store the offer details in the offers mapping and emit an OfferCreated event.
     * @param offerInfo the Offer details 
     */
     function createOffer(
        Offer calldata offerInfo
    )external nonReentrant returns (uint256) {
        // checks to provide only supported interface for nftContractAddress
        require(
            (IERC165(offerInfo.tokenContract).supportsInterface(ERC721_INTERFACE_ID) ||
                IERC165(offerInfo.tokenContract).supportsInterface(ERC1155_INTERFACE_ID)),
            "tokenContract does not support ERC721 or ERC1155 interface"
        );
        // check for enough token allowance to create offer
        require(
                IERC20(offerInfo.currency).allowance(msg.sender, address(this)) >=
                    offerInfo.offerPrice,
                "insufficent token allowance"
        );
        // Validating the Tax Settlement Address 
        if(offerInfo.taxAmount!=0)
        require(offerInfo.taxSettlementAddress!=address(0),"Invalid TaxSettlementAddress");

        uint256 offerId = offerIdTracker.current();
        uint256 quantity = 1;

        if (IERC165(offerInfo.tokenContract).supportsInterface(ERC1155_INTERFACE_ID)) {
            quantity = IERC1155(offerInfo.tokenContract).balanceOf(offerInfo.tokenOwner,offerInfo.tokenId);
        }
        offers[offerId] = offerInfo;
        offers[offerId].maker=msg.sender;
        offerIdTracker.increment();

        emit OfferCreated(
            offerId,
            offerInfo,
            quantity
        );

        return offerId;
    }

     /**
     * @notice Change Fixed Price for the sale
     * @dev Only callable by the curator or owner. Cannot be called if the offer doesn't exist.
     * @param offerId The offer Id which user wants to update     
     * @param currency The contract addresss of payment Token
     * @param offerPrice The Offer price is set by Maker
     */
    function setOfferAmount(
        uint256 offerId,
        address currency,
        uint256 offerPrice
    ) external offerExists(offerId) {
        //Ensuring msg.sender is offer_maker
        require(
            offers[offerId].maker == msg.sender,
            "setOfferAmount must be maker"
        );
        // check for enough token allowance to update the offer
        require(
                IERC20(currency).allowance(msg.sender, address(this)) >=
                    offerPrice,
                "insufficent token allowance"
        );
        // If same currency --
        if (currency == offers[offerId].currency) {
            offers[offerId].offerPrice = offerPrice;
             
            // Else other currency --
        } else {
            // Update storage
            offers[offerId].currency = currency;
            offers[offerId].offerPrice = offerPrice;
        }
        emit OfferAmountUpdated(
            offerId,
            offers[offerId].tokenId,
            offers[offerId].tokenContract,
            offerPrice
        );
    }
    
    /**
     * @notice End an offer, finalizing and paying out the respective parties.
     * @dev  Approve the provided amount to this contract.
     * @param offerId The offer Id which user wants to update     
     * @param currency The contract addresss of payment Token
     * @param offerPrice The Offer price is set by Maker
     */
    function fillOffer(
        uint256 offerId,
        address currency,
        uint256 offerPrice
    ) external offerExists(offerId) nonReentrant {
        //Ensuring offer_maker address is valid
        require(
            offers[offerId].maker != address(0),
            "fillOffer must be active offer"
        );
        //Ensuring caller is token owner to accept the offer
        require(
            offers[offerId].tokenOwner == msg.sender,
            "fillOffer must be token owner"
        );
        //Ensurring PaymentType address and offerPrice with OfferID's attributes
        require(
            offers[offerId].currency == currency &&
                offers[offerId].offerPrice == offerPrice,
            "fillOffer currency & offerPrice must match offer"
        );
        //Ensuring the maker has enough balance to transfer.
        require(
            IERC20(currency).balanceOf(offers[offerId].maker) >= offerPrice,
            "insufficient amount"
        );
        // check for enough token allowance to contract address
        require(
            IERC20(currency).allowance(offers[offerId].maker, address(this)) >=
                    offerPrice,
            "insufficent token allowance"
        );

        Offer memory offerList = offers[offerId];
        delete offers[offerId]; 


        // transferring the tax amount to taxSettlementAddress
        uint256 remainingProfit = 0;
        if(offerList.taxAmount==0){
          remainingProfit = offerPrice;
        }
        else{
        _handlePayment(
                offerList.maker,
                payable(offerList.taxSettlementAddress),
                currency,
                offerList.taxAmount
            );
        remainingProfit = offerPrice.sub(offerList.taxAmount);
        }
        // PlatformFee Settlement
        uint256 platformFee = 0;
        if (platformAddress != address(0) && platformFeePercentage > 0) {
            platformFee = (remainingProfit.mul(platformFeePercentage)).div(10000);
            remainingProfit = remainingProfit.sub(platformFee);
      
            _handlePayment(
                offerList.maker, 
                platformAddress, 
                currency, 
                platformFee);
        }

        // Royalty Fee Payout Settlement
        remainingProfit = _handleRoyaltyEnginePayout(
            offerList.maker,
             offerList.tokenContract,
             offerList.tokenId,
            remainingProfit,
            currency
        );
        // Transfer the remaing amount to the tokenOwner
        _handlePayment(
            offerList.maker, 
            payable(offerList.tokenOwner), 
            currency, 
            remainingProfit
        );

        uint256 quantity = 1;
        if (
            IERC165(offerList.tokenContract).supportsInterface(
                ERC721_INTERFACE_ID
            )
        ) {
            IERC721(offerList.tokenContract).safeTransferFrom(
                msg.sender,
                offerList.maker,
                offerList.tokenId
            );
        } else {
            bytes memory data = "0x";
            quantity = IERC1155(offerList.tokenContract).balanceOf(
                msg.sender,
                offerList.tokenId
            );
            IERC1155(offerList.tokenContract).safeTransferFrom(
                msg.sender,
                offerList.maker,
                offerList.tokenId,
                quantity,
                data
            );
        }
        emit OfferClosed(
            offerId,
            offerList,
            quantity
        );
       
    }

    /**
     * @notice Cancel an offer.
     * @dev  emits an OfferCancelled event
     * @param offerId The offer Id which user wants to cancel
     */
    function cancelOffer(uint256 offerId)
        external
        nonReentrant
        offerExists(offerId)
    {   
        //to check whether caller is offer maker or token owner.
        require(
            ((offers[offerId].maker == msg.sender) ||
                (offers[offerId].tokenOwner == msg.sender)),
            "cancelOffer must be maker or token Owner"
        );
        emit OfferCanceled(
            offerId,
            offers[offerId].tokenId,
            offers[offerId].tokenContract,
            offers[offerId].tokenOwner,
            offers[offerId].offerPrice
        );
        delete offers[offerId];
    }
     
    /**
     * @notice To check alive OfferId.
     * @dev returns true if offerId exists,else false
     * @param offerId The offer Id which user wants to check
     */ 
    function _exists(uint256 offerId) internal view returns (bool) {
        return offers[offerId].tokenOwner != address(0);
    }
     
    /**
     * @notice handelling the errors while buying the nfts.
     * @param saleId the Id of the created sale
     * @param tokenId the token Id of the owner owns
     * @param tokenQuantity the token Quantity only required if minting
     * @param quantity the quantity of tokens for 1155 only
     * @param paymentToken the type of payment currency that the buyers pays
     * @param paymentAmount the amount to be paid in the payment currency
     * @param buyer address of the buyerwho buys the token
     */
    function errorHandelling(
        string memory saleId,
        uint256 tokenId,
        uint256 tokenQuantity,
        uint256 quantity,
        address paymentToken,
        uint256 paymentAmount,
        address buyer
    )
        private
        view
        returns (
            uint256 minimumPrice,
            address paymentCurrency,
            address tokenContract
        )
    {
        // checks the nft to be buyed is supported in the saleId
        if (
            listings[saleId].nftStartTokenId == 0 &&
            listings[saleId].nftEndTokenId > 0
        ) {
            require(
                tokenId <= listings[saleId].nftEndTokenId,
                "tokenId does not support listed tokens"
            );
        } else if (
            listings[saleId].nftStartTokenId > 0 &&
            listings[saleId].nftEndTokenId == 0
        ) {
            require(
                tokenId >= listings[saleId].nftStartTokenId,
                "tokenId does not support listed tokens"
            );
        } else if (
            listings[saleId].nftStartTokenId > 0 &&
            listings[saleId].nftEndTokenId > 0
        ) {
            require(
                tokenId >= listings[saleId].nftStartTokenId &&
                    tokenId <= listings[saleId].nftEndTokenId,
                "tokenId does not support listed tokens"
            );
        }
        // geetting the payment currency and the price using saleId
        tokenContract = listings[saleId].nftContractAddress;
        for (uint256 i=0; i < listings[saleId].paymentCurrency.length; i++) {
            if (listings[saleId].paymentCurrency[i] == paymentToken) {
                minimumPrice = listings[saleId].minimumPrice[i];
                paymentCurrency = listings[saleId].paymentCurrency[i];
                break;
            }
        }
        // chek for the minimumPrice we get should not be zero
        require(minimumPrice != 0, "we support only the listed tokens");

        if (listings[saleId].status == Status.mint) {
            if (
                IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID)
            ) {
                minimumPrice = (minimumPrice * tokenQuantity);
            } else if (
                IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
            ) {
                if (
                    IERC1155CreatorCore(tokenContract).totalSupply(tokenId) ==
                    0
                ) {
                    /* multiplying the total number of tokens and quantity with amount to get the 
                     total price for 1155 nfts ofr minting*/
                    minimumPrice = (minimumPrice *
                        tokenQuantity *
                        quantity);
                } else {
                    /* multiplying the total number of tokens with amount to get the 
                     total price for 721 nfts for minting*/
                    minimumPrice = (minimumPrice * quantity);
                }
            }
        } else if (listings[saleId].status == Status.transfer) {
            minimumPrice = (minimumPrice * quantity);
        }
        if (paymentCurrency == address(0)) {
            require(
                msg.value >= minimumPrice && paymentAmount >= minimumPrice,
                "insufficient amount"
            );
        } else {
            // checks the buyer has sufficient amount to buy the nft
            require(
                IERC20(paymentCurrency).balanceOf(buyer) >= minimumPrice &&
                    paymentAmount >= minimumPrice,
                "insufficient amount"
            );
            // checks the buyer has provided approval for the contract to transfer the amount
            require(
                IERC20(paymentCurrency).allowance(buyer, address(this)) >=
                    minimumPrice,
                "insufficent token allowance"
            );
        }
    }

    /**
     * @notice handelling royaltyPayout while buying the nfts.
     * @param buyer the address of the buyer
     * @param tokenId the token Id of the nft
     * @param tokenIds the Ids of the nft which are minted
     * @param tokenContract the address of the nft contract
     * @param amount the amount to be paid in the payment currency
     * @param paymentToken the type of payment currency that the buyers pays
     * @param status the status of minting or transferring of nfts
     */
    function royaltyPayout(
        address buyer,
        uint256 tokenId,
        uint256[] memory tokenIds,
        address tokenContract,
        uint256 amount,
        address paymentToken,
        Status status
    ) private returns (uint256 remainingProfit) {
        if (status == Status.transfer) {
            //  royalty payout for already minted tokens
            remainingProfit = _handleRoyaltyEnginePayout(
                buyer,
                tokenContract,
                tokenId,
                amount,
                paymentToken
            );
        } else if (status == Status.mint) {
            if (
                IERC165(tokenContract).supportsInterface(
                    ERC1155_INTERFACE_ID
                ) &&
                IERC1155CreatorCore(tokenContract).totalSupply(tokenId) > 0
            ) {
                // royalty payout for newly minted existeng ERC1155 tokens
                remainingProfit = _handleRoyaltyEnginePayout(
                    buyer,
                    tokenContract,
                    tokenId,
                    amount,
                    paymentToken
                );
            } else {
                amount = (amount / tokenIds.length);
                uint256 remainingTokenBalance;
                // royalty payout for all the newly minted tokens for 721 and 1155
                for (uint256 i=0; i < tokenIds.length; i++) {
                    remainingTokenBalance = _handleRoyaltyEnginePayout(
                        buyer,
                        tokenContract,
                        tokenIds[i],
                        amount,
                        paymentToken
                    );
                    remainingProfit = remainingProfit + remainingTokenBalance;
                }
            }
            return remainingProfit;
        }
    }

    /// @notice The details to be provided to buy the token
    /// @param saleId the Id of the created sale
    /// @param tokenOwner the owner of the nft token
    /// @param tokenContract the address of the nft contract
    /// @param buyer the address of the buyer
    /// @param tokenId the token Id of the owner owns
    /// @param tokenQuantity the token Quantity only required if minting
    /// @param quantity the quantity of tokens for 1155 only
    /// @param status the status of minting or transferring of nfts
    function _tokenTransaction(
        string memory saleId,
        address tokenOwner,
        address tokenContract,
        address buyer,
        uint256 tokenId,
        uint256 tokenQuantity,
        uint256 quantity,
        Status status
    ) private returns (uint256[] memory nftTokenId) {
        if (IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID)) {
            if (status == Status.transfer) {
                require(
                    IERC721(tokenContract).ownerOf(tokenId) == tokenOwner,
                    "maker is not the owner"
                );
                // Transferring the ERC721
                IERC721(tokenContract).safeTransferFrom(
                    tokenOwner,
                    buyer,
                    tokenId
                );
            } else if (status == Status.mint) {
                require(
                    tokensUsed[saleId] + tokenQuantity <=
                        listings[saleId].maxCap,
                    "tokenUsed should be lesser than maxCap"
                );

                tokensUsed[saleId] = tokensUsed[saleId] + tokenQuantity;

                // Minting the ERC721 in a batch
                nftTokenId = IERC721CreatorCore(tokenContract)
                    .mintExtensionBatch(buyer, uint16(tokenQuantity));
                
            }
        } else if (
            IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            if (status == Status.transfer) {
                uint256 ownerBalance = IERC1155(tokenContract).balanceOf(
                    tokenOwner,
                    tokenId
                );
                require(
                    quantity <= ownerBalance && quantity > 0,
                    "Insufficeint token balance"
                );

                // Transferring the ERC1155
                IERC1155(tokenContract).safeTransferFrom(
                    tokenOwner,
                    buyer,
                    tokenId,
                    quantity,
                    "0x"
                );
            } else if (status == Status.mint) {
                address[] memory to = new address[](1);
                uint256[] memory amounts = new uint256[](tokenQuantity);
                string[] memory uris = new string[](tokenQuantity);
                to[0] = buyer;
                amounts[0] = quantity;
                if (
                    IERC1155CreatorCore(tokenContract).totalSupply(tokenId) ==
                    0
                ) {
                    require(
                        tokensUsed[saleId] < listings[saleId].maxCap,
                        "tokenUsed should be lesser than maxCap"
                    );
                    for (uint256 i=0; i < tokenQuantity; i++) {
                        amounts[i] = quantity;
                    }
                    tokensUsed[saleId] = tokensUsed[saleId] + tokenQuantity;
                    // Minting ERC1155  of already existing tokens
                    nftTokenId = IERC1155CreatorCore(tokenContract)
                        .mintExtensionNew(to, amounts, uris);
                    
                } else if (
                    IERC1155CreatorCore(tokenContract).totalSupply(tokenId) >
                    0
                ) {
                    uint256[] memory tokenIdNew = new uint256[](1);
                    tokenIdNew[0] = tokenId;
                    // Minting new ERC1155 tokens
                    IERC1155CreatorCore(tokenContract).mintExtensionExisting(
                        to,
                        tokenIdNew,
                        amounts
                    );
                }
            }
        }
        return nftTokenId;
    }

    /// @notice Settle the Payment based on the given parameters
    /// @param from Address from whom the amount to be transferred
    /// @param to Address to whom need to settle the payment
    /// @param paymentToken Address of the ERC20 Payment Token
    /// @param amount Amount to be transferred
    function _handlePayment(
        address from,
        address payable to,
        address paymentToken,
        uint256 amount
    ) private {
        bool success;
        if (paymentToken == address(0)) {
            // transferreng the native currency
            (success, ) = to.call{value: amount}(new bytes(0));
            require(success, "transaction failed");
        } else {
            // transferring ERC20 currency
            IERC20(paymentToken).safeTransferFrom(from, to, amount);
        }
    }

    /// @notice Get the Royalty Fee details for the tokenID
    /// @param tokenContract The NFT Contract address
    /// @param tokenId The NFT tokenId
    /// @param amount the NFT price
    function getRoyaltyInfo(
        address tokenContract,
        uint256 tokenId,
        uint256 amount
    )
        private
        view
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
                INTERFACE_ID_ROYALTIES_RARIBLE
            )
        ) {
            recipients = ICreatorCore(tokenContract).getFeeRecipients(tokenId);
            bps = ICreatorCore(tokenContract).getFeeBps(tokenId);
        } else if (
            IERC165(tokenContract).supportsInterface(
                INTERFACE_ID_ROYALTIES_FOUNDATION
            )
        ) {
            (recipients, bps) = ICreatorCore(tokenContract).getFees(tokenId);
        } else if (
            IERC165(tokenContract).supportsInterface(
                INTERFACE_ID_ROYALTIES_EIP2981
            )
        ) {
            (address recipient, uint256 amountbps) = ICreatorCore(tokenContract)
                .royaltyInfo(tokenId, amount);
            recipients[0] = payable(recipient);
            bps[0] = (amountbps * 10000) / amount;
        }
    }

    /// @notice Settle the Royalty Payment based on the given parameters
    /// @param tokenContract The NFT Contract address
    /// @param tokenId The NFT tokenId
    /// @param amount Amount to be transferred
    /// @param payoutCurrency Address of the ERC20 Payout
    function _handleRoyaltyEnginePayout(
        address buyer,
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        address payoutCurrency
    ) private returns (uint256) {
        // Store the initial amount
        uint256 amountRemaining = amount;
        uint256 feeAmount;

        // Verifying whether the token contract supports Royalties of supported interfaces
        (
            address payable[] memory recipients,
            uint256[] memory bps // Royalty amount denominated in basis points
        ) = getRoyaltyInfo(tokenContract, tokenId, amount);

        // Store the number of recipients
        uint256 totalRecipients = recipients.length;

        // If there are no royalties, return the initial amount
        if (totalRecipients == 0) return amount;

        // Payout each royalty
        for (uint256 i = 0; i < totalRecipients; ) {
            // Cache the recipient and amount
            address payable recipient = recipients[i];

            feeAmount = (bps[i] * amount) / 10000;

            // Ensure that we aren't somehow paying out more than we have
            require(amountRemaining >= feeAmount, "insolvent");

            _handlePayment(buyer, recipient, payoutCurrency, feeAmount);
            emit RoyaltyPayout(tokenContract, tokenId, recipient, feeAmount);

            // Cannot underflow as remaining amount is ensured to be greater than or equal to royalty amount
            unchecked {
                amountRemaining -= feeAmount;
                ++i;
            }
        }

        return amountRemaining;
    }

    /// @notice get the listings currency and price
    /// @param saleId to get the details of sale
    function getListingPrice(string calldata saleId)
        external
        view
        returns (
            uint256[] memory minimumPrice,
            address[] memory paymentCurrency
        )
    {
        minimumPrice = listings[saleId].minimumPrice;
        paymentCurrency = listings[saleId].paymentCurrency;
    }

    /// @notice Withdraw the funds to owner
    function withdraw() external adminRequired {
        bool success;
        address payable to = payable(msg.sender);
        (success, ) = to.call{value: address(this).balance}(new bytes(0));
        require(success, "withdraw failed");
    }

    /// @notice cancel the sale of a listed token
    /// @param saleId to cansel the sale
    function cancelSale(string memory saleId) external adminRequired {
        require(usedSaleId[saleId], "unsupported sale");

        delete (listings[saleId]);
    }

    /// @notice Update the platform Address
    /// @param platformAddressArg The Platform Address
    function updatePlatformAddress(address platformAddressArg)
        external
        adminRequired
    {
        require(platformAddressArg != address(0), "Invalid Platform Address");
        platformAddress = payable(platformAddressArg);
    }

    /// @notice Update the Platform Fee Percentage
    /// @param platformFeePercentageArg The Platform fee percentage
    function updatePlatformFeePercentage(uint256 platformFeePercentageArg)
        external
        adminRequired
    {
        require(
            platformFeePercentageArg < 10000,
            "platformFee should not be more than 100 %"
        );
        platformFeePercentage = platformFeePercentageArg;
    }

    receive() external payable {}

    fallback() external payable {}
}