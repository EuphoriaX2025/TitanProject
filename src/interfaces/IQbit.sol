// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IQbit {
    function mint(address recipient, uint256 amount) external;
    function stagePrices(uint256 stageNumber) external view returns (uint256);
    function soldInitialAmount() external view returns (uint256);
    function isPhaseFiveExtended() external view returns (bool);
    function getCurrentPrice() external view returns (uint256);

    function theInvestors(uint256) external view returns (address);
    function freeBalance(uint256) external view returns (uint256);
    function hasFreeBalance(address) external view returns (bool);
    function stageLimits(uint256) external view returns (uint256);

    function getCurrentStage() external view returns (uint256);

    function purchaseHistory(address)
        external
        view
        returns (uint256 stage, uint256 purchaseAmount, uint256 purchaseTime, uint256 amount, uint256 soldAmount);

    function lockedTokens(address) external view returns (uint256 phaseNumber, uint256 amount, uint256 purchaseTime);
}
