// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../libraries/TitanV2/TitanDataTypes.sol";

interface ITitanCapitalFund {
    function notifyPackageActivation(
        uint256 _packageId,
        address _user,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        uint256 _erxPrice,
        uint256 _shareCount,
        bool _isBusiness
    ) external;

    function notifyRoyalStatusRevoked(address _royalAddress) external;

    function isPackageSettled(uint256 _packageId) external view returns (bool);

    /**
     * @notice (تابع جدید نسخه 3.3.0) آدرس استخر ماهانه فعال را برمی‌گرداند.
     * @dev این تابع توسط Titan_Register برای واریز وجوه استفاده می‌شود.
     */
    function getActiveCapitalPool() external view returns (address);
}
