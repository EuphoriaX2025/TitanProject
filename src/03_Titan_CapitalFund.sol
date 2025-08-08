// SPDX-License-Identifier: MIT
// /**
//  * @title Titan_CapitalFund Contract (v3.0.0)
//  * @author Kamyar (Concept & Lead) - Dr. Satoshi Arcanum (Architecture & Code)
//  * @notice نسخه نهایی و یکپارچه شده با معماری کل اکوسیستم تایتان.
//  * @dev v3.0.0: افزودن مقادیر پیش‌فرض پکیج‌ها، تابع simulateClaim و منطق ردیابی آمار کلی سیستم.
//  */
pragma solidity ^0.8.20;

import {console} from "forge-std/Test.sol";

// // --- Imports ---
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/TitanV2/ITitanRegister.sol";

import "../../interfaces/IEuphoriaX.sol";
import {ITitanEventsCapital} from "../../interfaces/IEvents.sol";
import "../../interfaces/TitanV2/ISupportFund.sol";
import "../../libraries/TitanV2/TitanDataTypes.sol";
import "../../libraries/TitanHelper.sol";
import "../../interfaces/IRouter.sol";
import "../../libraries/DateTime.sol";

contract Titan_CapitalFund is ReentrancyGuard, Pausable, ITitanEventsCapital {
    using SafeERC20 for IERC20;
    using SafeERC20 for IEuphoriaX;

    // --- Constants ---
    uint256 private constant CFT_CLAIM_FEE_BPS = 150; // 1.5%
    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 private constant FORFEIT_WINDOW_MONTHS = 1;
    uint256 private constant INACTIVITY_PERIOD = 180 days;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant CLAIM_ALL_PACKAGE_LIMIT = 35; // CHANGED TO 35
    uint256 public constant MAX_PACKAGES_PER_GROUP = 10;

    // --- State Variables ---
    IRouter public immutable titanRouter;
    IRouter public router;
    address public immutable titanPanel;

    ITitanRegister public titanRegister;
    IEuphoriaX public erxToken;
    IERC20 public qbitToken;
    ISupportFund public supportFund;

    address public daoAddress;
    address public qbitBurnerAddress;
    address[2] public cftPools;
    uint8 public activePoolIndex;

    // --- NEW STATE VARIABLES for getSystemStats ---
    uint256 public totalSystemActivePackages;
    uint256 public totalSystemErxPaidOut;

    enum PackageStatus {
        Active,
        Ended
    }

    // --- Structs ---
    struct CapitalPackage {
        address owner;
        uint256 totalLimitUSD;
        uint256 monthlyLimitUSD;
        uint256 amountClaimedUSD;
        uint64 creationTimestamp;
        uint64 lastClaimTimestamp;
        uint8 packageTypeId;
        PackageStatus status;
        uint8 investorCycle;
        uint8 groupIdx;
        TitanDataTypes.PackageType pkgType;
    }

    struct MonthlyData {
        uint256 totalShares;
        uint256 pricePerShareUSD;
        uint256 lockedErxForPayout;
        bool isPriced;
        bool isCleanedUp;
    }

    // --- Mappings ---
    mapping(uint256 => CapitalPackage) public packages;
    mapping(uint32 => MonthlyData) public monthlyData;
    mapping(uint256 => mapping(uint32 => uint256)) public cftShares;
    mapping(address => mapping(uint8 => uint256[])) private _userPackagesInGroup;
    mapping(address => uint256) public userActivePackageCount;
    mapping(address => mapping(uint8 => uint8)) public userPackageTypeCompletionCount;

    // --- Modifiers ---
    modifier onlyDAO() {
        require(msg.sender == daoAddress, "CF: Caller is not the DAO");
        _;
    }

    modifier onlyTitanRegister() {
        require(msg.sender == address(titanRegister), "CF: Caller is not the TitanRegister contract");
        _;
    }

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "CF: Address parameter cannot be the zero address");
        _;
    }

    modifier onlyPanel() {
        require(msg.sender == titanPanel, "CF: Caller is not the Titan Panel");
        _;
    }

    modifier onlyUser() {
        require(tx.origin == msg.sender, "CF: Caller must be a user, not a contract");
        _;
    }

    // --- Constructor ---
    constructor(
        address _titanRouterAddress,
        address _titanPanelAddress,
        address[2] memory _initialCftPools,
        address _initialSupportFund
    ) {
        // ITitanRouter _router = ITitanRouter(_titanRouterAddress);
        titanRouter = IRouter(_titanRouterAddress);
        titanPanel = _titanPanelAddress;
        address _registerAddress = titanRouter.getTitanRegistration();
        require(_registerAddress != address(0), "CF: TitanRegister address not set in Router");
        titanRegister = ITitanRegister(_registerAddress);
        // erxToken = IERC20(_router.getTokenAddress("ERX"));
        erxToken = IEuphoriaX(titanRouter.getERXToken());
        qbitToken = IERC20(titanRouter.getQbitToken());
        daoAddress = titanRouter.getDao();
        // address _erxOracleAddress = titanRouter.getOracleAddress("ERX");
        // require(_erxOracleAddress != address(0), "CF: ERX Oracle address not set in Router");
        // erxUsdOracle = IPriceOracle(_erxOracleAddress);
        // qbitBurnerAddress = titanRouter.getContractAddress("QBIT_BURNER");
        qbitBurnerAddress = address(111); // !edit
        require(_initialSupportFund != address(0), "CF: Initial SupportFund address cannot be zero");
        supportFund = ISupportFund(_initialSupportFund);
        require(
            _initialCftPools[0] != address(0) && _initialCftPools[1] != address(0),
            "CF: Initial CFT pool addresses cannot be zero"
        );
        cftPools = _initialCftPools;
        activePoolIndex = 0;
    }

    // --- DAO Functions ---

    function pause() external onlyDAO {
        _pause();
    }

    function unpause() external onlyDAO {
        _unpause();
    }

    function approveSupportFund(uint256 amount) external onlyDAO {
        erxToken.approve(address(supportFund), amount);
        uint256 allowance = erxToken.allowance(address(this), address(supportFund));
        emit LOG("[approveSupportFund]:address(erxToken)", address(erxToken));
        emit LOG("[approveSupportFund]:Allowance after approval", allowance);
    }

    function setSupportFundAddress(address _newSupportFundAddress)
        external
        onlyDAO
        nonZeroAddress(_newSupportFundAddress)
    {
        supportFund = ISupportFund(_newSupportFundAddress);
    }

    function setQbitBurnerAddress(address _newQbitBurnerAddress)
        external
        onlyDAO
        nonZeroAddress(_newQbitBurnerAddress)
    {
        qbitBurnerAddress = _newQbitBurnerAddress;
    }

    function setCftPools(address[2] memory _newCftPools)
        external
        onlyDAO
        nonZeroAddress(_newCftPools[0])
        nonZeroAddress(_newCftPools[1])
    {
        cftPools = _newCftPools;
    }

    // --- System-to-System & View Functions ---
    /**
     * @notice Receives notification from Titan_Register about a new package.
     * @dev It also implements the 15-day rule for initial CFT generation.
     */
    function notifyPackageActivation(
        uint256 packageId,
        address user,
        uint8 groupIdx,
        TitanDataTypes.PackageType pkgType,
        uint256, /* erxPrice - reserved for future use */
        uint256 shareCount,
        bool /*isBusiness*/
    ) external /*override*/ onlyTitanRegister whenNotPaused {
        emit LOG("[notifyPackageActivation]: entered for user", user);
        // console.log("[notifyPackageActivation]: entered");
        console.log("[notifyPackageActivation]: packageId", packageId);
        // emit LOG("[notifyPackageActivation]: packageId", packageId);
        require(packages[packageId].creationTimestamp == 0, "CF: Package ID already exists");
        // Note: The isBusiness flag is not used in CapitalFund's logic as per the final decision.
        uint8 packageTypeId = TitanHelper.getPackageTypeId(groupIdx, pkgType);
        // emit LOG("[notifyPackageActivation]: packageTypeId", packageTypeId);
        console.log("[notifyPackageActivation]: packageTypeId", packageTypeId);
        uint8 cycle = userPackageTypeCompletionCount[user][packageTypeId];
        // emit LOG("[notifyPackageActivation]: cycle", cycle);
        console.log("[notifyPackageActivation]: cycle", cycle);
        _createPackage(packageId, user, groupIdx, pkgType, cycle);

        console.log("[notifyPackageActivation]: block.timestamp", block.timestamp);
        (uint256 year, uint256 month, uint256 day) = BokkyPooBahsDateTimeLibrary.timestampToDate(block.timestamp);
        console.log("[notifyPackageActivation]: day", day);
        console.log("[notifyPackageActivation]: month", month);
        console.log("[notifyPackageActivation]: year", year);
        uint32 currentMonthId = uint32(year * 100 + month);
        console.log("[notifyPackageActivation]: currentMonthId", currentMonthId);
        uint32 nextMonthId;
        if (month == 12) {
            nextMonthId = uint32((year + 1) * 100 + 1); // برو به سال بعد
        } else {
            nextMonthId = currentMonthId + 1; // برو به ماه بعد
        }
        console.log("[notifyPackageActivation]: nextMonthId", nextMonthId);
        console.log("[notifyPackageActivation]: shareCount", shareCount);

        // از shareCount که از قرارداد Register پاس داده شده برای تولید سهام استفاده کن
        require(shareCount > 0, "CF: Share count cannot be zero");
        _generateCFTsForMonth(packageId, nextMonthId, shareCount);
    }

    event LOG(string message);
    event LOG(string message, string value);
    event LOG(string message, bool value);
    event LOG(string message, uint256 value);
    event LOG(string message, uint256[] value);
    event LOG(string message, bytes32 value);
    event LOG(string message, bytes value);
    event LOG(string message, address value);
    event LOG(string message, CapitalPackage value);
    event LOG(string message, MonthlyData value);
    event LOG(string message, TitanDataTypes.PackageType value);

    function getActiveCapitalPool() external view returns (address) {
        return cftPools[activePoolIndex];
    }

    function isPackageSettled(uint256 packageId) external view returns (bool) {
        return packages[packageId].status == PackageStatus.Ended;
    }

    function getPackageDetails(uint256 packageId) external view returns (CapitalPackage memory) {
        return packages[packageId];
    }

    function getUserPackagesInGroup(address user, uint8 groupIndex) external view returns (uint256[] memory) {
        return _userPackagesInGroup[user][groupIndex];
    }

    function getMonthlyData(uint32 monthId) external view returns (MonthlyData memory) {
        return monthlyData[monthId];
    }

    function getCurrentMonthId() public view returns (uint32) {
        (uint256 year, uint256 month,) = BokkyPooBahsDateTimeLibrary.timestampToDate(block.timestamp);
        return uint32(year * 100 + month);
    }
    /**
     * @notice Returns a financial summary for a specific user.
     * @dev Iterates through all of the user's packages to calculate aggregate values.
     * @param user The address of the user to query.
     * @return totalClaimedUSD The total USD value the user has claimed across all packages.
     * @return totalLimitUSD The combined total USD limit of all packages owned by the user.
     * @return activePackages The count of packages the user currently has in 'Active' status.
     */

    function getUserFinancialSummary(address user)
        external
        view
        returns (uint256 totalClaimedUSD, uint256 totalLimitUSD, uint256 activePackages)
    {
        activePackages = userActivePackageCount[user];
        for (uint8 i = 1; i <= 7; i++) {
            uint256[] memory groupPackageIds = _userPackagesInGroup[user][i];
            for (uint256 j = 0; j < groupPackageIds.length; j++) {
                uint256 packageId = groupPackageIds[j];
                CapitalPackage storage pkg = packages[packageId];

                if (pkg.owner == user) {
                    totalClaimedUSD += pkg.amountClaimedUSD;
                    totalLimitUSD += pkg.totalLimitUSD;
                }
            }
        }
    }
    /**
     * @notice Returns key performance indicators for the entire fund.
     * @return totalActivePackages The total number of packages currently in 'Active' status across the system.
     * @return totalErxPaidOut The cumulative amount of ERX ever paid out by the fund.
     * @return currentMonthTotalShares The total number of CFT shares generated for the current, ongoing month.
     */

    function getSystemStats()
        external
        view
        returns (uint256 totalActivePackages, uint256 totalErxPaidOut, uint256 currentMonthTotalShares)
    {
        totalActivePackages = totalSystemActivePackages;
        totalErxPaidOut = totalSystemErxPaidOut;
        uint32 currentMonthId = getCurrentMonthId();
        currentMonthTotalShares = monthlyData[currentMonthId].totalShares;
    }
    // --- Main Public Functions ---
    /**
     * @notice Prices a completed month, delegates economic logic to SupportFund, and sweeps unclaimed funds.
     * @dev This function is public and can be called by anyone to trigger the monthly pricing cycle.
     */

    function priceMonth(uint32 monthId) external whenNotPaused nonReentrant {
        emit LOG("[priceMonth]: entered for monthId", monthId);
        // --- Step 1: Initial Checks ---
        require(monthId < getCurrentMonthId(), "CF: Cannot price a current or future month");
        MonthlyData storage month = monthlyData[monthId];
        require(!month.isPriced, "CF: This month has already been priced");
        // --- Step 2: Sweep Unclaimed Funds from the Expired Window ---
        _sweepUnclaimedFunds(monthId > 0 ? monthId - 1 : 0);
        // --- Step 3: Collect Capital from Active Pool ---
        address poolToDrain = cftPools[activePoolIndex];
        uint256 erxBalanceFromPool = erxToken.balanceOf(poolToDrain);
        if (erxBalanceFromPool > 0) {
            erxToken.safeTransferFrom(poolToDrain, address(this), erxBalanceFromPool);
        }

        uint256 totalErxToProcess = erxToken.balanceOf(address(this));

        // --- Step 4: Handle Months with No Shares ---
        uint256 totalShares = month.totalShares;
        if (totalShares == 0) {
            month.isPriced = true;
            month.lockedErxForPayout = totalErxToProcess;
            emit MonthPriced(monthId, 0, totalErxToProcess, 0);
            activePoolIndex = 1 - activePoolIndex;
            return;
        }
        // --- Step 5: Delegate Valuation Logic to SupportFund ---
        erxToken.approve(address(supportFund), type(uint256).max);
        // erxToken.approve(address(supportFund), erxBalanceFromPool);
        emit LOG("[priceMonth]: erxBalanceFromPool", erxBalanceFromPool);
        emit LOG("[priceMonth]: totalShares", totalShares);
        emit LOG("[priceMonth]: address(supportFund)", address(supportFund));
        supportFund.processPeriodValuation(totalShares, totalErxToProcess);
        erxToken.approve(address(supportFund), 0);

        // --- Step 6: Calculate and Record Final Price ---
        uint256 finalErxBalance = erxToken.balanceOf(address(this));
        month.lockedErxForPayout = finalErxBalance;

        uint256 erxPriceUSD = erxToken.getCurrentPrice();
        uint256 finalTotalBalanceUSD = (finalErxBalance * erxPriceUSD) / PRECISION;
        uint256 finalPricePerShareUSD = finalTotalBalanceUSD * PRECISION / totalShares;

        month.pricePerShareUSD = finalPricePerShareUSD;
        month.isPriced = true;

        // --- Step 7: Prepare for Next Month ---
        activePoolIndex = 1 - activePoolIndex;

        emit MonthPriced(monthId, finalPricePerShareUSD, totalErxToProcess, totalShares);
    }
    /**
     * @notice Simulates a claim for a user to see the potential payout without executing a state-changing transaction.
     * @param user The address of the user for whom the claim is being simulated.
     * @param packageIds An array of package IDs to be included in the claim simulation.
     * @param monthToClaim The month (e.g., 202506 for June 2025) for which the claim is being simulated.
     * @return totalErxPayout The total amount of ERX the user would receive.
     * @return qbitFee The total amount of QBIT the user would need to pay as a fee.
     */

    function simulateClaim(address user, uint256[] calldata packageIds, uint32 monthToClaim)
        external
        view
        returns (uint256 totalErxPayout, uint256 qbitFee)
    {
        uint32 currentMonthId = getCurrentMonthId();
        if (monthToClaim >= currentMonthId) return (0, 0);

        MonthlyData storage monthData = monthlyData[monthToClaim];
        if (!monthData.isPriced) return (0, 0);

        uint32 claimDeadline = monthToClaim + uint32(FORFEIT_WINDOW_MONTHS);
        if (currentMonthId > claimDeadline) return (0, 0);

        uint256 totalUsdValueToClaim = 0;
        uint256 erxPriceUSD;

        try erxToken.getCurrentPrice() returns (uint256 price) {
            erxPriceUSD = price;
        } catch {
            return (0, 0); // Cannot simulate if oracle is down.
        }

        for (uint256 i = 0; i < packageIds.length; i++) {
            uint256 packageId = packageIds[i];
            CapitalPackage storage pkg = packages[packageId];

            if (pkg.owner != user || pkg.status != PackageStatus.Active) continue;

            if (block.timestamp - pkg.lastClaimTimestamp > INACTIVITY_PERIOD) continue;

            uint256 sharesToClaim = cftShares[packageId][monthToClaim];
            if (sharesToClaim == 0) continue;

            uint256 usdValue = (sharesToClaim * monthData.pricePerShareUSD) / PRECISION;
            uint256 remainingTotalLimit = pkg.totalLimitUSD - pkg.amountClaimedUSD;
            if (usdValue > pkg.monthlyLimitUSD) usdValue = pkg.monthlyLimitUSD;
            if (usdValue > remainingTotalLimit) usdValue = remainingTotalLimit;

            if (usdValue > 0) {
                totalUsdValueToClaim += usdValue;
            }
        }

        if (totalUsdValueToClaim == 0) {
            return (0, 0);
        }

        totalErxPayout = (totalUsdValueToClaim * PRECISION) / erxPriceUSD;
        uint256 qbitValueForFee = (totalUsdValueToClaim * CFT_CLAIM_FEE_BPS) / BPS_DENOMINATOR;
        qbitFee = TitanHelper.convertUSDToSingleToken(address(titanRouter), qbitValueForFee, "QBIT");

        return (totalErxPayout, qbitFee);
    }

    // =============================================================================
    // |                    Dual-Path User Claiming Functions                      |
    // =============================================================================
    // --- Direct User Path ---
    // --- Main Public Functions (Claiming) ---
    function ClaimMyCFT(uint256 packageId, uint32 monthToClaim) external nonReentrant whenNotPaused /*onlyUser */ {
        uint256[] memory packageIds = new uint256[](1);
        packageIds[0] = packageId;
        _claimAndRenew(msg.sender, packageIds, monthToClaim);
    }

    function ClaimGroupCFT(uint8 groupIndex, uint32 monthToClaim) external nonReentrant whenNotPaused /*onlyUser */ {
        uint256[] memory packageIds = _userPackagesInGroup[msg.sender][groupIndex];
        _claimAndRenew(msg.sender, packageIds, monthToClaim);
    }

    function claimGroupCFTFor(address user, uint8 groupIndex, uint32 monthToClaim)
        external
        nonReentrant
        whenNotPaused
        onlyPanel
    {
        uint256[] memory packageIds = _userPackagesInGroup[user][groupIndex];
        _claimAndRenew(user, packageIds, monthToClaim);
    }

    struct ProcessedPackage {
        uint256 id;
        uint256 usdValue;
        uint256 shares;
    }

    // --- Internal Logic ---
    /**
     * @notice Core logic for claiming monthly rewards and renewing shares for the next cycle.
     * @dev MODIFIED to accept `_user` address for Dual-Path compatibility.
     */
    function _claimAndRenew(address _user, uint256[] memory packageIds, uint32 monthToClaim) internal {
        emit LOG("[_claimAndRenew]: entered for user", _user);
        emit LOG("[_claimAndRenew]: packageIds", packageIds);
        emit LOG("[_claimAndRenew]: monthToClaim", monthToClaim);
        uint32 currentMonthId = getCurrentMonthId();
        emit LOG("[_claimAndRenew]: currentMonthId", currentMonthId);
        require(monthToClaim < currentMonthId, "CF: Cannot claim for a current or future month");

        if (packageIds.length > 0) {
            CapitalPackage storage firstPkg = packages[packageIds[0]];
            emit LOG("[_claimAndRenew]: firstPkg", firstPkg);
            emit LOG("[_claimAndRenew]: titanRegister", address(titanRegister));
            emit LOG("[_claimAndRenew]: firstPkg.owner", firstPkg.owner);
            emit LOG("[_claimAndRenew]: _user", _user);
            // Ensure we're checking a valid package for this user to prevent errors.
            if (firstPkg.owner == _user) {
                (uint256 year, uint256 month,) = BokkyPooBahsDateTimeLibrary.timestampToDate(firstPkg.creationTimestamp);
                emit LOG("[_claimAndRenew]: year", year);
                emit LOG("[_claimAndRenew]: month", month);
                uint32 creationMonthId = uint32(year * 100 + month);
                emit LOG("[_claimAndRenew]: creationMonthId", creationMonthId);

                // The first claimable month must be at least the month AFTER activation.
                require(
                    monthToClaim >= creationMonthId + 1, "CF: Grace period applies; claims start from the next month"
                );
            }
        }

        MonthlyData storage monthData = monthlyData[monthToClaim];
        emit LOG("[_claimAndRenew]: monthData", monthData);
        require(monthData.isPriced, "CF: The selected month has not been priced yet");

        uint32 claimDeadline = monthToClaim + uint32(FORFEIT_WINDOW_MONTHS);
        emit LOG("[_claimAndRenew]: claimDeadline", claimDeadline);
        require(currentMonthId <= claimDeadline, "CF: The claim window for this month has expired");

        ProcessedPackage[] memory processedPackages = new ProcessedPackage[](packageIds.length);
        uint256 processedCount = 0;
        uint256 totalUsdValueToClaim = 0;

        for (uint256 i = 0; i < packageIds.length; i++) {
            uint256 packageId = packageIds[i];
            CapitalPackage storage pkg = packages[packageId];

            if (pkg.owner != _user || pkg.status != PackageStatus.Active) continue;

            uint32 nextMonthToGenerate = monthToClaim + 1;

            if (cftShares[packageId][nextMonthToGenerate] == 0) {
                if (pkg.amountClaimedUSD < pkg.totalLimitUSD) {
                    // TitanDataTypes.PackageConfig storage config = packageConfigs[pkg.packageTypeId];
                    uint256 baseShares = TitanHelper.getCFTPerMonth(pkg.groupIdx);
                    _generateCFTsForMonth(packageId, nextMonthToGenerate, baseShares);
                }
            }

            if (block.timestamp - pkg.lastClaimTimestamp > INACTIVITY_PERIOD) {
                pkg.status = PackageStatus.Ended;
                userActivePackageCount[_user]--;
                totalSystemActivePackages--;
                emit PackageCompleted(packageId);

                try ITitanRegister(address(titanRegister)).notifyPackageSettled(_user, packageId) {} catch {}
                continue;
            }

            uint256 sharesToClaim = cftShares[packageId][monthToClaim];
            emit LOG("[_claimAndRenew]: sharesToClaim", sharesToClaim);
            if (sharesToClaim == 0) continue;

            uint256 usdValue = (sharesToClaim * monthData.pricePerShareUSD) / PRECISION;
            emit LOG("[_claimAndRenew]: usdValue", usdValue);
            uint256 remainingTotalLimit = pkg.totalLimitUSD - pkg.amountClaimedUSD;
            emit LOG("[_claimAndRenew]: remainingTotalLimit", remainingTotalLimit);
            if (usdValue > pkg.monthlyLimitUSD) usdValue = pkg.monthlyLimitUSD;
            if (usdValue > remainingTotalLimit) usdValue = remainingTotalLimit;
            emit LOG("[_claimAndRenew]: usdValue", usdValue);

            if (usdValue > 0) {
                totalUsdValueToClaim += usdValue;
                processedPackages[processedCount++] = ProcessedPackage(packageId, usdValue, sharesToClaim);
            }
        }

        if (totalUsdValueToClaim == 0) {
            return;
        }

        uint256 erxPriceUSD;
        try erxToken.getCurrentPrice() returns (uint256 price) {
            require(price > 0, "CF: Oracle returned an invalid price");
            erxPriceUSD = price;
        } catch {
            revert("CF: Cannot claim if ERX price is down");
        }

        uint256 erxPriceUSDForEffects = erxPriceUSD;
        emit LOG("[_claimAndRenew]: erxPriceUSDForEffects", erxPriceUSDForEffects);

        // --- Effects ---
        for (uint256 i = 0; i < processedCount; i++) {
            ProcessedPackage memory processed = processedPackages[i];
            CapitalPackage storage pkg = packages[processed.id];

            pkg.amountClaimedUSD += processed.usdValue;
            pkg.lastClaimTimestamp = uint64(block.timestamp);
            monthData.lockedErxForPayout -= (processed.usdValue * PRECISION) / erxPriceUSDForEffects;
            cftShares[processed.id][monthToClaim] = 0;

            if (pkg.amountClaimedUSD >= pkg.totalLimitUSD) {
                pkg.status = PackageStatus.Ended;
                userActivePackageCount[_user]--;
                totalSystemActivePackages--;
                uint8 packageTypeId = pkg.packageTypeId;
                userPackageTypeCompletionCount[_user][packageTypeId]++;
                emit PackageTypeCompletionIncremented(
                    _user, packageTypeId, userPackageTypeCompletionCount[_user][packageTypeId]
                );
                emit PackageCompleted(processed.id);

                try ITitanRegister(address(titanRegister)).notifyPackageSettled(_user, processed.id) {} catch {}
            }
        }

        // --- Interactions ---
        uint256 erxPriceUSDForPayout = erxPriceUSDForEffects;
        emit LOG("[_claimAndRenew]: erxPriceUSDForPayout", erxPriceUSDForPayout);
        uint256 totalErxPayout = (totalUsdValueToClaim * PRECISION) / erxPriceUSDForPayout;
        emit LOG("[_claimAndRenew]: totalErxPayout", totalErxPayout);
        uint256 qbitValueForFee = (totalUsdValueToClaim * CFT_CLAIM_FEE_BPS) / BPS_DENOMINATOR;
        emit LOG("[_claimAndRenew]: qbitValueForFee", qbitValueForFee);
        uint256 qbitFee = TitanHelper.convertUSDToSingleToken(address(titanRouter), qbitValueForFee, "QBIT");
        emit LOG("[_claimAndRenew]: qbitFee", qbitFee);
        emit LOG("[_claimAndRenew]: erxToken.balanceOf(address(this))", erxToken.balanceOf(address(this)));

        require(erxToken.balanceOf(address(this)) >= totalErxPayout, "CF: Insufficient contract balance for ERX payout");

        emit LOG("[_claimAndRenew]: address(qbit)", address(qbitToken));
        if (qbitFee > 0) qbitToken.safeTransferFrom(_user, qbitBurnerAddress, qbitFee);
        if (totalErxPayout > 0) erxToken.safeTransfer(_user, totalErxPayout);

        totalSystemErxPaidOut += totalErxPayout;
        emit LOG("[_claimAndRenew]: totalSystemErxPaidOut", totalSystemErxPaidOut);

        for (uint256 i = 0; i < processedCount; i++) {
            ProcessedPackage memory p = processedPackages[i];
            uint256 erxPaidForPackage = (p.usdValue * PRECISION) / erxPriceUSDForPayout;
            emit PackageClaimed(p.id, monthToClaim, p.shares, p.usdValue, erxPaidForPackage);
        }
    }

    function _createPackage(
        uint256 packageId,
        address user,
        uint8 groupIdx,
        TitanDataTypes.PackageType pkgType,
        uint8 cycle
    ) internal {
        emit LOG("[_createPackage]: entered");
        console.log("[_createPackage]: entered");

        emit LOG("[_createPackage]: packageId", packageId);
        emit LOG("[_createPackage]: groupIdx", groupIdx);
        emit LOG("[_createPackage]: pkgType", pkgType);
        emit LOG("[_createPackage]: cycle", cycle);
        uint256 totalLimitUSD = TitanHelper.getTotalCapUSD(groupIdx, uint8(pkgType));
        emit LOG("[_createPackage]: totalLimitUSD", totalLimitUSD);
        uint256 monthlyLimitUSD = TitanHelper.getMonthlyCapUSD(groupIdx, uint8(pkgType));
        emit LOG("[_createPackage]: monthlyLimitUSD", monthlyLimitUSD);
        uint256 initialShares = TitanHelper.getCFTPerMonth(groupIdx);
        emit LOG("[_createPackage]: initialShares", initialShares);
        require(totalLimitUSD > 0, "CF: Package config could not be retrieved from Helper");

        packages[packageId] = CapitalPackage({
            owner: user,
            totalLimitUSD: totalLimitUSD,
            monthlyLimitUSD: monthlyLimitUSD,
            amountClaimedUSD: 0,
            creationTimestamp: uint64(block.timestamp),
            lastClaimTimestamp: uint64(block.timestamp),
            packageTypeId: TitanHelper.getPackageTypeId(groupIdx, pkgType),
            status: PackageStatus.Active,
            investorCycle: cycle,
            groupIdx: groupIdx,
            pkgType: pkgType
        });

        emit LOG("[_createPackage]: groupIdx", groupIdx);
        console.log("[_createPackage]: groupIdx", groupIdx);

        _userPackagesInGroup[user][groupIdx].push(packageId);
        userActivePackageCount[user]++;
        totalSystemActivePackages++;

        emit PackageCreated(packageId, user, TitanHelper.getPackageTypeId(groupIdx, pkgType), initialShares);
    }

    function _generateCFTsForMonth(uint256 packageId, uint32 monthId, uint256 baseShares) internal {
        uint8 cycle = packages[packageId].investorCycle;
        emit LOG("[_generateCFTsForMonth]: packageId", packageId);
        emit LOG("[_generateCFTsForMonth]: monthId", monthId);
        emit LOG("[_generateCFTsForMonth]: baseShares", baseShares);
        emit LOG("[_generateCFTsForMonth]: cycle", cycle);
        uint256 finalShares;

        if (cycle == 0) {
            // First cycle
            finalShares = baseShares;
        } else if (cycle == 1) {
            // Second cycle
            finalShares = (baseShares * 90) / 100;
        } else {
            // Third cycle onwards
            finalShares = (baseShares * 80) / 100;
        }
        emit LOG("[_generateCFTsForMonth]: finalShares", finalShares);

        cftShares[packageId][monthId] = finalShares;
        emit LOG("[_generateCFTsForMonth]: cftShares[packageId][monthId]", cftShares[packageId][monthId]);
        monthlyData[monthId].totalShares += finalShares;
        emit LOG("[_generateCFTsForMonth]: monthlyData[monthId].totalShares", monthlyData[monthId].totalShares);

        emit CFTsRenewed(packageId, monthId, finalShares);
    }

    function _sweepUnclaimedFunds(uint32 monthId) private {
        if (monthId == 0) return;

        MonthlyData storage month = monthlyData[monthId];

        if (month.isPriced && !month.isCleanedUp) {
            uint256 unclaimedErxAmount = month.lockedErxForPayout;
            if (unclaimedErxAmount > 0) {
                month.lockedErxForPayout = 0;
                emit UnclaimedFundsSwept(monthId, monthId + 1, unclaimedErxAmount);
            }
            month.isCleanedUp = true;
        }
    }

    function setQbitTokenAddress(address _newQbitTokenAddress) external onlyDAO nonZeroAddress(_newQbitTokenAddress) {
        qbitToken = IERC20(_newQbitTokenAddress);
    }

    // Add this function anywhere inside your Titan_CapitalFund contract
    function updateAddresses() external {
        // Only the Router or DAO should be able to call this.
        require(msg.sender == address(titanRouter) || msg.sender == daoAddress, "CF: Not authorized");
        emit LOG("[updateAddresses]: Updating contract addresses");
        // Re-fetch all addresses from the router
        erxToken = IEuphoriaX(titanRouter.getERXToken());
        qbitToken = IERC20(titanRouter.getQbitToken());
        daoAddress = titanRouter.getDao();
        supportFund = ISupportFund(titanRouter.getSupportFundContract());
        titanRegister = ITitanRegister(titanRouter.getTitanRegistration());
    }
}
