// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title AggregatorV3Interface
/// @notice Minimal Chainlink price feed interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title MockAggregator
/// @notice A simple mock Chainlink aggregator for testing.
contract MockAggregator is AggregatorV3Interface, Ownable {
    uint8  private _decimals;
    int256 private _price;
    uint256 public updatedAt; // FIX: Store timestamp in state

    constructor(int256 initialPrice, uint8 dec) Ownable(msg.sender) {
        _price    = initialPrice;
        _decimals = dec;
        updatedAt = block.timestamp; // FIX: Initialize timestamp
    }

    function setPrice(int256 newPrice) external onlyOwner {
        _price = newPrice;
        updatedAt = block.timestamp; // FIX: Update timestamp
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        )
    {
        // FIX: Return the state variable instead of subtracting from current time
        return (1, _price, 0, updatedAt, 1);
    }
}

/// @title PriceOracle
/// @notice Wraps Chainlink price feeds and normalises prices to 18-decimal USD values.
///         A manual fallback price can also be set by the owner for assets without feeds.
contract PriceOracle is Ownable {
    /// @notice Maps asset address → Chainlink aggregator
    mapping(address => AggregatorV3Interface) public priceFeeds;

    /// @notice Fallback manual prices (18 decimals) for assets without a feed
    mapping(address => uint256) public manualPrices;

    /// @notice Maximum age (in seconds) of an acceptable oracle answer
    uint256 public constant MAX_ORACLE_FRESHNESS = 1 hours;

    event FeedSet(address indexed asset, address feed);
    event ManualPriceSet(address indexed asset, uint256 price);

    constructor() Ownable(msg.sender) {}

    /// @notice Register (or replace) a Chainlink feed for an asset.
    function setFeed(address asset, address feed) external onlyOwner {
        require(asset != address(0), "Oracle: zero asset");
        require(feed  != address(0), "Oracle: zero feed");
        priceFeeds[asset] = AggregatorV3Interface(feed);
        emit FeedSet(asset, feed);
    }

    /// @notice Set a manual USD price (18 decimals) for an asset.
    ///         Used as fallback when no feed is registered or as mock override.
    function setManualPrice(address asset, uint256 priceUsd18) external onlyOwner {
        require(asset != address(0), "Oracle: zero asset");
        manualPrices[asset] = priceUsd18;
        emit ManualPriceSet(asset, priceUsd18);
    }

    /// @notice Returns the USD price of `asset` normalised to 18 decimal places.
    ///         Prefers the Chainlink feed if registered; falls back to manual price.
    /// @param asset  ERC20 token address.
    /// @return price  Asset USD price with 18 decimals (e.g. 1 ETH = 2000e18).
    function getPrice(address asset) external view returns (uint256 price) {
       AggregatorV3Interface feed = priceFeeds[asset];

        if (address(feed) != address(0)) {
            (, int256 answer, , uint256 updatedAt,) = feed.latestRoundData();

            require(answer > 0, "Oracle: non-positive price");

            uint256 unsignedAnswer = uint256(answer);
            require(
                block.timestamp - updatedAt <= MAX_ORACLE_FRESHNESS,
                "Oracle: stale price"
            );

            uint8 dec = feed.decimals();

            if (dec <= 18) {
                return unsignedAnswer * (10 ** (18 - dec));
            } else {
                return unsignedAnswer / (10 ** (dec - 18));
            }
        }
        // Fallback to manual price
        price = manualPrices[asset];
        require(price > 0, "Oracle: price not available");
    }
}