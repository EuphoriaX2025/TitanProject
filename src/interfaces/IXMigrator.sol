// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct WhaleInfo {}

interface IEuphoriaXMigrator {
    function receiveMigratedUserData(
        address user,
        EuphoriaX.UserActivity memory userActivityData,
        EuphoriaX.WhaleInfo memory whaleInfoData,
        bool userIsInvestor,
        bool userIsWhitelisted,
        uint256 userERXBalance
    ) external;
}