// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Titan_Register Contract (Final Optimized Version)
 * @author Kamyar (Concept & Lead) - Dr. Satoshi Arcanum (Architecture & Security)
 * @notice لایه هویت و عضویت اکوسیستم تایتان. این قرارداد مسئولیت مدیریت کاربران،
 * ساختار درختی، و فعال‌سازی پکیج‌ها را بر عهده دارد.
 * @dev نسخه 4.0.1 - اضافه شدن توابع نمایشی برای اطلاعات کاربر
 */
import {console} from "forge-std/Test.sol";

// --- Imports ---
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";


import "libraries/TitanHelper.sol";
import "libraries/DateTime.sol";
import "libraries/TitanV2/TitanDataTypes.sol";
import "interfaces/IRouter.sol";
import "TitanV2/ITitanRegister.sol";
import "TitanV2/ITitanRewardFund.sol";
import "TitanV2/ITitanCapitalFund.sol";


contract Titan_Register is Context, Pausable, ITitanRegister {
    using SafeERC20 for IERC20;

    // --- Constants ---
    uint8 public constant GROUP_COUNT = 7;
    uint256 public constant USD_PRECISION = 1e18;
    uint256 internal constant ONE_DAY = 24 * 60 * 60;
    uint256 public constant FREE_TO_INACTIVE_DURATION = 60 * ONE_DAY;
    uint256 public constant INACTIVE_TO_BLOCKED_DURATION = 30 * ONE_DAY;
    uint256 public constant PACKAGE_VALIDITY_DURATION = 365 * ONE_DAY;
    uint256 public constant BLOCKED_USER_CLEANUP_DEFAULT_PERIOD = 90 * ONE_DAY;
    uint256 public constant PACKAGE_PURCHASE_LIMIT_PER_PERIOD = 90 * ONE_DAY;
    uint256 public constant MAX_PACKAGE_PURCHASES_IN_PERIOD = 70;
    uint256 public constant MAX_ACTIVE_PACKAGES_PER_GROUP = 10;
    uint256 public constant CLEANUP_BATCH_SIZE = 20;
    uint256 private constant UPLINE_INFO_DEPTH = 30;

    enum ActivationCategory {
        Business,
        Investor,
        Gray
    }

    // --- State Variables ---
    // ITitanRouter public titanRouter;
    IRouter public titanRouter;
    ITitanCapitalFund public titanCapitalFund;
    ITitanRewardFund public titanRewardFund;
    IERC20 public erxToken;
    IERC20 public qbitToken;
    address public updateFundRecipient;
    address public supportFundContractAddress;
    address public qbitBurnRecipient;
    address public reserveAddress;
    address public immutable queenAddress;
    address public daoAddress;
    address public immutable titanPanel;

    // --- Counters ---
    uint256 public nextUserId;
    uint256 public nextPackageId;
    uint256 public packageCounter;
    uint256 public lastPackageCounterReset;
    uint256 public totalCumulativeShares;

    // --- Mappings ---
    mapping(address => TitanDataTypes.User) internal users;
    mapping(address => bool) public isUserAddressRegistered;
    mapping(uint256 => address) public userAddressByUserId;
    mapping(uint256 => TitanDataTypes.LeanPackageInfo) public packageInfos;
    mapping(bytes32 => uint256) public packageIdByCodeHash;
    mapping(address => mapping(uint8 => uint256[])) public userActivePackageIdsInGroup;
    address[] public removeBlockedsList;
    mapping(address => bool) internal isUserInRemoveBlockedsList;
    mapping(address => uint256) public userIndexInRemoveList;
    mapping(uint256 => uint256) public weeklyShareCount;
    mapping(uint256 => uint256) public monthlyShareCount;
    mapping(address => mapping(uint8 => uint256)) public userPackageGroupExpiry;
    mapping(address => mapping(uint8 => uint8)) public userActivePackagesInGroupCount;
    mapping(address => mapping(uint8 => bool)) public userFirstActivationInGroup;

    event PanelAddressSet(address indexed panelAddress);
    event PackageSlotFreed(address indexed user, uint256 indexed packageId, uint8 indexed groupIdx);

    // --- Modifier ---
    modifier onlyDAO() {
        require(_msgSender() == daoAddress, "TR: Caller is not the DAO");
        _;
    }

    modifier onlyPanel() {
        require(msg.sender == titanPanel, "TR: Caller is not the Titan Panel");
        _;
    }

    modifier onlyUser() {
        require(tx.origin == msg.sender, "TR: Caller must be a user, not a contract");
        _;
    }

    modifier onlyCapitalFund() {
        require(_msgSender() == address(titanCapitalFund), "TR: Caller is not the Capital Fund");
        _;
    }

    constructor(
        address _initialQueenAddress,
        address _titanRouterAddress,
        address _titanPanelAddress,
        address _initialDaoAddress,
        address _initialQbitBurnRecipient
    ) {
        require(_initialQueenAddress != address(0) && _initialQueenAddress != msg.sender, "TR: Invalid Queen address");
        require(_titanRouterAddress != address(0), "TR: Invalid Router address");
        require(_titanPanelAddress != address(0), "TR: Invalid Panel address");
        require(_initialDaoAddress != address(0), "TR: Invalid DAO address");
        require(_initialQbitBurnRecipient != address(0), "TR: Invalid address");

        daoAddress = _initialDaoAddress;
        titanRouter = IRouter(_titanRouterAddress);
        titanPanel = _titanPanelAddress;
        queenAddress = _initialQueenAddress;
        qbitBurnRecipient = _initialQbitBurnRecipient;

        erxToken = IERC20(titanRouter.getERXToken());
        qbitToken = IERC20(titanRouter.getQbitToken());
        titanCapitalFund = ITitanCapitalFund(titanRouter.getCapitalFundContract());
        titanRewardFund = ITitanRewardFund(titanRouter.getRewardFundContract());
        supportFundContractAddress = titanRouter.getSupportFundContract();
        updateFundRecipient = titanRouter.getUpdateFundRecipient();
        // reserveAddress = titanRouter.getFundAddress("RESERVE");
        reserveAddress = address(999); // ! update this to reserve address

        nextUserId = 786;
        nextPackageId = 1;

        isUserAddressRegistered[_initialQueenAddress] = true;
        TitanDataTypes.User storage queen = users[_initialQueenAddress];
        queen.userId = nextUserId;
        userAddressByUserId[nextUserId] = _initialQueenAddress;
        nextUserId++;

        queen.status = TitanDataTypes.UserStatus.Queen;
        queen.isQueen = true;
        queen.registrationTimestamp = block.timestamp;
        queen.depth = 0;
        queen.pathHash = keccak256(abi.encodePacked(uint256(0), uint8(0), address(0)));

        for (uint8 i = 1; i <= GROUP_COUNT; i++) {
            userPackageGroupExpiry[_initialQueenAddress][i] = type(uint256).max;
        }

        // emit PanelAddressSet(_titanPanelAddress);

        // emit UserRegistered(_initialQueenAddress, address(0), queen.userId, block.timestamp);
    }

    //================================================================================
    // SECTION: DAO Management & Pausable Control
    //================================================================================
    function pause() external override onlyDAO {
        _pause();
    }

    function unpause() external override onlyDAO {
        _unpause();
    }

    function setDaoAddress(address _newDaoAddress) external override onlyDAO {
        require(_newDaoAddress != address(0), "TR: New DAO address cannot be zero");
        // emit DaoAddressChanged(daoAddress, _newDaoAddress);
        daoAddress = _newDaoAddress;
    }

    function addRoyal(address _newRoyalAddress) external override onlyDAO whenNotPaused {
        require(isUserAddressRegistered[_newRoyalAddress], "TR: User not registered");
        TitanDataTypes.User storage user = users[_newRoyalAddress];
        require(
            user.status != TitanDataTypes.UserStatus.Blocked && user.status != TitanDataTypes.UserStatus.Royal
                && !user.isQueen,
            "TR: Invalid status for promotion"
        );

        user.status = TitanDataTypes.UserStatus.Royal;
        user.currentPurchaseCountInPeriod = 0; // بازنشانی برای جلوگیری از مشکلات سقف خرید
        user.packagePurchaseLimitResetDueDate = block.timestamp + PACKAGE_PURCHASE_LIMIT_PER_PERIOD;
        for (uint8 groupIdx = 1; groupIdx <= GROUP_COUNT; groupIdx++) {
            userPackageGroupExpiry[_newRoyalAddress][groupIdx] = type(uint256).max;
            if (!userFirstActivationInGroup[_newRoyalAddress][groupIdx]) {
                userFirstActivationInGroup[_newRoyalAddress][groupIdx] = true;
            }
            if (userActivePackagesInGroupCount[_newRoyalAddress][groupIdx] == 0) {
                userActivePackagesInGroupCount[_newRoyalAddress][groupIdx] = 1;
            }
            // (uint256 packageId,, uint256 shareCount) =
            //     _generateAndStorePackageInfo(_newRoyalAddress, groupIdx, TitanDataTypes.PackageType.Royal);
        }
        emit RoyalAdded(_newRoyalAddress);
    }

    function removeRoyal(address _royalAddress) external override onlyDAO whenNotPaused {
        TitanDataTypes.User storage user = users[_royalAddress];
        require(user.status == TitanDataTypes.UserStatus.Royal, "TR: User is not a Royal");

        _transitionUserToInactive(_royalAddress);

        for (uint8 groupIdx = 1; groupIdx <= GROUP_COUNT; groupIdx++) {
            delete userActivePackageIdsInGroup[_royalAddress][groupIdx];
            delete userPackageGroupExpiry[_royalAddress][groupIdx];
            delete userActivePackagesInGroupCount[_royalAddress][groupIdx];
        }
        titanCapitalFund.notifyRoyalStatusRevoked(_royalAddress);
        titanRewardFund.notifyRoyalStatusRevoked(_royalAddress);
        // emit RoyalRemoved(_royalAddress);
    }

    function recoverTokens(address _tokenAddress, address _to, uint256 _amount) external override onlyDAO {
        require(_to != address(0), "TR: Invalid recipient address");
        bool isAllowedRecipient = (_to == address(titanCapitalFund)) || (_to == address(titanRewardFund))
            || (_to == supportFundContractAddress) || (_to == updateFundRecipient);
        require(isAllowedRecipient, "TR: Recipient not in whitelist");
        IERC20(_tokenAddress).safeTransfer(_to, _amount);
        emit TokensRecovered(_tokenAddress, _to, _amount);
    }

    //================================================================================
    // SECTION: User Registration
    //================================================================================
    function register(address _referrerAddress) external override whenNotPaused {
        _performRegistration(msg.sender, _referrerAddress);
        // emit UserRegistered(msg.sender, _referrerAddress, users[msg.sender].userId, block.timestamp);
    }

    function registerFor(address _user, address _referrerAddress) external whenNotPaused onlyPanel {
        _performRegistration(_user, _referrerAddress);
        // emit UserRegistered(_user, _referrerAddress, users[_user].userId, block.timestamp);
    }

    event LOG(string message);
    event LOG(string message, string value);
    event LOG(string message, bool value);
    event LOG(string message, uint256 value);
    event LOG(string message, bytes32 value);
    event LOG(string message, bytes value);
    event LOG(string message, address value);
    event LOG(string message, TitanDataTypes.User value);
    event LOG(string message, TitanDataTypes.UserStatus value);
    event LOG(string message, TitanDataTypes.PackageType value);
    event LOG(string message, TitanDataTypes.LeanPackageInfo value);
    //================================================================================
    // SECTION: Package Activation
    //================================================================================

    /**
     * @notice Direct package activation path for users (EOA).
     */
    function activatePackages(TitanDataTypes.PackageActivationInput[] calldata _packages)
        public
        override
        whenNotPaused
    {
        _executeActivatePackages(msg.sender, _packages);
    }

    /**
     * @notice Delegated package activation path for TitanPanel.
     */
    function activatePackagesFor(address _user, TitanDataTypes.PackageActivationInput[] calldata _packages)
        external
        whenNotPaused
        onlyPanel
    {
        _executeActivatePackages(_user, _packages);
    }

    /**
     * @dev Core logic for package activation, extracted to support dual-path architecture.
     */
    function _executeActivatePackages(address _userAddress, TitanDataTypes.PackageActivationInput[] calldata _packages)
        internal
    {
        TitanDataTypes.User storage user = users[_userAddress];
        TitanDataTypes.UserStatus initialUserStatus = user.status;

        _updateUserLifecycleStatus(_userAddress);
        require(user.status != TitanDataTypes.UserStatus.Blocked, "TR: User is or became blocked");
        require(user.status != TitanDataTypes.UserStatus.Royal && !user.isQueen, "TR: User status not eligible");

        uint8 totalPackagesToActivate = 0;
        for (uint256 i = 0; i < _packages.length; i++) {
            require(_packages[i].count > 0, "TR: Package count cannot be zero");
            totalPackagesToActivate += _packages[i].count;
        }
        require(
            totalPackagesToActivate > 0 && totalPackagesToActivate <= MAX_PACKAGE_PURCHASES_IN_PERIOD,
            "TR: Total package count out of bounds"
        );

        if (block.timestamp >= user.packagePurchaseLimitResetDueDate) {
            user.currentPurchaseCountInPeriod = 0;
            user.packagePurchaseLimitResetDueDate = block.timestamp + PACKAGE_PURCHASE_LIMIT_PER_PERIOD;
        }
        require(
            user.currentPurchaseCountInPeriod + totalPackagesToActivate <= MAX_PACKAGE_PURCHASES_IN_PERIOD,
            "TR: Exceeds 90-day purchase limit"
        );

        uint256 totalErxCost;
        uint256 totalQbitCost;

        for (uint256 i = 0; i < _packages.length; i++) {
            (uint8 group, TitanDataTypes.PackageType pType, bool success) =
                _parsePackageSymbol(_packages[i].packageSymbol);
            require(success, "TR: Invalid package symbol");
            uint8 count = _packages[i].count;

            _checkUserEligibility(_userAddress, group);
            require(
                userActivePackagesInGroupCount[_userAddress][group] + count <= MAX_ACTIVE_PACKAGES_PER_GROUP,
                "TR: Exceeds max active packages for group"
            );

            (uint256 erxPrice, uint256 qbitPrice) = getPackagePrice(group, pType);
            emit LOG(
                "[_executeActivatePackages]:Package Activation",
                string(
                    abi.encodePacked(
                        "Group: ", uint2str(group), ", Type: ", uint2str(uint8(pType)), ", Count: ", uint2str(count)
                    )
                )
            );
            emit LOG(
                "[_executeActivatePackages]:Package Prices",
                string(abi.encodePacked("ERX: ", uint2str(erxPrice), ", QBIT: ", uint2str(qbitPrice)))
            );
            totalErxCost += erxPrice * count;
            totalQbitCost += qbitPrice * count;
            emit LOG(
                "[_executeActivatePackages]:Total Costs",
                string(
                    abi.encodePacked("Total ERX: ", uint2str(totalErxCost), ", Total QBIT: ", uint2str(totalQbitCost))
                )
            );
        }

        erxToken.safeTransferFrom(_userAddress, address(this), totalErxCost);
        qbitToken.safeTransferFrom(_userAddress, qbitBurnRecipient, totalQbitCost);

        for (uint256 i = 0; i < _packages.length; i++) {
            (uint8 group, TitanDataTypes.PackageType pType,) = _parsePackageSymbol(_packages[i].packageSymbol);
            for (uint256 j = 0; j < _packages[i].count; j++) {
                _processSingleActivation(_userAddress, group, pType, initialUserStatus);
            }
        }
        user.currentPurchaseCountInPeriod += totalPackagesToActivate;
        emit LOG("[_executeActivatePackages]:user.currentPurchaseCountInPeriod", user.currentPurchaseCountInPeriod);

        emit LOG("[_executeActivatePackages]:removeBlockedsList.length", removeBlockedsList.length);
        emit LOG("[_executeActivatePackages]:gasleft()", gasleft());
        if (removeBlockedsList.length > 0 && gasleft() > 500_000) {
            cleanupBlockedUsersBatch(CLEANUP_BATCH_SIZE);
        }
        emit LOG("[_executeActivatePackages]:ended");
    }

    /**
     * @notice توسط CapitalFund برای آزاد کردن اسلات پکیج تسویه‌شده فراخوانی می‌شود.
     * @param _userAddress آدرس مالک پکیج.
     * @param _packageId شناسه پکیجی که تسویه شده است.
     */
    function notifyPackageSettled(address _userAddress, uint256 _packageId) external /*override*/ onlyCapitalFund {
        TitanDataTypes.LeanPackageInfo storage pkgInfo = packageInfos[_packageId];
        require(pkgInfo.owner == _userAddress, "TR: Mismatched package owner");

        uint8 groupIdx = pkgInfo.groupIdx;
        uint256[] storage activeIds = userActivePackageIdsInGroup[_userAddress][groupIdx];
        uint256 packageCount = activeIds.length;

        // الگوریتم بهینه حذف از آرایه (Swap and Pop)
        for (uint256 i = 0; i < packageCount; i++) {
            if (activeIds[i] == _packageId) {
                activeIds[i] = activeIds[packageCount - 1];
                activeIds.pop();

                userActivePackagesInGroupCount[_userAddress][groupIdx]--;

                emit PackageSlotFreed(_userAddress, _packageId, groupIdx);
                return;
            }
        }
    }

    //================================================================================
    // SECTION: User Status & Cleanup Management
    //================================================================================
    function updateUserStatus(address _userAddress) external override onlyDAO {
        console.log("[updateUserStatus]:entered for user", _userAddress);
        TitanDataTypes.User storage user = users[_userAddress];
        require(
            user.status == TitanDataTypes.UserStatus.Free || user.status == TitanDataTypes.UserStatus.Active
                || user.status == TitanDataTypes.UserStatus.Inactive,
            "TR: Status is final or not applicable"
        );
        _updateUserLifecycleStatus(_userAddress);
    }

    function cleanupBlockedUsersBatch(uint256 _batchSize) public override whenNotPaused {
        console.log("[cleanupBlockedUsersBatch]:entered with batch size", _batchSize);
        require(_batchSize > 0 && _batchSize <= CLEANUP_BATCH_SIZE, "TR: Batch size must be between 1 and 20");
        uint256 listLength = removeBlockedsList.length;
        console.log("[cleanupBlockedUsersBatch]:listLength", listLength);
        if (listLength == 0) return;
        uint256 count = _batchSize > listLength ? listLength : _batchSize;
        address[] memory usersToProcess = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            usersToProcess[i] = removeBlockedsList[listLength - 1 - i];
        }

        for (uint256 i = 0; i < count; i++) {
            address userToClean = usersToProcess[i];
            console.log("[cleanupBlockedUsersBatch]:userToClean", userToClean);
            if (users[userToClean].isFlaggedForCleanup) {
                _cleanUserFromSystem(userToClean);
            }
        }
    }

    function removeInactiveChild(address _childAddress) external override whenNotPaused onlyUser {
        _executeRemoveInactiveChild(msg.sender, _childAddress);
    }

    /**
     * @notice Delegated path for TitanPanel to remove an inactive child on behalf of a parent.
     */
    function removeInactiveChildFor(address _parentAddress, address _childAddress) external whenNotPaused onlyPanel {
        _executeRemoveInactiveChild(_parentAddress, _childAddress);
    }

    /**
     * @dev Core logic for removing an inactive child, extracted to support dual-path architecture.
     */
    function _executeRemoveInactiveChild(address _parentAddress, address _childAddress) internal {
        TitanDataTypes.User storage childUser = users[_childAddress];
        require(isUserAddressRegistered[_childAddress], "TR: Child not registered");
        require(childUser.parentAddress == _parentAddress, "TR: Caller is not the parent");
        require(childUser.status == TitanDataTypes.UserStatus.Blocked, "TR: Child is not blocked");
        require(childUser.directChildrenCount == 0, "TR: Child must have no children");

        _cleanUserFromSystem(_childAddress);

        if (removeBlockedsList.length > 0 && gasleft() > 500_000) {
            cleanupBlockedUsersBatch(CLEANUP_BATCH_SIZE);
        }
    }

    //================================================================================
    // SECTION: View & Helper Functions
    //================================================================================
    function getPackagePrice(uint8 _groupIdx, TitanDataTypes.PackageType _packageType)
        public
        view
        override
        returns (uint256 erxAmount, uint256 qbitAmount)
    {
        uint256 packagePriceUSD;
        if (_groupIdx == 1) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 10 * USD_PRECISION : 20 * USD_PRECISION;
        } else if (_groupIdx == 2) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 30 * USD_PRECISION : 60 * USD_PRECISION;
        } else if (_groupIdx == 3) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 50 * USD_PRECISION : 100 * USD_PRECISION;
        } else if (_groupIdx == 4) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 100 * USD_PRECISION : 200 * USD_PRECISION;
        } else if (_groupIdx == 5) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 300 * USD_PRECISION : 600 * USD_PRECISION;
        } else if (_groupIdx == 6) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 500 * USD_PRECISION : 1000 * USD_PRECISION;
        } else if (_groupIdx == 7) {
            packagePriceUSD =
                (_packageType == TitanDataTypes.PackageType.Classic) ? 1000 * USD_PRECISION : 2000 * USD_PRECISION;
        } else {
            revert("TR: Invalid group index for price");
        }

        uint256 qbitPriceUSD = (packagePriceUSD * 5) / 100;

        erxAmount = TitanHelper.convertUSDToSingleToken(address(titanRouter), packagePriceUSD, "ERX");
        qbitAmount = TitanHelper.convertUSDToSingleToken(address(titanRouter), qbitPriceUSD, "QBIT");
    }

    function isGroupActive(address _user, uint8 _groupIdx) public view override returns (bool) {
        require(_groupIdx >= 1 && _groupIdx <= GROUP_COUNT, "TR: Invalid group index");
        require(users[_user].registrationTimestamp > 0, "TR: User not registered");

        for (uint8 i = 1; i <= _groupIdx; i++) {
            if (userPackageGroupExpiry[_user][i] < block.timestamp) {
                return false;
            }
        }
        return true;
    }

    function getShareCount(uint8 _groupIdx) public pure override returns (uint8 shareCount) {
        shareCount = uint8(TitanHelper.getCFTPerMonth(_groupIdx));
    }

    function getPackageOwner(string calldata _packageCode) external view override returns (address) {
        bytes32 codeHash = keccak256(abi.encodePacked(_packageCode));
        uint256 packageId = packageIdByCodeHash[codeHash];
        require(packageId != 0, "TR: Package code not found");
        return packageInfos[packageId].owner;
    }

    function getPackageInfo(uint256 _packageId)
        external
        view
        override
        returns (TitanDataTypes.LeanPackageInfo memory)
    {
        require(packageInfos[_packageId].activationTimestamp > 0, "TR: Package ID not found");
        return packageInfos[_packageId];
    }

    function getBatchUplineInfo(address _user, uint8 _groupIdx)
        public
        view
        override
        returns (TitanDataTypes.UplineInfo[30] memory uplines)
    {
        address currentUser = _user;

        for (uint8 i = 0; i < UPLINE_INFO_DEPTH; i++) {
            address parentAddress = users[currentUser].parentAddress;

            if (parentAddress == address(0)) {
                break;
            }

            TitanDataTypes.User storage parentUser = users[parentAddress];
            bool groupActivity = this.isGroupActive(parentAddress, _groupIdx);

            uplines[i] = TitanDataTypes.UplineInfo({
                userAddress: parentAddress,
                status: parentUser.status,
                isGroupActive: groupActivity
            });

            currentUser = parentAddress;
        }

        return uplines;
    }

    function getUsersLastPackageTypeInGroup(address _user, uint8 _groupIdx)
        external
        view
        override
        returns (TitanDataTypes.PackageType)
    {
        uint256[] storage activeIds = userActivePackageIdsInGroup[_user][_groupIdx];
        TitanDataTypes.PackageType highestType = TitanDataTypes.PackageType.Classic;

        for (uint256 i = 0; i < activeIds.length; i++) {
            TitanDataTypes.LeanPackageInfo storage pkgInfo = packageInfos[activeIds[i]];
            if (uint8(pkgInfo.pkgType) > uint8(highestType)) {
                highestType = pkgInfo.pkgType;
            }
        }
        return highestType;
    }

    // ** تابع جدید: نمایش کدشناسه و وضعیت کاربر **
    function getUserInfo(address _userAddress)
        external
        view
        returns (uint256 userId, TitanDataTypes.UserStatus status)
    {
        require(isUserAddressRegistered[_userAddress], "TR: User not registered");
        TitanDataTypes.User storage user = users[_userAddress];
        return (user.userId, user.status);
    }

    // ** تابع جدید: نمایش گروه‌های فعال کاربر **
    function getUserActiveGroups(address _userAddress) external view returns (bool[] memory activeGroups) {
        require(isUserAddressRegistered[_userAddress], "TR: User not registered");
        activeGroups = new bool[](GROUP_COUNT + 1); // شاخص 0 استفاده نمی‌شود
        for (uint8 i = 1; i <= GROUP_COUNT; i++) {
            activeGroups[i] = this.isGroupActive(_userAddress, i);
        }
        return activeGroups;
    }

    // ** تابع جدید: نمایش پکیج‌های فعال کاربر **
    function getUserActivePackages(address _userAddress)
        external
        view
        returns (TitanDataTypes.LeanPackageInfo[] memory activePackages)
    {
        require(isUserAddressRegistered[_userAddress], "TR: User not registered");
        uint256 totalActivePackages = 0;
        for (uint8 i = 1; i <= GROUP_COUNT; i++) {
            totalActivePackages += userActivePackageIdsInGroup[_userAddress][i].length;
        }
        activePackages = new TitanDataTypes.LeanPackageInfo[](totalActivePackages);
        uint256 index = 0;
        for (uint8 i = 1; i <= GROUP_COUNT; i++) {
            uint256[] storage packageIds = userActivePackageIdsInGroup[_userAddress][i];
            for (uint256 j = 0; j < packageIds.length; j++) {
                activePackages[index] = packageInfos[packageIds[j]];
                index++;
            }
        }
        return activePackages;
    }

    // ** تابع جدید: نمایش آدرس فرزندان مستقیم چپ و راست **
    function getDirectChildren(address _userAddress) external view returns (address leftChild, address rightChild) {
        require(isUserAddressRegistered[_userAddress], "TR: User not registered");
        TitanDataTypes.User storage user = users[_userAddress];
        return (user.directChildrenAddresses[0], user.directChildrenAddresses[1]);
    }

    // ** تابع جدید: نمایش تعداد کاربران در شاخه‌های چپ و راست **
    function getSubtreeCounts(address _userAddress) external view returns (uint256 leftCount, uint256 rightCount) {
        require(isUserAddressRegistered[_userAddress], "TR: User not registered");
        TitanDataTypes.User storage user = users[_userAddress];
        return (user.leftLegSubtreeCount, user.rightLegSubtreeCount);
    }

    // ** تابع جدید: نمایش تعداد کل کاربران ثبت‌شده **
    function getTotalRegisteredUsers() external view returns (uint256) {
        return nextUserId - 786; // با فرض شروع nextUserId از 786
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
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
            k--;
            uint8 temp = (48 + uint8(_i % 10));
            bstr[k] = bytes1(temp);
            _i /= 10;
        }
        return string(bstr);
    }

    //================================================================================
    // SECTION: Internal (Private) Functions
    //================================================================================
    function _performRegistration(address _childAddress, address _parentAddress) internal {
        require(!isUserAddressRegistered[_childAddress], "TR: User already registered");
        require(!TitanHelper.isContract(_childAddress), "TR: Smart contracts cannot register");
        require(_parentAddress != address(0) && _parentAddress != address(this), "TR: Referrer address invalid");
        require(isUserAddressRegistered[_parentAddress], "TR: Referrer not registered");

        TitanDataTypes.User storage referrerUser = users[_parentAddress];
        require(referrerUser.status != TitanDataTypes.UserStatus.Blocked, "TR: Blocked users cannot be referrers");
        require(referrerUser.directChildrenCount < 2, "TR: Referrer slots are full");

        TitanDataTypes.User storage childUser = users[_childAddress];
        uint256 newUserId = nextUserId++;
        childUser.userId = newUserId;
        userAddressByUserId[newUserId] = _childAddress;
        isUserAddressRegistered[_childAddress] = true;
        childUser.parentAddress = _parentAddress;
        if (referrerUser.directChildrenAddresses[0] == address(0)) {
            referrerUser.directChildrenAddresses[0] = _childAddress;
            childUser.positionInParentLeg = 0;
        } else {
            referrerUser.directChildrenAddresses[1] = _childAddress;
            childUser.positionInParentLeg = 1;
        }
        referrerUser.directChildrenCount++;

        if (childUser.positionInParentLeg == 0) {
            referrerUser.leftLegSubtreeCount++;
        } else {
            referrerUser.rightLegSubtreeCount++;
        }

        childUser.registrationTimestamp = block.timestamp;
        childUser.status = TitanDataTypes.UserStatus.Free;
        childUser.statusTransitionDueDate = block.timestamp + FREE_TO_INACTIVE_DURATION;
        childUser.packagePurchaseLimitResetDueDate = block.timestamp + PACKAGE_PURCHASE_LIMIT_PER_PERIOD;
        childUser.depth = referrerUser.depth + 1;
        childUser.pathHash = keccak256(abi.encodePacked(childUser.depth, childUser.positionInParentLeg, _parentAddress));
        assert(childUser.depth == referrerUser.depth + 1);
    }

    function _checkUserEligibility(address _userAddress, uint8 _groupIdxToActivate) internal view {
        console.log("[_checkUserEligibility]:_userAddress", _userAddress);
        console.log("[_checkUserEligibility]:_groupIdxToActivate", _groupIdxToActivate);
        TitanDataTypes.User storage user = users[_userAddress];
        require(user.registrationTimestamp > 0, "TR: User not registered");
        require(
            user.status != TitanDataTypes.UserStatus.Blocked && user.status != TitanDataTypes.UserStatus.Royal
                && !user.isQueen,
            "TR: User status not eligible"
        );

        if (_groupIdxToActivate > 1) {
            require(this.isGroupActive(_userAddress, _groupIdxToActivate - 1), "TR: Prerequisite group is not active");
        }
    }

    function _processSingleActivation(
        address _userAddress,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        TitanDataTypes.UserStatus _initialStatus
    ) internal {
        emit LOG("[_processSingleActivation]:entered for user", _userAddress);
        emit LOG("[_processSingleActivation]:groupIdx", _groupIdx);
        emit LOG("[_processSingleActivation]:packageType", _packageType);
        ActivationCategory category;

        // TitanDataTypes.UserStatus initialUserStatus = users[_userAddress].status;
        emit LOG("[_processSingleActivation]:_initialStatus", uint8(_initialStatus));

        uint256 groupExpiryTimestamp = userPackageGroupExpiry[_userAddress][_groupIdx];
        emit LOG("[_processSingleActivation]:groupExpiryTimestamp", groupExpiryTimestamp);
        bool isReactivatingExpiredGroup = (groupExpiryTimestamp > 0 && block.timestamp > groupExpiryTimestamp);
        emit LOG("[_processSingleActivation]:isReactivatingExpiredGroup", isReactivatingExpiredGroup);

        bool isBusiness = _isBusinessActivation(_userAddress, _groupIdx);
        emit LOG("[_processSingleActivation]:isBusiness", isBusiness);

        TitanDataTypes.User storage user = users[_userAddress];
        emit LOG("[_processSingleActivation]:user.status", user.status);

        if (
            user.status == TitanDataTypes.UserStatus.Royal || user.isQueen
                || user.status == TitanDataTypes.UserStatus.Inactive
        ) {
            category = ActivationCategory.Gray;
        } else if (isBusiness) {
            category = ActivationCategory.Business;
        } else {
            category = ActivationCategory.Investor;
        }

        (uint256 packageId, /*string memory packageCode*/, uint256 shareCount) =
            _generateAndStorePackageInfo(_userAddress, _groupIdx, _packageType);

        if (user.status == TitanDataTypes.UserStatus.Free || user.status == TitanDataTypes.UserStatus.Inactive) {
            user.status = TitanDataTypes.UserStatus.Active;
            user.statusTransitionDueDate = 0;
        }

        userPackageGroupExpiry[_userAddress][_groupIdx] = block.timestamp + PACKAGE_VALIDITY_DURATION;
        userActivePackagesInGroupCount[_userAddress][_groupIdx]++;

        if (!userFirstActivationInGroup[_userAddress][_groupIdx]) {
            userFirstActivationInGroup[_userAddress][_groupIdx] = true;
        }

        userActivePackageIdsInGroup[_userAddress][_groupIdx].push(packageId);
        (uint256 erxPrice,) = getPackagePrice(_groupIdx, _packageType);
        _distributeFunds(erxPrice, _groupIdx, _packageType, category);

        emit LOG("[_processSingleActivation]:titanCapitalFund", address(titanCapitalFund));
        emit LOG("[_processSingleActivation]:titanRewardFund", address(titanRewardFund));
        emit LOG("[_processSingleActivation]:category", uint8(category));

        if (category == ActivationCategory.Business) {
            // Notify both funds, generate Star Points
            titanCapitalFund.notifyPackageActivation(
                packageId, _userAddress, _groupIdx, _packageType, erxPrice, shareCount, true
            );
            titanRewardFund.notifyStarPointGeneration(packageId, _userAddress, _groupIdx, _packageType, shareCount);
        } else if (category == ActivationCategory.Gray) {
            // Notify only RewardFund, NO Star Points
            // Note: For RewardFund, 'isBusiness' flag is what controls Star Point generation.
            // We need to ensure the function signature in RewardFund can handle this.
            // Assuming notifyStarPointGeneration with a false/different flag means "investor only"
            titanRewardFund.notifyGroupReactivation(packageId, _userAddress, _groupIdx, _packageType, shareCount); // Using a more specific function
        } else {
            // Investor category
            // Notify only CapitalFund
            titanCapitalFund.notifyPackageActivation(
                packageId, _userAddress, _groupIdx, _packageType, erxPrice, shareCount, false
            );
        }
    }

    function _isBusinessActivation(address _userAddress, uint8 _groupIdx) internal view returns (bool) {
        if (
            users[_userAddress].status == TitanDataTypes.UserStatus.Inactive
                || users[_userAddress].status == TitanDataTypes.UserStatus.Royal || users[_userAddress].isQueen
        ) {
            return false;
        }

        uint256 groupExpiryTimestamp = userPackageGroupExpiry[_userAddress][_groupIdx];
        if (groupExpiryTimestamp > 0 && block.timestamp > groupExpiryTimestamp) {
            return false;
        }

        return (
            !userFirstActivationInGroup[_userAddress][_groupIdx]
                && block.timestamp <= users[_userAddress].registrationTimestamp + PACKAGE_VALIDITY_DURATION
        );
    }

    function _generateAndStorePackageInfo(address _owner, uint8 _groupIdx, TitanDataTypes.PackageType _packageType)
        internal
        returns (uint256 newPackageId, string memory packageCode, uint256 shareCount)
    {
        console.log("[_generateAndStorePackageInfo]:entered");
        console.log("[_generateAndStorePackageInfo]:block.timestamp", block.timestamp);
        console.log("[_generateAndStorePackageInfo]:lastPackageCounterReset", lastPackageCounterReset);
        if (block.timestamp >= lastPackageCounterReset + 7 * ONE_DAY) {
            packageCounter = 0;
            lastPackageCounterReset = block.timestamp;
        }
        packageCounter++;
        (uint256 year, uint256 month, uint256 day) = BokkyPooBahsDateTimeLibrary.timestampToDate(block.timestamp);
        // (uint256 year, uint256 month, uint256 day) = TitanHelper.timestampToDate(block.timestamp);
        console.log("[_generateAndStorePackageInfo]:year", year);
        console.log("[_generateAndStorePackageInfo]:month", month);
        console.log("[_generateAndStorePackageInfo]:day", day);
        uint256 weekOfMonth = (day - 1) / 7 + 1;
        console.log("[_generateAndStorePackageInfo]:weekOfMonth", weekOfMonth);
        shareCount = getShareCount(_groupIdx);
        console.log("[_generateAndStorePackageInfo]:shareCount", shareCount);
        string memory typePart = (_packageType == TitanDataTypes.PackageType.Classic)
            ? "C"
            : ((_packageType == TitanDataTypes.PackageType.VIP) ? "V" : "R");
        console.log("[_generateAndStorePackageInfo]:typePart", typePart);
        string memory randPart = _generateRandomSegment(totalCumulativeShares + packageCounter);
        console.log("[_generateAndStorePackageInfo]:randPart", randPart);
        packageCode = string(
            abi.encodePacked(
                "G",
                uint2str(_groupIdx),
                typePart,
                uint2str(year % 100),
                month < 10 ? string(abi.encodePacked("0", uint2str(month))) : uint2str(month),
                uint2str(weekOfMonth),
                randPart,
                uint2str(packageCounter),
                "S",
                uint2str(shareCount)
            )
        );
        console.log("[_generateAndStorePackageInfo]:packageCode", packageCode);
        // uint256 cumulativeSharesAtCreation = totalCumulativeShares;
        totalCumulativeShares += shareCount;
        console.log("[_generateAndStorePackageInfo]:totalCumulativeShares", totalCumulativeShares);
        uint256 weekId = (year * 1000) + (block.timestamp / (7 * ONE_DAY));
        uint256 monthId = (year * 100) + month;
        weeklyShareCount[weekId] += shareCount;
        console.log("[_generateAndStorePackageInfo]:weeklyShareCount[weekId]", weeklyShareCount[weekId]);
        monthlyShareCount[monthId] += shareCount;
        console.log("[_generateAndStorePackageInfo]:monthlyShareCount[monthId]", monthlyShareCount[monthId]);
        newPackageId = nextPackageId++;
        packageInfos[newPackageId] = TitanDataTypes.LeanPackageInfo({
            owner: _owner,
            activationTimestamp: uint64(block.timestamp),
            groupIdx: _groupIdx,
            pkgType: _packageType,
            isSettledInCapitalFund: false
        });
        emit LOG("[_generateAndStorePackageInfo]:packageInfos[newPackageId]", packageInfos[newPackageId]);
        bytes32 codeHash = keccak256(abi.encodePacked(packageCode));
        emit LOG("[_generateAndStorePackageInfo]:codeHash", codeHash);
        packageIdByCodeHash[codeHash] = newPackageId;
        console.log("[_generateAndStorePackageInfo]:packageIdByCodeHash[codeHash]", packageIdByCodeHash[codeHash]);
        // emit PackageCodeGenerated(_owner, packageCode, newPackageId, shareCount, cumulativeSharesAtCreation);
    }

    function _distributeFunds(
        uint256 _erxAmount,
        uint8 _groupIdx,
        TitanDataTypes.PackageType _packageType,
        ActivationCategory _category
    ) internal {
        uint256 cap;
        uint256 rwd;
        uint256 sup;
        uint256 upd;
        if (_category == ActivationCategory.Business) {
            if (_groupIdx <= 3) {
                if (_packageType == TitanDataTypes.PackageType.Classic) {
                    cap = 55;
                    rwd = 30;
                    sup = 10;
                    upd = 5;
                } else {
                    cap = 50;
                    rwd = 35;
                    sup = 10;
                    upd = 5;
                }
            } else {
                if (_packageType == TitanDataTypes.PackageType.Classic) {
                    cap = 60;
                    rwd = 25;
                    sup = 10;
                    upd = 5;
                } else {
                    cap = 45;
                    rwd = 30;
                    sup = 10;
                    upd = 5;
                }
            }
        } else {
            cap = 70;
            rwd = 10;
            sup = 10;
            upd = 10;
        }
        require(cap + rwd + sup + upd == 100, "TR: Invalid percentages");
        uint256 capitalAmount = (_erxAmount * cap) / 100;
        uint256 rewardAmount = (_erxAmount * rwd) / 100;
        uint256 supportAmount = (_erxAmount * sup) / 100;
        // uint256 updateAmount = _erxAmount - capitalAmount - rewardAmount - supportAmount;
        uint256 updateAmount = (_erxAmount * upd) / 100;

        console.log("[_distributeFunds]:_erxAmount share", _erxAmount);
        console.log("[_distributeFunds]:capitalAmount share", capitalAmount);
        console.log("[_distributeFunds]:rewardAmount share", rewardAmount);
        console.log("[_distributeFunds]:supportAmount share", supportAmount);
        console.log("[_distributeFunds]:updateAmount share", updateAmount);

        // Verify we're not trying to distribute more than we have
        uint256 totalDistribution = capitalAmount + rewardAmount + supportAmount + updateAmount;
        console.log("[_distributeFunds]:totalDistribution share", totalDistribution);
        require(totalDistribution <= _erxAmount, "TR: Distribution exceeds available amount");

        console.log(
            "[_distributeFunds]:erxToken.balanceOf(register) before titanCapitalFund", erxToken.balanceOf(address(this))
        );
        console.log(
            "[_distributeFunds]:titanCapitalFund.getActiveCapitalPool() before",
            erxToken.balanceOf(titanCapitalFund.getActiveCapitalPool())
        );

        try erxToken.transfer(titanCapitalFund.getActiveCapitalPool(), capitalAmount) {
            console.log("[_distributeFunds]:erxToken.balanceOf(register) after", erxToken.balanceOf(address(this)));
            console.log(
                "[_distributeFunds]:titanCapitalFund.getActiveCapitalPool() after",
                erxToken.balanceOf(titanCapitalFund.getActiveCapitalPool())
            );
        } catch {
            // emit FundTransferFailed(titanCapitalFund.getActiveCapitalPool(), capitalAmount, block.timestamp);
            erxToken.safeTransfer(reserveAddress, capitalAmount);
        }
        console.log(
            "[_distributeFunds]:erxToken.balanceOf(register) before titanRewardFund", erxToken.balanceOf(address(this))
        );
        try erxToken.transfer(titanRewardFund.getActiveRewardPool(), rewardAmount) {
            console.log("[_distributeFunds]:erxToken.balanceOf(register) after", erxToken.balanceOf(address(this)));
            console.log(
                "[_distributeFunds]:titanRewardFund.getActiveRewardPool() after",
                erxToken.balanceOf(titanRewardFund.getActiveRewardPool())
            );
        } catch {
            // emit FundTransferFailed(titanRewardFund.getActiveRewardPool(), rewardAmount, block.timestamp);
            erxToken.safeTransfer(reserveAddress, rewardAmount);
        }
        console.log(
            "[_distributeFunds]:erxToken.balanceOf(register) before supportFundContractAddress",
            erxToken.balanceOf(address(this))
        );
        try erxToken.transfer(supportFundContractAddress, supportAmount) {
            console.log("[_distributeFunds]:erxToken.balanceOf(register) after", erxToken.balanceOf(address(this)));
            console.log(
                "[_distributeFunds]:supportFundContractAddress after", erxToken.balanceOf(supportFundContractAddress)
            );
        } catch {
            // emit FundTransferFailed(supportFundContractAddress, supportAmount, block.timestamp);
            erxToken.safeTransfer(reserveAddress, supportAmount);
        }
        console.log(
            "[_distributeFunds]:erxToken.balanceOf(register) before updateFundRecipient",
            erxToken.balanceOf(address(this))
        );
        console.log("[_distributeFunds]:sending updateAmount to updateFundRecipient", updateAmount);
        try erxToken.transfer(updateFundRecipient, updateAmount) {
            console.log("[_distributeFunds]:erxToken.balanceOf(register) after", erxToken.balanceOf(address(this)));
            console.log("[_distributeFunds]:updateFundRecipient after", erxToken.balanceOf(updateFundRecipient));
        } catch (bytes memory lowLevelData) {
            emit LOG("[_distributeFunds]:transferring to updateFundRecipient, lowLevelData:", lowLevelData);
            // emit FundTransferFailed(updateFundRecipient, updateAmount, block.timestamp);
            erxToken.safeTransfer(reserveAddress, updateAmount);
        }

        // emit FundsDistributed(
        //     titanCapitalFund.getActiveCapitalPool(),
        //     capitalAmount,
        //     titanRewardFund.getActiveRewardPool(),
        //     rewardAmount,
        //     supportFundContractAddress,
        //     supportAmount,
        //     updateFundRecipient,
        //     updateAmount
        // );
    }

    function _generateRandomSegment(uint256 _seed) private view returns (string memory) {
        bytes memory result = new bytes(5);
        bytes memory chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender, _seed)));
        for (uint256 i = 0; i < 5; i++) {
            result[i] = chars[rand % chars.length];
            rand /= chars.length;
        }
        return string(result);
    }

    function _parsePackageSymbol(string calldata _symbol)
        internal
        pure
        returns (uint8 group, TitanDataTypes.PackageType pType, bool success)
    {
        console.log("[_parsePackageSymbol]:entered with symbol", _symbol);
        bytes memory symbolBytes = bytes(_symbol);
        if (symbolBytes.length != 3) return (0, TitanDataTypes.PackageType.Classic, false);
        if (symbolBytes[0] != "G") return (0, TitanDataTypes.PackageType.Classic, false);
        bytes1 groupChar = symbolBytes[1];
        if (groupChar >= "1" && groupChar <= "7") {
            group = uint8(groupChar) - 48;
        } else {
            return (0, TitanDataTypes.PackageType.Classic, false);
        }
        bytes1 typeChar = symbolBytes[2];
        if (typeChar == "C") {
            pType = TitanDataTypes.PackageType.Classic;
        } else if (typeChar == "V") {
            pType = TitanDataTypes.PackageType.VIP;
        } else {
            return (0, TitanDataTypes.PackageType.Classic, false);
        }
        return (group, pType, true);
    }

    function _updateUserLifecycleStatus(address _userAddress) private {
        console.log("[_updateUserLifecycleStatus]:entered for user", _userAddress);
        TitanDataTypes.User storage user = users[_userAddress];

        if (user.status == TitanDataTypes.UserStatus.Free && block.timestamp > user.statusTransitionDueDate) {
            _transitionUserToInactive(_userAddress);
        } else if (user.status == TitanDataTypes.UserStatus.Inactive && block.timestamp > user.statusTransitionDueDate)
        {
            _transitionUserToBlocked(_userAddress);
        } else if (user.status == TitanDataTypes.UserStatus.Active) {
            if (
                userPackageGroupExpiry[_userAddress][1] > 0 && block.timestamp > userPackageGroupExpiry[_userAddress][1]
            ) {
                _transitionUserToInactive(_userAddress);
            }
        }
    }

    function _transitionUserToInactive(address _userAddress) private {
        TitanDataTypes.User storage user = users[_userAddress];
        if (user.status == TitanDataTypes.UserStatus.Inactive) return;
        user.status = TitanDataTypes.UserStatus.Inactive;
        user.statusTransitionDueDate = block.timestamp + INACTIVE_TO_BLOCKED_DURATION;
        // emit UserStatusUpdated(_userAddress, TitanDataTypes.UserStatus.Inactive, user.statusTransitionDueDate);
    }

    function _transitionUserToBlocked(address _userAddress) private {
        TitanDataTypes.User storage user = users[_userAddress];
        if (user.status == TitanDataTypes.UserStatus.Blocked) return;
        user.status = TitanDataTypes.UserStatus.Blocked;
        user.statusTransitionDueDate = 0;
        if (user.directChildrenCount == 0 && !isUserInRemoveBlockedsList[_userAddress]) {
            _addUserToCleanupList(_userAddress);
        }
        // emit UserStatusUpdated(_userAddress, TitanDataTypes.UserStatus.Blocked, 0);
    }

    function _addUserToCleanupList(address _userAddress) private {
        TitanDataTypes.User storage user = users[_userAddress];
        user.isFlaggedForCleanup = true;
        user.cleanupDueTimestamp = block.timestamp + BLOCKED_USER_CLEANUP_DEFAULT_PERIOD;

        isUserInRemoveBlockedsList[_userAddress] = true;
        removeBlockedsList.push(_userAddress);
        userIndexInRemoveList[_userAddress] = removeBlockedsList.length - 1;

        // emit UserFlaggedForCleanup(_userAddress, user.cleanupDueTimestamp);
    }

    function _cleanUserFromSystem(address _userAddress) private {
        console.log("[_cleanUserFromSystem]:entered with user address", _userAddress);
        TitanDataTypes.User storage userToClean = users[_userAddress];
        console.log("[_cleanUserFromSystem]:userToClean.registrationTimestamp", userToClean.registrationTimestamp);
        require(userToClean.registrationTimestamp > 0, "TR: User does not exist");
        address parentAddress = userToClean.parentAddress;
        console.log("[_cleanUserFromSystem]:parentAddress", parentAddress);
        uint256 userId = userToClean.userId;
        console.log("[_cleanUserFromSystem]:userId", userId);
        uint8 position = userToClean.positionInParentLeg;
        console.log("[_cleanUserFromSystem]:position", position);
        console.log(
            "[_cleanUserFromSystem]:isUserInRemoveBlockedsList[_userAddress]", isUserInRemoveBlockedsList[_userAddress]
        );

        if (isUserInRemoveBlockedsList[_userAddress]) {
            _removeFromRemoveListStorage(_userAddress);
        }

        if (parentAddress != address(0)) {
            TitanDataTypes.User storage parentUser = users[parentAddress];
            console.log(
                "[_cleanUserFromSystem]:parentUser.directChildrenAddresses[position]",
                parentUser.directChildrenAddresses[position]
            );
            if (parentUser.directChildrenAddresses[position] == _userAddress) {
                parentUser.directChildrenAddresses[position] = address(0);
                console.log(
                    "[_cleanUserFromSystem]:parentUser.directChildrenAddresses[position]",
                    parentUser.directChildrenAddresses[position]
                );
                parentUser.directChildrenCount--;
                console.log("[_cleanUserFromSystem]:parentUser.directChildrenCount", parentUser.directChildrenCount);

                if (
                    parentUser.status == TitanDataTypes.UserStatus.Blocked && parentUser.directChildrenCount == 0
                        && !isUserInRemoveBlockedsList[parentAddress]
                ) {
                    _addUserToCleanupList(parentAddress);
                }
            }
        }

        delete isUserAddressRegistered[_userAddress];
        delete userAddressByUserId[userId];
        delete users[_userAddress];

        for (uint8 i = 1; i <= GROUP_COUNT; i++) {
            delete userPackageGroupExpiry[_userAddress][i];
            delete userActivePackagesInGroupCount[_userAddress][i];
            delete userFirstActivationInGroup[_userAddress][i];
            delete userActivePackageIdsInGroup[_userAddress][i];
        }

        emit UserCleaned(_userAddress, parentAddress, userId);
    }

    function _removeFromRemoveListStorage(address _userAddress) private {
        console.log("[_removeFromRemoveListStorage]:entered with user address", _userAddress);
        require(isUserInRemoveBlockedsList[_userAddress], "TR: User not in cleanup list");
        uint256 indexToRemove = userIndexInRemoveList[_userAddress];
        console.log("[_removeFromRemoveListStorage]:indexToRemove", indexToRemove);
        console.log("[_removeFromRemoveListStorage]:removeBlockedsList.length", removeBlockedsList.length);
        uint256 lastIndex = removeBlockedsList.length - 1;
        console.log("[_removeFromRemoveListStorage]:lastIndex", lastIndex);
        if (indexToRemove != lastIndex) {
            address lastUser = removeBlockedsList[lastIndex];
            console.log("[_removeFromRemoveListStorage]:lastUser", lastUser);
            removeBlockedsList[indexToRemove] = lastUser;
            userIndexInRemoveList[lastUser] = indexToRemove;
        }
        removeBlockedsList.pop();
        delete isUserInRemoveBlockedsList[_userAddress];
        delete userIndexInRemoveList[_userAddress];
    }

    function getUserBasicDetails(address _userAddress)
        external
        view
        returns (
            uint256 userId,
            uint256 registrationTimestamp,
            uint256 statusTransitionDueDate,
            uint256 packagePurchaseLimitResetDueDate
        )
    {
        TitanDataTypes.User storage user = users[_userAddress];
        return (
            user.userId, user.registrationTimestamp, user.statusTransitionDueDate, user.packagePurchaseLimitResetDueDate
        );
    }

    function getUserBasicInfo(address _userAddress)
        external
        view
        override
        returns (TitanDataTypes.UserBasicInfo memory)
    {
        TitanDataTypes.User storage user = users[_userAddress];

        return TitanDataTypes.UserBasicInfo({
            userId: user.userId,
            status: user.status,
            registrationTimestamp: user.registrationTimestamp,
            statusTransitionDueDate: user.statusTransitionDueDate,
            packagePurchaseLimitResetDueDate: user.packagePurchaseLimitResetDueDate,
            currentPurchaseCountInPeriod: user.currentPurchaseCountInPeriod
        });
    }

    /**
     * @notice Returns the structural/tree information for a user.
     * @dev Specifically created for other contracts like RewardFund to query tree data efficiently.
     */
    function getUserTreeInfo(address _userAddress) external view returns (TitanDataTypes.UserTreeInfo memory) {
        TitanDataTypes.User storage user = users[_userAddress];

        return TitanDataTypes.UserTreeInfo({
            parentAddress: user.parentAddress,
            positionInParentLeg: user.positionInParentLeg,
            depth: user.depth,
            pathHash: user.pathHash,
            directChildrenCount: user.directChildrenCount,
            directChildrenAddresses: user.directChildrenAddresses,
            leftLegSubtreeCount: user.leftLegSubtreeCount,
            rightLegSubtreeCount: user.rightLegSubtreeCount
        });
    }

    function getUserStatusInfo(address _userAddress)
        external
        view
        override
        returns (TitanDataTypes.UserStatusInfo memory)
    {
        TitanDataTypes.User storage user = users[_userAddress];

        return TitanDataTypes.UserStatusInfo({
            isQueen: user.isQueen,
            isFlaggedForCleanup: user.isFlaggedForCleanup,
            cleanupDueTimestamp: user.cleanupDueTimestamp
        });
    }

    function getUserFullInfo(address _userAddress)
        external
        view
        override
        returns (TitanDataTypes.UserFullInfo memory)
    {
        return TitanDataTypes.UserFullInfo({
            basic: this.getUserBasicInfo(_userAddress),
            tree: this.getUserTreeInfo(_userAddress),
            status: this.getUserStatusInfo(_userAddress)
        });
    }

    function getUserStatus(address _userAddress) external view returns (TitanDataTypes.UserStatus) {
        return users[_userAddress].status;
    }

    function updateAddresses() external {
        erxToken = IERC20(titanRouter.getERXToken());
        qbitToken = IERC20(titanRouter.getQbitToken());
        titanCapitalFund = ITitanCapitalFund(titanRouter.getCapitalFundContract());
        titanRewardFund = ITitanRewardFund(titanRouter.getRewardFundContract());
        supportFundContractAddress = titanRouter.getSupportFundContract();
        updateFundRecipient = titanRouter.getUpdateFundRecipient();
        // emit EuphoriaX_AddressesUpdated(updateFund, daoAddress, qbitToken, block.timestamp);
    }

    function updateRouter(address newRouter) external onlyDAO {
        // if (newRouter == address(0)) revert IA();
        // if (newRouter.code.length == 0) revert TNC();
        titanRouter = IRouter(newRouter);
        // emit RouterUpdated(newRouter, block.timestamp);
    }
}
