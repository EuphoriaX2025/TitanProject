// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUpdateFund {
    function getVestingInfo(address beneficiary)
        external
        view
        returns (
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 month6Amount,
            uint256 month12Amount,
            uint256 immediateWithdrawn,
            uint256 month6Withdrawn,
            uint256 month12Withdrawn,
            uint256 startTime,
            uint256 stage2UnlockTime,
            uint256 stage3UnlockTime,
            bool stage2Unlocked,
            bool stage3Unlocked
        );

    function onFeeReceived(address token, uint256 amount) external;
    function onQBitReceived(uint256 amount) external;
    function updateAddresses() external;
    function updateBeneficiary(uint256 index, address newBeneficiary) external;
    function updateShares(uint256[7] memory newShares) external;
    function updateRouter(address newRouter) external;
}