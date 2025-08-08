// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IEuphoriaX is IERC20 {
    function getCurrentPrice() external view returns (uint256);
    function getMigrationStatus()
        external
        view
        returns (
            uint256 totalUsers,
            uint256 totalWhales,
            bool migrationAnnounced,
            address migrationTarget,
            uint256 timeRemaining,
            bool routerMigrationInProgress
        );
}