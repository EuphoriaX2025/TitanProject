// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
 * ▓▓                                                                                  ▓▓
 * ▓▓     ██████╗ ██████╗ ██╗████████╗    ████████╗ ██████╗ ██╗  ██╗███████╗███╗   ██╗ ▓▓
 * ▓▓    ██╔═══██╗██╔══██╗██║╚══██╔══╝    ╚══██╔══╝██╔═══██╗██║ ██╔╝██╔════╝████╗  ██║ ▓▓
 * ▓▓    ██║   ██║██████╔╝██║   ██║          ██║   ██║   ██║█████╔╝ █████╗  ██╔██╗ ██║ ▓▓
 * ▓▓    ██║▄▄ ██║██╔══██╗██║   ██║          ██║   ██║   ██║██╔═██╗ ██╔══╝  ██║╚██╗██║ ▓▓
 * ▓▓    ╚██████╔╝██████╔╝██║   ██║          ██║   ╚██████╔╝██║  ██╗███████╗██║ ╚████║ ▓▓
 * ▓▓     ╚═════╝ ╚═════╝ ╚═╝   ╚═╝          ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝ ▓▓
 * ▓▓                                                                                  ▓▓
 * ▓▓                            🚀        QBit        🚀                             ▓▓
 * ▓▓                            ⚡ EUPHORIA ECOSYSTEM ⚡                             ▓▓
 * ▓▓                                                                                  ▓▓
 * ▓▓                        🔮 THE FUTURE IS DECENTRALIZED 🔮                        ▓▓
 * ▓▓                                                                                  ▓▓
 * ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "interfaces/IRouter.sol";
import "interfaces/IUpdateFund.sol";

import "interfaces/TitanV2/ITitanRegister.sol";

import "interfaces/IEuphoriaX.sol";

