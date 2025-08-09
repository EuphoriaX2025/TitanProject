// SPDX-License-Identifier: MIT
// Version: 1.0.0
// File: ./libraries/TitanDataTypes.sol

pragma solidity ^0.8.20;

library TitanDataTypes {
    enum UserStatus {
        Free,
        Active,
        Inactive,
        Blocked,
        Royal,
        Queen
    }

    enum PackageType {
        Classic,
        VIP,
        Royal
    }

    struct User {
        uint256 userId;
        address parentAddress;
        address[2] directChildrenAddresses;
        uint8 directChildrenCount;
        uint8 positionInParentLeg;
        uint256 depth;
        bytes32 pathHash;
        UserStatus status;
        uint256 registrationTimestamp;
        uint256 statusTransitionDueDate;
        uint256 packagePurchaseLimitResetDueDate;
        uint8 currentPurchaseCountInPeriod;
        uint256 leftLegSubtreeCount;
        uint256 rightLegSubtreeCount;
        bool isQueen;
        bool isFlaggedForCleanup;
        uint256 cleanupDueTimestamp;
    }

    struct UserBasicInfo {
        uint256 userId;
        UserStatus status;
        uint256 registrationTimestamp;
        uint256 statusTransitionDueDate;
        uint256 packagePurchaseLimitResetDueDate;
        uint8 currentPurchaseCountInPeriod;
    }

    struct UserTreeInfo {
        address parentAddress;
        uint8 positionInParentLeg;
        uint256 depth;
        bytes32 pathHash;
        uint8 directChildrenCount;
        address[2] directChildrenAddresses;
        uint256 leftLegSubtreeCount;
        uint256 rightLegSubtreeCount;
    }

    struct UserStatusInfo {
        bool isQueen;
        bool isFlaggedForCleanup;
        uint256 cleanupDueTimestamp;
    }

    // Optional combined struct if we want all user info in one call
    struct UserFullInfo {
        UserBasicInfo basic;
        UserTreeInfo tree;
        UserStatusInfo status;
    }

    struct LeanPackageInfo {
        address owner;
        uint64 activationTimestamp;
        uint8 groupIdx;
        PackageType pkgType;
        bool isSettledInCapitalFund;
    }

    struct PackageActivationInput {
        string packageSymbol;
        uint8 count;
    }

    struct UplineInfo {
        address userAddress;
        UserStatus status;
        bool isGroupActive;
    }

    struct PackageConfig {
        uint8 packageTypeId;
        uint8 groupId;
        uint8 initialShares;
        uint256 monthlyLimitUSD;
        uint256 totalLimitUSD;
    }
}

enum AddressType {
        Router,
        SupportFund,
        UpdateFund,
        DAO
    }
}