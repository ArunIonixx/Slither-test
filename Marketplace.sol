// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {IERC721, IERC165} from "../../openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "../../openzeppelin/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "../../openzeppelin/security/ReentrancyGuard.sol";
import {IERC20} from "../../openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "../../openzeppelin/utils/cryptography/ECDSA.sol";
import {ICreatorCore} from "../../manifold/creator-core/core/ICreatorCore.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {SafeCast} from "../../openzeppelin/utils/math/SafeCast.sol";
import "../interfaces/IRoyaltyEngine.sol";

/**
 * @title IWrapperNativeToken
 * @dev Interface for Wrapped native tokens such as WETH, WMATIC, WBNB, etc
 */
interface IWrappedNativeToken {
    function deposit() external payable;

    function withdraw(uint256 wad) external;

    function transfer(address to, uint256 value) external returns (bool);
}

contract Marketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    address public immutable owner;

    /// @notice The metadata for a given Order
    /// @param uuid The generated Unique uuid
    /// @param tokenId The NFT tokenId
    /// @param tokenContract The NFT Contract address
    /// @param quantity The total quantity of the ERC1155 token if ERC721 it is 1
    /// @param tokenOwner The address of the Token Owner
    /// @param fixedPrice Price fixed by the TokenOwner
    /// @param paymentToken ERC20 address chosen by TokenOwner for Payments
    /// @param tax Price fixed by the Exchange.
    /// @param whitelistedBuyer Address of the Whitelisted Buyer
    /// @param quotePrice If Buyer quoted price in fiat currency
    /// @param slippage Price Limit based on the percentage
    /// @param buyer Address of the buyer
    struct Order {
        string uuid;
        uint256 tokenId;
        address tokenContract;
        uint256 quantity;
        address payable tokenOwner;
        uint256 fixedPrice;
        address paymentToken;
        uint256 tax;
        address whitelistedBuyer;
        uint256 quotePrice;
        uint256 slippage;
        address buyer;
    }

    /// @notice The Bid History for a Token
    /// @param bidder Address of the Bidder
    /// @param quotePrice Price quote by them
    /// @param paymentAddress Payment ERC20 Address by the Bidder
    struct BidHistory {
        address bidder;
        uint256 quotePrice;
        address paymentAddress;
    }
    // Interface ID constants
    bytes4 constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 constant ERC1155_INTERFACE_ID = 0xd9b67a26;
   
    // 1 Ether in Wei, 10^18
    int64 constant ONE_ETH_WEI = 1e18;

    // ERC20 address of the Native token (can be WETH, WBNB, WMATIC, etc)
    address public wrappedNativeToken;

    // Platform Address
    address payable public platformAddress;

    // Fee percentage to the Platform
    uint256 public platformFeePercentage;

    // The address of the Price Feed Aggregator to use via this contract
    address public priceFeedAddress;

    // Address of the Admin
    address public adminAddress;

    // Address of the Royalty Registry
    address public royaltyRegistryAddress;

    // Status of the Royalty Contract Active or not
    bool public royaltyActive;

    // UUID validation on orders
    mapping(string => bool) private usedUUID;

    /// @notice Emitted when an Buy Event is completed
    /// @param uuid The generated Unique uuid
    /// @param tokenId The NFT tokenId
    /// @param tokenContract The NFT Contract address
    /// @param quantity The total quantity of the ERC1155 token if ERC721 it is 1
    /// @param tokenOwner The address of the Token Owner
    /// @param buyer Address of the buyer
    /// @param amount Fixed Price
    /// @param paymentToken ERC20 address chosen by TokenOwner for Payments
    /// @param marketplaceAddress Address of the Platform
    /// @param platformFee Fee sent to the Platform Address
    event BuyExecuted(
        string uuid,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 quantity,
        address indexed tokenOwner,
        address buyer,
        uint256 amount,
        uint256 tax,
        address paymentToken,
        address marketplaceAddress,
        uint256 platformFee
    );

    /// @notice Emitted when an Sell(Accept Offer) Event is completed
    /// @param uuid The generated Unique uuid
    /// @param tokenId The NFT tokenId
    /// @param tokenContract The NFT Contract address
    /// @param quantity The total quantity of the ERC1155 token if ERC721 it is 1
    /// @param tokenOwner The address of the Token Owner
    /// @param buyer Address of the buyer
    /// @param amount Fixed Price
    /// @param paymentToken ERC20 address chosen by TokenOwner for Payments
    /// @param marketplaceAddress Address of the Platform
    /// @param platformFee Fee sent to the Platform Address
    event SaleExecuted(
        string uuid,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 quantity,
        address indexed tokenOwner,
        address buyer,
        uint256 amount,
        uint256 tax,
        address paymentToken,
        address marketplaceAddress,
        uint256 platformFee
    );

    /// @notice Emitted when an End Auction Event is completed
    /// @param uuid The generated Unique uuid
    /// @param tokenId The NFT tokenId
    /// @param tokenContract The NFT Contract address
    /// @param quantity The total quantity of the ERC1155 token if ERC721 it is 1
    /// @param tokenOwner The address of the Token Owner
    /// @param highestBidder Address of the highest bidder
    /// @param amount Fixed Price
    /// @param paymentToken ERC20 address chosen by TokenOwner for Payments
    /// @param marketplaceAddress Address of the Platform
    /// @param platformFee Fee sent to the Platform Address
    /// @param bidderlist Bid History List
    event AuctionClosed(
        string uuid,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 quantity,
        address indexed tokenOwner,
        address highestBidder,
        uint256 amount,
        uint256 tax,
        address paymentToken,
        address marketplaceAddress,
        uint256 platformFee,
        BidHistory[] bidderlist
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
    
    /// @notice Emitted when an AdminA ddress is Updated
    /// @param oldAdminAddress The address of previous Admin
    /// @param newAdminAddress TThe address of Current Admin
    event AdminAddressUpdated(address oldAdminAddress,address newAdminAddress);

    /// @notice Modifier to check only the owner or admin calls the function
    modifier onlyOwner() {
        require(msg.sender == owner || msg.sender == adminAddress);
        _;
    }

    /// @param wrappedNativeTokenArg Native ERC20 Address
    /// @param platformAddressArg The Platform Address
    /// @param platformFeePercentageArg The Platform fee percentage
    /// @param priceFeedAddressArg PriceFeed Contract Address
    /// @param adminAddressArg Admin Address
    constructor(
        address wrappedNativeTokenArg,
        address platformAddressArg,
        uint256 platformFeePercentageArg,
        address priceFeedAddressArg,
        address adminAddressArg,
        address royaltyRegistryAddressArg,
        bool royaltyActiveArg
    ) {
        require(platformAddressArg != address(0), "Invalid Platform Address");
        require(priceFeedAddressArg != address(0), "Invalid PriceFeed Address");
        require(
            wrappedNativeTokenArg != address(0),
            "Invalid WrappedNativeToken Address"
        );
        require(
            platformFeePercentageArg < 10000,
            "platformFee should not be more than 100 %"
        );
        require(adminAddressArg != address(0), "Invalid Admin Address");
        require(royaltyRegistryAddressArg != address(0), "Invalid Admin Address");
        wrappedNativeToken = wrappedNativeTokenArg;
        platformAddress = payable(platformAddressArg);
        platformFeePercentage = platformFeePercentageArg;
        priceFeedAddress = priceFeedAddressArg;
        owner = msg.sender;
        adminAddress = adminAddressArg;
        royaltyRegistryAddress = royaltyRegistryAddressArg;
        royaltyActive = royaltyActiveArg;
    }

    /// @notice Buy the listed token with the sellersignature
    /// @param order Order struct consists of the listedtoken details
    /// @param sellerSignature Signature generated when signing the hash(order details) by the seller
    function buy(
        Order memory order,
        bytes memory sellerSignature,
        address payableToken
    ) external payable nonReentrant {
        // Validating the InterfaceID
        require(
            (IERC165(order.tokenContract).supportsInterface(
                ERC721_INTERFACE_ID
            ) ||
                IERC165(order.tokenContract).supportsInterface(
                    ERC1155_INTERFACE_ID
                )),
            "tokenContract does not support ERC721 or ERC1155 interface"
        );
        // Validating the caller to be the buyer
        require(order.buyer == msg.sender, "msg.sender should be the buyer");

        // Validating address if whitelisted address is present
        require(
            order.whitelistedBuyer == address(0) ||
                order.whitelistedBuyer == msg.sender,
            "can only be called by whitelisted buyer"
        );

        // Validating the paymentToken chosen by Seller
        require(
            order.paymentToken == wrappedNativeToken ||
                order.paymentToken == address(0),
            "should provide only supported currencies"
        );

        // Validating the currencyToken chosen by Buyer
        require(
            payableToken == wrappedNativeToken || payableToken == address(0),
            "currencyToken must be supported"
        );

        // Checking sufficient balance of ether
        if (payableToken == address(0)) {
            require(
                msg.value >= (order.fixedPrice + order.tax),
                "insufficient amount"
            );
        } else if (payableToken == wrappedNativeToken) {
            require(
                IERC20(payableToken).balanceOf(order.buyer) >=
                    (order.fixedPrice + order.tax),
                "insufficient balance"
            );
            require(
                IERC20(payableToken).allowance(order.buyer, address(this)) >=
                    (order.fixedPrice + order.tax),
                "insufficient token allowance"
            );
        }
        // Validating signatures
        require(
            _verifySignature(order, sellerSignature, order.tokenOwner),
            "Invalid seller signature"
        );

        // Validating UUID
        require(!usedUUID[order.uuid], "UUID already used");

        // Updating the Used UUID
        usedUUID[order.uuid] = true;

        // Validating the Price Conversion if quoteprice is given
        if (order.quotePrice > 0) {
            _validatePrice(
                SafeCast.toInt256(order.fixedPrice),
                SafeCast.toInt256(order.quotePrice),
                payableToken,
                SafeCast.toInt256(order.slippage)
            );
        }

        uint256 remainingProfit = order.fixedPrice;
        // Tax Settlement
        if (platformAddress != address(0) && order.tax > 0) {
            _handlePayment(
                order.buyer,
                platformAddress,
                order.paymentToken,
                order.tax,
                payableToken
            );
        }

        // PlatformFee Settlement
        uint256 platformFee = 0;
        if (platformAddress != address(0) && platformFeePercentage > 0) {
            platformFee = (remainingProfit * platformFeePercentage) / 10000;
            remainingProfit = remainingProfit - platformFee;

            _handlePayment(
                order.buyer,
                platformAddress,
                order.paymentToken,
                platformFee,
                payableToken
            );
        }

        // Royalty Fee Payout Settlement
        remainingProfit = _handleRoyaltyEnginePayout(
            order.tokenContract,
            order.tokenId,
            remainingProfit,
            order.paymentToken,
            order.buyer,
            payableToken
        );

        // Transfer the balance to the tokenOwner
        _handlePayment(
            order.buyer,
            order.tokenOwner,
            order.paymentToken,
            remainingProfit,
            payableToken
        );

        // Transaferring Tokens
        _tokenTransaction(order);

        emit BuyExecuted(
            order.uuid,
            order.tokenId,
            order.tokenContract,
            order.quantity,
            order.tokenOwner,
            order.buyer,
            order.fixedPrice,
            order.tax,
            order.paymentToken,
            platformAddress,
            platformFee
        );
    }

    /// @notice Sell the listed token with the BuyerSignature - Accepting the Offer
    /// @param order Order struct consists of the listedtoken details
    /// @param buyerSignature Signature generated when signing the hash(order details) by the buyer
    /// @param expirationTime Expiration Time for the offer
    function sell(
        Order memory order,
        bytes memory buyerSignature,
        uint256 expirationTime,
        address receivableToken
    ) external nonReentrant {
        // Validating the InterfaceID
        require(
            (IERC165(order.tokenContract).supportsInterface(
                ERC721_INTERFACE_ID
            ) ||
                IERC165(order.tokenContract).supportsInterface(
                    ERC1155_INTERFACE_ID
                )),
            "tokenContract does not support ERC721 or ERC1155 interface"
        );

        // Validating that seller owns a sufficient amount of the token to be listed
        if (
            IERC165(order.tokenContract).supportsInterface(ERC1155_INTERFACE_ID)
        ) {
            uint256 tokenQty = IERC1155(order.tokenContract).balanceOf(
                msg.sender,
                order.tokenId
            );
            require(
                order.quantity <= tokenQty && order.quantity > 0,
                "Insufficient token balance"
            );
        }

        // Validating msg.sender to be Token Owner
        require(
            order.tokenOwner == msg.sender,
            "msg.sender should be token owner"
        );

        // Validating the expiration time
        require(
            expirationTime >= block.timestamp,
            "expirationTime must be a future timestamp"
        );

        // Validating the currencyToken chosen by Seller
        require(
            (receivableToken == wrappedNativeToken ||
                receivableToken == address(0)) &&
                order.paymentToken == wrappedNativeToken,
            "both payment and currency tokens must be supported"
        );

        // Validating buyer's ERC20 balance
        if (order.paymentToken == wrappedNativeToken) {
            require(
                IERC20(order.paymentToken).balanceOf(order.buyer) >=
                    (order.fixedPrice + order.tax),
                "insufficient balance"
            );
            require(
                IERC20(order.paymentToken).allowance(
                    order.buyer,
                    address(this)
                ) >= (order.fixedPrice + order.tax),
                "insufficient token allowance"
            );
        }
        // Validating address if whitelisted address is present
        require(
            order.whitelistedBuyer == address(0) ||
                order.whitelistedBuyer == order.buyer,
            "can only be called by whitelisted buyer"
        );

        // Validating signatures
        require(
            _verifySignature(order, buyerSignature, order.buyer),
            "Invalid buyer signature"
        );

        // Validating UUID
        require(!usedUUID[order.uuid], "UUID already used");

        // Updating the Used UUID
        usedUUID[order.uuid] = true;

        // Validating the Price Conversion if quoteprice is given
        if (order.quotePrice > 0) {
            _validatePrice(
                SafeCast.toInt256(order.fixedPrice),
                SafeCast.toInt256(order.quotePrice),
                receivableToken,
                SafeCast.toInt256(order.slippage)
            );
        }

        uint256 remainingProfit = order.fixedPrice;

        // Tax settlement
        if (platformAddress != address(0) && order.tax > 0) {
            _handlePayment(
                order.buyer,
                platformAddress,
                receivableToken,
                order.tax,
                order.paymentToken
            );
        }

        uint256 platformFee = 0;
        // PlatformFee Settlement
        if (platformAddress != address(0) && platformFeePercentage > 0) {
            platformFee = (remainingProfit * platformFeePercentage) / 10000;
            remainingProfit = remainingProfit - platformFee;

            _handlePayment(
                order.buyer,
                platformAddress,
                receivableToken,
                platformFee,
                order.paymentToken
            );
        }

        // Royalty Fee Payout Settlement
        remainingProfit = _handleRoyaltyEnginePayout(
            order.tokenContract,
            order.tokenId,
            remainingProfit,
            receivableToken,
            order.buyer,
            order.paymentToken
        );

        // Transfer the balance to the tokenOwner
        _handlePayment(
            order.buyer,
            payable(msg.sender),
            receivableToken,
            remainingProfit,
            order.paymentToken
        );

        // Transaferring Tokens
        _tokenTransaction(order);

        emit SaleExecuted(
            order.uuid,
            order.tokenId,
            order.tokenContract,
            order.quantity,
            msg.sender,
            order.buyer,
            order.fixedPrice,
            order.tax,
            receivableToken,
            platformAddress,
            platformFee
        );
    }

    /// @notice Ending an Auction based on the signature verification with highest bidder
    /// @param order Order struct consists of the listedtoken details
    /// @param sellerSignature Signature generated when signing the hash(order details) by the seller
    /// @param buyerSignature Signature generated when signing the hash(order details) by the buyer
    /// @param bidHistory Bidhistory which contains the list of bidders with the details
    function executeAuction(
        Order memory order,
        bytes memory sellerSignature,
        bytes memory buyerSignature,
        address payableToken,
        BidHistory[] memory bidHistory
    ) external payable nonReentrant {
        // Validating the InterfaceID
        require(
            (IERC165(order.tokenContract).supportsInterface(
                ERC721_INTERFACE_ID
            ) ||
                IERC165(order.tokenContract).supportsInterface(
                    ERC1155_INTERFACE_ID
                )),
            "tokenContract does not support ERC721 or ERC1155 interface"
        );

        // Validating the msg.sender with admin or buyer
        require(
            order.buyer == msg.sender || adminAddress == msg.sender,
            "Only Buyer or the Admin can call this function"
        );

        // Validating Admin can only call only if the currencyToken is WrappedNativeToken
        if (adminAddress == msg.sender) {
            require(
                payableToken == wrappedNativeToken,
                "Only Admin can call this function if currencyToken is WrappedNativeToken"
            );
        }
        // Validating address if whitelisted address is present
        require(
            order.whitelistedBuyer == address(0) ||
                order.whitelistedBuyer == msg.sender,
            "can only be called by whitelisted buyer"
        );

        // Validating the paymentToken chosen by Seller
        require(
            order.paymentToken == wrappedNativeToken ||
                order.paymentToken == address(0),
            "can only pay with a supported currency"
        );

        // Validating the currencyToken chosen by Buyer
        require(
            payableToken == wrappedNativeToken || payableToken == address(0),
            "currencyToken must be supported"
        );

        // Checking sufficient balance of ether
        if (payableToken == address(0)) {
            require(
                msg.value >= (order.fixedPrice + order.tax),
                "insufficient amount"
            );
        } else if (payableToken == wrappedNativeToken) {
            require(
                IERC20(payableToken).balanceOf(order.buyer) >=
                    (order.fixedPrice + order.tax),
                "insufficient balance"
            );
            require(
                IERC20(payableToken).allowance(order.buyer, address(this)) >=
                    (order.fixedPrice + order.tax),
                "insufficient token allowance"
            );
        }

        // Validating seller signature
        require(
            _verifySignature(order, sellerSignature, order.tokenOwner),
            "Invalid seller signature"
        );

        // Validating buyer signature
        require(
            _verifySignature(order, buyerSignature, order.buyer),
            "Invalid buyer signature"
        );

        // Validating UUID
        require(!usedUUID[order.uuid], "UUID already used");

        // Updating the Used UUID
        usedUUID[order.uuid] = true;

        // Validating the Price Conversion if quoteprice is given
        if (order.quotePrice > 0) {
            _validatePrice(
                SafeCast.toInt256(order.fixedPrice),
                SafeCast.toInt256(order.quotePrice),
                payableToken,
                SafeCast.toInt256(order.slippage)
            );
        }

        uint256 remainingProfit = order.fixedPrice;

        // Tax Settlement
        if (platformAddress != address(0) && order.tax > 0) {
            _handlePayment(
                order.buyer,
                platformAddress,
                order.paymentToken,
                order.tax,
                payableToken
            );
        }

        // PlatformFee Settlement
        uint256 platformFee = 0;
        if (platformAddress != address(0) && platformFeePercentage > 0) {
            platformFee = (remainingProfit * platformFeePercentage) / 10000;
            remainingProfit = remainingProfit - platformFee;

            _handlePayment(
                order.buyer,
                platformAddress,
                order.paymentToken,
                platformFee,
                payableToken
            );
        }

        // Royalty Fee Payout Settlement
        remainingProfit = _handleRoyaltyEnginePayout(
            order.tokenContract,
            order.tokenId,
            remainingProfit,
            order.paymentToken,
            order.buyer,
            payableToken
        );

        // Transfer the balance to the tokenOwner
        _handlePayment(
            order.buyer,
            order.tokenOwner,
            order.paymentToken,
            remainingProfit,
            payableToken
        );

        // Transferring the Tokens
        _tokenTransaction(order);

        emit AuctionClosed(
            order.uuid,
            order.tokenId,
            order.tokenContract,
            order.quantity,
            order.tokenOwner,
            order.buyer,
            order.fixedPrice,
            order.tax,
            order.paymentToken,
            platformAddress,
            platformFee,
            bidHistory
        );
    }

    /// @notice Transferring the tokens based on the from and to Address
    /// @param order Order struct consists of the listedtoken details
    function _tokenTransaction(Order memory order) internal {
        if (
            IERC165(order.tokenContract).supportsInterface(ERC721_INTERFACE_ID)
        ) {
            require(
                IERC721(order.tokenContract).ownerOf(order.tokenId) ==
                    order.tokenOwner,
                "maker is not the owner"
            );

            // Transferring the ERC721
            IERC721(order.tokenContract).safeTransferFrom(
                order.tokenOwner,
                order.buyer,
                order.tokenId
            );
        }
        if (
            IERC165(order.tokenContract).supportsInterface(
                ERC1155_INTERFACE_ID
            )
        ) {
            uint256 ownerBalance = IERC1155(order.tokenContract).balanceOf(
                order.tokenOwner,
                order.tokenId
            );
            require(
                order.quantity <= ownerBalance && order.quantity > 0,
                "Insufficeint token balance"
            );

            // Transferring the ERC1155
            IERC1155(order.tokenContract).safeTransferFrom(
                order.tokenOwner,
                order.buyer,
                order.tokenId,
                order.quantity,
                "0x"
            );
        }
    }

    /// @notice Settle the Payment based on the given parameters
    /// @param from Address from whom we get the payment amount to settle
    /// @param to Address to whom need to settle the payment
    /// @param paymentToken Address of the ERC20 Payment Token
    /// @param amount Amount to be transferred
    function _handlePayment(
        address from,
        address payable to,
        address paymentToken,
        uint256 amount,
        address currencyToken
    ) internal {
        bool success;
        if (paymentToken == address(0) && currencyToken == address(0)) {
            (success, ) = to.call{value: amount}(new bytes(0));
            require(success, "transaction failed");
        } else if (
            paymentToken == wrappedNativeToken && currencyToken == address(0)
        ) {
            IWrappedNativeToken(wrappedNativeToken).deposit{value: amount}();
            IERC20(paymentToken).safeTransfer(to, amount);
        } else if (
            paymentToken == address(0) && currencyToken == wrappedNativeToken
        ) {
            IERC20(wrappedNativeToken).safeTransferFrom(
                from,
                address(this),
                amount
            );
            IWrappedNativeToken(wrappedNativeToken).withdraw(amount);
            (success, ) = to.call{value: amount}(new bytes(0));
            require(success, "transaction failed");
        } else if (paymentToken == currencyToken) {
            IERC20(paymentToken).safeTransferFrom(from, to, amount);
        }
    }

    /// @notice Settle the Royalty Payment based on the given parameters
    /// @param tokenContract The NFT Contract address
    /// @param tokenId The NFT tokenId
    /// @param amount Amount to be transferred
    /// @param payoutCurrency Address of the ERC20 Payout
    /// @param buyer From Address for the ERC20 Payout
    function _handleRoyaltyEnginePayout(
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        address payoutCurrency,
        address buyer,
        address currencyToken
    ) internal returns (uint256) {
        // Store the initial amount
        uint256 amountRemaining = amount;
        uint256 feeAmount;
        address payable[] memory recipients;
        uint256[] memory bps;
        // Verifying whether the token contract supports Royalties of supported interfaces
        if (royaltyActive) {
            (recipients, bps) = IRoyaltyEngine(royaltyRegistryAddress)
                .getRoyalty(tokenContract, tokenId);
        }

        // Store the number of recipients
        uint256 totalRecipients = recipients.length;

        // If there are no royalties, return the initial amount
        if (totalRecipients == 0) return amount;

        // pay out each royalty
        for (uint256 i = 0; i < totalRecipients; ) {
            // Cache the recipient and amount
            address payable recipient = recipients[i];

            // Calculate royalty basis points
            feeAmount = (bps[i] * amount) / 10000;

            // Ensure that there's still enough balance remaining
            require(amountRemaining >= feeAmount, "insolvent");

            _handlePayment(
                buyer,
                recipient,
                payoutCurrency,
                feeAmount,
                currencyToken
            );
            emit RoyaltyPayout(tokenContract, tokenId, recipient, feeAmount);

            // Cannot underflow as remaining amount is ensured to be greater than or equal to royalty amount
            unchecked {
                amountRemaining -= feeAmount;
                ++i;
            }
        }

        return amountRemaining;
    }

    /// @notice Verifies the Signature with the required Signer
    /// @param order Order struct consists of the listedtoken details
    /// @param signature Signature generated when signing the hash(order details) by the signer
    /// @param signer Address of the Signer
    function _verifySignature(
        Order memory order,
        bytes memory signature,
        address signer
    ) internal view returns (bool) {
        return
            keccak256(
                abi.encodePacked(
                    order.uuid,
                    order.tokenId,
                    order.tokenContract,
                    order.quantity,
                    order.tokenOwner,
                    order.fixedPrice,
                    order.paymentToken,
                    block.chainid
                )
            ).toEthSignedMessageHash().recover(signature) == signer;
    }

    /// @notice Validate the quoted price with the ERC20 address price
    /// @param basePrice Price fixed by the TokenOwner
    /// @param destPrice Quoted price in fiat currency
    /// @param saleCurrency ERC20 address chosen by TokenOwner for Payments
    /// @param slippage Price Limit based on the percentage
    function _validatePrice(
        int256 basePrice,
        int256 destPrice,
        address saleCurrency,
        int256 slippage
    ) internal {
        // Getting the latest Price from the PriceFeed Contract
        (int256 price, uint8 roundId) = IPriceFeed(priceFeedAddress)
            .getLatestPrice(saleCurrency);

        // Validate the exact fixed Price with the quoted Price
        require(
            (((destPrice / ONE_ETH_WEI) +
                (((destPrice * slippage) / ONE_ETH_WEI) / 100)) >=
                (price * basePrice) /
                    (SafeCast.toInt256(10**roundId) * ONE_ETH_WEI)),
            "quotePrice with slippage is less than the fixedPrice"
        );
    }

    /// @notice Withdraw the funds to contract owner
    function withdraw() external onlyOwner {
        require(address(this).balance > 0, "zero balance in the contract");
        bool success;
        address payable to = payable(msg.sender);
         require(to != address(0),"invalid address");
        (success, ) = to.call{value: address(this).balance}(new bytes(0));
        require(success, "withdrawal failed");
    }

    /// @notice Update the WrappedNative Token Address
    /// @param wrappedNativeTokenArg Native ERC20 Address
    function updateWrappedNativeToken(address wrappedNativeTokenArg)
        external
        onlyOwner
    {
        require(
            wrappedNativeTokenArg != address(0) &&
                wrappedNativeTokenArg != wrappedNativeToken,
            "Invalid WrappedNativeToken Address"
        );
        wrappedNativeToken = wrappedNativeToken;
    }

    /// @notice Update the PriceFeed Address
    /// @param priceFeedAddressArg PriceFeed Contract Address
    function updatePriceFeedAddress(address priceFeedAddressArg)
        external
        onlyOwner
    {
        require(
            priceFeedAddressArg != address(0) &&
                priceFeedAddressArg != priceFeedAddress,
            "Invalid PriceFeed Address"
        );
        priceFeedAddress = priceFeedAddressArg;
    }

    /// @notice Update the admin Address
    /// @param adminAddressArg Admin Address
    function updateAdminAddress(address adminAddressArg) external onlyOwner {
        require(
            adminAddressArg != address(0) && adminAddressArg != adminAddress,
            "Invalid Admin Address"
        );
        emit AdminAddressUpdated(adminAddress,adminAddressArg);
        adminAddress = adminAddressArg;
    }

    /// @notice Update the platform Address
    /// @param platformAddressArg The Platform Address
    function updatePlatformAddress(address platformAddressArg)
        external
        onlyOwner
    {
        require(
            platformAddressArg != address(0) &&
                platformAddressArg != platformAddress,
            "Invalid Platform Address"
        );
        platformAddress = payable(platformAddressArg);
    }

    /// @notice Update the Platform Fee Percentage
    /// @param platformFeePercentageArg The Platform fee percentage
    function updatePlatformFeePercentage(uint256 platformFeePercentageArg)
        external
        onlyOwner
    {
        require(
            platformFeePercentageArg < 10000,
            "platformFee should not be more than 100 %"
        );
        platformFeePercentage = platformFeePercentageArg;
    }

    /// @notice Update the Royalty Registry Address
    /// @param royaltyRegistryAddressArg The Royalty Registry Address
    function updateRoyaltyRegistryAddress(address royaltyRegistryAddressArg)
        external
        onlyOwner
    {
        require(
            royaltyRegistryAddressArg != address(0) &&
                royaltyRegistryAddressArg != royaltyRegistryAddress,
            "Invalid Royalty Registry Address"
        );
        royaltyRegistryAddress = royaltyRegistryAddressArg;
    }

    /// @notice Update the Royalty Active Status
    /// @param royaltyStatusArg The Royalty Active Status true or false
    function updateRoyaltyActive(bool royaltyStatusArg) external onlyOwner {
        royaltyActive = royaltyStatusArg;
    }

    /// @notice Get the Royalty Info Details against the collection and TokenID
    /// @param collectionAddress The Collection Address of the token
    /// @param tokenId The TokenId value
    function getRoyaltyInfo(address collectionAddress, uint256 tokenId)
        external
        view
        returns (address payable[] memory recipients, uint256[] memory bps)
    {
        require(royaltyActive, "The Royalty Address is inactive.");
        (
            recipients,
            bps // Royalty amount denominated in basis points
        ) = IRoyaltyEngine(royaltyRegistryAddress).getRoyalty(
            collectionAddress,
            tokenId
        );
    }

    receive() external payable {}

    fallback() external payable {}
}