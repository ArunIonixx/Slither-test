// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;
import {IPriceFeed} from "./../interfaces/IPriceFeed.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PriceFeed is IPriceFeed {
    mapping(address => AggregatorV3Interface) internal priceFeed;

    /// @param priceFeedAddress List of Chainlink Aggregator Address
    /// @param currencyAddress List of ERC20 Currency Address
    constructor(
        address[] memory priceFeedAddress,
        address[] memory currencyAddress
    ) {
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

    /// @notice Getting the latestprice for the given currencyAddress
    /// @param currencyAddress ERC20 Currency Address
    function getLatestPrice(address currencyAddress)
        external
        view
        override
        returns (int256, uint8)
    {
        (, int256 price, , , ) = priceFeed[currencyAddress].latestRoundData();
        uint8 roundId = priceFeed[currencyAddress].decimals();
        return (price, roundId);
    }

    /// @notice Update the currencyAddress with respective priceFeedAddress
    /// @param priceFeedAddress List of Chainlink Aggregator Address
    /// @param currencyAddress List of ERC20 Currency Address
    function updatePriceFeedAddress(
        address[] memory priceFeedAddress,
        address[] memory currencyAddress
    ) external override {
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
}
