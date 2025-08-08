// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
 * ▓▓                                                                             ▓▓
 * ▓▓    ███████╗██╗   ██╗██████╗ ██╗  ██╗ ██████╗ ██████╗ ██╗ █████╗ ██╗  ██╗    ▓▓
 * ▓▓    ██╔════╝██║   ██║██╔══██╗██║  ██║██╔═══██╗██╔══██╗██║██╔══██╗╚██╗██╔╝    ▓▓
 * ▓▓    █████╗  ██║   ██║██████╔╝███████║██║   ██║██████╔╝██║███████║ ╚███╔╝     ▓▓
 * ▓▓    ██╔══╝  ██║   ██║██╔═══╝ ██╔══██║██║   ██║██╔══██╗██║██╔══██║ ██╔██╗     ▓▓
 * ▓▓    ███████╗╚██████╔╝██║     ██║  ██║╚██████╔╝██║  ██║██║██║  ██║██╔╝ ██╗    ▓▓
 * ▓▓    ╚══════╝ ╚═════╝ ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝    ▓▓
 * ▓▓                                                                             ▓▓
 * ▓▓                          🚀      EUPHORIAX     🚀                          ▓▓
 * ▓▓                          ⚡ EUPHORIA ECOSYSTEM ⚡                          ▓▓
 * ▓▓                                                                             ▓▓
 * ▓▓                      🔮 THE FUTURE IS DECENTRALIZED 🔮                     ▓▓
 * ▓▓                                                                             ▓▓
 * ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
 */
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "interfaces/IRouter.sol";
import {IEuphoriaXMigrator} from "interfaces/IXMigrator.sol";
import {IEuphoriaEvents, ITitanEventsShared, IEuphoriaEventsShared} from "interfaces/IEvents.sol";
import {IUpdateFund} from "interfaces/IUpdateFund.sol";

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract EuphoriaX is
    IERC20Errors,
    ERC20,
    ReentrancyGuard,
    Pausable,
    IEuphoriaEvents,
    ITitanEventsShared,
    IEuphoriaEventsShared
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _userKeys;
    EnumerableSet.AddressSet private _whaleKeys;

    uint256 private constant _divisor = 1000;

    uint256 public constant DAO_DELAY = 24 hours;
    uint256 public constant MAX_PRICE_CHANGE_PERCENT = 20;
    uint256 public constant MAX_PRICE_DROP_PERCENT = 3;
    uint256 constant dailyLimitPercentage = 100; // 10%

    bool public isForkMigration;
    address public migrationTarget;
    uint256 public migrationAnnouncedTime;

    uint256 public blockedTxCount;
    uint256 public lastBlockedTxTime;
    uint256 public lastPriceBeforeTx;

    IERC20Metadata[] public stablecoins;
    IRouter router;
    IUniswapV2Router public swapRouter;

    address public _treasury;
    address public daoAddress;
    address public updateFund;
    address public qbitToken;

    uint256 private _totalBurnt;
    uint256 public investors;
    uint256 public lastPrice;
    uint256 public lastPriceUpdateTime;

    bool activePenalty = true;

    enum TradeDirection {
        Buy,
        Sell,
        Transfer
    }

    struct UserActivity {
        uint256 totalBalance; // Total balance
        uint256 consecutiveTxCount; // Consecutive transaction count
        uint256 txCountInMinute; // Tx count in the last minute
        uint256 lastMinuteReset; // Last minute reset timestamp
        uint256 lastTxTimestamp; // Last transaction timestamp
        uint256 hourlyTxCount; // Hourly tx count
        uint256 lastHourlyReset; // Last hourly reset
        uint256 penaltyEndTime; // Penalty end time
        uint256 lastPenaltyReset; // Last penalty reset
        uint256 violationCount; // Violation count
        uint8 violationLevel; // Violation level
    }

    struct ContractInfo {
        uint256 totalLockedValue;
        address[] stablecoinAddresses;
        uint256[] stablecoinBalances;
        uint256 totalTokens;
        uint256 totalSupply;
        uint256 totalBurnt;
        uint256 currentPrice;
    }

    // Whale management
    enum WhaleType {
        None,
        MiniWhale,
        PinkWhale,
        BlueWhale,
        KillerWhale
    }

    struct WhaleInfo {
        WhaleType whaleType;
        uint256 firstHoldTimestamp;
        uint256 lastTxTimestamp;
        uint256 hourlyTxCount;
        uint256 lastHourlyReset;
        uint256 dailyVolume;
        uint256 lastDailyReset;
        uint256 dailyTxCount;
        uint256 weeklyVolumeAmount;
        uint256 lastWeeklyReset;
        uint256 weeklyViolationCount;
        uint256 penaltyEndTime;
        uint256 consecutiveTxCount;
    }

    mapping(string => address) public supportedStableCoins;
    mapping(address => bool) public isSupportedStablecoin;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => uint256) public minAmount;
    mapping(address => UserActivity) public userActivity;
    mapping(address => WhaleInfo) public whaleInfo;
    mapping(address => bool) public whitelisted;
    mapping(address => bool) public isInvestor;

    error OD(); // OnlyDao
    error MONM(); // Minimum order is 1 USD
    error US(); // Unsupported Stablecoin
    error NW(); // Not whitelisted
    error ISB(); // Insufficient stablecoin balance
    error ISA(); // Insufficient stablecoin allowance
    error ITB(); // Insufficient token balance
    error ISI(); // Invalid stablecoin index
    error ISL(); // Insufficient liquidity for this stablecoin
    error IP(); // Invalid price
    error IA(); // Invalid address
    error AW(); // Already whitelisted
    error TNC(); // Target must be a contract
    error MNA(); // Migration Not announced
    error MDNP(); // Migration delay not passed
    error AS(); // Already supported
    error MPL(); // Max penalty level reached
    error HA7(); // hold at least 7 days before upgrading
    error HA30(); // hold at least 30 days before upgrading
    error SD(); // sane decimals
    error MAN(); // Migration already announced
    error IPL(); // Invalid Penalty Level
    error SNE(); // Stablecoin Not Empty

    modifier onlyDAO() {
        if (msg.sender != daoAddress) revert OD();
        _;
    }

    modifier validPrice() {
        uint256 beforePrice = getCurrentPrice();
        if (lastPriceBeforeTx > 0) {
            restrictPriceDrop(lastPriceBeforeTx, beforePrice);
        }
        _;
        uint256 afterPrice = getCurrentPrice();
        restrictPriceDrop(beforePrice, afterPrice);
    }

    constructor(address _IRouter) ERC20("EuphoriaX", "ERX") {
        if (_IRouter == address(0)) revert IA();
        router = IRouter(_IRouter);
        _treasury = address(this);
        daoAddress = router.getDao();
        updateFund = router.getUpdateFundRecipient();
        qbitToken = router.getQbitToken();

        address[] memory initialStablecoins = new address[](4);
        initialStablecoins[0] = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063; // DAI
        initialStablecoins[1] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; // old bridged USDC
        initialStablecoins[2] = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // new native USDC
        initialStablecoins[3] = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // USDT
        for (uint256 i = 0; i < initialStablecoins.length; i++) {
            address stablecoin = initialStablecoins[i];
            stablecoins.push(IERC20Metadata(stablecoin));
            uint8 dec = IERC20Metadata(stablecoin).decimals();
            if (dec > 18) revert SD();
            if (stablecoin == address(0)) revert IA();
            string memory stbcSymbol = IERC20Metadata(stablecoin).symbol();
            supportedStableCoins[stbcSymbol] = stablecoin;
            isSupportedStablecoin[stablecoin] = true;
            tokenDecimals[stablecoin] = dec;
            minAmount[stablecoin] = 10 ** dec;
        }

        swapRouter = IUniswapV2Router(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
        whitelisted[router.getUpdateFundRecipient()] = true;
    }

    function buy(uint256 usdAmount, string memory tokenSymbol)
        public
        whenNotPaused
        nonReentrant
        validPrice
        returns (uint256)
    {
        address stbcAddress = getTokenAddress(tokenSymbol);
        if (!isSupportedStablecoin[stbcAddress]) {
            revert US();
        }
        uint8 dec = tokenDecimals[stbcAddress];
        uint256 normUsdAmount = normalizeTokenDecimals(usdAmount, dec, 18);
        if (normUsdAmount < normalizeTokenDecimals(minAmount[stbcAddress], dec, 18)) revert MONM();
        address buyer = _msgSender();
        IERC20 stablecoin = IERC20(stbcAddress);

        uint256 amountToTransferInTokenDecimals = denormalizeTokenDecimals(normUsdAmount, 18, dec);

        if (stablecoin.balanceOf(buyer) < amountToTransferInTokenDecimals) revert ISB();
        if (stablecoin.allowance(buyer, address(this)) < amountToTransferInTokenDecimals) revert ISA();

        uint256 currentPrice = getCurrentPrice();
        if (currentPrice <= 0) revert IP();
        (uint256 erxAmount,, uint256 treasuryFee, uint256 updateFundFee) =
            _handleTransaction(normUsdAmount, currentPrice);
        if (erxAmount == 0) revert ITB();

        stablecoin.safeTransferFrom(buyer, address(this), amountToTransferInTokenDecimals);

        if (!isInvestor[buyer] && balanceOf(buyer) == 0) {
            isInvestor[buyer] = true;
            investors++;
            if (!_userKeys.contains(buyer)) {
                _userKeys.add(buyer);
            }
        }

        uint256 normTreasuryFee = denormalizeTokenDecimals(treasuryFee, 18, dec);
        uint256 normUpdateFee = denormalizeTokenDecimals(updateFundFee, 18, dec);
        uint256 tFee = normTreasuryFee + normUpdateFee;

        uint256 denormUsdAmount = denormalizeTokenDecimals(normUsdAmount, 18, dec);

        if (stablecoin.balanceOf(address(this)) < tFee && _treasury == address(this)) revert ISL();

        if (normTreasuryFee > 0) {
            stablecoin.safeTransfer(_treasury, normTreasuryFee);
        }
        if (normUpdateFee > 0) {
            _sendUpdateFee(stablecoin, normUpdateFee);
        }

        _mint(buyer, erxAmount);
        UserActivity storage activity = userActivity[buyer];
        _updateUserBalance(buyer);
        activity.lastTxTimestamp = block.timestamp;
        updatePrice();
        emit Buy(buyer, denormUsdAmount, erxAmount, block.timestamp);
        emit FeeCollected(buyer, normTreasuryFee, normUpdateFee, uint8(TradeDirection.Buy));

        return erxAmount;
    }

    function sell(uint256 erxAmount, string memory tokenSymbol)
        public
        whenNotPaused
        nonReentrant
        validPrice
        returns (uint256)
    {
        address stbcAddress = getTokenAddress(tokenSymbol);
        if (!isSupportedStablecoin[stbcAddress]) {
            revert US();
        }

        uint8 dec = tokenDecimals[stbcAddress];
        address seller = _msgSender();

        // Check ERX balance
        if (balanceOf(seller) < erxAmount) revert ERC20InsufficientBalance(seller, balanceOf(seller), erxAmount);
        if (erxAmount == 0) {
            revert("Invalid token amount");
        }

        uint256 currentPrice = getCurrentPrice();
        if (currentPrice <= 0) revert IP();

        // Calculate USD value in 18 decimals
        uint256 usdValueNormalized = (erxAmount * currentPrice) / 1e18;

        // Calculate fees using normalized amount (18 decimals)
        (uint256 totalFee, uint256 treasuryFee, uint256 updateFundFee) =
            _calcFee(usdValueNormalized, TradeDirection.Sell);

        uint256 totalFeeInERX = (totalFee * 1e18) / currentPrice;
        uint256 treasuryFeeInERX = (treasuryFee * 1e18) / currentPrice;
        uint256 updateFundFeeInERX = (updateFundFee * 1e18) / currentPrice;

        uint256 remainingERX = erxAmount - totalFeeInERX;
        if (remainingERX == 0) revert("Fee exceeds sell amount");

        uint256 remainingUsdValue = (remainingERX * currentPrice) / 1e18;

        uint256 userReceivesStablecoin = denormalizeTokenDecimals(remainingUsdValue, 18, dec);

        IERC20 stablecoin = IERC20(stbcAddress);

        if (stablecoin.balanceOf(address(this)) < userReceivesStablecoin) {
            revert("Insufficient contract stablecoin balance");
        }

        _enforceTxRestrictions(seller);
        _whalesCare(seller, erxAmount);

        uint256 totalBurningAmt = remainingERX + treasuryFeeInERX;
        _burn(seller, totalBurningAmt);
        _totalBurnt += totalBurningAmt;

        // Transfer stablecoins to user
        stablecoin.safeTransfer(seller, userReceivesStablecoin);

        if (updateFundFeeInERX > 0) {
            _transfer(seller, updateFund, updateFundFeeInERX);
            _notifyUpdateFund(updateFundFeeInERX);
        }

        // Update user activity
        UserActivity storage activity = userActivity[seller];
        _updateUserBalance(seller);
        activity.lastTxTimestamp = block.timestamp;

        // Update investor status if balance becomes zero
        if (balanceOf(seller) == 0 && isInvestor[seller]) {
            isInvestor[seller] = false;
            investors--;
            if (_userKeys.contains(seller)) {
                _userKeys.remove(seller);
            }
        }

        updatePrice();
        emit Sell(seller, usdValueNormalized, erxAmount, block.timestamp);
        emit FeeCollected(seller, treasuryFeeInERX, updateFundFeeInERX, uint8(TradeDirection.Sell));

        return userReceivesStablecoin;
    }

    function transfer(address to, uint256 erxAmount) public override whenNotPaused validPrice returns (bool) {
        address sender = _msgSender();
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        if (erxAmount == 0) revert ITB();

        uint256 currentPrice = getCurrentPrice();
        if (currentPrice == 0 && erxAmount > 0) revert IP();
        uint256 usdValue = (erxAmount * currentPrice) / 1e18;

        (uint256 totalFee, uint256 treasuryFee, uint256 updateFundFee) = _calcFee(usdValue, TradeDirection.Transfer);

        uint256 totalFeeInERX = (totalFee * 1e18) / currentPrice;
        uint256 treasuryFeeInERX = (treasuryFee * 1e18) / currentPrice;
        uint256 updateFundFeeInERX = (updateFundFee * 1e18) / currentPrice;

        uint256 burnFee = totalFeeInERX - updateFundFeeInERX;
        uint256 totalRequired = erxAmount + totalFeeInERX;
        if (balanceOf(sender) < totalRequired) {
            revert ERC20InsufficientBalance(sender, balanceOf(sender), totalRequired);
        }

        _enforceTxRestrictions(sender);
        _whalesCare(sender, erxAmount);

        super.transfer(address(_treasury), totalRequired);
        if (totalFeeInERX > 0) {
            require(balanceOf(address(_treasury)) >= totalFeeInERX + erxAmount, "Insufficient treasury balance");
            if (burnFee > 0) {
                _burn(address(_treasury), burnFee);
                _totalBurnt += burnFee;
            }

            if (updateFundFeeInERX > 0) {
                _transfer(_treasury, updateFund, updateFundFeeInERX);
            }
        }
        _transfer(_treasury, to, erxAmount);

        _updateUserBalance(sender);
        _updateUserBalance(to);
        _whalesCare(to, erxAmount);

        if (isInvestor[sender] && balanceOf(sender) == 0) {
            isInvestor[sender] = false;
            if (investors > 0) {
                investors--;
            }
            if (_userKeys.contains(sender)) {
                _userKeys.remove(sender);
            }
        }
        if (!isInvestor[to] && balanceOf(to) > 0) {
            isInvestor[to] = true;
            investors++;
            if (!_userKeys.contains(to)) {
                _userKeys.add(to);
            }
        }

        updatePrice();

        if (updateFundFeeInERX > 0) {
            _notifyUpdateFund(updateFundFeeInERX);
        }

        emit FeeCollected(sender, treasuryFeeInERX, updateFundFeeInERX, uint8(TradeDirection.Transfer));
        return true;
    }

    function updateSwapRouter(address newRouter) external onlyDAO {
        if (newRouter == address(0)) revert IA();
        swapRouter = IUniswapV2Router(newRouter);
    }

    function addToWhitelist(address contractAddress) external onlyDAO {
        if (contractAddress == address(0)) revert IA();
        if (whitelisted[contractAddress]) revert AW();
        whitelisted[contractAddress] = true;
    }

    function removeFromWhitelist(address contractAddress) external onlyDAO {
        if (!whitelisted[contractAddress]) revert NW();
        whitelisted[contractAddress] = false;
    }

    function togglePenalty() external onlyDAO {
        activePenalty = !activePenalty;
    }

    function updateAddresses() external {
        daoAddress = router.getDao();
        updateFund = router.getUpdateFundRecipient();
        qbitToken = router.getQbitToken();

        emit EuphoriaX_AddressesUpdated(updateFund, daoAddress, qbitToken, block.timestamp);
    }

    function updateRouter(address newRouter) external onlyDAO {
        if (newRouter == address(0)) revert IA();
        if (newRouter.code.length == 0) revert TNC();
        router = IRouter(newRouter);
        emit RouterUpdated(newRouter, block.timestamp);
    }

    function getAllWhales() external view returns (address[] memory) {
        return _whaleKeys.values();
    }

    function getUsersPage(uint256 start, uint256 count) external view returns (address[] memory) {
        uint256 len = _userKeys.length();
        if (start >= len) {
            return new address[](0);
        }
        if (start + count > len) count = len - start;
        address[] memory page = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = _userKeys.at(start + i);
        }
        return page;
    }

    function getSupportedStablecoins() external view returns (address[] memory tokens) {
        tokens = new address[](stablecoins.length);
        for (uint256 i = 0; i < stablecoins.length; i++) {
            tokens[i] = address(stablecoins[i]);
        }
    }

    function getStablecoinSettings(address token) external view returns (uint8 decimals_, uint256 minAmount_) {
        if (!isSupportedStablecoin[token]) revert US();
        return (tokenDecimals[token], minAmount[token]);
    }

    function convertStableCoin(address stablecoin, uint256 amount, uint256 minAmountOut, uint256 deadline)
        external
        onlyDAO
        whenNotPaused
    {
        if (!isSupportedStablecoin[stablecoin]) revert US();
        if (stablecoins.length == 0) revert("No target token");
        if (amount == 0) revert("Zero amount");
        if (deadline < block.timestamp) revert("Expired deadline");

        IERC20Metadata fromToken = IERC20Metadata(stablecoin);
        IERC20Metadata toToken = stablecoins[0];

        if (address(fromToken) == address(toToken)) revert("Same token");
        if (fromToken.balanceOf(_treasury) < amount) revert ITB();

        _safeApprove(fromToken, address(swapRouter), amount);

        address[] memory path = new address[](2);
        path[0] = address(fromToken);
        path[1] = address(toToken);
        uint256 _minAmountOut = minAmountOut > 0 ? minAmountOut : (amount * 99) / 100;
        swapRouter.swapExactTokensForTokens(amount, _minAmountOut, path, _treasury, block.timestamp + deadline);

        _safeApprove(fromToken, address(swapRouter), 0);
    }

    function addStablecoin(address stablecoin) external onlyDAO {
        if (isSupportedStablecoin[stablecoin]) revert AS();
        if (stablecoin == address(0)) revert IA();
        stablecoins.push(IERC20Metadata(stablecoin));
        uint8 dec = IERC20Metadata(stablecoin).decimals();
        if (dec > 18) revert SD(); // guard against weird tokens
        supportedStableCoins[IERC20Metadata(stablecoin).symbol()] = stablecoin;
        isSupportedStablecoin[stablecoin] = true;
        tokenDecimals[stablecoin] = dec;
        minAmount[stablecoin] = 10 ** dec;
    }

    function removeStablecoin(uint256 index) external onlyDAO {
        if (index >= stablecoins.length) revert ISI();
        address removingCoinAddress = address(stablecoins[index]);
        IERC20 removingCoin = IERC20(removingCoinAddress);
        uint256 currentBalance = removingCoin.balanceOf(address(this));

        if (currentBalance > 0) {
            revert SNE();
        }
        _removeStablecoin(removingCoinAddress);
        for (uint256 i = index; i < stablecoins.length - 1; i++) {
            stablecoins[i] = stablecoins[i + 1];
        }
        stablecoins.pop();
        emit StablecoinRemoved(removingCoinAddress, block.timestamp);
    }

    function _removeStablecoin(address stablecoin) internal {
        if (!isSupportedStablecoin[stablecoin]) revert ISA();
        if (stablecoin == address(0)) revert IA();
        isSupportedStablecoin[stablecoin] = false;
        delete supportedStableCoins[IERC20Metadata(stablecoin).symbol()];
        delete tokenDecimals[stablecoin];
        delete minAmount[stablecoin];
    }

    function getAllUsers() public view returns (address[] memory) {
        return _userKeys.values();
    }

    function getPenaltyDuration(uint8 level) public pure returns (uint256 baseDuration) {
        if (level == 1) baseDuration = 10 minutes;
        else if (level == 2) baseDuration = 1 hours;
        else if (level == 3) baseDuration = 24 hours;
        else if (level == 4) baseDuration = 72 hours;
        else if (level == 5) baseDuration = 30 days;
        if (level == 0 || level > 5) {
            revert IPL();
        }
    }

    function usdToERX(uint256 usdAmount) public view returns (uint256) {
        uint256 currentPrice = getCurrentPrice();
        if (currentPrice == 0) {
            if (usdAmount > 0) revert IP();
            return 0;
        }
        return (usdAmount * 1e18) / currentPrice;
    }

    function erxToUSD(uint256 erxAmount) public view returns (uint256) {
        uint256 currentPrice = getCurrentPrice();
        return (erxAmount * currentPrice) / 1e18;
    }

    function getTokenAddress(string memory symbol_) public view returns (address) {
        address token = supportedStableCoins[symbol_];
        if (token == address(0)) {
            revert US();
        }
        return token;
    }

    function getStablecoinBalance(uint256 tokenIndex) public view returns (uint256) {
        if (tokenIndex >= stablecoins.length) revert ISI();
        return stablecoins[tokenIndex].balanceOf(_treasury);
    }

    function getAllStablecoinBalances() public view returns (address[] memory tokens, uint256[] memory balances) {
        tokens = new address[](stablecoins.length);
        balances = new uint256[](stablecoins.length);
        for (uint256 i = 0; i < stablecoins.length; i++) {
            tokens[i] = address(stablecoins[i]);
            balances[i] = stablecoins[i].balanceOf(_treasury);
        }
        return (tokens, balances);
    }

    function getContractInfo() public view returns (ContractInfo memory) {
        (address[] memory tokens, uint256[] memory balances) = getAllStablecoinBalances();
        return ContractInfo({
            totalLockedValue: getTotalLockedValue(),
            stablecoinAddresses: tokens,
            stablecoinBalances: balances,
            // totalTokens: totalBurnt() + totalSupply(),
            totalTokens: totalTokens(),
            totalSupply: totalSupply(),
            totalBurnt: totalBurnt(),
            currentPrice: getCurrentPrice()
        });
    }

    function getCurrentPrice() public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return 1e17;
        return (getTotalLockedValue() * 1e18) / _totalSupply;
    }

    function getTotalLockedValue() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < stablecoins.length; i++) {
            address tokenAddr = address(stablecoins[i]);
            uint8 tokenDec = tokenDecimals[tokenAddr];
            uint256 balance = stablecoins[i].balanceOf(_treasury);
            total += normalizeTokenDecimals(balance, tokenDec, 18);
        }
        return total;
    }

    function totalBurnt() internal view returns (uint256) {
        return _totalBurnt;
    }

    function totalTokens() internal view returns (uint256) {
        return _totalBurnt + totalSupply();
    }

    function emergencyPause() public onlyDAO {
        _pause();
    }

    function emergencyUnpause() public onlyDAO {
        _unpause();
    }

    function transferFrom(address from, address to, uint256 erxAmount)
        public
        override
        whenNotPaused
        validPrice
        returns (bool)
    {
        address spender = _msgSender();
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (erxAmount == 0) revert ITB();

        uint256 currentPrice = getCurrentPrice();
        if (currentPrice == 0 && erxAmount > 0) revert IP();
        uint256 usdValue = (erxAmount * currentPrice) / 1e18;

        (uint256 totalFee, uint256 treasuryFee, uint256 updateFundFee) = _calcFee(usdValue, TradeDirection.Transfer);

        uint256 totalFeeInERX = (totalFee * 1e18) / currentPrice;
        uint256 treasuryFeeInERX = (treasuryFee * 1e18) / currentPrice;
        uint256 updateFundFeeInERX = (updateFundFee * 1e18) / currentPrice;

        uint256 burnFee = totalFeeInERX - updateFundFeeInERX;

        uint256 totalRequired = erxAmount + totalFeeInERX;
        if (balanceOf(from) < totalRequired) {
            revert ERC20InsufficientBalance(from, balanceOf(from), totalRequired);
        }
        _spendAllowance(from, spender, totalRequired);

        _enforceTxRestrictions(from);
        _whalesCare(from, erxAmount);

        super.transferFrom(from, address(_treasury), totalRequired);

        if (totalFeeInERX > 0) {
            require(balanceOf(address(_treasury)) >= totalFeeInERX + erxAmount, "Insufficient treasury balance");
            if (burnFee > 0) {
                _burn(address(_treasury), burnFee);
                _totalBurnt += burnFee;
            }
            if (updateFundFeeInERX > 0) {
                _transfer(_treasury, updateFund, updateFundFeeInERX);
            }
        }
        _transfer(_treasury, to, erxAmount);

        _updateUserBalance(from);
        _updateUserBalance(to);
        _whalesCare(to, erxAmount);

        if (isInvestor[from] && balanceOf(from) == 0) {
            isInvestor[from] = false;
            if (investors > 0) {
                investors--;
            }
            if (_userKeys.contains(from)) {
                _userKeys.remove(from);
            }
        }
        if (!isInvestor[to] && balanceOf(to) > 0) {
            isInvestor[to] = true;
            investors++;
            if (!_userKeys.contains(to)) {
                _userKeys.add(to);
            }
        }
        updatePrice();

        if (updateFundFeeInERX > 0) {
            _notifyUpdateFund(updateFundFeeInERX);
        }

        emit FeeCollected(from, treasuryFeeInERX, updateFundFeeInERX, uint8(TradeDirection.Transfer));
        return true;
    }

    function updatePrice() internal {
        uint256 currentPrice = getCurrentPrice();
        uint256 timeElapsed = block.timestamp - lastPriceUpdateTime;

        if (timeElapsed > 1 hours) {
            lastPrice = currentPrice;
            lastPriceUpdateTime = block.timestamp;
        } else if (lastPrice > 0) {
            uint256 priceDiff = currentPrice > lastPrice ? currentPrice - lastPrice : lastPrice - currentPrice;
            uint256 maxChange = (lastPrice * MAX_PRICE_CHANGE_PERCENT) / 100;
            if (priceDiff > maxChange) {
                if (currentPrice > lastPrice) {
                    currentPrice = lastPrice + maxChange;
                } else {
                    currentPrice = lastPrice - maxChange;
                }
            }
        }
        lastPrice = currentPrice;
        lastPriceUpdateTime = block.timestamp;
    }

    function _enforceTxRestrictions(address user) internal whenNotPaused {
        if (whitelisted[user]) return;
        UserActivity storage activity = userActivity[user];

        uint256 now_ = block.timestamp;
        if (activity.penaltyEndTime > now_) {
            revert("User is penalized");
        }

        if (now_ >= activity.lastMinuteReset + 65) {
            activity.txCountInMinute = 0;
            activity.lastMinuteReset = now_;
        }

        if (checkMinuteLimit(user)) {
            _applyPenalty(user);
            return;
        }

        uint256 blocksSinceLastTx = (now_ - activity.lastTxTimestamp) / 2;
        if (blocksSinceLastTx < 32) {
            activity.consecutiveTxCount++;
        } else {
            activity.consecutiveTxCount = 1;
        }
        activity.txCountInMinute++;
        activity.lastTxTimestamp = now_;

        uint256 lastResetTime = activity.lastPenaltyReset;
        bool shouldReset = false;

        if (now_ >= lastResetTime + 7 days && activity.violationCount <= 4) {
            shouldReset = true;
        } else if (now_ >= lastResetTime + 30 days && activity.violationCount > 4) {
            shouldReset = true;
        }
        if (shouldReset) {
            activity.violationLevel = 0;
            activity.penaltyEndTime = 0;
            activity.lastPenaltyReset = now_;
            activity.violationCount = 0;
        }
    }

    function checkMinuteLimit(address user) internal view returns (bool) {
        UserActivity storage activity = userActivity[user];
        return (block.timestamp - activity.lastMinuteReset < 65 && activity.txCountInMinute >= 2);
    }

    function _applyPenalty(address user) internal {
        UserActivity storage activity = userActivity[user];
        if (activity.violationLevel >= 5) revert MPL();
        activity.txCountInMinute = 0;
        activity.consecutiveTxCount = 0;

        activity.violationLevel = activity.violationLevel < 5 ? activity.violationLevel + 1 : 5;
        activity.violationCount++;

        uint256 penaltyDuration = getPenaltyDuration(activity.violationLevel);
        activity.penaltyEndTime = block.timestamp + penaltyDuration;

        activity.lastPenaltyReset = block.timestamp;
        activity.lastMinuteReset = block.timestamp;
        emit UserPenalized(user, activity.violationLevel, activity.penaltyEndTime);
    }

    function _whalesCare(address user, uint256 amount) internal whenNotPaused {
        if (whitelisted[user]) return;
        WhaleInfo storage info = whaleInfo[user];
        uint256 now_ = block.timestamp;

        if (info.penaltyEndTime > now_) {
            revert("Whale is penalized");
        }
        if (info.penaltyEndTime != 0 && now_ > info.penaltyEndTime) {
            info.penaltyEndTime = 0;
            info.weeklyViolationCount = 0;
        }

        if (info.lastTxTimestamp > 0 && now_ < info.lastTxTimestamp + 5 minutes) {
            revert("Whale cooldown: wait 5 minutes");
        }

        uint256 userBalance = balanceOf(user);
        uint256 totalSupplyCache = totalSupply();

        uint256 percentage = 0;

        if (totalSupplyCache > 0 && userBalance > 0) percentage = (userBalance * 100e18) / totalSupplyCache;
        uint256 usdValue = (userBalance * getCurrentPrice()) / 1e18;

        WhaleType wTier = WhaleType.None;
        if (percentage >= 25e18 && usdValue >= 750_000e18) {
            wTier = WhaleType.KillerWhale;
        } else if (percentage >= 15e18 && usdValue >= 300_000e18) {
            wTier = WhaleType.BlueWhale;
        } else if (percentage >= 10e18 && usdValue >= 100_000e18) {
            wTier = WhaleType.PinkWhale;
        } else if (percentage >= 5e18 && usdValue >= 10_000e18) {
            wTier = WhaleType.MiniWhale;
        }

        if (wTier == WhaleType.None) {
            info.firstHoldTimestamp = 0;
            info.whaleType = WhaleType.None;
            if (_whaleKeys.contains(user)) {
                _whaleKeys.remove(user);
            }
            return;
        }

        if (wTier != info.whaleType) {
            if (wTier > info.whaleType) {
                if (wTier != WhaleType.None && info.firstHoldTimestamp == 0) {
                    info.firstHoldTimestamp = now_;
                } else {
                    if (now_ <= info.firstHoldTimestamp + 7 days) revert HA7();
                    info.firstHoldTimestamp = now_;
                }
            } else if (wTier < info.whaleType) {
                if (now_ <= info.firstHoldTimestamp + 30 days) revert HA30();
                info.firstHoldTimestamp = now_;
            }
            info.whaleType = wTier;
            if (!_whaleKeys.contains(user)) {
                _whaleKeys.add(user);
            }
            if (wTier == WhaleType.None) {
                info.firstHoldTimestamp = 0;
                if (_whaleKeys.contains(user)) {
                    _whaleKeys.remove(user);
                }
            }

            emit ERXS_WhaleStatusUpdated(user, uint8(wTier), percentage / 1e18, usdValue);
        }

        if (now_ >= info.lastHourlyReset + 1 hours) {
            info.hourlyTxCount = 0;
            info.lastHourlyReset = now_;
        }
        if (now_ >= info.lastDailyReset + 24 hours) {
            info.dailyTxCount = 0;
            info.dailyVolume = 0;
            info.lastDailyReset = now_;
        }

        info.hourlyTxCount++;
        info.dailyTxCount++;
        uint256 hourlyLimit = _whaleHourlyLimit(wTier);
        if (info.hourlyTxCount > hourlyLimit) {
            revert("Whale hourly tx limit reached");
        }

        uint256 dailyLimit = _whaleDailyLimit(wTier);
        if (info.dailyTxCount > dailyLimit) {
            revert("Whale daily tx limit reached");
        }

        uint256 txUsdValue = (amount * getCurrentPrice()) / 1e18;
        info.dailyVolume += txUsdValue;

        uint256 dailyVolumeLimit = getTotalLockedValue() * _whaleDailyPct(wTier) / 100;
        if (info.dailyVolume > dailyVolumeLimit) {
            if (activePenalty) {
                _applyWhalePenalty(user);
                return;
            } else {
                revert("Whale daily liquidity limit exceeded");
            }
        }

        if (info.consecutiveTxCount >= 4 && info.consecutiveTxCount <= 6) {
            info.lastTxTimestamp = now_;
            info.consecutiveTxCount++;
            if (activePenalty) {
                _applyWhalePenalty(user);
                return;
            } else {
                revert("Consecutive transaction limit exceeded");
            }
        } else if (info.consecutiveTxCount >= 7) {
            if (activePenalty) {
                _applyWhalePenalty(user);
                return;
            } else {
                revert("Excessive transaction frequency");
            }
        }
        uint256 sinceLast = now_ - info.lastTxTimestamp;
        info.consecutiveTxCount = (sinceLast < 1 minutes) ? info.consecutiveTxCount + 1 : 1;
        info.lastTxTimestamp = now_;

        _restrictWeeklyWhaleLimits(user, txUsdValue, info.whaleType);
        emit ERXS_WhaleActivity(user, uint8(info.whaleType), amount, now_);
    }

    function _restrictWeeklyWhaleLimits(address user, uint256 txUsdValue, WhaleType whaleType) internal {
        WhaleInfo storage info = whaleInfo[user];
        uint256 now_ = block.timestamp;

        if (now_ >= info.lastWeeklyReset + 7 days) {
            info.weeklyVolumeAmount = 0;
            info.weeklyViolationCount = 0;
            info.lastWeeklyReset = now_;
        }

        uint256 whaleUsdValue = (balanceOf(user) * getCurrentPrice()) / 1e18;
        uint256 maxWeeklyWhaleVolume =
            (whaleType == WhaleType.MiniWhale) ? (whaleUsdValue * 70 / 100) : (whaleUsdValue * 50 / 100);
        uint256 weeklyVolumeLimit = getTotalLockedValue() * _whaleWeeklyPct(whaleType) / 100;

        bool balanceLimitExceeded = info.weeklyVolumeAmount + txUsdValue > maxWeeklyWhaleVolume;

        bool volumeExceeded = info.weeklyVolumeAmount + txUsdValue > weeklyVolumeLimit;

        if (balanceLimitExceeded || volumeExceeded) {
            info.weeklyViolationCount++;
            if (info.weeklyViolationCount <= 3) {
                if (activePenalty) {
                    _applyWhalePenalty(user);
                    return;
                } else {
                    revert(
                        balanceLimitExceeded
                            ? "Weekly whale sell limit exceeded"
                            : "Weekly whale liquidity limit exceeded"
                    );
                }
            } else {
                if (activePenalty) {
                    _applyWhalePenalty(user);
                    return;
                } else {
                    revert(
                        balanceLimitExceeded
                            ? "Penalty-Weekly whale sell limit exceeded"
                            : "Penalty-Weekly whale liquidity limit exceeded"
                    );
                }
            }
        }

        info.weeklyVolumeAmount += txUsdValue;
    }

    function _applyWhalePenalty(address user) internal {
        WhaleInfo storage info = whaleInfo[user];
        uint256 penaltyDuration;

        if (info.weeklyViolationCount <= 3) {
            penaltyDuration = 10 minutes;
        } else if (info.weeklyViolationCount == 4) {
            penaltyDuration = 30 minutes;
        } else if (info.weeklyViolationCount == 5) {
            penaltyDuration = 1 hours;
        } else if (info.weeklyViolationCount == 6) {
            penaltyDuration = 24 hours;
        } else {
            penaltyDuration = 72 hours;
        }

        info.penaltyEndTime = block.timestamp + penaltyDuration;
        emit WhalePenalized(user, uint8(info.weeklyViolationCount), info.penaltyEndTime);
    }

    function _whaleHourlyLimit(WhaleType t) internal pure returns (uint256) {
        if (t == WhaleType.MiniWhale) return 10;
        if (t == WhaleType.PinkWhale) return 6;
        if (t == WhaleType.BlueWhale) return 4;
        if (t == WhaleType.KillerWhale) return 2;
        return type(uint256).max;
    }

    function _whaleDailyLimit(WhaleType t) internal pure returns (uint256) {
        if (t == WhaleType.MiniWhale) return 10;
        if (t == WhaleType.PinkWhale) return 6;
        if (t == WhaleType.BlueWhale) return 4;
        if (t == WhaleType.KillerWhale) return 2;
        return type(uint256).max;
    }

    function _whaleDailyPct(WhaleType t) internal pure returns (uint256) {
        if (t == WhaleType.MiniWhale) return 5;
        if (t == WhaleType.PinkWhale) return 10;
        if (t == WhaleType.BlueWhale) return 15;
        if (t == WhaleType.KillerWhale) return 20;
        return 100;
    }

    function _whaleWeeklyPct(WhaleType t) internal pure returns (uint256) {
        if (t == WhaleType.MiniWhale) return 10;
        if (t == WhaleType.PinkWhale) return 20;
        if (t == WhaleType.BlueWhale) return 30;
        if (t == WhaleType.KillerWhale) return 40;
        return 100;
    }

    function normalizeTokenDecimals(uint256 amount, uint8 tokenDecimals_, uint8 targetDecimals)
        internal
        pure
        returns (uint256)
    {
        if (tokenDecimals_ > targetDecimals) {
            uint256 divisor = 10 ** (tokenDecimals_ - targetDecimals);
            return (amount + divisor / 2) / divisor;
        } else if (tokenDecimals_ < targetDecimals) {
            return amount * (10 ** (targetDecimals - tokenDecimals_));
        }
        return amount;
    }

    function denormalizeTokenDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
        internal
        pure
        returns (uint256)
    {
        if (fromDecimals > toDecimals) {
            uint256 divisor = 10 ** (fromDecimals - toDecimals);
            return (amount + divisor / 2) / divisor; // Round to nearest
        } else if (fromDecimals < toDecimals) {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
        return amount;
    }

    function _handleTransaction(uint256 usdValue, uint256 currentPrice)
        internal
        view
        returns (uint256 erxAmount, uint256 totalFee, uint256 treasuryFee, uint256 updateFundFee)
    {
        if (currentPrice <= 0) revert IP();

        TradeDirection direction = TradeDirection.Buy;
        (totalFee, treasuryFee, updateFundFee) = _calcFee(usdValue, direction);

        uint256 netUsdAmount = usdValue - totalFee;

        erxAmount = (netUsdAmount * 1e18) / currentPrice;
    }

    function _calcFee(uint256 usdValue, TradeDirection direction)
        internal
        view
        returns (uint256 totalFee, uint256 treasuryFee, uint256 updateFundFee)
    {
        if (whitelisted[msg.sender]) {
            return (0, 0, 0);
        }

        uint256 treasuryFeeRate;
        uint256 updateFundFeeRate;

        if (direction == TradeDirection.Buy) {
            updateFundFeeRate = 1e16; // 1%
            if (usdValue <= 100 * 1e18) treasuryFeeRate = 40e15; // 4%

            else if (usdValue <= 1000 * 1e18) treasuryFeeRate = 35e15; // 3.5%

            else if (usdValue <= 10_000 * 1e18) treasuryFeeRate = 30e15; // 3%

            else if (usdValue <= 100_000 * 1e18) treasuryFeeRate = 25e15; // 2.5%

            else treasuryFeeRate = 20e15; // 2%
        } else if (direction == TradeDirection.Sell) {
            updateFundFeeRate = 1e16; // 1%
            if (usdValue <= 100 * 1e18) treasuryFeeRate = 50e15; // 5%

            else if (usdValue <= 1000 * 1e18) treasuryFeeRate = 45e15; // 4.5%

            else if (usdValue <= 50_000 * 1e18) treasuryFeeRate = 40e15; // 4%

            else treasuryFeeRate = 35e15; // 3.5%
        } else {
            updateFundFeeRate = 5e15; // 0.5%
            if (usdValue <= 100 * 1e18) treasuryFeeRate = 35e15; // 3.5%

            else if (usdValue <= 10_000 * 1e18) treasuryFeeRate = 30e15; // 3%

            else treasuryFeeRate = 25e15; // 2.5%
        }

        treasuryFee = (usdValue * treasuryFeeRate) / 1e18;
        updateFundFee = (usdValue * updateFundFeeRate) / 1e18;
        totalFee = treasuryFee + updateFundFee;
    }

    function restrictPriceDrop(uint256 oldPrice, uint256 newPrice) internal {
        if (newPrice < oldPrice && oldPrice > 0) {
            uint256 priceDropPercent = ((oldPrice - newPrice) * 100) / oldPrice;
            if (priceDropPercent > MAX_PRICE_DROP_PERCENT) {
                revert("Price drop exceeds limit");
            }
        } else if (newPrice >= oldPrice) {
            if (blockedTxCount > 0 && block.timestamp > lastBlockedTxTime + 24 hours) {
                blockedTxCount = 0;
                lastBlockedTxTime = 0;
            }
        }
        lastPriceBeforeTx = oldPrice;
    }

    function _updateUserBalance(address user) internal {
        UserActivity storage activity = userActivity[user];
        activity.totalBalance = balanceOf(user);
    }

    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        uint256 currentAllowance = token.allowance(address(this), spender);

        if (currentAllowance != 0) {
            token.approve(spender, 0);
        }

        if (amount != 0) {
            token.approve(spender, amount);
        }
    }

    function _sendUpdateFee(IERC20 stablecoin, uint256 amount) internal {
        stablecoin.safeTransfer(updateFund, amount);

        try IUpdateFund(updateFund).onFeeReceived(address(stablecoin), amount) {
            emit FeeDistributionLog(
                address(stablecoin), address(this), updateFund, block.timestamp, amount, true, "Distribution success"
            );
        } catch (bytes memory reason) {
            emit FeeDistributionLog(
                address(stablecoin), address(this), updateFund, block.timestamp, amount, false, string(reason)
            );
        }
    }

    function _notifyUpdateFund(uint256 amount) internal {
        try IUpdateFund(updateFund).onFeeReceived(address(this), amount) {
            emit FeeDistributionLog(
                address(this), address(this), updateFund, block.timestamp, amount, true, "ERX distribution success"
            );
        } catch (bytes memory reason) {
            emit FeeDistributionLog(
                address(this), address(this), updateFund, block.timestamp, amount, false, string(reason)
            );
        }
    }

    // Migration funcitons
    function announceForkMigration(address to) external onlyDAO {
        if (to == address(0)) revert IA();
        if (isForkMigration) revert MAN();
        if (to.code.length <= 0) revert TNC();
        if (!whitelisted[to]) revert NW();

        router.startMigration(to);

        isForkMigration = true;
        migrationTarget = to;
        migrationAnnouncedTime = block.timestamp;

        emit ForkMigrationAnnounced(to, block.timestamp);
    }

    function cancelForkMigration() external onlyDAO {
        if (!isForkMigration) revert MNA();

        if (router.migrationInProgress()) {
            router.cancelMigration();
        }

        isForkMigration = false;
        migrationTarget = address(0);
        migrationAnnouncedTime = 0;
        emit ForkMigrationCancelled(block.timestamp);
    }

    function migrateAllStablecoinBalances(address to) external onlyDAO whenPaused {
        if (!isForkMigration) revert MNA();
        if (block.timestamp < migrationAnnouncedTime + DAO_DELAY) revert MDNP();
        if (to != migrationTarget) revert IA();
        if (to == address(0)) revert IA();
        if (to.code.length == 0) revert IA();
        if (keccak256(abi.encodePacked(IERC20Metadata(to).name())) != keccak256(abi.encodePacked("EuphoriaX"))) {
            revert IA();
        }

        address[] memory tokens = new address[](stablecoins.length);
        uint256[] memory amounts = new uint256[](stablecoins.length);
        uint256 count = 0;

        for (uint256 i = 0; i < stablecoins.length; i++) {
            IERC20Metadata token = stablecoins[i];
            uint256 bal = token.balanceOf(address(this));
            if (bal > 0) {
                tokens[count] = address(token);
                amounts[count] = bal;
                token.safeTransfer(to, bal);
                count++;
            }
        }

        emit StablecoinBalancesMigrated(to, tokens, amounts);
        isForkMigration = false;
        migrationTarget = address(0);
        migrationAnnouncedTime = 0;
    }

    function migrateAllUsersData(address to, uint256 batchSize, uint256 startIndex)
        external
        onlyDAO
        whenPaused
        returns (uint256 migratedCount, uint256 failedCount, bool isComplete)
    {
        if (!isForkMigration) revert MNA();
        if (block.timestamp < migrationAnnouncedTime + DAO_DELAY) revert MDNP();
        if (to != migrationTarget) revert IA();

        // Set migration source on target contract
        if (startIndex == 0) {
            IEuphoriaXMigrator(to).setMigrationSource(address(this));
        }

        uint256 totalUsers = _userKeys.length();
        if (totalUsers == 0 || startIndex >= totalUsers) {
            isComplete = true;
            IEuphoriaXMigrator(to).finalizeMigration();
            router.completeMigration();
            return (0, 0, true);
        }

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > totalUsers) {
            endIndex = totalUsers;
            isComplete = true;
        }

        // STEP 1: Collect users to migrate (don't modify array yet)
        uint256 actualBatchSize = endIndex - startIndex;
        address[] memory usersToMigrate = new address[](actualBatchSize);
        address[] memory successfullyMigrated = new address[](actualBatchSize);
        uint256 successIndex = 0;

        for (uint256 i = 0; i < actualBatchSize; i++) {
            usersToMigrate[i] = _userKeys.at(startIndex + i);
        }

        // STEP 2: Migrate collected users
        for (uint256 i = 0; i < usersToMigrate.length; i++) {
            address user = usersToMigrate[i];

            // Check if user still exists and has data to migrate
            if (_userKeys.contains(user) || _whaleKeys.contains(user)) {
                try this._migrateUserDataInternal(user, to) {
                    successfullyMigrated[successIndex] = user;
                    successIndex++;
                    migratedCount++;
                } catch {
                    failedCount++;
                }
            }
        }

        // STEP 3: Clean up migrated users
        _cleanupMigratedUsers(successfullyMigrated, successIndex);

        // Check if this was the last batch
        if (isComplete) {
            uint256 updateFundBalance = balanceOf(updateFund);
            if (updateFundBalance > 0) {
                _burn(updateFund, updateFundBalance);
                _totalBurnt += updateFundBalance;

                try IEuphoriaXMigrator(to).receiveMigratedUpdateFundTokens(updateFundBalance, updateFund) {}
                catch {
                    _mint(updateFund, updateFundBalance);
                    _totalBurnt -= updateFundBalance;
                }
            }
            IEuphoriaXMigrator(to).finalizeMigration();
            router.completeMigration();
            emit BatchUserMigrationCompleted(to, totalUsers, block.timestamp);
        }

        return (migratedCount, failedCount, isComplete);
    }

    function _migrateUserDataInternal(address user, address to) external {
        require(msg.sender == address(this), "Only self");
        _migrateUserDataInternalSafe(user, to);
    }

    function _migrateUserDataInternalSafe(address user, address to) internal {
        // Get user's ERX balance
        uint256 userERXBalance = balanceOf(user);

        // Get user activity data
        UserActivity memory userActivityData = userActivity[user];

        // Get whale info data
        WhaleInfo memory whaleInfoData = whaleInfo[user];

        // Get user status flags
        bool userIsInvestor = isInvestor[user];
        bool userIsWhitelisted = whitelisted[user];

        // Transfer ERX tokens to target contract first
        if (userERXBalance > 0) {
            _burn(user, userERXBalance);
        }

        // Send all user data to target contract
        try IEuphoriaXMigrator(to).receiveMigratedUserData(
            user, userActivityData, whaleInfoData, userIsInvestor, userIsWhitelisted, userERXBalance
        ) {
            _clearUserDataOnly(user);
            emit UserDataMigrated(user, to, block.timestamp);
        } catch (bytes memory reason) {
            emit UserMigrationFailed(user, to, string(reason), block.timestamp);
            if (userERXBalance > 0) {
                _mint(user, userERXBalance);
            }
        } catch Panic(uint256 errorCode) {
            emit UserMigrationFailed(user, to, string(abi.encodePacked("Panic: ", errorCode)), block.timestamp);
            if (userERXBalance > 0) {
                _mint(user, userERXBalance);
            }
        }
    }

    /**
     * @notice Clear user data from the current contract after migration
     * @param user The user address to clear data for
     */
    function _clearUserDataOnly(address user) internal {
        // Clear user activity
        delete userActivity[user];

        // Clear whale info
        delete whaleInfo[user];

        // Clear investor status
        if (isInvestor[user]) {
            isInvestor[user] = false;
            if (investors > 0) {
                investors--;
            }
        }

        // Clear whitelist status
        whitelisted[user] = false;
    }

    /**
     * @notice Clean up migrated users from tracking arrays
     * @param migratedUsers Array of users that were successfully migrated
     */
    function _cleanupMigratedUsers(address[] memory migratedUsers, uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            address user = migratedUsers[i];

            // Remove from user keys
            if (_userKeys.contains(user)) {
                _userKeys.remove(user);
            }

            // Remove from whale keys
            if (_whaleKeys.contains(user)) {
                _whaleKeys.remove(user);
            }
        }
    }

    function getMigrationStatus()
        external
        view
        returns (
            uint256 totalUsers,
            uint256 totalWhales,
            bool migrationAnnounced,
            address migrationTarget_,
            uint256 timeRemaining,
            bool routerMigrationInProgress
        )
    {
        totalUsers = _userKeys.length();
        totalWhales = _whaleKeys.length();
        migrationAnnounced = isForkMigration;
        migrationTarget_ = migrationTarget;

        routerMigrationInProgress = router.migrationInProgress();

        if (isForkMigration && block.timestamp < migrationAnnouncedTime + DAO_DELAY) {
            timeRemaining = (migrationAnnouncedTime + DAO_DELAY) - block.timestamp;
        } else {
            timeRemaining = 0;
        }
        return (totalUsers, totalWhales, migrationAnnounced, migrationTarget_, timeRemaining, routerMigrationInProgress);
    }

    function getUsersForMigration(uint256 startIndex, uint256 batchSize)
        external
        view
        returns (address[] memory users, bool hasMore)
    {
        uint256 totalUsers = _userKeys.length();
        require(startIndex < totalUsers, "Start index out of bounds");
        if (startIndex >= totalUsers) {
            return (new address[](0), false);
        }

        uint256 endIndex = startIndex + batchSize;
        if (endIndex > totalUsers) {
            endIndex = totalUsers;
            hasMore = false;
        } else {
            hasMore = true;
        }

        uint256 actualBatchSize = endIndex - startIndex;
        users = new address[](actualBatchSize);

        for (uint256 i = 0; i < actualBatchSize; i++) {
            users[i] = _userKeys.at(startIndex + i);
        }

        return (users, hasMore);
    }

    function migrateSpecificUsers(address[] calldata users, address to) external onlyDAO whenPaused {
        if (!isForkMigration) revert MNA();
        if (block.timestamp < migrationAnnouncedTime + DAO_DELAY) revert MDNP();
        if (to != migrationTarget) revert IA();

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];

            if (_userKeys.contains(user) || _whaleKeys.contains(user)) {
                _migrateUserDataInternalSafe(user, to);
                emit UserDataMigrated(user, to, block.timestamp);
            }
        }
    }
}