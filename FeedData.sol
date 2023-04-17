// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract FeedData {
    /// mapping of chainfeed address with currency address
    mapping(address => AggregatorV3Interface) internal priceFeed;

    /// mapping of currencyaddress with heartbeat time
    mapping(address => uint256) internal timeInterval;

    // Address of the owner
    address public immutable owner;

    // Address of the Admin
    address public admin;

    /// @param priceFeedAddress List of Chainlink Aggregator Address
    /// @param currencyAddress List of ERC20 Currency Address
    constructor(
        address[] memory priceFeedAddress,
        address[] memory currencyAddress,
        uint256[] memory heartbeat,
        address _admin
    ) {
        require(
            priceFeedAddress.length == currencyAddress.length &&
                priceFeedAddress.length == heartbeat.length,
            "Arrays must have the same length"
        );
        for (uint256 i = 0; i < priceFeedAddress.length; i++) {
            priceFeed[currencyAddress[i]] = AggregatorV3Interface(
                priceFeedAddress[i]
            );
            timeInterval[currencyAddress[i]] = heartbeat[i];
        }
        owner = msg.sender;
        admin = _admin;
    }

    /// @notice Getting the latestprice for the given currencyAddress
    /// @param fiat ERC20 Currency Address
    /// @param amount conversion amount in usd
    function getLatestPrice(uint256 amount, address fiat)
        external
        view
        returns (uint256 value)
    {
        require(
            priceFeed[fiat] != AggregatorV3Interface(address(0)),
            "ChainlinkFeed is not available. Please provide valid chainlink supported ERC20 address"
        );
        // getting the latest chainfeed price
        (, int256 price, , , uint256 updatedAt) = priceFeed[fiat]
            .latestRoundData();
        // checking of heartbeat
        require(timeInterval[fiat] != 0, "update heartbeat for the currency");
        require(
            block.timestamp <= (updatedAt + timeInterval[fiat]),
            "chainfeed data not updated in derived time"
        );
        // conversion of chainfeed value to wei
        uint256 USDinCRYPTO = ((amount * 10**26) / (uint256(price)));

        return USDinCRYPTO;
    }

    /// @notice Update the currencyAddress with respective priceFeedAddress
    /// @param priceFeedAddress List of Chainlink Aggregator Address
    /// @param currencyAddress List of ERC20 Currency Address
    function updatePriceFeedAddress(
        address[] memory priceFeedAddress,
        address[] memory currencyAddress
    ) external {
        require(
            msg.sender == admin || msg.sender == owner,
            "should be called by owner or admin"
        );
        require(
            priceFeedAddress.length == currencyAddress.length,
            "Arrays must have the same length"
        );
        for (uint256 i = 0; i < priceFeedAddress.length; i++) {
            priceFeed[currencyAddress[i]] = AggregatorV3Interface(
                priceFeedAddress[i]
            );
        }
    }

    /// @notice Update the heartBeat with respective priceFeedAddress
    /// @param currencyAddress List of ERC20 Currency Address
    /// @param heartBeat timeinterval to check the feed updation
    function updateheartbeat(address currencyAddress, uint256 heartBeat)
        external
    {
        require(
            msg.sender == admin || msg.sender == owner,
            "should be called by owner or admin"
        );
        timeInterval[currencyAddress] = heartBeat;
    }
}
