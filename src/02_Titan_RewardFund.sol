// SPDX-License-Identifier: MIT
/**
 * @title Titan_RewardFund Contract
 * @author Kamyar (Concept & Lead) - Dr. Satoshi Arcanum (Architecture & Code)
 * @notice موتور اقتصادی پاداش‌دهی که با واگذاری منطق تثبیت قیمت به SupportFund بهینه شده است.
 * @dev نسخه 15.5.0 - پیاده‌سازی نهایی تمام سیاست‌های اقتصادی و معماری توافق‌شده.
 */
pragma solidity ^0.8.20;

import {console} from "forge-std/Test.sol";

// --- Imports ---
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/IEuphoriaX.sol";
import "../../interfaces/IQbit.sol";
import "../../interfaces/TitanV2/ITitanRegister.sol";
import "../../interfaces/IRouter.sol";
import "../../interfaces/TitanV2/ISupportFund.sol";

import "../../libraries/TitanV2/TitanDataTypes.sol";
import "../../interfaces/IEvents.sol";
import "../../libraries/TitanHelper.sol";

contract Titan_RewardFund is ReentrancyGuard, Pausable, ITitanEventsReward {
    using SafeERC20 for IERC20;
    using SafeERC20 for IEuphoriaX;
    using SafeERC20 for IQbit;

    // --- Constants ---
    uint256 public distributionChainLimit;
    address public immutable queenAddress;
    uint256 private constant MANUAL_DISTRIBUTION_LEVELS = 30;
    uint256 private constant ONE_WEEK = 7 days;
    uint256 private constant ONE_DAY = 24 hours;
    uint256 private constant CLAIM_WINDOW_DURATION = 7 days;
    uint256 private constant RAW_POINTS_EXPIRATION_DURATION = 180 days;
    uint256 private constant MONSTER_MAKER_TIMEFRAME = 30 days;
    uint256 private constant CLAIM_FEE_BPS = 150; // 1.5%
    uint256 private constant BPS_DENOMINATOR = 10000;
    // uint256 private constant VOUCHER_THRESHOLD = 2500 * 1e18;
    // uint256 private constant VOUCHER_DISCOUNT_BPS = 1000; // 10%
    uint256 private constant PRECISION = 1e18;

    uint256 public constant LIFE_FEE_THRESHOLD_SHARES = 2500 * 1e18; // آستانه اعمال مالیات - previously VOUCHER_THRESHOLD
    uint256 private constant LIFE_FEE_BPS = 1000; // 10% Fee - previously VOUCHER_DISCOUNT_BPS

    // --- State Variables ---
    IRouter public router;
    ITitanRegister public titanRegister;
    IEuphoriaX public erxToken;
    IQbit public qbitToken;
    ISupportFund public supportFund;

    PointRelayTask[] public pointRelayQueue;
    MonsterAwardConfig public monsterAwardConfig10;
    MonsterAwardConfig public monsterAwardConfig30;

    address public immutable titanPanel;
    address public qbitBurnerAddress;
    address public daoAddress;
    address[] public rftPools;

    uint256 public currentPoolIndex;
    uint256 public lastKnownERXPriceUSD;
    uint256 public lastKnownQBITPriceUSD;
    uint256[] private rftBaseShares;

    // --- Data Structures ---
    struct WeeklyData {
        uint256 totalSharesGenerated;
        uint256 lockedErxForPayout;
        uint256 pricePerShareUSD;
        bool isPriced;
        bool isCleanedUp;
    }

    struct PointLedger {
        uint256 rawLeft;
        uint256 rawRight;
        uint256 paidLeft;
        uint256 paidRight;
    }

    // MODIFIED v15.5.0: Added weekId to handle weekly expiration of pending points.
    struct PendingPoints {
        uint256 left;
        uint256 right;
        uint256 weekId;
    }

    struct MonsterAward {
        uint256 totalAwardAmountUSD; // ۳۲ بایت
        uint256 amountClaimedUSD; // ۳۲ بایت
        uint256 lastClaimTimestamp; // ۸ بایت - یک عدد ۶۴ بیتی برای زمان کافی است
        MonsterAwardStatus status; // ۱ بایت - یک enum در واقع یک uint8 است
    }

    struct MonsterAwardConfig {
        uint256 totalAwardUSD;
        uint256 installmentUSD;
    }

    struct PointRelayTask {
        uint256 originatingPackageId; // شناسه پکیجی که امتیاز را ایجاد کرده
        address lastRecipient; // آخرین کاربری که در مرحله قبل امتیاز را دریافت کرد
        uint8 groupIdx;
        uint256 points;
    }

    enum MonsterAwardStatus {
        None,
        QualifiedFor10,
        QualifiedFor30,
        FullyClaimed10,
        FullyClaimed30
    }

    // --- Mappings ---
    mapping(uint256 => WeeklyData) public weeklyData;
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) public userSharesInWeekByGroup;
    mapping(address => mapping(uint8 => PointLedger)) public userPointLedgers;
    mapping(address => mapping(uint8 => PendingPoints)) public userPendingPoints;
    mapping(address => mapping(uint8 => uint256)) public lastBalanceTimestamp;
    mapping(address => mapping(uint8 => TitanDataTypes.PackageType)) public userMainPackageInGroup;
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) public dailyRftSharesGeneratedInGroup;
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) public weeklyUsdClaimedInGroup;
    mapping(address => uint256) public userTotalRftBaseShares;
    mapping(address => MonsterAward) public userMonsterAwards;
    mapping(address => mapping(uint8 => uint256)) public lastRftGenerationDayId;
    mapping(address => bool) public isSubjectToLifeFee; // پرچمی برای شناسایی کاربران مشمول مالیات
    mapping(uint256 => mapping(address => bool)) public hasReceivedPointForPackage;

    // --- Events ---
    event RFTsGenerated(
        address indexed user, uint8 indexed groupIndex, uint256 balanceCount, uint256 totalShares, uint256 weekId
    );
    event WeekPriced(uint256 indexed weekId, uint256 pricePerShareUSD, uint256 totalShares, uint256 totalErxValue);
    event RFTsClaimed(
        address indexed user, uint256 totalShares, uint256 totalUsdValue, uint256 erxPaidOut, uint256 qbitFee
    );
    event UserCapUpgraded(address indexed user, uint8 indexed groupIdx, TitanDataTypes.PackageType packageType);
    event PendingPointsClaimed(address indexed user, uint8 indexed groupIdx, uint256 leftPoints, uint256 rightPoints);
    event StarPointCached(address indexed user, uint8 indexed groupIdx, uint256 points, uint8 position);
    event RawPointsExpired(address indexed user, uint8 indexed groupIdx, uint256 amount, uint256 leg);
    event WeekClaimPeriodClosed(uint256 indexed weekId, uint256 remainingBalance);
    event MonsterAwardQualified(address indexed user, MonsterAwardStatus status, uint256 totalAward);
    event MonsterAwardClaimed(address indexed user, uint256 installmentAmount);
    event GroupReactivated(
        uint256 indexed packageId,
        address indexed user,
        uint8 indexed groupIndex,
        TitanDataTypes.PackageType packageType
    );
    event WeekManuallyPriced(uint256 indexed weekId, uint256 pricePerShareUSD, address indexed setter); // ADDED v15.5.0
    event UserQualifiedForLifeFee(address indexed user);
    event LifeFeeDeducted(address indexed user, uint256 feeAmountUSD, uint256 grossAmountUSD);
    event LastKnownPriceUpdated(uint256 newErxPriceUSD, uint256 newQbitPriceUSD);
    event MonsterAwardConfigUpdated(
        uint256 totalAward10, uint256 installment10, uint256 totalAward30, uint256 installment30
    );
    event RelayTaskCreated(uint256 indexed packageId, address indexed lastRecipient, uint256 queueLength);
    event RelayTaskProcessed(uint256 indexed packageId, address indexed newLastRecipient, uint256 stepsProcessed);
    event RelayTaskCompleted(uint256 indexed packageId);

    modifier onlyDAO() {
        require(msg.sender == daoAddress, "TRF: Caller is not DAO");
        _;
    }

    modifier onlyDaoAndRouter() {
        require(_msgSender() == daoAddress || _msgSender() == address(router), "TR: Caller is not the DAO");
        _;
    }

    modifier onlyPanel() {
        require(msg.sender == titanPanel, "TRF: Caller is not the Titan Panel");
        _;
    }

    // modifier onlyUser() {
    //     require(tx.origin == msg.sender, "TRF: Caller must be a user, not a contract");
    //     _;
    // }

    modifier onlyTitanRegister() {
        require(msg.sender == address(titanRegister), "TRF: Caller is not TitanRegister");
        _;
    }

    // --- Constructor ---
    constructor(
        address _routerAddress,
        address _titanPanelAddress,
        address[] memory _initialRftPools,
        address _initialSupportFund,
        address _erxToken,
        address _qbitToken,
        uint256 _initialPoolIndex,
        address _queenAddress
    ) {
        require(
            _routerAddress != address(0) && _titanPanelAddress != address(0) && _initialSupportFund != address(0)
                && _erxToken != address(0) && _qbitToken != address(0),
            "TRF: Zero address"
        );
        require(_initialRftPools.length == 3, "TRF: Must provide 3 RFT pools");
        require(_initialPoolIndex < 3, "TRF: Invalid initial pool index");

        router = IRouter(_routerAddress);
        daoAddress = router.getDao();
        titanPanel = _titanPanelAddress;

        address _registerAddress = router.getTitanRegistration();
        require(_registerAddress != address(0), "TRF: Register address not set");
        titanRegister = ITitanRegister(_registerAddress);

        // erxToken = IERC20(router.getTokenAddress("ERX"));
        erxToken = IEuphoriaX(router.getERXToken());
        qbitToken = IQbit(router.getQbitToken());

        // qbitBurnerAddress = router.getContractAddress("QBIT_BURNER");
        qbitBurnerAddress = address(111);

        supportFund = ISupportFund(_initialSupportFund);
        rftPools = _initialRftPools;

        rftBaseShares = [0, 1, 3, 5, 10, 30, 50, 100];
        lastKnownERXPriceUSD = 1 * 1e17; // $0.1
        lastKnownQBITPriceUSD = 2 * 1e19; // $20.00
        distributionChainLimit = 100;
        currentPoolIndex = _initialPoolIndex;
        queenAddress = _queenAddress;

        monsterAwardConfig10 = MonsterAwardConfig({
            totalAwardUSD: 200 * PRECISION, // 200 USD
            installmentUSD: 50 * PRECISION // 50 USD per week
        });
        monsterAwardConfig30 = MonsterAwardConfig({
            totalAwardUSD: 500 * PRECISION, // 500 USD
            installmentUSD: 100 * PRECISION // 100 USD per week
        });
    }

    function pause() external onlyDAO {
        _pause();
    }

    function unpause() external onlyDAO {
        _unpause();
    }

    function setSupportFundAddress(address _newAddress) external onlyDAO {
        require(_newAddress != address(0), "TRF: Zero address");
        supportFund = ISupportFund(_newAddress);
    }

    function setRftPools(address[] memory _newPools) external onlyDAO {
        require(_newPools.length == 3, "TRF: Exactly 3 pools required");
        for (uint256 i = 0; i < 3; i++) {
            require(_newPools[i] != address(0), "TRF: Invalid pool address");
        }
        rftPools = _newPools;
    }

    function setQbitBurner(address _newBurnerAddress) external onlyDAO {
        require(_newBurnerAddress != address(0), "TRF: Zero address");
        qbitBurnerAddress = _newBurnerAddress;
    }

    function setDistributionChainLimit(uint256 _newLimit) external onlyDAO {
        require(_newLimit > 30 && _newLimit <= 200, "TRF: Invalid limit");
        distributionChainLimit = _newLimit;
    }

    function setMonsterAwardConfig(
        uint256 _totalAward10,
        uint256 _installment10,
        uint256 _totalAward30,
        uint256 _installment30
    ) external onlyDAO {
        monsterAwardConfig10 = MonsterAwardConfig(_totalAward10, _installment10);
        monsterAwardConfig30 = MonsterAwardConfig(_totalAward30, _installment30);
        // It's good practice to emit an event here
        emit MonsterAwardConfigUpdated(_totalAward10, _installment10, _totalAward30, _installment30);
    }

    /**
     * @notice Allows the DAO to recover any ERC20 token accidentally sent to this contract.
     * @dev This is a safety measure. It prevents locking of funds.
     * It deliberately prevents recovering the protocol's main tokens (ERX, QBIT).
     * @param tokenAddress The address of the ERC20 token to recover.
     * @param recipient The address to send the recovered tokens to.
     * @param amount The amount of tokens to recover.
     */
    function recoverTokens(address tokenAddress, address recipient, uint256 amount) external onlyDAO {
        require(
            tokenAddress != address(erxToken) && tokenAddress != address(qbitToken),
            "TRF: Cannot recover native protocol tokens"
        );
        require(recipient != address(0), "TRF: Cannot send to the zero address");

        IERC20(tokenAddress).safeTransfer(recipient, amount);
    }

    // ADDED v15.5.0: Emergency price setting function for DAO.
    function manuallySetWeekPrice(uint256 _weekId, uint256 _pricePerShareUSD) external onlyDAO {
        WeeklyData storage week = weeklyData[_weekId];
        require(!week.isPriced, "TRF: Week is already priced");
        week.pricePerShareUSD = _pricePerShareUSD;
        week.isPriced = true;
        emit WeekManuallyPriced(_weekId, _pricePerShareUSD, msg.sender);
    }

    /**
     * @notice به DAO اجازه می‌دهد تا قیمت‌های بازگشتی را در مواقع اضطراری به روز کند.
     * @dev یک تابع ایمنی حیاتی برای حفظ پایداری اقتصادی سیستم است.
     * @param _newErxPrice قیمت جدید بازگشتی برای ERX با 18 رقم اعشار.
     * @param _newQbitPrice قیمت جدید بازگشتی برای QBIT با 18 رقم اعشار.
     */
    function updateLastKnownPrices(uint256 _newErxPrice, uint256 _newQbitPrice) external onlyDAO {
        require(_newErxPrice > 0 && _newQbitPrice > 0, "TRF: Prices cannot be zero");

        lastKnownERXPriceUSD = _newErxPrice;
        lastKnownQBITPriceUSD = _newQbitPrice;

        emit LastKnownPriceUpdated(_newErxPrice, _newQbitPrice);
    }

    // =============================================================================
    // |                 System Notification & Weekly Cycle Functions               |
    // =============================================================================

    /**
     * @notice Notifies the contract about a new activation to generate and cache Star Points for the upline.
     * @dev This function is called by Titan_Register ONLY for "Business Packages" (first activation in a group).
     */
    function notifyStarPointGeneration(
        uint256 _packageId,
        address _activator,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        uint256 /*_shareCount*/
    ) external whenNotPaused onlyTitanRegister {
        emit LOG("[notifyStarPointGeneration]: entered");
        emit LOG("[notifyStarPointGeneration]: _activator", _activator);
        emit LOG("[notifyStarPointGeneration]: _groupIdx", _groupIdx);
        emit LOG("[notifyStarPointGeneration]: _packageType", uint8(_packageType));
        // Step 1: Update the user's main package type for cap calculations if it's their first in this fund.
        if (userMainPackageInGroup[_activator][_groupIdx] == TitanDataTypes.PackageType(0)) {
            userMainPackageInGroup[_activator][_groupIdx] = _packageType;
            emit UserCapUpgraded(_activator, _groupIdx, _packageType); // ! nemidoonam
        }

        // آغاز توزیع امدادی
        uint256 RELAY_CHUNK_SIZE = 100; // اندازه قطعه اولیه
        address currentUser = _activator;
        emit LOG("[notifyStarPointGeneration]: currentUser", currentUser);
        address highestRecipient;
        uint256 currentWeek = block.timestamp / ONE_WEEK;
        emit LOG("[notifyStarPointGeneration]: currentWeek", currentWeek);
        emit LOG("[notifyStarPointGeneration]: queenAddress", queenAddress);

        for (uint256 i = 0; i < RELAY_CHUNK_SIZE; i++) {
            TitanDataTypes.UserTreeInfo memory userTreeInfo = titanRegister.getUserTreeInfo(currentUser);
            emit LOG("[notifyStarPointGeneration]: userTreeInfo", userTreeInfo);
            address parent = userTreeInfo.parentAddress;
            emit LOG("[notifyStarPointGeneration]: parent", parent);

            if (parent == address(0)) {
                // اگر به ریشه رسیدیم
                highestRecipient = currentUser; // آخرین نفر همان کاربر فعلی است
                emit LOG("[notifyStarPointGeneration]: highestRecipient", highestRecipient);
                break;
            }

            TitanDataTypes.UserStatus parentStatus = titanRegister.getUserStatus(parent);
            bool isStatusEligible = (
                parentStatus == TitanDataTypes.UserStatus.Active || parentStatus == TitanDataTypes.UserStatus.Royal
                    || parentStatus == TitanDataTypes.UserStatus.Queen
            );
            emit LOG("[notifyStarPointGeneration]: isStatusEligible", isStatusEligible);

            if (isStatusEligible && titanRegister.isGroupActive(parent, _groupIdx)) {
                emit LOG(
                    "[notifyStarPointGeneration]: hasReceivedPointForPackage[_packageId][parent]",
                    hasReceivedPointForPackage[_packageId][parent]
                );
                // چک کردن برای جلوگیری از امتیاز تکراری
                if (!hasReceivedPointForPackage[_packageId][parent]) {
                    PendingPoints storage pending = userPendingPoints[parent][_groupIdx];
                    emit LOG("[notifyStarPointGeneration]: pending.weekId", pending.weekId);
                    emit LOG("[notifyStarPointGeneration]: pending.left", pending.left);
                    emit LOG("[notifyStarPointGeneration]: pending.right", pending.right);
                    if (currentWeek != pending.weekId) {
                        pending.left = 0;
                        pending.right = 0;
                        pending.weekId = currentWeek;
                    }
                    if (userTreeInfo.positionInParentLeg == 0) {
                        // Left leg
                        pending.left += 1;
                    } else {
                        // Right leg
                        pending.right += 1;
                    }
                    emit LOG("[notifyStarPointGeneration]: pending.weekId", pending.weekId);
                    emit LOG("[notifyStarPointGeneration]: pending.left", pending.left);
                    emit LOG("[notifyStarPointGeneration]: pending.right", pending.right);

                    hasReceivedPointForPackage[_packageId][parent] = true;
                    emit LOG(
                        "[notifyStarPointGeneration]: hasReceivedPointForPackage[_packageId][parent]",
                        hasReceivedPointForPackage[_packageId][parent]
                    );
                    emit StarPointCached(parent, _groupIdx, 1, userTreeInfo.positionInParentLeg);
                }
            }
            currentUser = parent;
            emit LOG("[notifyStarPointGeneration]: currentUser", currentUser);
            highestRecipient = parent; // به‌روزرسانی آخرین دریافت‌کننده در هر مرحله
            emit LOG("[notifyStarPointGeneration]: highestRecipient", highestRecipient);
        }

        // اگر پس از اتمام حلقه، هنوز به ملکه نرسیده‌ایم، یک وظیفه جدید ایجاد می‌کنیم
        if (highestRecipient != queenAddress) {
            pointRelayQueue.push(
                PointRelayTask({
                    originatingPackageId: _packageId,
                    lastRecipient: highestRecipient,
                    groupIdx: _groupIdx,
                    points: 1
                })
            );
            emit RelayTaskCreated(_packageId, highestRecipient, pointRelayQueue.length);
        }
    }

    event LOG(string message);
    event LOG(string message, string value);
    event LOG(string message, bool value);
    event LOG(string message, uint256 value);
    event LOG(string message, bytes32 value);
    event LOG(string message, bytes value);
    event LOG(string message, address value);
    event LOG(string message, TitanDataTypes.PackageType value);
    event LOG(string message, TitanDataTypes.UserTreeInfo value);

    function notifyGroupReactivation(
        uint256 _packageId,
        address _user,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        uint256 /* _shareCount - Intentionally unused */
    ) external whenNotPaused onlyTitanRegister {
        // Reactivation is a qualifying action, not a direct earning event for upline.
        emit GroupReactivated(_packageId, _user, _groupIdx, _packageType);
    }

    function finalizeAndPriceWeek(uint256 _weekIdToPrice) external whenNotPaused nonReentrant {
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: entered");
        uint256 currentWeek = block.timestamp / ONE_WEEK;
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: currentWeek", currentWeek);
        require(_weekIdToPrice < currentWeek, "TRF: Cannot price current/future week");
        WeeklyData storage week = weeklyData[_weekIdToPrice];
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: week.isPriced", week.isPriced);
        require(!week.isPriced, "TRF: Week already priced");

        if (_weekIdToPrice > 0) {
            _cleanupExpiredWeek(_weekIdToPrice - 1);
        }

        address poolAddress = rftPools[_weekIdToPrice % 3];
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: poolAddress", poolAddress);
        uint256 erxInPool = erxToken.balanceOf(poolAddress);
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: erxInPool", erxInPool);
        if (erxInPool > 0) {
            erxToken.safeTransferFrom(poolAddress, address(this), erxInPool);
        }

        uint256 totalShares = week.totalSharesGenerated;
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: totalShares", totalShares);
        if (totalShares == 0) {
            week.isPriced = true;
            week.lockedErxForPayout = erxInPool;
            emit WeekPriced(_weekIdToPrice, 0, 0, erxInPool);
            return;
        }

        erxToken.approve(address(supportFund), erxInPool);

        // ! todo: uncomment and fix
        // supportFund.processRFTValuation(totalShares, erxInPool);
        erxToken.approve(address(supportFund), 0);

        uint256 finalErxForWeek = erxToken.balanceOf(address(this));
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: finalErxForWeek", finalErxForWeek);
        week.lockedErxForPayout = finalErxForWeek;
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: week.lockedErxForPayout", week.lockedErxForPayout);

        uint256 erxPriceUSD = _getERXPrice();
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: erxPriceUSD", erxPriceUSD);
        require(erxPriceUSD > 0, "TRF: Invalid ERX price");

        week.pricePerShareUSD = (finalErxForWeek * erxPriceUSD) / totalShares;
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: week.pricePerShareUSD", week.pricePerShareUSD);
        week.isPriced = true;
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: week.isPriced", week.isPriced);

        currentPoolIndex = (_weekIdToPrice + 1) % 3;
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: currentPoolIndex", currentPoolIndex);

        emit WeekPriced(_weekIdToPrice, week.pricePerShareUSD, totalShares, finalErxForWeek);
        console.log("[Titan_RewardFund]:[finalizeAndPriceWeek]: exited");
    }

    // =============================================================================
    // |                     Dual-Path User Interaction Functions                    |
    // =============================================================================

    // --- 1. Upgrade Income Caps ---

    function _executeUpgradeIncomeCaps(address _user, uint8 _groupIdx) internal {
        TitanDataTypes.PackageType latestPackageType = titanRegister.getUsersLastPackageTypeInGroup(_user, _groupIdx);
        require(latestPackageType > userMainPackageInGroup[_user][_groupIdx], "TRF: No upgrade available");
        require(latestPackageType == TitanDataTypes.PackageType.VIP, "TRF: Upgrade is only for VIP");

        uint256 feeInUSD = _getVipPriceUSD(_groupIdx);
        uint256 erxPrice = _getERXPrice();
        require(erxPrice > 0, "TRF: Invalid ERX price");
        uint256 feeInErx = (feeInUSD * PRECISION) / erxPrice;

        erxToken.safeTransferFrom(_user, address(this), feeInErx);

        address activePool = rftPools[currentPoolIndex];
        erxToken.safeTransfer(activePool, feeInErx);

        userMainPackageInGroup[_user][_groupIdx] = latestPackageType;
        emit UserCapUpgraded(_user, _groupIdx, latestPackageType);
    }

    // ! correct the modifier
    function upgradeMyIncomeCaps(uint8 _groupIdx) external whenNotPaused nonReentrant /*onlyPanel*/ {
        _executeUpgradeIncomeCaps(msg.sender, _groupIdx);
    }

    // --- 2. Process Pending Points ---

    function _executeProcessPendingPoints(address _user, uint8 _groupIdx) internal {
        console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: entered", _user);
        console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: _groupIdx", _groupIdx);
        uint256 currentWeek = block.timestamp / ONE_WEEK;

        PendingPoints storage pending = userPendingPoints[_user][_groupIdx];
        require(pending.left > 0 || pending.right > 0, "TRF: No pending points");

        uint256 pointsLeft = pending.left;
        uint256 pointsRight = pending.right;
        uint256 pointsWeekId = pending.weekId;

        delete userPendingPoints[_user][_groupIdx];
        PointLedger storage ledger = userPointLedgers[_user][_groupIdx];

        if (currentWeek != pointsWeekId) {
            ledger.paidLeft += pointsLeft;
            ledger.paidRight += pointsRight;
            console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: ledger.paidLeft", ledger.paidLeft);
            console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: ledger.paidRight", ledger.paidRight);
            emit PendingPointsClaimed(_user, _groupIdx, pointsLeft, pointsRight);
        } else {
            ledger.rawLeft += pointsLeft;
            ledger.rawRight += pointsRight;
            console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: ledger.rawLeft", ledger.rawLeft);
            console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: ledger.rawRight", ledger.rawRight);
            emit PendingPointsClaimed(_user, _groupIdx, pointsLeft, pointsRight);
            _calculateBalanceAndGenerateRFTs(_user, _groupIdx);
            // _distributePointsToUpline(_user, _groupIdx, pointsLeft + pointsRight);
        }
        if (pointRelayQueue.length > 0) {
            // عدد ۳۰ به عنوان یک اندازه کوچک و ایمن برای این تابع انتخاب شده است
            _processSingleRelayTask(30);
        }

        console.log("[Titan_RewardFund]:[_executeProcessPendingPoints]: exited");
    }

    function processMyPendingPoints(uint8 _groupIdx) external nonReentrant whenNotPaused /*onlyUser*/ {
        _executeProcessPendingPoints(msg.sender, _groupIdx);
    }

    // ! note : correct the modifier
    function processPendingPointsFor(address _user, uint8 _groupIdx)
        external
        nonReentrant
        whenNotPaused /*onlyPanel*/
    {
        emit LOG("[Titan_RewardFund]:[processPendingPointsFor]: entered", _user);
        emit LOG("[Titan_RewardFund]:[processPendingPointsFor]: _groupIdx", _groupIdx);
        _executeProcessPendingPoints(_user, _groupIdx);
    }

    // --- 3. Claim RFTs ---
    mapping(uint8 => uint256) public usdClaimedThisTxInGroup;

    function _executeClaimRFTs(address _user, uint8[] calldata groupIndexesToClaim) internal {
        console.log("[Titan_RewardFund]:[_executeClaimRFTs]: entered for user", _user);

        uint256 totalUsdValueToPay = 0; // مبلغ نهایی پرداختی به کاربر
        uint256 totalSharesToClaim = 0; // مجموع سهامی که در این تراکنش ادعا می‌شود

        uint256 currentWeekId = block.timestamp / ONE_WEEK;
        uint256 weekToClaim = currentWeekId > 0 ? currentWeekId - 1 : 0;

        WeeklyData storage week = weeklyData[weekToClaim];
        require(week.isPriced, "TRF: Previous week is not priced yet");

        // بررسی اینکه آیا کاربر مشمول مالیات است یا خیر (یک بار قبل از حلقه)
        bool userIsSubjectToFee = isSubjectToLifeFee[_user];

        for (uint256 i = 0; i < groupIndexesToClaim.length; i++) {
            uint8 groupIdx = groupIndexesToClaim[i];
            require(groupIdx > 0 && groupIdx <= 7, "TRF: Invalid group index");

            uint256 sharesInWeek = userSharesInWeekByGroup[_user][groupIdx][weekToClaim];
            if (sharesInWeek == 0) continue;

            // 1. محاسبه ارزش ناخالص (Gross Value) بدون در نظر گرفتن سقف
            uint256 grossUsdForGroup = (sharesInWeek * week.pricePerShareUSD) / PRECISION;

            // 2. کسر مالیات LifeFee از ارزش ناخالص (در صورت واجد شرایط بودن)
            uint256 feeAdjustedUsdForGroup = grossUsdForGroup;
            if (userIsSubjectToFee) {
                uint256 feeAmount = (grossUsdForGroup * LIFE_FEE_BPS) / BPS_DENOMINATOR;
                feeAdjustedUsdForGroup = grossUsdForGroup - feeAmount;
                // ما می‌توانیم رویداد را در اینجا یا در انتها ثبت کنیم
            }

            // 3. اعمال سقف درآمد هفتگی بر روی مبلغِ تعدیل‌شده با مالیات
            TitanDataTypes.PackageType userPackageType = titanRegister.getUsersLastPackageTypeInGroup(_user, groupIdx);
            uint256 weeklyCapForGroup = TitanHelper.getWeeklyUsdErxCap(groupIdx, userPackageType);
            uint256 alreadyClaimedForGroup = weeklyUsdClaimedInGroup[_user][groupIdx][currentWeekId];

            uint256 remainingCap =
                weeklyCapForGroup > alreadyClaimedForGroup ? weeklyCapForGroup - alreadyClaimedForGroup : 0;

            uint256 payableUsdForGroup = feeAdjustedUsdForGroup < remainingCap ? feeAdjustedUsdForGroup : remainingCap;

            if (payableUsdForGroup > 0) {
                totalUsdValueToPay += payableUsdForGroup;
                totalSharesToClaim += sharesInWeek;

                // به‌روزرسانی مقادیر مصرفی از سقف و سهام
                weeklyUsdClaimedInGroup[_user][groupIdx][currentWeekId] += payableUsdForGroup;
                userSharesInWeekByGroup[_user][groupIdx][weekToClaim] = 0; // صفر کردن سهام این هفته پس از ادعا
            }
        }

        require(totalSharesToClaim > 0, "TRF: No valid shares to claim");

        // محاسبات نهایی و پرداخت بر اساس totalUsdValueToPay
        uint256 qbitPrice = _getQBITPrice();
        require(qbitPrice > 0, "TRF: Invalid QBIT price");
        uint256 qbitFeeInUsd = (totalUsdValueToPay * CLAIM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 qbitFeeAmount = (qbitFeeInUsd * PRECISION) / qbitPrice;

        IERC20 qbitTokenInstance = IERC20(router.getQbitToken());
        SafeERC20.safeTransferFrom(qbitTokenInstance, _user, qbitBurnerAddress, qbitFeeAmount);

        uint256 erxPrice = _getERXPrice();
        require(erxPrice > 0, "TRF: Invalid ERX price");
        uint256 erxPayoutAmount = (totalUsdValueToPay * PRECISION) / erxPrice;

        require(erxToken.balanceOf(address(this)) >= erxPayoutAmount, "TRF: Insufficient balance");
        erxToken.safeTransfer(_user, erxPayoutAmount);

        if (pointRelayQueue.length > 0) {
            // چون این تراکنش معمولاً Gas بیشتری مصرف می‌کند، می‌توانیم قطعه بزرگتری را پردازش کنیم
            _processSingleRelayTask(50);
        }

        emit RFTsClaimed(_user, totalSharesToClaim, totalUsdValueToPay, erxPayoutAmount, qbitFeeAmount);
        console.log("[Titan_RewardFund]:[_executeClaimRFTs]: exited");
    }

    // --- Internal Core Economic Logic ---

    function _calculateBalanceAndGenerateRFTs(address _user, uint8 _groupIdx) internal {
        if (
            lastBalanceTimestamp[_user][_groupIdx] > 0
                && block.timestamp > lastBalanceTimestamp[_user][_groupIdx] + RAW_POINTS_EXPIRATION_DURATION
        ) {
            PointLedger storage expiredLedger = userPointLedgers[_user][_groupIdx];
            if (expiredLedger.rawLeft > expiredLedger.rawRight) {
                uint256 amountToExpire = expiredLedger.rawLeft - expiredLedger.rawRight;
                if (amountToExpire > 0) {
                    expiredLedger.paidLeft += amountToExpire;
                    expiredLedger.rawLeft -= amountToExpire;
                    emit RawPointsExpired(_user, _groupIdx, amountToExpire, 0);
                }
            } else {
                uint256 amountToExpire = expiredLedger.rawRight - expiredLedger.rawLeft;
                if (amountToExpire > 0) {
                    expiredLedger.paidRight += amountToExpire;
                    expiredLedger.rawRight -= amountToExpire;
                    emit RawPointsExpired(_user, _groupIdx, amountToExpire, 1);
                }
            }
        }

        PointLedger storage ledger = userPointLedgers[_user][_groupIdx];
        uint256 balance = (ledger.rawLeft < ledger.rawRight) ? ledger.rawLeft : ledger.rawRight;
        emit LOG("[_calculateBalanceAndGenerateRFTs]: balance", balance);

        if (balance > 0) {
            uint256 dayId = block.timestamp / ONE_DAY;
            uint256 weekId = dayId / 7;
            TitanDataTypes.PackageType userPackageType = titanRegister.getUsersLastPackageTypeInGroup(_user, _groupIdx);

            // گام ۲: محاسبه سقف تجمعی با قانون ریست هفتگی
            uint256 lastDay = lastRftGenerationDayId[_user][_groupIdx];
            uint256 daysToAccumulate;

            if (lastDay == 0) {
                daysToAccumulate = 1; // اولین بار تولید RFT
            } else {
                uint256 lastWeek = lastDay / 7;
                if (weekId > lastWeek) {
                    daysToAccumulate = (dayId % 7) + 1; // اولین فعالیت در هفته جدید
                } else {
                    daysToAccumulate = dayId - lastDay; // فعالیت قبلی در همین هفته بوده
                    if (daysToAccumulate == 0) daysToAccumulate = 1;
                }
            }

            emit LOG("[_calculateBalanceAndGenerateRFTs]: daysToAccumulate", daysToAccumulate);
            uint256 dailyCapInShares = TitanHelper.getDailyRftShareCap(_groupIdx, userPackageType);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: dailyCapInShares", dailyCapInShares);
            uint256 dynamicCapInShares = daysToAccumulate * dailyCapInShares;
            emit LOG("[_calculateBalanceAndGenerateRFTs]: dynamicCapInShares", dynamicCapInShares);

            // گام ۳: تولید RFT تا سقف مؤثر
            uint256 alreadyGeneratedToday = dailyRftSharesGeneratedInGroup[_user][_groupIdx][dayId];
            emit LOG("[_calculateBalanceAndGenerateRFTs]: alreadyGeneratedToday", alreadyGeneratedToday);
            uint256 baseSharesPerBalance = rftBaseShares[_groupIdx];
            emit LOG("[_calculateBalanceAndGenerateRFTs]: baseSharesPerBalance", baseSharesPerBalance);
            require(baseSharesPerBalance > 0, "TRF: Invalid base shares for group");

            uint256 effectiveCap =
                dynamicCapInShares > alreadyGeneratedToday ? dynamicCapInShares - alreadyGeneratedToday : 0;
            emit LOG("[_calculateBalanceAndGenerateRFTs]: effectiveCap", effectiveCap);

            uint256 potentialShares = balance * baseSharesPerBalance;
            emit LOG("[_calculateBalanceAndGenerateRFTs]: potentialShares", potentialShares);
            uint256 balanceToProcessForRFT = balance;

            if (potentialShares > effectiveCap) {
                balanceToProcessForRFT = effectiveCap / baseSharesPerBalance;
            }
            emit LOG("[_calculateBalanceAndGenerateRFTs]: balanceToProcessForRFT", balanceToProcessForRFT);

            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.rawLeft before", ledger.rawLeft);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.rawRight before", ledger.rawRight);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.paidLeft before", ledger.paidLeft);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.paidRight before", ledger.paidRight);

            // گام ۴: به‌روزرسانی دفتر حساب (Ledger)
            ledger.rawLeft -= balance;
            ledger.rawRight -= balance;
            ledger.paidLeft += balance;
            ledger.paidRight += balance;
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.rawLeft after", ledger.rawLeft);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.rawRight after", ledger.rawRight);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.paidLeft after", ledger.paidLeft);
            emit LOG("[_calculateBalanceAndGenerateRFTs]: ledger.paidRight after", ledger.paidRight);

            if (balanceToProcessForRFT > 0) {
                _generateRFTs(_user, _groupIdx, balanceToProcessForRFT);
                lastRftGenerationDayId[_user][_groupIdx] = dayId; // ثبت آخرین روز تولید RFT
            }
            emit LOG(
                "[_calculateBalanceAndGenerateRFTs]: lastRftGenerationDayId[_user][_groupIdx]",
                lastRftGenerationDayId[_user][_groupIdx]
            );

            lastBalanceTimestamp[_user][_groupIdx] = block.timestamp;
        }
        emit LOG(
            "[_calculateBalanceAndGenerateRFTs]: lastBalanceTimestamp[_user][_groupIdx]",
            lastBalanceTimestamp[_user][_groupIdx]
        );

        console.log("[Titan_RewardFund]:[_calculateBalanceAndGenerateRFTs]: exited");
    }

    function _generateRFTs(address _user, uint8 _groupIdx, uint256 _balanceCount) internal {
        emit LOG("[Titan_RewardFund]:[_generateRFTs]: entered", _user);
        emit LOG("[Titan_RewardFund]:[_generateRFTs]: _groupIdx", _groupIdx);
        emit LOG("[Titan_RewardFund]:[_generateRFTs]: _balanceCount", _balanceCount);

        uint256 totalSharesToAdd = _balanceCount * rftBaseShares[_groupIdx];
        emit LOG("[Titan_RewardFund]:[_generateRFTs]: totalSharesToAdd", totalSharesToAdd);
        if (totalSharesToAdd > 0) {
            uint256 weekId = block.timestamp / ONE_WEEK;
            uint256 dayId = block.timestamp / ONE_DAY;

            userSharesInWeekByGroup[_user][_groupIdx][weekId] += totalSharesToAdd;
            weeklyData[weekId].totalSharesGenerated += totalSharesToAdd;
            dailyRftSharesGeneratedInGroup[_user][_groupIdx][dayId] += totalSharesToAdd;
            userTotalRftBaseShares[_user] += totalSharesToAdd;

            // بررسی شرط و فعال‌سازی پرچم مالیات با استفاده از نام‌های جدید
            if (!isSubjectToLifeFee[_user] && userTotalRftBaseShares[_user] >= LIFE_FEE_THRESHOLD_SHARES) {
                isSubjectToLifeFee[_user] = true;
                emit UserQualifiedForLifeFee(_user); // ثبت رویداد
            }

            // if (!isVoucherUser[_user] && userTotalRftBaseShares[_user] >= VOUCHER_THRESHOLD) {
            //     isVoucherUser[_user] = true;
            // }

            emit RFTsGenerated(_user, _groupIdx, _balanceCount, totalSharesToAdd, weekId);
        }
        emit LOG("[Titan_RewardFund]:[_generateRFTs]: exited");
    }

    function updateAddresses() external {
        daoAddress = router.getDao();
        supportFund = ISupportFund(router.getSupportFundContract());
        erxToken = IEuphoriaX(router.getERXToken());
        qbitToken = IQbit(router.getQbitToken());

        // emit EuphoriaX_AddressesUpdated(updateFund, daoAddress, qbitToken, block.timestamp);
    }

    function updateRouter(address newRouter) external onlyDAO {
        // if (newRouter == address(0)) revert IA();
        // if (newRouter.code.length == 0) revert TNC();
        router = IRouter(newRouter);
        // emit RouterUpdated(newRouter, block.timestamp);
    }

    // --- Main Public & User Interaction Functions ---

    function claimRFTs(uint8[] calldata groupIndexesToClaim) external nonReentrant whenNotPaused /*onlyUser*/ {
        _executeClaimRFTs(msg.sender, groupIndexesToClaim);
    }

    // !note : correct the modifier
    function claimRFTsFor(address _user, uint8[] calldata groupIndexesToClaim) external nonReentrant whenNotPaused 
    /*onlyPanel*/
    {
        _executeClaimRFTs(_user, groupIndexesToClaim);
    }

    // --- 4. Qualify For Monster Award ---
    function _executeQualifyForMonsterAward(address _user) internal {
        MonsterAward storage award = userMonsterAwards[_user];
        require(award.status == MonsterAwardStatus.None, "TRF: Award status determined");

        (, uint256 regTimestamp,,) = titanRegister.getUserBasicDetails(_user);

        // uint256 regTimestamp = titanRegister.users(_user).registrationTimestamp;
        require(regTimestamp > 0, "TRF: User not registered");
        require(block.timestamp < regTimestamp + MONSTER_MAKER_TIMEFRAME, "TRF: 30-day window passed");

        uint256 balanceCount = userPointLedgers[_user][4].paidLeft < userPointLedgers[_user][4].paidRight
            ? userPointLedgers[_user][4].paidLeft
            : userPointLedgers[_user][4].paidRight;

        if (balanceCount >= 30) {
            award.status = MonsterAwardStatus.QualifiedFor30;
            award.totalAwardAmountUSD = monsterAwardConfig30.totalAwardUSD;
            // award.totalAwardAmountUSD = 500 * PRECISION;
            emit MonsterAwardQualified(_user, award.status, award.totalAwardAmountUSD);
        } else if (balanceCount >= 10) {
            award.status = MonsterAwardStatus.QualifiedFor10;
            award.totalAwardAmountUSD = monsterAwardConfig10.totalAwardUSD;
            // award.totalAwardAmountUSD = 200 * PRECISION;
            emit MonsterAwardQualified(_user, award.status, award.totalAwardAmountUSD);
        }
    }

    function qualifyForMonsterAward() external whenNotPaused /*onlyUser*/ {
        _executeQualifyForMonsterAward(msg.sender);
    }

    function qualifyForMonsterAwardFor(address _user) external whenNotPaused onlyPanel {
        _executeQualifyForMonsterAward(_user);
    }

    // --- 5. Claim Monster Award Installment ---

    function _executeClaimMonsterAwardInstallment(address _user) internal {
        MonsterAward storage award = userMonsterAwards[_user];
        require(
            award.status == MonsterAwardStatus.QualifiedFor10 || award.status == MonsterAwardStatus.QualifiedFor30,
            "TRF: Not qualified"
        );
        require(award.amountClaimedUSD < award.totalAwardAmountUSD, "TRF: Award fully claimed");
        require(block.timestamp >= award.lastClaimTimestamp + CLAIM_WINDOW_DURATION, "TRF: Wait for next claim");

        uint256 installmentUSD = award.status == MonsterAwardStatus.QualifiedFor10
            ? monsterAwardConfig10.installmentUSD
            : monsterAwardConfig30.installmentUSD;
        // uint256 installmentUSD = award.status == MonsterAwardStatus.QualifiedFor10 ? 50 * PRECISION : 100 * PRECISION;
        uint256 remainingAward = award.totalAwardAmountUSD - award.amountClaimedUSD;
        uint256 amountToPayUSD = installmentUSD > remainingAward ? remainingAward : installmentUSD;

        award.amountClaimedUSD += amountToPayUSD;
        award.lastClaimTimestamp = uint64(block.timestamp);
        if (award.amountClaimedUSD >= award.totalAwardAmountUSD) {
            award.status = award.status == MonsterAwardStatus.QualifiedFor10
                ? MonsterAwardStatus.FullyClaimed10
                : MonsterAwardStatus.FullyClaimed30;
        }

        uint256 erxPrice = _getERXPrice();
        require(erxPrice > 0, "TRF: Invalid ERX price");
        uint256 erxToPay = (amountToPayUSD * PRECISION) / erxPrice;
        require(erxToken.balanceOf(address(this)) >= erxToPay, "TRF: Insufficient balance");
        erxToken.safeTransfer(_user, erxToPay);

        emit MonsterAwardClaimed(_user, amountToPayUSD);
    }

    function claimMonsterAwardInstallment() external nonReentrant whenNotPaused /*onlyUser*/ {
        _executeClaimMonsterAwardInstallment(msg.sender);
    }

    function claimMonsterAwardInstallmentFor(address _user) external nonReentrant whenNotPaused onlyPanel {
        _executeClaimMonsterAwardInstallment(_user);
    }

    // --- System Notification Functions ---
    /**
     * @notice Called by Titan_Register when a user's Royal status is revoked.
     * @dev Cleans up all reward-related data for the user to prevent future earnings.
     * @param _royalAddress The address of the user whose Royal status has been revoked.
     */
    function notifyRoyalStatusRevoked(address _royalAddress) external onlyTitanRegister {
        // Loop through all groups to delete group-specific data
        for (uint8 i = 1; i <= 7; i++) {
            // Delete any unprocessed raw/paid points
            delete userPointLedgers[_royalAddress][i];

            // Delete any pending points that have not been processed
            delete userPendingPoints[_royalAddress][i];

            // Delete the user's main package type for cap calculations
            delete userMainPackageInGroup[_royalAddress][i];

            // It is not strictly necessary to delete userSharesInWeekByGroup for past weeks,
            // as they are tied to priced weeks. However, clearing them ensures a full cleanup.
            // For gas efficiency, we can choose to leave historical share data.
        }

        // Delete non-group-specific reward statuses
        delete userMonsterAwards[_royalAddress];
        delete isSubjectToLifeFee[_royalAddress];

        // Resetting their total shares counter
        userTotalRftBaseShares[_royalAddress] = 0;

        // The RoyalStatusRevoked event should be defined in the IEvents interface
        // emit RoyalStatusRevoked(_royalAddress);
    }

    // --- Public View Functions ---

    function getActiveRewardPool() external view returns (address) {
        uint256 currentWeek = block.timestamp / ONE_WEEK;
        return rftPools[currentWeek % 3];
    }

    // --- Internal & Helper Functions ---

    // ADDED v15.5.0: Helper function to get the USD price of a VIP package.
    function _getVipPriceUSD(uint8 _groupIdx) internal pure returns (uint256) {
        if (_groupIdx == 1) return 20 * 1e18;
        if (_groupIdx == 2) return 60 * 1e18;
        if (_groupIdx == 3) return 100 * 1e18;
        if (_groupIdx == 4) return 200 * 1e18;
        if (_groupIdx == 5) return 600 * 1e18;
        if (_groupIdx == 6) return 1000 * 1e18;
        if (_groupIdx == 7) return 2000 * 1e18;
        revert("TRF: Invalid group for VIP price");
    }

    function _getERXPrice() internal view returns (uint256) {
        try erxToken.getCurrentPrice() returns (uint256 price) {
            if (price > 0) {
                uint256 decimals = erxToken.decimals();
                return price * (10 ** (18 - decimals));
            }
            return lastKnownERXPriceUSD;
        } catch {
            return lastKnownERXPriceUSD;
        }
    }

    function _getQBITPrice() internal view returns (uint256) {
        try qbitToken.stagePrices(qbitToken.getCurrentStage()) returns (uint256 price) {
            return price;
        } catch {
            return lastKnownQBITPriceUSD;
        }
    }

    function _cleanupExpiredWeek(uint256 _weekId) internal {
        WeeklyData storage week = weeklyData[_weekId];
        if (!week.isPriced || week.isCleanedUp) return;

        uint256 claimWindowDeadline = (_weekId + 2) * ONE_WEEK;

        if (block.timestamp >= claimWindowDeadline) {
            uint256 unclaimedBalance = week.lockedErxForPayout;

            // uint256 remainingBalance = week.lockedErxForPayout;
            if (unclaimedBalance > 0) {
                week.lockedErxForPayout = 0;
                emit WeekClaimPeriodClosed(_weekId, unclaimedBalance);
                week.isCleanedUp = true;
            }
        }
    }

    /**
     * @notice یک وظیفه را از صف امدادی برداشته، آن را برای `steps` مرحله پردازش کرده و در صورت نیاز، دوباره به صف برمی‌گرداند.
     */
    function _processSingleRelayTask(uint256 steps) internal {
        if (pointRelayQueue.length == 0) return;

        // خواندن و حذف وظیفه از ابتدای صف (بهینه)
        PointRelayTask memory task = pointRelayQueue[0];
        pointRelayQueue[0] = pointRelayQueue[pointRelayQueue.length - 1];
        pointRelayQueue.pop();

        address currentUser = task.lastRecipient;
        address highestRecipient;
        uint256 currentWeek = block.timestamp / ONE_WEEK;

        for (uint256 i = 0; i < steps; i++) {
            TitanDataTypes.UserTreeInfo memory userTreeInfo = titanRegister.getUserTreeInfo(currentUser);
            address parent = userTreeInfo.parentAddress;

            if (parent == address(0) || parent == queenAddress) {
                highestRecipient = parent == queenAddress ? parent : currentUser;
                break;
            }

            // ... (منطق بررسی صلاحیت و افزودن امتیاز دقیقاً مشابه گام ۲.۲) ...
            TitanDataTypes.UserStatus parentStatus = titanRegister.getUserStatus(parent);
            bool isStatusEligible = (
                parentStatus == TitanDataTypes.UserStatus.Active || parentStatus == TitanDataTypes.UserStatus.Royal
                    || parentStatus == TitanDataTypes.UserStatus.Queen
            );

            if (isStatusEligible && titanRegister.isGroupActive(parent, task.groupIdx)) {
                if (!hasReceivedPointForPackage[task.originatingPackageId][parent]) {
                    // ... افزودن امتیاز به pending points ...
                    hasReceivedPointForPackage[task.originatingPackageId][parent] = true;
                    // ... emit StarPointCached ...
                }
            }
            currentUser = parent;
            highestRecipient = parent;
        }

        if (highestRecipient == queenAddress) {
            emit RelayTaskCompleted(task.originatingPackageId);
        } else if (highestRecipient != address(0)) {
            // اگر زنجیره تمام نشده، وظیفه به‌روز شده را به انتهای صف برگردان
            task.lastRecipient = highestRecipient;
            pointRelayQueue.push(task);
            emit RelayTaskProcessed(task.originatingPackageId, highestRecipient, steps);
        } else {
            // اگر هیچ والد جدیدی پیدا نشد، وظیفه را برمی‌گردانیم تا دوباره تلاش شود
            pointRelayQueue.push(task);
        }
    }

    // --- Private Helper Functions (Not business logic) ---
    function _uint2str(uint256 _i) private pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            bstr[k] = bytes1(uint8(48 + _i % 10));
            _i /= 10;
        }
        return string(bstr);
    }

    function _addr2str(address _addr) private pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }

    /**
     * @notice یک تابع عمومی برای پردازش دسته‌ای صف توزیع امدادی.
     * @dev هر کسی می‌تواند این تابع را برای کمک به پیشبرد سریع‌تر توزیع امتیازات فراخوانی کند.
     * این تابع تا زمانی که Gas تراکنش به یک آستانه ایمن برسد، به پردازش ادامه می‌دهد.
     */
    function processRelayQueuePublic() external {
        // یک آستانه ایمن برای Gas تعریف می‌کنیم تا از شکست تراکنش جلوگیری شود.
        uint256 GAS_THRESHOLD = 100000;
        uint256 relayChunkSize = 50; // اندازه هر قطعه پردازشی

        while (gasleft() > GAS_THRESHOLD && pointRelayQueue.length > 0) _processSingleRelayTask(relayChunkSize);
    }

    function getPointRelayQueueSize() external view returns (uint256) {
        return pointRelayQueue.length;
    }
}
