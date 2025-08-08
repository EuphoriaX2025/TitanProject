// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "interfaces/IRouter.sol";
import "interfaces/IEuphoriaX.sol";
import "interfaces/IQbit.sol";
import "TitanV2/ITitanRegister.sol";
import "libraries/TitanV2/TitanDataTypes.sol";

library TitanHelper {
    // ثابت‌ها
    uint256 constant WEEK = 7 days;
    uint256 constant MONTH_DURATION = 30 days;
    uint256 constant CLAIM_EXPIRATION = 7 days; // فرصت 7 روزه برای برداشت
    uint256 constant INACTIVITY_THRESHOLD = 180 days; // غیرفعال شدن بعد از 180 روز

    enum PackageType {
        Classic,
        VIP,
        None
    }

    function getERXPrice(address _router) internal view returns (uint256) {
        address euphoriaContractAddress = IRouter(_router).getEuphoriaContract();
        uint256 price = IEuphoriaX(euphoriaContractAddress).getCurrentPrice();
        require(price > 0 && price >= 1e17, "TH: Invalid ERX price");
        return price;
    }

    function getQbitPrice(address _router) internal view returns (uint256) {
        uint256 stageNumber = getQBitCurrentStage(_router);
        address qbitContractAddress = IRouter(_router).getQbitToken();
        uint256 price = IQbit(qbitContractAddress).stagePrices(stageNumber);
        // !note: uncomment this in prod  require(price >= 20e18 && price <= 32e18, "TH: Invalid QBit price");
        return price;
    }

    function getQBitCurrentStage(address _router) internal view returns (uint256 currentStage) {
        address qbitContractAddress = IRouter(_router).getQbitToken();
        uint256 soldInitAmt = IQbit(qbitContractAddress).soldInitialAmount();
        bool isPhaseFiveExtended = IQbit(qbitContractAddress).isPhaseFiveExtended();
        currentStage = isPhaseFiveExtended ? 4 : soldInitAmt / (10_000 * 10 ** 18);
        require(currentStage >= 0 && currentStage < 5, "TH: Invalid QBit stage");
    }

    function isContract(address _addr) internal view returns (bool) {
        return _addr.code.length > 0;
    }

    function getWeekMonthYear(uint256 _timestamp) internal pure returns (uint256 week, uint256 month, uint256 year) {
        week = (_timestamp / WEEK) + 1;
        month = (_timestamp / MONTH_DURATION) + 1;
        year = (_timestamp / (365 days)) + 1970;
    }

    // دریافت زمان شروع ماه جاری
    function getCurrentMonthStart() internal view returns (uint256) {
        return (block.timestamp / MONTH_DURATION) * MONTH_DURATION;
    }

    // دریافت زمان شروع ماه بعدی
    function getNextMonthStart(uint256 _timestamp) internal pure returns (uint256) {
        return ((_timestamp / MONTH_DURATION) + 1) * MONTH_DURATION;
    }

    function getPreviousMonthStart(uint256 _monthStart) internal pure returns (uint256) {
        return ((_monthStart / MONTH_DURATION) + 1) * MONTH_DURATION;
    }

    function getMonthlyCapUSD(uint8 _group, uint8 _type) internal pure returns (uint256) {
        if (_group == 1) return _type == uint8(PackageType.Classic) ? 4 * 1e6 : 5 * 1e6;
        if (_group == 2) return _type == uint8(PackageType.Classic) ? 6 * 1e6 : 12.5 * 1e6;
        if (_group == 3) return _type == uint8(PackageType.Classic) ? 20 * 1e6 : 25 * 1e6;
        if (_group == 4) return _type == uint8(PackageType.Classic) ? 40 * 1e6 : 50 * 1e6;
        if (_group == 5) return _type == uint8(PackageType.Classic) ? 75 * 1e6 : 120 * 1e6;
        if (_group == 6) return _type == uint8(PackageType.Classic) ? 125 * 1e6 : 200 * 1e6;
        if (_group == 7) return _type == uint8(PackageType.Classic) ? 250 * 1e6 : 450 * 1e6;
        return 0;
    }

    function getTotalCapUSD(uint8 _group, uint8 _type) internal returns (uint256) {
        if (_group == 1) return _type == uint8(PackageType.Classic) ? 12 * 1e6 : 30 * 1e6;
        if (_group == 2) return _type == uint8(PackageType.Classic) ? 36 * 1e6 : 75 * 1e6;
        if (_group == 3) return _type == uint8(PackageType.Classic) ? 60 * 1e6 : 150 * 1e6;
        if (_group == 4) return _type == uint8(PackageType.Classic) ? 120 * 1e6 : 300 * 1e6;
        if (_group == 5) return _type == uint8(PackageType.Classic) ? 450 * 1e6 : 1080 * 1e6;
        if (_group == 6) return _type == uint8(PackageType.Classic) ? 750 * 1e6 : 1800 * 1e6;
        if (_group == 7) return _type == uint8(PackageType.Classic) ? 1500 * 1e6 : 4000 * 1e6;
        return 0;
    }

    function calculateRFTShares(uint256 balancedPoints, uint8 groupIdx) internal pure returns (uint256) {
        uint256 rftShares;
        if (groupIdx == 1) rftShares = balancedPoints * 1;
        else if (groupIdx == 2) rftShares = balancedPoints * 3;
        else if (groupIdx == 3) rftShares = balancedPoints * 5;
        else if (groupIdx == 4) rftShares = balancedPoints * 10;
        else if (groupIdx == 5) rftShares = balancedPoints * 30;
        else if (groupIdx == 6) rftShares = balancedPoints * 50;
        else if (groupIdx == 7) rftShares = balancedPoints * 100;
        return rftShares * 1e18;
    }

    function getDailyRFTCap(address _titanRegistration, address _user, uint8 _group) internal view returns (uint256) {
        uint8 userPackageType = ITitanRegistration(_titanRegistration).getPackageType(_user, uint8(_group));

        if (PackageType(userPackageType) == PackageType.Classic) {
            if (_group == 1) return 10;
            if (_group == 2) return 25;
            if (_group == 3) return 45;
            if (_group == 4) return 90;
            if (_group == 5) return 260;
            if (_group == 6) return 450;
            if (_group == 7) return 850;
        } else if (PackageType(userPackageType) == PackageType.VIP) {
            if (_group == 1) return 30;
            if (_group == 2) return 85;
            if (_group == 3) return 130;
            if (_group == 4) return 300;
            if (_group == 5) return 750;
            if (_group == 6) return 1750;
            if (_group == 7) return 3500;
        }
        return 0;
    }

    function getWeeklyIncomeCap(address _titanRegistration, address _user, uint8 _group)
        internal
        view
        returns (uint256)
    {
        uint8 userPackageType = ITitanRegistration(_titanRegistration).getPackageType(_user, uint8(_group));
        if (PackageType(userPackageType) == PackageType.Classic) {
            if (_group == 1) return 100;
            if (_group == 2) return 300;
            if (_group == 3) return 500;
            if (_group == 4) return 1000;
            if (_group == 5) return 3000;
            if (_group == 6) return 5000;
            if (_group == 7) return 10000;
        } else if (PackageType(userPackageType) == PackageType.VIP) {
            if (_group == 1) return 350;
            if (_group == 2) return 950;
            if (_group == 3) return 1500;
            if (_group == 4) return 3500;
            if (_group == 5) return 8500;
            if (_group == 6) return 20000;
            if (_group == 7) return 45000;
        }
        return 0;
    }

    // دریافت CFT پایه برای هر گروه
    function getCFTPerMonth(uint8 _group) internal pure returns (uint256) {
        if (_group == 1) return 1;
        if (_group == 2) return 3;
        if (_group == 3) return 5;
        if (_group == 4) return 10;
        if (_group == 5) return 30;
        if (_group == 6) return 50;
        if (_group == 7) return 100;
        return 0;
    }

    function getCFTWithDecay(uint256 _baseCFT, uint256 _activationCount) internal pure returns (uint256) {
        if (_activationCount <= 1) return _baseCFT;
        uint256 decay = (_activationCount - 1) * 10;
        if (decay > 70) decay = 70; // حداکثر کاهش 70%
        return (_baseCFT * (100 - decay)) / 100;
    }

    function getRFTFromBalance(uint8 _group, uint256 _balance) internal pure returns (uint256) {
        if (_group == 1) return _balance * 1;
        if (_group == 2) return _balance * 3;
        if (_group == 3) return _balance * 5;
        if (_group == 4) return _balance * 10;
        if (_group == 5) return _balance * 30;
        if (_group == 6) return _balance * 50;
        if (_group == 7) return _balance * 100;
        return 0;
    }

    function getStarAmount(uint8 _group) internal pure returns (uint256) {
        if (_group == 1) return 1;
        if (_group == 2) return 1;
        if (_group == 3) return 1;
        if (_group == 4) return 1;
        if (_group == 5) return 1;
        if (_group == 6) return 1;
        if (_group == 7) return 1;
        return 0;
    }

    function generateRFTId(address _user, uint8 _group) internal view returns (string memory) {
        return string(
            abi.encodePacked("RFT", uint2str(_group), "S_", uint2str(block.timestamp), substring(toHex(_user), 2, 6))
        );
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k--;
            bstr[k] = bytes1(uint8(48 + (_i % 10)));
            _i /= 10;
        }
        return string(bstr);
    }

    function toHex(address _addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(_addr);
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            buffer[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            buffer[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(buffer);
    }

    /**
     * @notice Converts a Unix timestamp to date components (year, month, day).
     * @param timestamp The Unix timestamp.
     * @return year The corresponding year.
     * @return month The corresponding month.
     * @return day The corresponding day.
     */
    function timestampToDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 daysSinceEpoch = timestamp / (24 * 60 * 60);
        uint256 L = daysSinceEpoch + 68569;
        uint256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        uint256 I = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * I) / 4 + 31;
        uint256 J = (80 * L) / 2447;
        day = L - (2447 * J) / 80;
        L = J / 11;
        month = J + 2 - 12 * L;
        year = 100 * (N - 49) + I + L;
    }

    function substring(string memory _str, uint256 _start, uint256 _end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(_str);
        bytes memory result = new bytes(_end - _start);
        for (uint256 i = _start; i < _end; i++) {
            result[i - _start] = strBytes[i];
        }
        return string(result);
    }

    /**
     * @notice A utility function to get the package type ID.
     * @dev This can be used consistently across contracts to derive a unique ID for a package configuration.
     * @param _groupIdx The group index of the package.
     * @param _pkgType The type of the package (e.g., Classic, VIP).
     * @return A unique identifier for the package type.
     */
    function getPackageTypeId(uint8 _groupIdx, TitanDataTypes.PackageType _pkgType) internal pure returns (uint8) {
        // A simple formula to generate a unique ID. Max groupIdx is 7, max pkgType is ~3.
        // This ensures no collisions. e.g., G1C=1, G1V=2, G2C=3, G2V=4...
        return (_groupIdx - 1) * 4 + (uint8(_pkgType) + 1);
    }

    /**
     * @notice Converts a given USD value to the equivalent amount of a specified token.
     * @dev Fetches the token's oracle from the router to get the latest price for conversion.
     * @param _router The address of the ITitanRouter compliant router contract.
     * @param _usdAmount The USD value with 18 decimals.
     * @return tokenAmount The calculated amount of the token with 18 decimals.
     */
    function convertUSDToSingleToken(address _router, uint256 _usdAmount, string memory _tokenSymbol)
        internal
        view
        returns (uint256 tokenAmount)
    {
        if (keccak256(abi.encodePacked(_tokenSymbol)) == keccak256(abi.encodePacked("ERX"))) {
            uint256 erxPrice = getERXPrice(_router);
            require(erxPrice > 0, "TH:: Invalid erx price");
            return (_usdAmount * 1e18) / erxPrice;
        } else if (keccak256(abi.encodePacked(_tokenSymbol)) == keccak256(abi.encodePacked("QBIT"))) {
            uint256 qbitPrice = getQbitPrice(_router);
            require(qbitPrice > 0, "TH:: Invalid qbit price");
            return (_usdAmount * 1e18) / qbitPrice;
        } else {
            revert("TH:: Unsupported token");
        }
    }

    /**
     * @notice سقف تولید سهام RFT روزانه را برای یک گروه و نوع پکیج مشخص برمی‌گرداند.
     * @param _groupIdx ایندکس گروه (1-7).
     * @param _pkgType نوع پکیج (Classic یا VIP).
     * @return سقف سهام روزانه با دقت 18 رقم اعشار.
     */
    function getDailyRftShareCap(uint8 _groupIdx, TitanDataTypes.PackageType _pkgType)
        internal
        pure
        returns (uint256)
    {
        // مقادیر مستقیماً از منطق اولیه در RewardFund گرفته شده‌اند.
        if (_groupIdx == 1) return _pkgType == TitanDataTypes.PackageType.Classic ? 10 * 1e18 : 30 * 1e18;
        if (_groupIdx == 2) return _pkgType == TitanDataTypes.PackageType.Classic ? 30 * 1e18 : 90 * 1e18;
        if (_groupIdx == 3) return _pkgType == TitanDataTypes.PackageType.Classic ? 50 * 1e18 : 150 * 1e18;
        if (_groupIdx == 4) return _pkgType == TitanDataTypes.PackageType.Classic ? 100 * 1e18 : 300 * 1e18;
        if (_groupIdx == 5) return _pkgType == TitanDataTypes.PackageType.Classic ? 300 * 1e18 : 900 * 1e18;
        if (_groupIdx == 6) return _pkgType == TitanDataTypes.PackageType.Classic ? 500 * 1e18 : 2000 * 1e18;
        if (_groupIdx == 7) return _pkgType == TitanDataTypes.PackageType.Classic ? 1000 * 1e18 : 5000 * 1e18;
        return 0;
    }

    /**
     * @notice سقف درآمد دلاری هفتگی را برای یک گروه و نوع پکیج مشخص برمی‌گرداند.
     * @param _groupIdx ایندکس گروه (1-7).
     * @param _pkgType نوع پکیج (Classic یا VIP).
     * @return سقف درآمد دلاری هفتگی با دقت 18 رقم اعشار.
     */
    function getWeeklyUsdErxCap(uint8 _groupIdx, TitanDataTypes.PackageType _pkgType) internal pure returns (uint256) {
        // مقادیر مستقیماً از منطق اولیه در RewardFund گرفته شده‌اند.
        if (_groupIdx == 1) return _pkgType == TitanDataTypes.PackageType.Classic ? 100 * 1e18 : 350 * 1e18;
        if (_groupIdx == 2) return _pkgType == TitanDataTypes.PackageType.Classic ? 300 * 1e18 : 950 * 1e18;
        if (_groupIdx == 3) return _pkgType == TitanDataTypes.PackageType.Classic ? 500 * 1e18 : 1500 * 1e18;
        if (_groupIdx == 4) return _pkgType == TitanDataTypes.PackageType.Classic ? 1000 * 1e18 : 3500 * 1e18;
        if (_groupIdx == 5) return _pkgType == TitanDataTypes.PackageType.Classic ? 3000 * 1e18 : 8500 * 1e18;
        if (_groupIdx == 6) return _pkgType == TitanDataTypes.PackageType.Classic ? 5000 * 1e18 : 20000 * 1e18;
        if (_groupIdx == 7) return _pkgType == TitanDataTypes.PackageType.Classic ? 10000 * 1e18 : 45000 * 1e18;
        return 0;
    }
}
