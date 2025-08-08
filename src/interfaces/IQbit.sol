// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IQbit is IERC20 {
    function exportFullMigrationData()
        external
        view
        returns (
            address[] memory users,
            uint256[] memory freeBalances,
            uint256 totalSold,
            uint256 currentStage_,
            uint256 totalInvestors_
        );

    function getUserCounts()
        external
        view
        returns (
            uint256 purchaseUserCount,
            uint256 lockUserCount,
            uint256 totalInvestors_
        );

    function addToWhitelist(address contractAddress) external;
    function removeFromWhitelist(address contractAddress) external;

    function getUsersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory users);

    function exportStageConfig()
        external
        view
        returns (uint256[5] memory prices, uint256[5] memory limits);
}