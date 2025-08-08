// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISupportFund Interface
 * @notice رابط برای تعامل با نسخه جدید و متمرکز Titan_SupportFund.
 */
interface ISupportFund {
    /**
     * @notice تابع یکپارچه برای پردازش دوره‌های مالی.
     * @param _totalShares تعداد کل سهام دوره.
     * @param _erxInPool موجودی ERX استخر در ابتدای دوره.
     */
    function processPeriodValuation(uint256 _totalShares, uint256 _erxInPool) external;
}
