// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "libraries/TitanV2/TitanDataTypes.sol";
import "interfaces/IEvents.sol";

/**
 * @title ITitanRegister Interface
 * @notice اینترفیس عمومی برای تعامل با قرارداد Titan_Register.
 * @dev نسخه 3.6.0 - افزودن تابع getUsersLastPackageTypeInGroup برای استعلام نوع پکیج توسط RewardFund.
 */

interface ITitanRegister {
    // function getUserDetails(address)
    //     external
    //     view
    //     returns (
    //         uint256 userId,
    //         // TitanDataTypes.UserStatus status,
    //         uint256 registrationTimestamp,
    //         uint256 statusTransitionDueDate,
    //         uint256 packagePurchaseLimitResetDueDate,
    //         uint8 currentPurchaseCountInPeriod,
    //         address parentAddress,
    //         uint8 positionInParentLeg,
    //         uint256 depth,
    //         bytes32 pathHash,
    //         uint8 directChildrenCount,
    //         address[2] memory directChildrenAddresses,
    //         uint256 leftLegSubtreeCount,
    //         uint256 rightLegSubtreeCount,
    //         bool isQueen,
    //         bool isFlaggedForCleanup,
    //         uint256 cleanupDueTimestamp
    //     );

    function getUserBasicInfo(address _userAddress) external view returns (TitanDataTypes.UserBasicInfo memory);
    function getUserTreeInfo(address _userAddress) external view returns (TitanDataTypes.UserTreeInfo memory);
    function getUserStatusInfo(address _userAddress) external view returns (TitanDataTypes.UserStatusInfo memory);
    function getUserFullInfo(address _userAddress) external view returns (TitanDataTypes.UserFullInfo memory);

    function getUserStatus(address _userAddress) external view returns (TitanDataTypes.UserStatus);
    function isUserAddressRegistered(address) external view returns (bool);
    function userAddressByUserId(uint256) external view returns (address);
    // function packageInfos(uint256) external view returns (TitanDataTypes.LeanPackageInfo memory);

    function pause() external;
    function unpause() external;
    function setDaoAddress(address _newDaoAddress) external;
    function addRoyal(address _newRoyalAddress) external;
    function removeRoyal(address _royalAddress) external;
    function recoverTokens(address _tokenAddress, address _to, uint256 _amount) external;

    function register(address _referrerAddress) external;
    function activatePackages(TitanDataTypes.PackageActivationInput[] calldata _packages) external;

    function updateUserStatus(address _userAddress) external;
    function cleanupBlockedUsersBatch(uint256 _batchSize) external;
    function removeInactiveChild(address _childAddress) external;

    function getPackagePrice(uint8 _groupIdx, TitanDataTypes.PackageType _packageType)
        external
        view
        returns (uint256 erxAmount, uint256 qbitAmount);
    function isGroupActive(address _user, uint8 _groupIdx) external view returns (bool);
    function getShareCount(uint8 _groupIdx) external pure returns (uint8 shareCount);
    function getPackageOwner(string calldata _packageCode) external view returns (address);
    function getPackageInfo(uint256 _packageId) external view returns (TitanDataTypes.LeanPackageInfo memory);

    function getBatchUplineInfo(address _user, uint8 _groupIdx)
        external
        view
        returns (TitanDataTypes.UplineInfo[30] memory uplines);

    /**
     * @notice (تابع جدید) بالاترین نوع پکیج فعال یک کاربر در یک گروه خاص را برمی‌گرداند.
     * @dev این تابع توسط RewardFund برای ارتقاء سقف درآمدی کاربران استفاده می‌شود.
     * @param _user آدرس کاربر مورد نظر.
     * @param _groupIdx ایندکس گروه مورد نظر.
     * @return PackageType بالاترین نوع پکیج (مثلاً VIP اگر هم Classic و هم VIP فعال باشد).
     */
    function getUsersLastPackageTypeInGroup(address _user, uint8 _groupIdx)
        external
        view
        returns (TitanDataTypes.PackageType);

    function getUserBasicDetails(address _user)
        external
        view
        returns (
            uint256 userId,
            uint256 registrationTimestamp,
            uint256 statusTransitionDueDate,
            uint256 packagePurchaseLimitResetDueDate
        );

    function notifyPackageSettled(address _userAddress, uint256 _packageId) external;

    function getPackageType(address _user, uint8 _group) external view returns (TitanDataTypes.PackageType);
}