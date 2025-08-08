// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IEuphoriaX is IERC20Metadata {
    function getCurrentPrice() external view returns (uint256);
    function ecoBurnFree(uint256 erxAmount, address contractAddress) external;
    function ecoPayFree(uint256 amount, uint256 tokenIndex, address contractAddress) external;
    function burnForStablecoin(uint256 erxAmount, uint256 tokenIndex, address contractAddress) external;

    // DAO functions
    function addToWhitelist(address contractAddress) external;
    function removeFromWhitelist(address contractAddress) external;
    function addStablecoin(address stablecoin) external;
    function removeStablecoin(uint256 index) external;
    function removeStablecoin(address stablecoin) external;
    function convertStablecoins(uint256 fromIndex, uint256 toIndex, uint256 amount) external;
    function convertStableCoin(address stablecoin, uint256 amount) external;

    function emergencyPause() external;
    function emergencyUnpause() external;

    function updateSwapRouter(address newRouter) external;
    function updateRouter(address newTitanRouter) external;
    function updateUpdateFund(address newUpdateFund) external;
    function updateTreasury(address newTreasury) external;
    function updateAddresses() external;

    function mintForMigration(address to, uint256 amount) external;
    function receiveMigrationData(address[] memory users, uint256 totalUsers, uint256 totalWhales) external;
    function setMigrationContract(address migrationContract) external;
}
