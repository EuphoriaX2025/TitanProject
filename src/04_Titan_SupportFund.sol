// SPDX-License-Identifier: MIT
/**
 * @title Titan_SupportFund Contract (v3.0.0 - With Circuit Breaker)
 * @author Kamyar (Concept & Lead) - Dr. Satoshi Arcanum (Architecture & Code)
 * @notice صندوق پشتیبانی و تثبیت اقتصادی اکوسیستم تایتان، مجهز به مکانیزم داخلی حفاظت از نوسان قیمت.
 * @dev نسخه 3.0.0: اضافه شدن فیوز قیمت آن‌چین (On-chain Price Volatility Circuit Breaker).
 */
pragma solidity ^0.8.20;

// --- Imports ---
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/IEuphoriaX.sol";
import "../../interfaces/IRouter.sol";
// import "./interfaces/IPriceOracle.sol"; // <--- ADDED: Standard Price Oracle Interface
import "../../interfaces/IEvents.sol";

contract Titan_SupportFund is ReentrancyGuard, Pausable, ITitanEventsSupport {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    IRouter public router;
    address public daoAddress;
    address public capitalFundAddress;
    address public rewardFundAddress;

    IEuphoriaX public immutable ERX_TOKEN;
    IERC20 public immutable DAI_TOKEN; // Assuming DAI or another stablecoin for treasury diversification

    // --- NEW: Price Volatility Circuit Breaker State ---
    bool public isVolatilityCheckActive;
    uint256 public MAX_PRICE_INCREASE_BPS; // e.g., 2000 for 20% Increase
    uint256 public MAX_PRICE_DECREASE_BPS; // e.g., 500 for 5% Decrease
    uint256 public lastErxPrice;
    // uint256 public lastPriceTimestamp;

    // --- Constants ---
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10000;
    // uint256 private constant VOLATILITY_WINDOW = 1 hours;

    // --- Pricing Bands ---
    uint256 private constant RFT_FLOOR_PRICE = 2 * 1e18; // $2.00
    uint256 private constant RFT_CEILING_PRICE = 3 * 1e18; // $3.00
    uint256 private constant CFT_FLOOR_PRICE = 4 * 1e18; // $4.00
    uint256 private constant CFT_CEILING_PRICE = 5 * 1e18; // $5.00

    // --- Modifiers ---
    modifier onlyDAO() {
        require(msg.sender == daoAddress, "SF: Caller is not the DAO");
        _;
    }

    modifier onlyAllowedFundContracts() {
        require(
            msg.sender == capitalFundAddress || msg.sender == rewardFundAddress,
            "SF: Caller is not an allowed fund contract"
        );
        _;
    }

    event LOG(string message, bytes32);

    function slotNumber() public view returns (bytes32 a) {
        assembly {
            a := lastErxPrice.slot
        }
    }

    // --- Constructor ---
    constructor(address _routerAddress, address _daiTokenAddress) {
        emit LOG("slotNumber", slotNumber());
        require(_routerAddress != address(0) && _daiTokenAddress != address(0), "SF: Zero address");

        router = IRouter(_routerAddress);
        daoAddress = router.getDao();

        address _erxTokenAddress = router.getERXToken();
        require(_erxTokenAddress != address(0), "SF: ERX token address is zero");
        ERX_TOKEN = IEuphoriaX(_erxTokenAddress);
        DAI_TOKEN = IERC20(_daiTokenAddress);

        // capitalFundAddress = router.getContractAddress("CapitalFund");
        capitalFundAddress = router.getCapitalFundContract();
        rewardFundAddress = router.getRewardFundContract();

        isVolatilityCheckActive = true; // Active by default
        MAX_PRICE_INCREASE_BPS = 2000; // Default 20%
        MAX_PRICE_DECREASE_BPS = 500; // Default 5%
    }

    // --- DAO Admin Functions ---
    function pause() external onlyDAO {
        _pause();
    }

    function unpause() external onlyDAO {
        _unpause();
    }

    /**
     * @notice (NEW) Enables or disables the on-chain price volatility check.
     * @dev A crucial safety switch for the DAO to manage market anomalies.
     * @param _active The desired state of the volatility check.
     */
    function setVolatilityCheck(bool _active) external onlyDAO {
        isVolatilityCheckActive = _active;
    }

    // /**
    //  * @notice (NEW) Sets the maximum allowed price swing in Basis Points (BPS).
    //  * @dev 100 BPS = 1%. For example, set to 2000 for a 20% max volatility.
    //  * @param _newBPS The new maximum volatility in BPS.
    //  */
    function setMaxIncreaseVolatilityBPS(uint256 _newBps) external onlyDAO {
        require(_newBps > 0 && _newBps < BPS_DENOMINATOR, "SF: Invalid BPS value");
        MAX_PRICE_INCREASE_BPS = _newBps;
    }

    /**
     * @notice (NEW) Sets the maximum allowed price DECREASE in Basis Points (BPS).
     * @dev This should be a much stricter (smaller) value. Example: 500 for a 5% max decrease.
     * @param _newBps The new maximum decrease volatility in BPS.
     */
    function setMaxDecreaseVolatilityBPS(uint256 _newBps) external onlyDAO {
        require(_newBps > 0 && _newBps < BPS_DENOMINATOR, "SF: Invalid BPS value");
        MAX_PRICE_DECREASE_BPS = _newBps;
    }

    function updateContractAddress(string calldata _name, address _newAddress) external onlyDAO {
        // ... (implementation to be provided in later parts)
    }

    // function withdrawFunds(address _token, address _to, uint256 _amount) external onlyDAO nonReentrant {
    //     // ... (implementation to be provided in later parts)
    // }

    event LOG(string message, uint256 value);
    event LOG(string message, bool value);

    // --- Core Economic Function ---
    /**
     * @notice Central valuation engine for CFT and RFT, now with a volatility circuit breaker.
     * @dev This function implements the direct price stabilization logic. It ensures the final price
     * for a period lands within the predefined corridor by either providing support or taking an overflow.
     * It will revert if the price volatility check is active and the price swing is too large.
     */
    function processPeriodValuation(uint256 _totalShares, uint256 _erxInPool)
        external
        whenNotPaused
        nonReentrant
        onlyAllowedFundContracts
    {
        emit LOG("[processPeriodValuation]: entered _totalShares", _totalShares);
        emit LOG("[processPeriodValuation]: _erxInPool", _erxInPool);
        emit LOG("[processPeriodValuation]: isVolatilityCheckActive", isVolatilityCheckActive);
        uint256 priceToUse = lastErxPrice;

        // ==================================================================
        // SECTION 1: ON-CHAIN PRICE VOLATILITY CIRCUIT BREAKER
        // ==================================================================
        if (isVolatilityCheckActive) {
            // uint256 newPrice = erxPriceOracle.getLatestPrice();
            uint256 newPrice = ERX_TOKEN.getCurrentPrice();
            emit LOG("[processPeriodValuation]: newPrice", newPrice);
            require(newPrice > 0, "SF: Oracle returned zero price");

            // If a significant time has passed, or it's the first run, just record the price.
            // if (lastErxPrice == 0 || block.timestamp > lastPriceTimestamp + VOLATILITY_WINDOW) {
            if (lastErxPrice == 0) {
                priceToUse = newPrice;
                lastErxPrice = newPrice;
                // lastPriceTimestamp = block.timestamp;
            } else {
                uint256 priceDiff;
                if (newPrice > lastErxPrice) {
                    priceDiff = newPrice - lastErxPrice;
                    uint256 volatilityBPS = (priceDiff * BPS_DENOMINATOR) / lastErxPrice;
                    require(volatilityBPS <= MAX_PRICE_INCREASE_BPS, "SF: Price increase exceeds threshold");
                } else {
                    priceDiff = lastErxPrice - newPrice;
                    uint256 volatilityBPS = (priceDiff * BPS_DENOMINATOR) / lastErxPrice;
                    require(volatilityBPS <= MAX_PRICE_DECREASE_BPS, "SF: Price decrease exceeds threshold");
                }

                // Check if the price difference exceeds the allowed volatility
                // uint256 volatilityBPS = (priceDiff * BPS_DENOMINATOR) / lastErxPrice;
                // require(volatilityBPS <= MAX_PRICE_VOLATILITY_BPS, "SF: Price volatility exceeds threshold");

                // If check passes, update the recorded price for the next check
                priceToUse = newPrice;
                lastErxPrice = newPrice;
                // lastPriceTimestamp = block.timestamp;
            }
        } else {
            // If the check is inactive, use the latest price without validation.
            priceToUse = ERX_TOKEN.getCurrentPrice();
            require(priceToUse > 0, "SF: Oracle returned zero price");
        }

        // ==================================================================
        // SECTION 2: CORE VALUATION & STABILIZATION LOGIC
        // ==================================================================
        uint256 erxPrice = priceToUse; // Use the validated price
        emit LOG("[processPeriodValuation]: erxPrice", erxPrice);

        // Determine correct price bands based on the caller
        bool isCFT = (msg.sender == capitalFundAddress);
        emit LOG("[processPeriodValuation]: isCFT", isCFT);
        uint256 FLOOR_PRICE = isCFT ? CFT_FLOOR_PRICE : RFT_FLOOR_PRICE;
        emit LOG("[processPeriodValuation]: FLOOR_PRICE", FLOOR_PRICE);
        uint256 CEILING_PRICE = isCFT ? CFT_CEILING_PRICE : RFT_CEILING_PRICE;
        emit LOG("[processPeriodValuation]: CEILING_PRICE", CEILING_PRICE);

        if (_totalShares == 0) {
            // If there are no shares, no valuation is needed. Funds will be handled by the calling contract.
            // This also prevents division by zero.
            return;
        }

        uint256 totalValueUsd = (_erxInPool * erxPrice) / PRECISION;
        emit LOG("[processPeriodValuation]: totalValueUsd", totalValueUsd);
        uint256 pricePerShare = (totalValueUsd * PRECISION) / _totalShares;
        emit LOG("[processPeriodValuation]: pricePerShare", pricePerShare);
        emit LOG("[processPeriodValuation]: pricePerShare > CEILING_PRICE", pricePerShare > CEILING_PRICE);

        if (pricePerShare > CEILING_PRICE) {
            // --- Overflow Logic ---
            uint256 targetValueUsd = (CEILING_PRICE * _totalShares) / PRECISION;
            emit LOG("[processPeriodValuation]: targetValueUsd", targetValueUsd);
            uint256 overflowUsd = totalValueUsd - targetValueUsd;
            emit LOG("[processPeriodValuation]: overflowUsd", overflowUsd);
            uint256 overflowErx = (overflowUsd * PRECISION) / erxPrice;
            emit LOG("[processPeriodValuation]: overflowErx", overflowErx);

            if (overflowErx > 0) {
                SafeERC20.safeTransferFrom(ERX_TOKEN, msg.sender, address(this), overflowErx);
                // ERX_TOKEN.safeTransferFrom(msg.sender, address(this), overflowErx);
                // emit PeriodValuationProcessed(msg.sender, false, overflowErx); // isSupport = false
            }
        } else if (pricePerShare < FLOOR_PRICE) {
            // --- Support Logic ---
            uint256 requiredValueUsd = (FLOOR_PRICE * _totalShares) / PRECISION;
            emit LOG("[processPeriodValuation]: requiredValueUsd", requiredValueUsd);
            uint256 deficitUsd = requiredValueUsd - totalValueUsd;
            emit LOG("[processPeriodValuation]: deficitUsd", deficitUsd);
            uint256 requiredErx = (deficitUsd * PRECISION) / erxPrice;
            emit LOG("[processPeriodValuation]: requiredErx", requiredErx);

            if (requiredErx > 0) {
                _provideSupport(msg.sender, requiredErx);
                // emit PeriodValuationProcessed(msg.sender, true, requiredErx); // isSupport = true
            }
        }
        // If the price is within the [FLOOR, CEILING] corridor, no action is needed.
    }

    // --- Public Deposit & Withdrawal Functions ---

    /**
     * @notice Allows anyone to deposit supported stablecoins into the treasury.
     */
    function deposit(uint256 _daiAmount) external whenNotPaused nonReentrant {
        require(_daiAmount > 0, "SF: Deposit amount must be greater than zero");
        DAI_TOKEN.safeTransferFrom(msg.sender, address(this), _daiAmount);
        // emit FundsDeposited(msg.sender, address(DAI_TOKEN), _daiAmount);
    }

    /**
     * @notice Allows the DAO to withdraw treasury funds for strategic purposes.
     */
    function withdrawFunds(address _token, address _to, uint256 _amount) external onlyDAO nonReentrant {
        require(_to != address(0), "SF: Destination address cannot be zero");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    // --- Internal Logic ---

    /**
     * @notice (REFACTORED) Internal logic to provide financial support to a fund contract.
     * @dev Follows a simplified "best-effort" strategy using only its own ERX reserves.
     * It will send what it can, up to the required amount, without reverting if reserves are insufficient.
     * @param _destination The fund contract to send ERX to.
     * @param _requiredAmountErx The amount of ERX needed by the fund.
     */
    function _provideSupport(address _destination, uint256 _requiredAmountErx) private {
        uint256 erxAvailable = ERX_TOKEN.balanceOf(address(this));

        if (erxAvailable == 0) {
            // No ERX to provide, do nothing.
            return;
        }

        // Determine the actual amount to send: either the full required amount or whatever is available.
        uint256 amountToSend = erxAvailable >= _requiredAmountErx ? _requiredAmountErx : erxAvailable;

        SafeERC20.safeTransfer(ERX_TOKEN, _destination, amountToSend);
        // emit SupportProvided(_destination, amountToSend);
    }

    /**
     * @notice Internal logic to provide financial support to a fund contract.
     * @dev Follows a dual-source strategy: first uses its own ERX reserves,
     * then buys more ERX using its DAI reserves if necessary.
     * @param _destination The fund contract to send ERX to.
     * @param _requiredAmountErx The amount of ERX needed by the fund.
     */
    // function _provideSupport(address _destination, uint256 _requiredAmountErx) private {
    //     uint256 erxAvailable = ERX_TOKEN.balanceOf(address(this));

    //     if (erxAvailable == 0) {
    //         return;
    //     }

    //     if (erxAvailable >= _requiredAmountErx) {
    //         // Scenario 1: Sufficient ERX in treasury
    //         SafeERC20.safeTransfer(ERX_TOKEN, _destination, _requiredAmountErx);
    //         // ERX_TOKEN.safeTransfer(_destination, _requiredAmountErx);
    //     } else {
    //         // Scenario 2: Insufficient ERX, must use DAI reserves to buy more
    //         uint256 erxDeficit = _requiredAmountErx - erxAvailable;

    //         // Transfer all available ERX first
    //         if (erxAvailable > 0) {
    //             SafeERC20.safeTransfer(ERX_TOKEN, _destination, erxAvailable);
    //             // ERX_TOKEN.safeTransfer(_destination, erxAvailable);
    //         }

    //         // Use DAI to buy the remaining ERX needed
    //         uint256 daiAvailable = DAI_TOKEN.balanceOf(address(this));
    //         uint256 erxPrice = lastErxPrice; // Use the validated price
    //         uint256 daiNeeded = (erxDeficit * erxPrice) / PRECISION;

    //         uint256 daiToUse = daiNeeded < daiAvailable ? daiNeeded : daiAvailable;

    //         if (daiToUse > 0) {
    //             // This logic assumes an external contract (like EuphoriaX) can process this.
    //             // For simplicity, we're showing a direct transfer. In a real scenario,
    //             // this would involve a swap call.
    //             // We will use the router to find the swapper contract.
    //             // IEUphoriaX(erxToken).buy(daiToUse, "DAI");

    //             // For now, we assume the mechanism exists and just transfer the tokens
    //             // to the destination, as the exact swap logic is out of scope for this contract.
    //             // This would be a call to a DEX or the EuphoriaX contract.
    //             // For the purpose of this refactor, we acknowledge the need for this interaction.
    //         }

    //         // After buying, the newly acquired ERX would be in this contract, ready for transfer.
    //         uint256 erxBought = (daiToUse * PRECISION) / erxPrice; // Theoretical amount
    //         SafeERC20.safeTransfer(ERX_TOKEN, _destination, erxBought);
    //         // ERX_TOKEN.safeTransfer(_destination, erxBought);
    //     }
    // }

    // --- View Functions & Address Updates ---

    /**
     * @notice Updates contract addresses from the central router.
     * @dev Should be called after the router updates any core address.
     */
    function updateAddresses() external {
        require(msg.sender == address(router) || msg.sender == daoAddress, "SF: Not authorized");

        daoAddress = router.getDao();
        capitalFundAddress = router.getCapitalFundContract();
        rewardFundAddress = router.getRewardFundContract();

        // address _erxOracleAddress = router.getEuphoriaContract();
        // erxPriceOracle = IPriceOracle(_erxOracleAddress);
    }

    modifier onlyDaoAndRouter() {
        require(_msgSender() == daoAddress || _msgSender() == address(router), "TR: Caller is not the DAO");
        _;
    }
}
