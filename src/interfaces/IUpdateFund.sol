// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

interface IUpdateFund {
    function onFeeReceived(address token, uint256 amount) external;
    function onQBitReceived(uint256 amount) external;

    function updateAddresses() external;
    function updateBeneficiary(uint256 index, address newBeneficiary) external;
    function updateShares(uint256[5] memory newShares) external;
    function updateRouter(address newRouter) external;
}
