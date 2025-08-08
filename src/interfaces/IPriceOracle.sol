// SPDX-License-Identifier: MIT
// Version: 1.0.0
// File: ./interfaces/IPriceOracle.sol

pragma solidity ^0.8.20;

/**
 * @title IPriceOracle Interface
 * @notice A standardized interface for price oracles within the Titan ecosystem.
 * @dev Any contract providing price data must implement this interface.
 */
interface IPriceOracle {
    /**
     * @notice Returns the latest price of an asset, normalized to 18 decimals (e.g., for USD value).
     * @return price The latest price with 18 decimals.
     */
    function getLatestPrice() external view returns (uint256 price);
}