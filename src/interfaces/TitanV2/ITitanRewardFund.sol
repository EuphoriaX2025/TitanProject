// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import "libraries/TitanV2/TitanDataTypes.sol";
import "interfaces/IEvents.sol";  // Assuming IEvents contains the necessary event definitions



/**
 * @title ITitanRewardFund Interface
 * @notice اینترفیس عمومی برای تعامل با قرارداد Titan_RewardFund.
 * @dev نسخه 3.5.0 - افزودن تابع notifyGroupReactivation برای مدیریت فعال‌سازی مجدد گروه‌ها.
 */
interface ITitanRewardFund is
    ITitanEventsReward // Assuming inheritance from a dedicated events interface
{
    function notifyNewUserRegistration(address _user, address _referrer, uint256 _depth) external;

    function notifyStarPointGeneration(
        uint256 _packageId,
        address _user,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        uint256 _shareCount
    ) external;

    function notifyBusinessPackageActivation(
        uint256 _packageId,
        address _activator,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        uint256 _shareCount
    ) external;

    /**
     * @notice (تابع جدید نسخه 3.5.0) برای اطلاع‌رسانی در مورد فعال‌سازی مجدد یک گروه منقضی شده.
     * @dev این تابع به RewardFund اجازه می‌دهد تا منطق خاص خود را (مثلاً عدم تخصیص امتیاز به آپلاین‌ها) پیاده‌سازی کند.
     * @param _packageId شناسه پکیجی که فعال شده است.
     * @param _user آدرس کاربری که گروه را مجدداً فعال کرده است.
     * @param _groupIdx ایندکس گروهی که مجدداً فعال شده است.
     * @param _packageType نوع پکیج فعال شده.
     * @param _shareCount تعداد سهام تولید شده توسط پکیج.
     */
    function notifyGroupReactivation(
        uint256 _packageId,
        address _user,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        uint256 _shareCount
    ) external;

    function notifyRoyalStatusRevoked(address _royalAddress) external;

    /**
     * @notice آدرس استخر هفتگی فعال را برمی‌گرداند.
     * @dev این تابع توسط Titan_Register برای واریز وجوه استفاده می‌شود.
     */
    function getActiveRewardPool() external view returns (address);

    function pointRelayQueue(uint256 index)
        external
        view
        returns (uint256 originatingPackageId, address lastRecipient, uint8 groupIdx, uint256 points);
}
