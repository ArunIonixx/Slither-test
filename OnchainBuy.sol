// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;
pragma experimental ABIEncoderV2;

import {IERC721, IERC165} from "../../openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "../../openzeppelin/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "../../openzeppelin/security/ReentrancyGuard.sol";
import {IERC20} from "../../openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {AdminControl} from "../../manifold/libraries-solidity/access/AdminControl.sol";
import {IERC721CreatorCore} from "../../manifold/creator-core/core/IERC721CreatorCore.sol";
import {IERC1155CreatorCore} from "../../manifold/creator-core/core/IERC1155CreatorCore.sol";

interface IPriceFeed {
    function getLatestPrice(uint256 amount, address fiat)
        external
        view
        returns (uint256);
}

interface IRoyaltyEngine {
    function getRoyalty(address collectionAddress, uint256 tokenId)
        external
        view
        returns (address payable[] memory, uint256[] memory);
}

/**
 * @title An onchain payment for buy now flow where owners can list the tokens for sale 
 and the buyers can buy the token using the buy function
 */
contract OnchainBuy is ReentrancyGuard, AdminControl {
    using SafeERC20 for IERC20;

    /// @notice The metadata for a given Order
    /// @param nftStartTokenId the Nft token Id listed From
    /// @param nftEndTokenId the NFT token Id listed To
    /// @param maxCap the total supply for minting
    /// @param nftContractAddress the nft contract address
    /// @param minimumFiatPrice the minimum price of the listed tokens
    /// @param minimumCryptoPrice the cryptoprice of provided crypto
    /// @param paymentCurrency the payment currency for seller requirement
    /// @param paymentSettlement the settlement address and payment percentage provided in basis points
    /// @param TransactionStatus the status to be minted or transfered
    /// @param PaymentStatus the status to get the price from fiat conversion or crypto price provided
    struct PriceList {
        uint64 nftStartTokenId;
        uint64 nftEndTokenId;
        uint64 maxCap;
        address nftContractAddress;
        uint256 minimumFiatPrice; // in USD
        uint256[] minimumCryptoPrice; // in Crypto
        address[] paymentCurrency; // in ETH/ERC20
        SettlementList paymentSettlement;
        TransactionStatus transactionStatus;
        PaymentStatus paymentStatus;
    }
    /// @notice The metadata for a given Order
    /// @param paymentSettlementAddress the settlement address for the listed tokens
    /// @param taxSettlementAddress the taxsettlement address for settlement of tax fee
    /// @param commissionAddress the commission address for settlement of commission fee
    /// @param platformSettlementAddress the platform address for settlement of platform fee
    /// @param commissionFeePercentage the commission fee given in basis points
    /// @param platformFeePercentage the platform fee given in basis points
    struct SettlementList {
        address payable paymentSettlementAddress;
        address payable taxSettlementAddress;
        address payable commissionAddress;
        address payable platformSettlementAddress;
        uint16 commissionFeePercentage; // in basis points
        uint16 platformFeePercentage; // in basis points
    }

    /// @notice The details to be provided to buy the token
    /// @param saleId the Id of the created sale
    /// @param tokenOwner the owner of the nft token
    /// @param tokenId the token Id of the owner owns
    /// @param tokenQuantity the token Quantity only required if minting
    /// @param quantity the quantity of tokens for 1155 only
    /// @param buyer the person who buys the nft
    /// @param paymentToken the type of payment currency that the buyers pay out
    /// @param paymentAmount the amount to be paid in the payment currency
    struct BuyList {
        string saleId;
        address tokenOwner;
        uint256 tokenId;
        uint64 tokenQuantity;
        uint64 quantity;
        address buyer;
        address paymentToken;
        uint256 paymentAmount;
    }

    // TransactionStatus shows the preference for mint or transfer
    enum TransactionStatus {
        mint,
        transfer
    }
    // PaymentStatus shows the preference for fiat conversion or direct crypto
    enum PaymentStatus {
        fiat,
        crypto
    }

    // Fee percentage to the Platform
    uint16 private platformFeePercentage;

    // maxQuantity for 1155 NFT-tokens
    uint64 private max1155Quantity;

    // Platform Address
    address payable private platformAddress;

    // The address of the Price Feed Aggregator to use via this contract
    IPriceFeed private priceFeedAddress;

    // The address of the royaltySupport to use via this contract
    IRoyaltyEngine private royaltySupport;

    // listing the sale details in sale Id
    mapping(string => PriceList) public listings;

    // tokens used to be compared with maxCap
    mapping(string => uint256) private tokensUsed;

    // validating saleId
    mapping(string => bool) usedSaleId;

    // Interface ID constants
    bytes4 private constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 private constant ERC1155_INTERFACE_ID = 0xd9b67a26;

    /// @notice Emitted when sale is created
    /// @param saleList contains the details of sale created
    /// @param CreatedOrUpdated the details provide whether sale is created or updated
    event SaleCreated(PriceList saleList, string CreatedOrUpdated);

    /// @notice Emitted when sale is closed
    /// @param saleId contains the details of cancelled sale
    event SaleClosed(string saleId);

    /// @notice Emitted when an Buy Event is completed
    /// @param tokenContract The NFT Contract address
    /// @param buyingDetails consist of buyer details
    /// @param MintedtokenId consist of minted tokenId details
    /// @param tax paid to the taxsettlement Address
    /// @param paymentAmount total amount paid by buyer
    /// @param totalAmount the amount paid by the buyer
    event BuyExecuted(
        address indexed tokenContract,
        BuyList buyingDetails,
        uint256[] MintedtokenId,
        uint256 tax,
        uint256 paymentAmount,
        uint256 totalAmount
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
    
    /// @notice Emitted when aContract Data is Updated
    /// @param newPlatformAddress The Platform Address
    /// @param newPlatformFeePercentage The Platform fee percentage
    /// @param newMax1155Quantity The max quantity we support for 1155 Nfts
    /// @param newPriceFeedAddress the address of the pricefeed
    /// @param newRoyaltycontract the address to get the royalty data
    event ContractDataUpdated(
        address newPlatformAddress,
        uint16 newPlatformFeePercentage,
        uint64 newMax1155Quantity,
        address newPriceFeedAddress,
        address newRoyaltycontract
    );

    /// @param platformAddressArg The Platform Address
    /// @param platformFeePercentageArg The Platform fee percentage
    /// @param max1155QuantityArg The max quantity we support for 1155 Nfts
    /// @param priceFeedAddressArg the address of the pricefeed
    /// @param royaltycontractArg the address to get the royalty data
    constructor(
        address platformAddressArg,
        uint16 platformFeePercentageArg,
        uint64 max1155QuantityArg,
        IPriceFeed priceFeedAddressArg,
        IRoyaltyEngine royaltycontractArg
    ) {
        require(platformAddressArg != address(0), "Invalid Platform Address");
        require(
            platformFeePercentageArg < 10000,
            "platformFee should be less than 10000"
        );
        platformAddress = payable(platformAddressArg);
        platformFeePercentage = platformFeePercentageArg;
        max1155Quantity = max1155QuantityArg;
        priceFeedAddress = priceFeedAddressArg;
        royaltySupport = royaltycontractArg;
    }

    /**
     * @notice creating a batch sales using batch details .
     * @param list gives the listing details to create a sale
     * @param saleId consist of the id of the listed sale
     */
    function createOrUpdateSale(PriceList calldata list, string calldata saleId)
        external
        adminRequired
    {

        uint16 totalFeeBasisPoints = 0;
        // checks for platform and commission fee to be less than 100 %
        if (list.paymentSettlement.platformFeePercentage != 0) {
            totalFeeBasisPoints += (list
                .paymentSettlement
                .platformFeePercentage +
                list.paymentSettlement.commissionFeePercentage);
        } else {
            totalFeeBasisPoints += (platformFeePercentage +
                list.paymentSettlement.commissionFeePercentage);
        }
        require(
            totalFeeBasisPoints < 10000,
            "The total fee basis point should be less than 10000"
        );
        // checks for valuable token start and end id for listing
        if (list.nftStartTokenId > 0 && list.nftEndTokenId > 0) {
            require(
                list.nftEndTokenId >= list.nftStartTokenId,
                "This is not a valid NFT start or end token ID. Please verify that the range provided is correct"
            );
        }
        // array for paymentCurrency and minimumPrice to be of same length
        require(
            list.paymentCurrency.length == list.minimumCryptoPrice.length,
            "should provide equal length in price and payment address"
        );

        // checks to provide maxcap while listing only for minting
        if (list.transactionStatus == TransactionStatus.mint) {
            require(list.maxCap != 0, "should provide maxCap for minting");

            require(
                list.nftStartTokenId == 0 && list.nftEndTokenId == 0,
                "The NFTstarttokenid and NFTendtokenid should be 0 for minting"
            );
        } else {
            require(
                list.maxCap == 0,
                "maxCap should be 0 for preminted tokens"
            );
        }
        // checks to provide only supported interface for nftContractAddress
        require(
            IERC165(list.nftContractAddress).supportsInterface(
                ERC721_INTERFACE_ID
            ) ||
                IERC165(list.nftContractAddress).supportsInterface(
                    ERC1155_INTERFACE_ID
                ),
            "should provide only supported contract interfaces ERC 721/1155"
        );
        // checks for paymentSettlementAddress should not be zero
        require(
            list.paymentSettlement.paymentSettlementAddress != address(0),
            "should provide valid wallet address for settlement"
        );
        // checks for taxSettlelentAddress should not be zero
        require(
            list.paymentSettlement.taxSettlementAddress != address(0),
            "should provide valid wallet address for tax settlement"
        );
        if(!usedSaleId[saleId] ){
        listings[saleId] = list;

        usedSaleId[saleId] = true;

        emit SaleCreated(list, "saleCreated");
        } else if(usedSaleId[saleId]){
            listings[saleId] = list;
            emit SaleCreated(list, "saleUpdated");
        }
    }

    /**
     * @notice End an sale, finalizing and paying out the respective parties.
     * @param list gives the listing details to buy the nfts
     * @param tax the amount of tax to be paid by the buyer
     */
    function buy(BuyList memory list, uint256 tax)
        external
        payable
        nonReentrant
        returns (uint256[] memory nftTokenId)
    {
        SettlementList memory settlement = listings[list.saleId]
            .paymentSettlement;
        PriceList memory saleList = listings[list.saleId];
        // checks for saleId is created for sale
        require(usedSaleId[list.saleId], "unsupported sale");

        // should be called by the contract admins or by the buyer
        require(
            isAdmin(msg.sender) || list.buyer == msg.sender,
            "Only the buyer or admin or owner of this contract can call this function"
        );

        // handling the errors before buying the NFT
        (uint256 minimumPrice, address tokenContract) = errorHandling(
            list.saleId,
            list.tokenId,
            list.tokenQuantity,
            list.quantity,
            list.paymentToken,
            (list.paymentAmount + tax),
            list.buyer
        );

        // Transferring  the NFT tokens to the buyer
        nftTokenId = _tokenTransaction(
            list.saleId,
            list.tokenOwner,
            tokenContract,
            list.buyer,
            list.tokenId,
            list.tokenQuantity,
            list.quantity,
            saleList.transactionStatus
        );
        // transferring the tax amount given by buyer as tax to taxSettlementAddress

        if (tax > 0) {
            _handlePayment(
                list.buyer,
                settlement.taxSettlementAddress,
                list.paymentToken,
                tax
            );
        }

        paymentTransaction(
            list.saleId,
            list.paymentAmount,
            list.buyer,
            list.paymentToken,
            list.tokenId,
            nftTokenId,
            tokenContract,
            saleList.transactionStatus
        );
        emit BuyExecuted(
            tokenContract,
            list,
            nftTokenId,
            tax,
            minimumPrice,
            list.paymentAmount
        );
        return nftTokenId;
    }

    /**
     * @notice payment settlement happens to all settlement address.
     * @param saleId consist of the id of the listed sale
     * @param totalAmount the totalAmount to be paid by the seller
     * @param paymentToken the selected currency the payment is made
     * @param transferredTokenId the tokenId of the transferred token
     * @param mintedTokenId the tokenId of the minted tokens
     * @param tokenContract the nftcontract address of the supported sale
     * @param status the transaction status for mint or transfer
     */
    function paymentTransaction(
        string memory saleId,
        uint256 totalAmount,
        address paymentFrom,
        address paymentToken,
        uint256 transferredTokenId,
        uint256[] memory mintedTokenId,
        address tokenContract,
        TransactionStatus status
    ) private {
        SettlementList memory settlement = listings[saleId].paymentSettlement;

        uint256 totalCommession = 0;

        // transferring the platformFee amount  to the platformSettlementAddress
        if (
            settlement.platformSettlementAddress != address(0) &&
            settlement.platformFeePercentage > 0
        ) {
            _handlePayment(
                paymentFrom,
                settlement.platformSettlementAddress,
                paymentToken,
                totalCommession += ((totalAmount *
                    settlement.platformFeePercentage) / 10000)
            );
        } else if (platformAddress != address(0) && platformFeePercentage > 0) {
            _handlePayment(
                paymentFrom,
                platformAddress,
                paymentToken,
                totalCommession += ((totalAmount * platformFeePercentage) /
                    10000)
            );
        }

        // transferring the commissionfee amount  to the commissionAddress
        if (
            settlement.commissionAddress != address(0) &&
            settlement.commissionFeePercentage > 0
        ) {
            totalCommession += ((totalAmount *
                settlement.commissionFeePercentage) / 10000);
            _handlePayment(
                paymentFrom,
                settlement.commissionAddress,
                paymentToken,
                ((totalAmount *
                settlement.commissionFeePercentage) / 10000)
            );
        }

        totalAmount = totalAmount - totalCommession;
        // Royalty Fee Payout Settlement
        totalAmount = royaltyPayout(
            paymentFrom,
            transferredTokenId,
            mintedTokenId,
            tokenContract,
            totalAmount,
            paymentToken,
            status
        );

        // Transfer the balance to the paymentSettlementAddress
        _handlePayment(
            paymentFrom,
            settlement.paymentSettlementAddress,
            paymentToken,
            totalAmount
        );
    }

    /**
     * @notice handling the errors while buying the nfts.
     * @param saleId the Id of the created sale
     * @param tokenId the token Id of the owner owns
     * @param tokenQuantity the token Quantity only required if minting
     * @param quantity the quantity of tokens for 1155 only
     * @param paymentToken the type of payment currency that the buyers pays
     * @param paymentAmount the amount to be paid in the payment currency
     * @param payee address of the buyer who buys the token
     */
    function errorHandling(
        string memory saleId,
        uint256 tokenId,
        uint256 tokenQuantity,
        uint256 quantity,
        address paymentToken,
        uint256 paymentAmount,
        address payee
    ) private view returns (uint256 minimumPrice, address tokenContract) {
        PriceList memory saleList = listings[saleId];
        // checks the nft to be buyed is supported in the saleId
        if (saleList.nftStartTokenId == 0 && saleList.nftEndTokenId > 0) {
            require(
                tokenId <= saleList.nftEndTokenId,
                "This is not a valid tokenId. Please verify that the tokenId provided is correct"
            );
        } else if (
            saleList.nftStartTokenId > 0 && saleList.nftEndTokenId == 0
        ) {
            require(
                tokenId >= saleList.nftStartTokenId,
                "This is not a valid tokenId. Please verify that the tokenId provided is correct"
            );
        } else if (saleList.nftStartTokenId > 0 && saleList.nftEndTokenId > 0) {
            require(
                tokenId >= saleList.nftStartTokenId &&
                    tokenId <= saleList.nftEndTokenId,
                "This is not a valid tokenId. Please verify that the tokenId provided is correct"
            );
        }
        // getting the payment currency and the price using saleId
        tokenContract = saleList.nftContractAddress;

        // getting the price using saleId
        if (saleList.paymentStatus == PaymentStatus.fiat) {
            minimumPrice = priceFeedAddress.getLatestPrice(
                saleList.minimumFiatPrice,
                paymentToken
            );
        } else if (saleList.paymentStatus == PaymentStatus.crypto) {
            for (uint256 i = 0; i < saleList.paymentCurrency.length; i++) {
                if (saleList.paymentCurrency[i] == paymentToken) {
                    minimumPrice = saleList.minimumCryptoPrice[i];
                    break;
                }
            }
        }
        // check for the minimumPrice we get should not be zero
        require(
            minimumPrice != 0,
            "Please provide valid supported ERC20/ETH address"
        );

        if (saleList.transactionStatus == TransactionStatus.mint) {
            // checks for tokenQuantity for 1155 NFTs
            require(
                quantity <= max1155Quantity,
                "The maximum quantity allowed to purchase at one time should not be more than defined in max1155Quantity"
            );
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
        } else if (saleList.transactionStatus == TransactionStatus.transfer) {
            minimumPrice = (minimumPrice * quantity);
        }
        if (paymentToken == address(0)) {
            require(
                msg.value == paymentAmount && paymentAmount >= minimumPrice,
                "Insufficient funds or invalid amount. You need to pass a valid amount to complete this transaction"
            );
        } else {
            // checks the buyer has sufficient amount to buy the nft
            require(
                IERC20(paymentToken).balanceOf(payee) >= paymentAmount &&
                    paymentAmount >= minimumPrice,
                "Insufficient funds. You should have sufficient balance to complete this transaction"
            );
            // checks the buyer has provided approval for the contract to transfer the amount
            require(
                IERC20(paymentToken).allowance(payee, address(this)) >=
                    paymentAmount,
                "Insufficient approval from an ERC20 Token. Please provide approval to this contract and try again"
            );
        }
    }

    /**
     * @notice handling royaltyPayout while buying the nfts.
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
        TransactionStatus status
    ) private returns (uint256 remainingProfit) {
        if (status == TransactionStatus.transfer) {
            //  royalty payout for already minted tokens
            remainingProfit = _handleRoyaltyEnginePayout(
                buyer,
                tokenContract,
                tokenId,
                amount,
                paymentToken
            );
        } else if (status == TransactionStatus.mint) {
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
                for (uint256 i = 0; i < tokenIds.length; i++) {
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
    /// @param tokenId the token Id to be buyed by the buyer
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
        TransactionStatus status
    ) private returns (uint256[] memory nftTokenId) {
        if (IERC165(tokenContract).supportsInterface(ERC721_INTERFACE_ID)) {
            if (status == TransactionStatus.transfer) {
                require(
                    IERC721(tokenContract).ownerOf(tokenId) == tokenOwner,
                    "Invalid NFT Owner Address. Please check and try again"
                );
                // Transferring the ERC721
                IERC721(tokenContract).safeTransferFrom(
                    tokenOwner,
                    buyer,
                    tokenId
                );
            } else if (status == TransactionStatus.mint) {
                require(
                    tokensUsed[saleId] + tokenQuantity <=
                        listings[saleId].maxCap,
                    "The maximum quantity allowed to purchase ERC721 token has been sold out. Please contact the sale owner for more details"
                );
                // Minting the ERC721 in a batch
                nftTokenId = IERC721CreatorCore(tokenContract)
                    .mintExtensionBatch(buyer, uint16(tokenQuantity));
                tokensUsed[saleId] = tokensUsed[saleId] + tokenQuantity;
            }
        } else if (
            IERC165(tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            if (status == TransactionStatus.transfer) {
                uint256 ownerBalance = IERC1155(tokenContract).balanceOf(
                    tokenOwner,
                    tokenId
                );
                require(
                    quantity <= ownerBalance && quantity > 0,
                    "Insufficient token balance from the owner"
                );

                // Transferring the ERC1155
                IERC1155(tokenContract).safeTransferFrom(
                    tokenOwner,
                    buyer,
                    tokenId,
                    quantity,
                    "0x"
                );
            } else if (status == TransactionStatus.mint) {
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
                        "The maximum quantity allowed to purchase ERC1155 token has been sold out. Please contact the sale owner for more details"
                    );
                    for (uint256 i = 0; i < tokenQuantity; i++) {
                        amounts[i] = quantity;
                    }
                    // Minting ERC1155  of already existing tokens
                    nftTokenId = IERC1155CreatorCore(tokenContract)
                        .mintExtensionNew(to, amounts, uris);

                    tokensUsed[saleId] = tokensUsed[saleId] + tokenQuantity;
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
            require(success, "unable to debit native balance please try again");
        } else {
            // transferring ERC20 currency
            IERC20(paymentToken).safeTransferFrom(from, to, amount);
        }
    }

    /// @notice Settle the Royalty Payment based on the given parameters
    /// @param buyer the address of the buyer
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
        ) = royaltySupport.getRoyalty(tokenContract, tokenId);

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
            require(
                amountRemaining >= feeAmount,
                "insolvent: unable to complete royalty"
            );

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
            uint256[] memory minimumCryptoPrice,
            address[] memory paymentCurrency
        )
    {
        minimumCryptoPrice = listings[saleId].minimumCryptoPrice;
        paymentCurrency = listings[saleId].paymentCurrency;
    }

    /// @notice get contract state details
    function getContractData()
        external
        view
        returns (
            address platformAddressArg,
            uint16 platformFeePercentageArg,
            IPriceFeed priceFeedAddressArg,
            IRoyaltyEngine royaltySupportArg,
            uint64 max1155QuantityArg
        )
    {
        platformAddressArg = platformAddress;
        platformFeePercentageArg = platformFeePercentage;
        priceFeedAddressArg = priceFeedAddress;
        royaltySupportArg = royaltySupport;
        max1155QuantityArg = max1155Quantity;
    }

    /// @notice Withdraw the funds to owner
    function withdraw(address paymentCurrency) external adminRequired {
        bool success;
        address payable to = payable(msg.sender);
        require(to!=address(0), "to address should not be zero Address");
        if(paymentCurrency == address(0)){
        (success, ) = to.call{value: address(this).balance}(new bytes(0));
        require(success, "withdraw to withdraw funds. Please try again");
        } else if (paymentCurrency != address(0)){
            // transferring ERC20 currency
            uint256 amount = IERC20(paymentCurrency).balanceOf(address(this));
            IERC20(paymentCurrency).safeTransfer(to, amount);    
        }
    }

    /// @notice cancel the sale of a listed token
    /// @param saleId to cancel the sale
    function cancelSale(string memory saleId) external adminRequired {
        require(
            usedSaleId[saleId],
            "the saleId you have entered is invalid. Please validate"
        );

        delete (listings[saleId]);
        emit SaleClosed(saleId);
    }

    /// @notice set contract state details
    /// @param platformAddressArg The Platform Address
    /// @param platformFeePercentageArg The Platform fee percentage
    /// @param max1155QuantityArg maxQuantity we support for 1155 NFTs
    /// @param royaltyContractArg The contract intracts to get the royalty fee
    /// @param pricefeedArg The contract intracts to get the chainlink feeded price
    function setContractData(
        address payable platformAddressArg,
        uint16 platformFeePercentageArg,
        uint64 max1155QuantityArg,
        address royaltyContractArg,
        address pricefeedArg
    ) external adminRequired {
        require(platformAddressArg != address(0), "Invalid Platform Address");
        require(
            platformFeePercentageArg < 10000,
            "platformFee should be less than 10000"
        );
        emit ContractDataUpdated(
            platformAddressArg,
            platformFeePercentageArg,
            max1155QuantityArg,
            royaltyContractArg,
            pricefeedArg
            );
        platformAddress = platformAddressArg;
        platformFeePercentage = platformFeePercentageArg;
        max1155Quantity = max1155QuantityArg;
        royaltySupport = IRoyaltyEngine(royaltyContractArg);
        priceFeedAddress = IPriceFeed(pricefeedArg);
        
    }

    /// @notice get royalty payout details
    /// @param collectionAddress the nft contract address
    /// @param tokenId the nft token Id
    function getRoyaltyInfo(address collectionAddress, uint256 tokenId)
        external
        view
        returns (address payable[] memory recipients, uint256[] memory bps)
    {
        (
            recipients,
            bps // Royalty amount denominated in basis points
        ) = royaltySupport.getRoyalty(collectionAddress, tokenId);
    }

    receive() external payable {}

    fallback() external payable {}
}
