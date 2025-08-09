// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEuphoriaXMigrator {
    enum WhaleType { None, Small, Medium, Large }

    struct UserActivity {
        uint256 totalBalance;
        uint256 consecutiveTxCount;
        uint256 txCountInMinute;
        uint256 lastMinuteReset;
        uint256 lastTxTimestamp;
        uint256 hourlyTxCount;
        uint256 lastHourlyReset;
        uint256 penaltyEndTime;
        uint256 lastPenaltyReset;
        uint256 violationCount;
        uint8 violationLevel;
    }

    struct WhaleInfo {
        WhaleType whaleType;
        uint256 firstHoldTimestamp;
        uint256 lastTxTimestamp;
        uint256 hourlyTxCount;
        uint256 lastHourlyReset;
        uint256 dailyVolume;
        uint256 lastDailyReset;
        uint256 dailyTxCount;
        uint256 weeklyVolumeAmount;
        uint256 lastWeeklyReset;
        uint256 weeklyViolationCount;
        uint256 penaltyEndTime;
        uint256 consecutiveTxCount;
    }

    function receiveMigratedUserData(
        address user,
        UserActivity memory userActivity,
        WhaleInfo memory whaleInfo,
        bool isInvestor,
        bool isWhitelisted,
        uint256 erxBalance
    ) external;

    function receiveMigratedUpdateFundTokens(uint256 amount, address who) external;
    function receiveMigratedERXTokens(address user, uint256 amount) external;
    function setMigrationSource(address source) external;
    function finalizeMigration() external;
}