// Qbit Phase 1 contract
contract Qbit is ERC20, ReentrancyGuard, Pausable, Ownable(msg.sender) {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _freeBalanceUsers;
    EnumerableSet.AddressSet private _purchaseUsers;
    EnumerableSet.AddressSet private _lockUsers;

    IRouter router;
    address public supportFund;
    address public titanContract;
    address public updateFund;
    address public daoAddress;
    address public erxToken; // ERX token contract address
    bool public internalSaleStopped;
    bool public isPhaseFiveExtended;
    uint256 currentVersion;
    uint256 investors;
    uint256 public soldInitialAmount;
    IERC20Metadata[] public stablecoins;
    string[] public tokenSymbols;

    // Structures
    struct Purchase {
        uint256 stage;
        uint256 purchasePrice;
        uint256 purchaseTime;
        uint256 amount;
        uint256 soldAmount;
    }

    struct LockedTokens {
        uint256 phaseNumber;
        uint256 amount;
        uint256 originalAmount;
        uint256 purchaseTime;
    }

    // Mappings
    mapping(uint256 => address) public theInvestors;
    mapping(address => Purchase[]) public purchaseHistory;
    mapping(address => LockedTokens[]) public lockedTokens;
    mapping(address => uint256) public freeBalance;
    mapping(address => bool) public hasFreeBalance;
    mapping(uint256 => uint256) public stagePrices;
    mapping(uint256 => uint256) public stageLimits;
    mapping(string => address) public supportedTokens;
    mapping(uint256 => address) public version;
    mapping(string => address) public supportedStableCoins;
    mapping(address => bool) public isSupportedStablecoin;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => uint256) public minAmount;
    mapping(address => mapping(uint256 => uint256)) public originalLockedAmounts;
    mapping(address => bool) public whitelisted;

    error NTTU(); // No tokens to unlock
    error ULE(); // Unlock limit exceeded
    error IFB(); //Insufficient free balance
    error SD(); // sane decimals
    error IA(); // Invalid address
    error AS(); // Already supported
    error ISI(); // Invalid stablecoin index
    error IST(); // Invalid supported token
    error SNE(); // Stablecoin Not Empty
    error ISA(); // Insufficient stablecoin allowance
    error MONM(); // Minimum order is 1 USD
    error NW(); // Not whitelisted
    error AW(); // Already whitelisted

    // Modifiers
    modifier onlyDAO() {
        require(msg.sender == daoAddress, "Only DAO");
        _;
    }

    modifier onlyTitan() {
        require(msg.sender == titanContract, "Only Titan");
        _;
    }

    modifier OnlyQBit(uint256 _version) {
        require(msg.sender == version[_version], "Invalid version caller");
        _;
    }

    modifier OnlyActiveVersion(uint256 _version) {
        if (currentVersion != _version) revert("QBit version not active");
        _;
    }

    constructor(address _IRouter) ERC20("Qbit EuphoriaX", "Qbit") {
        require(_IRouter != address(0), "Invalid IRouter");
        router = IRouter(_IRouter);

        titanContract = router.getTitanRegistration();
        supportFund = router.getSupportFundContract();
        updateFund = router.getUpdateFundRecipient();
        daoAddress = router.getDao();
        erxToken = router.getERXToken();

        require(supportFund != address(0), "Invalid supportFund address");
        require(updateFund != address(0), "Invalid updateFund address");
        require(daoAddress != address(0), "Invalid daoAddress address");

        // address[] memory initialStablecoins = new address[](4);
        // initialStablecoins[0] = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063; // DAI
        // initialStablecoins[1] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; // old bridged USDC
        // initialStablecoins[2] = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // new native USDC
        // initialStablecoins[3] = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F; // USDT
        // for (uint256 i = 0; i < initialStablecoins.length; i++) {
        //     address stablecoin = initialStablecoins[i];
        //     stablecoins.push(IERC20Metadata(stablecoin));
        //     uint8 dec = IERC20Metadata(stablecoin).decimals();
        //     if (dec > 18) revert SD();
        //     if (stablecoin == address(0)) revert IA();
        //     string memory stbcSymbol = IERC20Metadata(stablecoin).symbol();
        //     supportedStableCoins[stbcSymbol] = stablecoin;
        //     isSupportedStablecoin[stablecoin] = true;
        //     tokenDecimals[stablecoin] = dec;
        //     minAmount[stablecoin] = 10 ** dec;
        // }

        stagePrices[0] = 20 * 10 ** 18; // $20
        stagePrices[1] = 225 * 10 ** 17; // $22.5
        stagePrices[2] = 255 * 10 ** 17; // $25.5
        stagePrices[3] = 285 * 10 ** 17; // $28.5
        stagePrices[4] = 32 * 10 ** 18; // $32

        stageLimits[0] = 20_000 * 10 ** 18;
        stageLimits[1] = 45_000 * 10 ** 18;
        stageLimits[2] = 20_000 * 10 ** 18;
        stageLimits[3] = 10_000 * 10 ** 18;
        stageLimits[4] = 5_000 * 10 ** 18;

        uint256 initialSupply = 1_000_000 * 10 ** 18;
        uint256 updateFundAllocation = 10_000 * 10 ** 18;
        _mint(address(this), initialSupply);
        freeBalance[address(this)] = initialSupply - updateFundAllocation;
        _updateFreeBalanceUser(address(this), freeBalance[address(this)]);

        _distQBitToUF(updateFundAllocation);

        initVersion();
        whitelisted[router.getUpdateFundRecipient()] = true;
    }

    function _distQBitToUF(uint256 amount) internal {
        require(amount > 0, "Amount must be greater than zero");
        require(freeBalance[address(this)] >= amount, "Insufficient contract balance");

        try IUpdateFund(updateFund).onQBitReceived(amount) {
            _mint(updateFund, amount);
            freeBalance[updateFund] = amount;
            _updateFreeBalanceUser(updateFund, freeBalance[updateFund]);
            emit QBIT_UF_DIST_DONE(block.timestamp, currentVersion, amount, updateFund);
        } catch {
            revert("Failed to notify update fund");
            emit QBIT_MigrationCompleted(
    block.timestamp, newContract, soldInitialAmount, _purchaseUsers.length(), _lockUsers.length()
);
        }
    }

    function buy(uint256 qbitAmount, string memory tokenSymbol) public {
        address buyer = _msgSender();
        if (keccak256(abi.encodePacked(tokenSymbol)) == keccak256(abi.encodePacked("ERX"))) {
            // For ERX purchases, calculate the minimum required ERX amount
            uint256 currentStage = getCurrentStage();

            require(currentStage < 5, "Sale has ended");

            uint256 qbitPrice = stagePrices[currentStage];

            uint256 requiredUSDValue = (qbitAmount * qbitPrice) / 10 ** 18;

            uint256 fee = _calculateFee(requiredUSDValue, true);

            uint256 totalRequiredUSDValue = requiredUSDValue + fee;

            // Get current ERX price
            IEuphoriaX erxContract = IEuphoriaX(erxToken);
            uint256 erxPriceUSD = erxContract.getCurrentPrice();

            require(erxPriceUSD > 0, "Invalid ERX price");

            // Calculate minimum required ERX amount (with small buffer for price fluctuations)
            uint256 minErxAmount = (totalRequiredUSDValue * 10 ** 18) / erxPriceUSD;

            // Call the ERX buy function with calculated amount
            this.Qbit_Buy_WithERX(buyer, qbitAmount, minErxAmount);
        } else {
            // For stablecoin purchases, use the regular function
            this.Qbit_Buy(buyer, qbitAmount, tokenSymbol);
        }
    }

    // Buy Qbit tokens with stablecoins
    function Qbit_Buy(address buyer, uint256 qbitAmount, string memory tokenSymbol)
        external
        nonReentrant
        whenNotPaused
        OnlyActiveVersion(1)
    {
        address currentContract = address(this);
        uint256 currentTime = block.timestamp;
        require(!internalSaleStopped, "Internal sale stopped");
        // require(qbitAmount >= 1 * 10 ** 18, "Below minimum order");

        require(freeBalance[currentContract] >= qbitAmount, "Insufficient contract balance");

        uint256 currentStage = getCurrentStage();

        require(currentStage < 5, "Sale has ended");

        uint256 currentStageCumulativeLimit = 0;
        for (uint256 i = 0; i <= currentStage; i++) {
            currentStageCumulativeLimit += stageLimits[i];
        }

        require(soldInitialAmount + qbitAmount <= currentStageCumulativeLimit, "Stage limit exceeded");

        address token = getTokenAddress(tokenSymbol);
        IERC20 paymentToken = IERC20(token);

        uint8 dec = IERC20Metadata(token).decimals();
        require(dec <= 18, "Invalid token decimals");

        uint256 price = stagePrices[currentStage];

        uint256 usdValueNormalized = (qbitAmount * price) / 10 ** 18;

        uint256 fee = _calculateFee(usdValueNormalized, true);

        uint256 totalCostNormalized = usdValueNormalized + fee;

        if (usdValueNormalized < normalizeTokenDecimals(minAmount[token], dec, 18)) revert MONM();

        uint256 totalCostInTokenDecimals = denormalizeTokenDecimals(totalCostNormalized, 18, dec);

        uint256 usdValueInTokenDecimals = denormalizeTokenDecimals(usdValueNormalized, 18, dec);

        uint256 feeInTokenDecimals = denormalizeTokenDecimals(fee, 18, dec);

        require(paymentToken.balanceOf(buyer) >= totalCostInTokenDecimals, "Insufficient balance");
        require(paymentToken.allowance(buyer, currentContract) >= totalCostInTokenDecimals, "Insufficient allowance");

        SafeERC20.safeTransferFrom(paymentToken, buyer, currentContract, totalCostInTokenDecimals);

        if (usdValueInTokenDecimals > 0) {
            SafeERC20.safeTransfer(paymentToken, supportFund, usdValueInTokenDecimals);
        }
        if (feeInTokenDecimals > 0) {
            _sendUpdateFee(paymentToken, feeInTokenDecimals);
        }

        uint256 lockPercentage = currentStage <= 1 ? 50 : currentStage <= 3 ? 30 : 20;
        uint256 tokensToLock = (qbitAmount * lockPercentage) / 100;
        uint256 freeTokens = qbitAmount - tokensToLock;

        lockedTokens[buyer].push(
            LockedTokens({
                phaseNumber: currentStage,
                amount: tokensToLock,
                originalAmount: tokensToLock,
                purchaseTime: currentTime
            })
        );
        _lockUsers.add(buyer);
        _purchaseUsers.add(buyer);

        if (freeBalance[currentContract] < qbitAmount) {
            uint256 amountToMint = qbitAmount - freeBalance[currentContract];
            _mint(currentContract, amountToMint);
            freeBalance[currentContract] += amountToMint;
        }

        freeBalance[buyer] += freeTokens;
        freeBalance[currentContract] -= qbitAmount;

        bool isNewInvestor = balanceOf(buyer) == 0;
        _transfer(currentContract, buyer, qbitAmount);

        if (isNewInvestor) {
            investors++;
            theInvestors[investors] = buyer;
        }

        purchaseHistory[buyer].push(
            Purchase({
                stage: currentStage,
                purchasePrice: price,
                purchaseTime: currentTime,
                amount: qbitAmount,
                soldAmount: 0
            })
        );
        soldInitialAmount += qbitAmount;

        // Bonus tokens
        uint256 bonusAmount =
            currentStage == 0 ? (qbitAmount * 7) / 100 : currentStage == 1 ? (qbitAmount * 3) / 100 : 0;

        if (bonusAmount > 0) {
            require(freeBalance[currentContract] >= bonusAmount, "Insufficient bonus tokens");
            freeBalance[currentContract] -= bonusAmount;
            freeBalance[buyer] += bonusAmount;
            _transfer(currentContract, buyer, bonusAmount);
            emit QBIT_BonusTokensAwarded(buyer, bonusAmount, currentTime);
        }

        _updateFreeBalanceUser(buyer, freeBalance[buyer]);
        _updateFreeBalanceUser(currentContract, freeBalance[currentContract]);
        emit QBIT_QbitPurchased(buyer, qbitAmount, usdValueNormalized, currentTime);
        emit QBIT_FeeCollected(buyer, 0, feeInTokenDecimals, 0);
    }

    // Buy Qbit tokens with ERX tokens
    function Qbit_Buy_WithERX(address buyer, uint256 qbitAmount, uint256 erxAmount)
        external
        nonReentrant
        whenNotPaused
        OnlyActiveVersion(1)
    {
        address currentContract = address(this);
        uint256 currentTime = block.timestamp;
        require(!internalSaleStopped, "Internal sale stopped");
        // require(qbitAmount >= 1 * 10 ** 18, "Below minimum order");
        require(erxAmount > 0, "ERX amount must be greater than zero");
        require(freeBalance[currentContract] >= qbitAmount, "Insufficient contract balance");

        uint256 currentStage = getCurrentStage();

        require(currentStage < 5, "Sale has ended");

        uint256 currentStageCumulativeLimit = 0;
        for (uint256 i = 0; i <= currentStage; i++) {
            currentStageCumulativeLimit += stageLimits[i];
        }

        require(soldInitialAmount + qbitAmount <= currentStageCumulativeLimit, "Stage limit exceeded");

        IERC20 erxToken_IERC20 = IERC20(erxToken);
        IEuphoriaX erxContract = IEuphoriaX(erxToken);

        // Get current ERX price in USD (assuming price is in 18 decimals)
        uint256 erxPriceUSD = erxContract.getCurrentPrice();

        require(erxPriceUSD > 0, "Invalid ERX price");

        // Calculate USD value of ERX payment (ERX amount * ERX price)
        uint256 erxValueUSD = (erxAmount * erxPriceUSD) / 10 ** 18;

        // Calculate required USD value for the Qbit purchase
        uint256 qbitPrice = stagePrices[currentStage];

        uint256 requiredUSDValue = (qbitAmount * qbitPrice) / 10 ** 18;

        uint256 totalRequiredUSDValue = requiredUSDValue;

        // Check if ERX payment covers the required USD value
        require(erxValueUSD >= totalRequiredUSDValue, "Insufficient ERX payment");

        // Check minimum order requirement (1 USD minimum)
        require(requiredUSDValue >= 1 * 10 ** 18, "Below minimum order value");

        // Check ERX token balance and allowance
        require(erxToken_IERC20.balanceOf(buyer) >= erxAmount, "Insufficient ERX balance");
        require(erxToken_IERC20.allowance(buyer, currentContract) >= erxAmount, "Insufficient ERX allowance");

        // Transfer ERX tokens from buyer to the contract
        SafeERC20.safeTransferFrom(erxToken_IERC20, buyer, currentContract, erxAmount);

        // Calculate ERX amounts for value and fee distribution
        uint256 erxForValue = (erxAmount * requiredUSDValue) / erxValueUSD;

        uint256 erxForFee = erxAmount - erxForValue;

        // Send ERX value to support fund
        if (erxForValue > 0) {
            SafeERC20.safeTransfer(erxToken_IERC20, supportFund, erxForValue);
        }

        // Send ERX fee to update fund
        if (erxForFee > 0) {
            _sendERXUpdateFee(erxToken_IERC20, erxForFee);
        }

        // Lock percentage based on the current stage
        uint256 lockPercentage = currentStage <= 1 ? 50 : currentStage <= 3 ? 30 : 20;
        uint256 tokensToLock = (qbitAmount * lockPercentage) / 100;
        uint256 freeTokens = qbitAmount - tokensToLock;

        // Add locked tokens
        lockedTokens[buyer].push(
            LockedTokens({
                phaseNumber: currentStage,
                amount: tokensToLock,
                originalAmount: tokensToLock,
                purchaseTime: currentTime
            })
        );
        _lockUsers.add(buyer);
        _purchaseUsers.add(buyer);

        // Mint additional tokens if needed
        if (freeBalance[currentContract] < qbitAmount) {
            uint256 amountToMint = qbitAmount - freeBalance[currentContract];
            _mint(currentContract, amountToMint);
            freeBalance[currentContract] += amountToMint;
        }

        // Update balances
        freeBalance[buyer] += freeTokens;
        freeBalance[currentContract] -= qbitAmount;

        bool isNewInvestor = balanceOf(buyer) == 0;
        _transfer(currentContract, buyer, qbitAmount);

        if (isNewInvestor) {
            investors++;
            theInvestors[investors] = buyer;
        }

        // Add to purchase history
        purchaseHistory[buyer].push(
            Purchase({
                stage: currentStage,
                purchasePrice: qbitPrice,
                purchaseTime: currentTime,
                amount: qbitAmount,
                soldAmount: 0
            })
        );
        soldInitialAmount += qbitAmount;

        // Award bonus tokens
        uint256 bonusAmount =
            currentStage == 0 ? (qbitAmount * 7) / 100 : currentStage == 1 ? (qbitAmount * 3) / 100 : 0;

        if (bonusAmount > 0) {
            require(freeBalance[currentContract] >= bonusAmount, "Insufficient bonus tokens");
            freeBalance[currentContract] -= bonusAmount;
            freeBalance[buyer] += bonusAmount;
            _transfer(currentContract, buyer, bonusAmount);
            emit QBIT_BonusTokensAwarded(buyer, bonusAmount, currentTime);
        }

        _updateFreeBalanceUser(buyer, freeBalance[buyer]);
        _updateFreeBalanceUser(currentContract, freeBalance[currentContract]);

        emit QBIT_QbitPurchasedWithERX(buyer, qbitAmount, erxAmount, requiredUSDValue, currentTime);
        emit QBIT_FeeCollected(buyer, 0, erxForFee, 0);
    }

    // Transfer Qbit tokens
    function Qbit_Transfer(address to, uint256 amount) public whenNotPaused returns (bool) {
        address user = _msgSender();
        // require(amount >= 1 * 10 ** 18, "Below minimum transfer");
        require(to != address(0), "Transfer to zero address");
        require(to != user, "Cannot transfer to self");
        require(freeBalance[user] >= amount, "Insufficient free balance");

        uint256 currentStage = getCurrentStage();
        uint256 currentPrice = currentStage < 5 ? stagePrices[currentStage] : stagePrices[4];
        uint256 usdValue = (amount * currentPrice) / 10 ** 18;
        // require(usdValue >= 1 * 10 ** 18, "Minimum transfer is $1 USD");

        uint256 fee = calculateTransferFee(usdValue);
        uint256 feeInTokens = (fee * 10 ** 18) / currentPrice;
        require(freeBalance[user] >= amount + feeInTokens, "Insufficient balance for fee");

        freeBalance[user] -= (amount + feeInTokens);
        freeBalance[to] += amount;

        _transfer(user, to, amount);

        if (feeInTokens > 0) {
            _transfer(user, updateFund, feeInTokens);

            try IUpdateFund(updateFund).onFeeReceived(address(this), feeInTokens) {
                emit QBIT_FeeDistributionLog(
                    address(this),
                    user,
                    updateFund,
                    block.timestamp,
                    feeInTokens,
                    true,
                    "QBit transfer fee distribution success"
                );
            } catch (bytes memory reason) {
                emit QBIT_FeeDistributionLog(
                    address(this), user, updateFund, block.timestamp, feeInTokens, false, string(reason)
                );
            }
        }

        _updatePurchaseHistoryOnTransfer(user, amount);
        _updateFreeBalanceUser(user, freeBalance[user]);
        _updateFreeBalanceUser(to, freeBalance[to]);

        emit QBIT_TokenTransferred(user, to, amount, feeInTokens, block.timestamp);
        emit QBIT_FeeCollected(user, 0, feeInTokens, 1); // 1 = transfer direction

        return true;
    }

    function _updatePurchaseHistoryOnTransfer(address user, uint256 amount) internal {
        uint256 remainingAmount = amount;

        // Update purchase history using FIFO (First In, First Out)
        for (uint256 i = 0; i < purchaseHistory[user].length && remainingAmount > 0; i++) {
            Purchase storage p = purchaseHistory[user][i];
            uint256 availableInPurchase = p.amount - p.soldAmount;

            if (availableInPurchase >= remainingAmount) {
                // This purchase can cover the remaining amount
                p.soldAmount += remainingAmount;
                remainingAmount = 0;
            } else {
                // This purchase is fully consumed
                remainingAmount -= availableInPurchase;
                p.soldAmount = p.amount;
            }
        }

        // If there's still remaining amount, it means we have an accounting error
        if (remainingAmount > 0) {
            emit QBIT_PurchaseHistoryMismatch(user, remainingAmount, block.timestamp);
        }
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
        emit QBIT_StablecoinRemoved(removingCoinAddress, block.timestamp);
    }

    function _removeStablecoin(address stablecoin) internal {
        if (!isSupportedStablecoin[stablecoin]) revert ISA();
        if (stablecoin == address(0)) revert IA();
        isSupportedStablecoin[stablecoin] = false;
        delete supportedStableCoins[IERC20Metadata(stablecoin).symbol()];
        delete tokenDecimals[stablecoin];
        delete minAmount[stablecoin];
    }

    function getLockedTokensBatch(address user, uint256 start, uint256 count)
        external
        view
        returns (LockedTokens[] memory batch)
    {
        uint256 total = lockedTokens[user].length;
        if (start >= total) {
            return new LockedTokens[](0);
        }
        // cap `count` so we don’t overflow
        uint256 len = count;
        if (start + len > total) {
            len = total - start;
        }
        batch = new LockedTokens[](len);
        for (uint256 i = 0; i < len; i++) {
            batch[i] = lockedTokens[user][start + i];
        }
    }

    function getLockedTokensCount(address user) external view returns (uint256) {
        return lockedTokens[user].length;
    }

    function getStageData() external view returns (uint256[] memory limits, uint256[] memory prices, uint256 sold) {
        limits = new uint256[](5);
        prices = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            limits[i] = stageLimits[i];
            prices[i] = stagePrices[i];
        }
        sold = soldInitialAmount;
    }

    // Get user purchase history
    function getUserPurchaseHistory(address user) external view returns (Purchase[] memory) {
        return purchaseHistory[user];
    }

    function getLockedTokensList(address u) external view returns (LockedTokens[] memory) {
        return lockedTokens[u];
    }

    // Get locked tokens
    function getLockedTokens(address user, uint256 phaseNumber) external view returns (uint256 totalLocked) {
        LockedTokens[] memory locks = lockedTokens[user];
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].phaseNumber == phaseNumber) {
                totalLocked += locks[i].amount;
            }
        }
        return totalLocked;
    }

    // Get free balance
    function QBIT_FreeBalance(address user) external view returns (uint256) {
        return freeBalance[user];
    }

    function getAllLockUsers() external view returns (address[] memory) {
        return _lockUsers.values();
    }

    // Unlock locked tokens
    function unlockTokens() external nonReentrant whenNotPaused {
        address user = _msgSender();
        uint256 currentTime = block.timestamp;
        uint256 totalUnlockedAmount = 0;
        LockedTokens[] storage locks = lockedTokens[user];
        uint256 i = 0;

        while (i < locks.length) {
            LockedTokens storage lock = locks[i];
            uint256 totalUnlockableNow = 0;

            if (currentTime >= lock.purchaseTime + 270 days && soldInitialAmount >= 50_000 * 10 ** 18) {
                totalUnlockableNow = lock.originalAmount;
            } else if (currentTime >= lock.purchaseTime + 180 days && soldInitialAmount >= 30_000 * 10 ** 18) {
                totalUnlockableNow = (lock.originalAmount * 50) / 100;
            } else if (currentTime >= lock.purchaseTime + 90 days && soldInitialAmount >= 10_000 * 10 ** 18) {
                totalUnlockableNow = (lock.originalAmount * 20) / 100;
            }

            uint256 alreadyUnlocked = lock.originalAmount - lock.amount;
            uint256 newUnlockAmount = 0;

            if (totalUnlockableNow > alreadyUnlocked) {
                newUnlockAmount = totalUnlockableNow - alreadyUnlocked;
                if (newUnlockAmount > lock.amount) {
                    newUnlockAmount = lock.amount;
                }

                totalUnlockedAmount += newUnlockAmount;
                lock.amount -= newUnlockAmount;
            }

            if (lock.amount == 0) {
                locks[i] = locks[locks.length - 1];
                locks.pop();
                if (lockedTokens[user].length == 0) {
                    _lockUsers.remove(user);
                }
            } else {
                i++;
            }
        }

        if (totalUnlockedAmount <= 0) revert NTTU();
        if (totalUnlockedAmount > 10_000 * 10 ** 18) revert ULE();

        freeBalance[user] += totalUnlockedAmount;
        _updateFreeBalanceUser(user, freeBalance[user]);
        emit QBIT_TokensUnlocked(user, totalUnlockedAmount, currentTime);
    }

    // Burn Qbit for Titan fees
    function burnForTitan(address user, uint256 amount, string memory reason) external onlyTitan {
        if (amount > freeBalance[user]) revert IFB();
        freeBalance[user] -= amount;
        _burn(user, amount);
        _updateFreeBalanceUser(user, freeBalance[user]);
        emit QBIT_QbitBurned(user, amount, reason, block.timestamp);
    }

    // Extend phase five
    function extendPhaseFive() external onlyDAO {
        require(!isPhaseFiveExtended, "Phase five already extended");
        isPhaseFiveExtended = true;
        emit QBIT_PhaseFiveExtended(block.timestamp);
    }

    // Stop internal sale
    function stopInternalSale() external onlyDAO {
        require(!internalSaleStopped, "Internal sale already stopped");
        internalSaleStopped = true;
        emit QBIT_InternalSaleStopped(block.timestamp);
    }

    // Pause or unpause contract
    function setPaused(bool _paused) external onlyDAO {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    function updateAddresses() external {
        daoAddress = router.getDao();
        updateFund = router.getUpdateFundRecipient();
        supportFund = router.getSupportFundContract();
        titanContract = router.getTitanRegistration();
        erxToken = router.getEuphoriaContract();

        emit QBIT_AddressesUpdated(daoAddress, updateFund, supportFund, titanContract, erxToken, block.timestamp);
    }

    function updateRouter(address newRouter) external onlyDAO {
        require(newRouter != address(0), "Invalid router address");
        router = IRouter(newRouter);
        emit RouterUpdated(newRouter, block.timestamp);
    }

    function migrationWithdrawTokens(address tokenAddress, uint256 amount)
        external
        OnlyQBit(currentVersion)
        nonReentrant
    {
        require(freeBalance[address(this)] >= amount, "Insufficient free balance");
        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).transfer(version[currentVersion], tokenBalance);
        freeBalance[address(this)] -= tokenBalance;
        freeBalance[version[currentVersion]] += tokenBalance;
        _mint(version[currentVersion], 1);
    }

    function equivalency(uint256 amount, bool state) external OnlyQBit(currentVersion) nonReentrant {
        if (state) {
            _mint(version[currentVersion], amount);
        } else {
            _burn(version[currentVersion], amount);
        }

        emit QBIT_Equivalency(block.timestamp, amount, state ? true : false); // true: mint , false: burn
    }

    function updateVersion(address _newAddress) public onlyDAO {
        currentVersion++;
        require(version[currentVersion] == address(0) && _newAddress != address(0));
        require(_newAddress.code.length != 0, "New address empty code");
        if (
            keccak256(abi.encodePacked(IERC20Metadata(_newAddress).name()))
                != keccak256(abi.encodePacked("Qbit EuphoriaX"))
        ) {
            revert("Invalid address");
        }
        version[currentVersion] = _newAddress;
        emit QBIT_VersionUpdated(block.timestamp, currentVersion, _newAddress);
    }

    // Override ERC20 transfer
    function transfer(address to, uint256 amount) public override returns (bool) {
        return Qbit_Transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        return Qbit_TransferFrom(from, to, amount);
    }

    function Qbit_TransferFrom(address from, address to, uint256 amount) public whenNotPaused returns (bool) {
        address spender = _msgSender();
        // require(amount >= 1 * 10 ** 18, "Below minimum transfer");
        require(to != address(0), "Transfer to zero address");
        require(to != from, "Cannot transfer to self");
        require(freeBalance[from] >= amount, "Insufficient free balance");

        uint256 currentStage = getCurrentStage();
        uint256 currentPrice = currentStage < 5 ? stagePrices[currentStage] : stagePrices[4];
        uint256 usdValue = (amount * currentPrice) / 10 ** 18;
        // require(usdValue >= 1 * 10 ** 18, "Minimum transfer is $1 USD");

        uint256 fee = calculateTransferFee(usdValue);
        uint256 feeInTokens = (fee * 10 ** 18) / currentPrice;
        require(freeBalance[from] >= amount + feeInTokens, "Insufficient balance for fee");

        uint256 currentAllowance = allowance(from, spender);
        require(currentAllowance >= amount + feeInTokens, "Transfer amount exceeds allowance");

        _approve(from, spender, currentAllowance - (amount + feeInTokens));

        if (updateFund == address(0)) revert("UpdateFund address not set");

        freeBalance[from] -= (amount + feeInTokens);
        freeBalance[to] += amount;

        super.transferFrom(from, to, amount);

        if (feeInTokens > 0) {
            _transfer(from, updateFund, feeInTokens);

            try IUpdateFund(updateFund).onQBitReceived(feeInTokens) {
                emit QBIT_FeeDistributionLog(
                    address(this),
                    from,
                    updateFund,
                    block.timestamp,
                    feeInTokens,
                    true,
                    "QBit transferFrom fee distribution success"
                );
            } catch (bytes memory reason) {
                emit QBIT_FeeDistributionLog(
                    address(this), from, updateFund, block.timestamp, feeInTokens, false, string(reason)
                );
            }
        }

        _updatePurchaseHistoryOnTransfer(from, amount);
        _updateFreeBalanceUser(from, freeBalance[from]);
        _updateFreeBalanceUser(to, freeBalance[to]);

        emit QBIT_TokenTransferred(from, to, amount, feeInTokens, block.timestamp);
        emit QBIT_FeeCollected(from, usdValue, feeInTokens, 1); // 1 = transfer direction

        return true;
    }

    // Get token address by symbol
    function getTokenAddress(string memory _symbol) public view returns (address) {
        address token = supportedStableCoins[_symbol];
        require(token != address(0), "Unsupported token");
        return token;
    }

    // Get supported token symbols
    function getSupportedTokenSymbols() public view returns (string[] memory) {
        return tokenSymbols;
    }

    // Update free balance user list
    function _updateFreeBalanceUser(address user, uint256 newBalance) internal {
        if (newBalance > 0 && !hasFreeBalance[user]) {
            hasFreeBalance[user] = true;
            _freeBalanceUsers.add(user);
        } else if (newBalance == 0 && hasFreeBalance[user]) {
            hasFreeBalance[user] = false;
            _freeBalanceUsers.remove(user);
        }
    }

    function getFreeBalanceUsers() external view returns (address[] memory) {
        return _freeBalanceUsers.values();
    }

    function getFreeBalanceUsersCount() external view returns (uint256) {
        return _freeBalanceUsers.length();
    }

    function getFreeBalanceUsersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory users)
    {
        uint256 total = _freeBalanceUsers.length();

        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        users = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            users[i] = _freeBalanceUsers.at(offset + i);
        }
    }

    function getSoldPercentage(address user, uint256 index) public view returns (uint256) {
        require(index < purchaseHistory[user].length, "Invalid index");
        Purchase memory p = purchaseHistory[user][index];
        return (p.soldAmount * 100) / p.amount;
    }

    // Calculate fee for buy/sell
    function _calculateFee(uint256 amount, bool isBuy) internal view returns (uint256) {
        if (whitelisted[msg.sender]) {
            return (0);
        }
        if (isBuy) {
            if (amount <= 21 * 10 ** 18) return (amount * 10) / 100; // > $21: 5%
            if (amount <= 41 * 10 ** 18) return (amount * 3) / 100; // $21-$41: 3%
            if (amount <= 61 * 10 ** 18) return (amount * 2) / 100; // $41-$61: 2%
            if (amount <= 81 * 10 ** 18) return (amount * 15) / 1000; // $61-$81: 1.5%
            if (amount <= 101 * 10 ** 18) return (amount * 12) / 1000; // $81-$101: 1.2%
            return (amount * 1) / 100; // $101+: 1%
        } else {
            if (amount < 10 * 10 ** 18) return 0;
            if (amount <= 21 * 10 ** 18) return (amount * 5) / 100;
            if (amount <= 41 * 10 ** 18) return (amount * 3) / 100;
            if (amount <= 61 * 10 ** 18) return (amount * 2) / 100;
            if (amount <= 81 * 10 ** 18) return (amount * 15) / 1000;
            if (amount <= 101 * 10 ** 18) return (amount * 12) / 1000;
            return (amount * 1) / 100;
        }
    }

    function calculateTransferFee(uint256 usdValue) internal view returns (uint256) {
        if (whitelisted[msg.sender]) {
            return (0);
        }
        if (usdValue <= 11 * 10 ** 18) return (usdValue * 5) / 100; // > $11: 5%
        if (usdValue <= 21 * 10 ** 18) return (usdValue * 25) / 1000; // $11-$21: 2.5%
        if (usdValue <= 41 * 10 ** 18) return (usdValue * 15) / 1000; // $21-$41: 1.5%
        if (usdValue <= 61 * 10 ** 18) return (usdValue * 1) / 100; // $41-$61: 1%
        if (usdValue <= 101 * 10 ** 18) return (usdValue * 75) / 10000; // $61-$101: 0.75%
        return (usdValue * 5) / 1000; // $101+: 0.5%
    }

    function getCurrentStage() public view returns (uint256) {
        if (isPhaseFiveExtended) {
            return 4;
        }

        uint256 cumulativeLimit = 0;
        for (uint256 i = 0; i < 5; i++) {
            cumulativeLimit += stageLimits[i];
            if (soldInitialAmount < cumulativeLimit) {
                return i; // Found the current stage
            }
        }

        return 5;
    }

    function initVersion() internal {
        currentVersion++;
        version[currentVersion] = address(this);
        emit QBIT_Initialized(block.timestamp, currentVersion, address(this));
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

    function _sendUpdateFee(IERC20 stablecoin, uint256 amount) internal {
        stablecoin.safeTransfer(updateFund, amount);

        try IUpdateFund(updateFund).onFeeReceived(address(stablecoin), amount) {
            emit QBIT_FeeDistributionLog(
                address(stablecoin),
                address(this),
                updateFund,
                block.timestamp,
                amount,
                true,
                "QBit fee distribution success"
            );
        } catch (bytes memory reason) {
            emit QBIT_FeeDistributionLog(
                address(stablecoin), address(this), updateFund, block.timestamp, amount, false, string(reason)
            );
        }
    }

    function exportUserData(address user)
        external
        view
        returns (
            Purchase[] memory purchases,
            LockedTokens[] memory locks,
            uint256 freeBalance_,
            bool isPurchaseUser,
            bool isLockUser
        )
    {
        return (
            purchaseHistory[user],
            lockedTokens[user],
            freeBalance[user],
            _purchaseUsers.contains(user),
            _lockUsers.contains(user)
        );
    }

    function exportBatchUserData(address[] calldata users)
        external
        view
        returns (Purchase[][] memory allPurchases, LockedTokens[][] memory allLocks, uint256[] memory allFreeBalances)
    {
        uint256 length = users.length;
        allPurchases = new Purchase[][](length);
        allLocks = new LockedTokens[][](length);
        allFreeBalances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            allPurchases[i] = purchaseHistory[users[i]];
            allLocks[i] = lockedTokens[users[i]];
            allFreeBalances[i] = freeBalance[users[i]];
        }
    }

    function exportSystemState()
        external
        view
        returns (
            uint256 soldAmount,
            uint256 currentStage,
            uint256 totalInvestors,
            bool saleStopped,
            bool phase5Extended,
            address[] memory allPurchaseUsers,
            address[] memory allLockUsers
        )
    {
        return (
            soldInitialAmount,
            getCurrentStage(),
            investors,
            internalSaleStopped,
            isPhaseFiveExtended,
            _purchaseUsers.values(),
            _lockUsers.values()
        );
    }

    function exportStageConfig() external view returns (uint256[5] memory prices, uint256[5] memory limits) {
        for (uint256 i = 0; i < 5; i++) {
            prices[i] = stagePrices[i];
            limits[i] = stageLimits[i];
        }
    }

    function exportFullMigrationData()
        external
        view
        returns (
            address[] memory users,
            uint256[] memory freeBalances,
            uint256 totalSold,
            uint256 currentStage_,
            uint256 totalInvestors_
        )
    {
        address[] memory purchaseUsers = _purchaseUsers.values();
        uint256 userCount = purchaseUsers.length;

        freeBalances = new uint256[](userCount);

        for (uint256 i = 0; i < userCount; i++) {
            freeBalances[i] = freeBalance[purchaseUsers[i]];
        }

        return (purchaseUsers, freeBalances, soldInitialAmount, getCurrentStage(), investors);
    }

 function migrateToNewContract(address newContract) external onlyDAO nonReentrant {
    require(newContract != address(0), "Invalid new contract");
    require(newContract.code.length > 0, "New contract has no code");

    // Update version
    currentVersion++;
    version[currentVersion] = newContract;

    // Transfer all stablecoins to the new contract
    for (uint256 i = 0; i < stablecoins.length; i++) {
        IERC20 stablecoin = IERC20(address(stablecoins[i]));
        uint256 balance = stablecoin.balanceOf(address(this));
        if (balance > 0) {
            SafeERC20.safeTransfer(IERC20(address(stablecoin)), newContract, balance);
        }
    }

    // Transfer contract's free balance
    uint256 contractBalance = freeBalance[address(this)];
    if (contractBalance > 0) {
        freeBalance[address(this)] = 0;
        freeBalance[newContract] = contractBalance;
        _transfer(address(this), newContract, contractBalance);
    }

    // Stop internal sale
    internalSaleStopped = true;

    // Emit event
    emit QBIT_MigrationCompleted(
        block.timestamp, newContract, soldInitialAmount, _purchaseUsers.length(), _lockUsers.length()
    );
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

    function getUserCounts()
        external
        view
        returns (uint256 purchaseUserCount, uint256 lockUserCount, uint256 totalInvestors_)
    {
        return (_purchaseUsers.length(), _lockUsers.length(), investors);
    }

    function getUsersPaginated(uint256 offset, uint256 limit) external view returns (address[] memory users) {
        address[] memory allUsers = _purchaseUsers.values();
        uint256 total = allUsers.length;

        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        users = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            users[i] = allUsers[offset + i];
        }
    }

    // Helper function to send ERX fees to update fund
    function _sendERXUpdateFee(IERC20 erxToken_IERC20, uint256 feeAmount) internal {
        try IUpdateFund(updateFund).onFeeReceived(address(erxToken_IERC20), feeAmount) {
            SafeERC20.safeTransfer(erxToken_IERC20, updateFund, feeAmount);
        } catch {
            // If update fund doesn't support ERX fees, send to support fund instead
            SafeERC20.safeTransfer(erxToken_IERC20, supportFund, feeAmount);
        }
    }
}
