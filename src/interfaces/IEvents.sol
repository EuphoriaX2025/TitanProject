// SPDX-License-Identifier: MIT
// Version: 2.0.0
// File: ./interfaces/IEvents.sol

pragma solidity ^0.8.20;

import "libraries/TitanV2/TitanDataTypes.sol";


/**
 * @title IEvents Interface
 * @author Dr. Satoshi Arcanum & Kamyar
 * @notice A unified interface containing all events for the Titan ecosystem.
 * @dev v2.0.0: Consolidated all event interfaces into one, indexed critical parameters,
 * and optimized event signatures for clarity and efficiency.
 */
interface IEvents {
    // =================================================================
    // |                       Global & DAO Events                     |
    // =================================================================
    event DaoAddressChanged(address indexed oldDao, address indexed newDao);
    // +++ IMPROVEMENT: Using enum instead of string for type safety and gas efficiency +++
    event SystemAddressChanged(TitanDataTypes.AddressType indexed addressType, address indexed newAddress);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event Paused(address account);
    event Unpaused(address account);

    // =================================================================
    // |                     Titan_Register Events                     |
    // =================================================================
    event UserRegistered(address indexed user, address indexed referrer, uint256 userId, uint256 timestamp);
    event PackageActivated(address indexed user, uint256 indexed packageId, string packageCode, uint8 groupIdx, TitanDataTypes.PackageType pkgType, bool isBusiness, uint256 timestamp);
    event UserStatusUpdated(address indexed user, TitanDataTypes.UserStatus newStatus, uint256 dueDate);
    event RoyalAdded(address indexed user);
    event RoyalRemoved(address indexed user);
    event UserCleaned(address indexed user, address indexed parent, uint256 userId);
    // +++ IMPROVEMENT: Indexed all pool addresses for better filterability +++
    event FundsDistributed(address indexed capitalPool, uint256 capitalAmount, address indexed rewardPool, uint256 rewardAmount, address indexed supportFund, uint256 supportAmount, address indexed updateFund, uint256 updateAmount);
    event FundTransferFailed(address indexed target, uint256 amount, uint256 timestamp);
    event PackageCodeGenerated(address indexed owner, string packageCode, uint256 indexed packageId, uint256 shareCount, uint256 cumulativeShares);
    event UserFlaggedForCleanup(address indexed user, uint256 cleanupTimestamp);

    // =================================================================
    // |                    Titan_RewardFund Events                    |
    // =================================================================
    event RFTsGenerated(address indexed user, uint8 indexed groupIndex, uint256 balanceCount, uint256 totalShares, uint256 weekId);
    event WeekPriced(uint256 indexed weekId, uint256 pricePerShareUSD, uint256 totalShares, uint256 totalErxValue);
    event RFTsClaimed(address indexed user, uint256 totalShares, uint256 totalUsdValue, uint256 erxPaidOut, uint256 qbitFee);
    // +++ IMPROVEMENT: Added missing events from contract logic +++
    event UserCapUpgraded(address indexed user, uint8 indexed groupIdx, TitanDataTypes.PackageType packageType);
    event PendingPointsClaimed(address indexed user, uint8 indexed groupIdx, uint256 leftPoints, uint256 rightPoints);
    event StarPointCached(address indexed user, uint8 indexed groupIdx, uint256 points, uint8 position);
    event RawPointsExpired(address indexed user, uint8 indexed groupIdx, uint256 amount, uint256 leg);
    event WeekClaimPeriodClosed(uint256 indexed weekId, uint256 remainingBalance);
    event MonsterAwardQualified(address indexed user, TitanDataTypes.MonsterAwardStatus status, uint256 totalAward);
    event MonsterAwardClaimed(address indexed user, uint256 installmentAmount);
    event GroupReactivated(uint256 indexed packageId, address indexed user, uint8 indexed groupIndex);
    event WeekManuallyPriced(uint256 indexed weekId, uint256 pricePerShareUSD, address indexed setter);

    // =================================================================
    // |                   Titan_CapitalFund Events                    |
    // =================================================================
    event PackageCreated(uint256 indexed packageId, address indexed owner, uint8 packageTypeId, uint256 initialShares);
    event CFTMonthPriced(uint32 indexed monthId, uint256 pricePerShareUSD, uint256 totalErx, uint256 totalShares);
    event PackageClaimed(uint256 indexed packageId, uint32 indexed monthId, uint256 sharesBurned, uint256 usdValueClaimed, uint256 erxPaid);
    event PackageSettled(uint256 indexed packageId, address indexed owner);
    // +++ IMPROVEMENT: Added missing events from contract logic +++
    event CFTsRenewed(uint256 indexed packageId, uint32 indexed newMonthId, uint256 sharesCreated);
    event UnclaimedCapitalSwept(uint32 indexed fromMonthId, uint32 indexed toMonthId, uint256 amountSwept);
    event PackageTypeCompletionIncremented(address indexed user, uint8 indexed packageTypeId, uint8 newCount);

    // =================================================================
    // |                   Titan_SupportFund Events                    |
    // =================================================================
    event PeriodValuationProcessed(address indexed sourceContract, bool indexed isSupport, uint256 amountErx);
    event FundsDeposited(address indexed from, address indexed token, uint256 amount);

    // =================================================================
    // |                   Qbit Events                                 |
    // =================================================================
    event QBIT_MigrationCompleted(
        uint256 timestamp, 
        address indexed newContract, 
        uint256 soldAmount, 
        uint256 purchaseUsers, 
        uint256 lockUsers
    );

    // =================================================================
    // |                   EuphoriaX (erx) Events                      |
    // =================================================================
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event UserDataMigrated(address indexed user, address indexed to, uint256 timestamp);
    event UserMigrationFailed(address indexed user, address indexed to, string reason, uint256 timestamp);
}