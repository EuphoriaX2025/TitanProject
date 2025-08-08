// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRouter {
    struct MigrationAttempt {
        address fromToken;
        address toToken;
        uint256 startTime;
        uint256 endTime;
        bool successful;
        string reason; // "completed", "cancelled", etc.
    }

    // Getter functions
    function getERXToken() external view returns (address);

    function getQbitToken() external view returns (address);

    function getTitanRegistration() external view returns (address);

    function getEuphoriaContract() external view returns (address);

    function getUpdateFundRecipient() external view returns (address);

    function getCapitalFundContract() external view returns (address);

    function getRewardFundContract() external view returns (address);

    function getSupportFundContract() external view returns (address);

    function getDao() external view returns (address);

    // Update functions – onlyOwner in the implementation
    function updateERXToken(address _erxToken) external;

    function updateQbitToken(address _qbitToken) external;

    function updateEuphoriaContract(address _euphoriaContract) external;

    function updateTitanRegisterContract(address _titanRegistration) external;

    function updateUpdateFundRecipient(address _updateFundRecipient) external;

    function updateCapitalFundContract(address _capitalFundContract) external;

    function updateRewardFundContract(address _rewardFundContract) external;

    function updateSupportFundContract(address _supportFundContract) external;

    function updateDao(address _dao) external;

    function startMigration(address newERXContract) external;
    function completeMigration() external;
    function cancelMigration() external;
    function migrationInProgress() external view returns (bool);
    function getPreviousERXToken() external view returns (address);
    function getMigrationInfo() external view returns (bool inProgress, address current, address previous);

    function migrationHistory(uint256 index)
        external
        view
        returns (
            address fromToken,
            address toToken,
            uint256 startTime,
            uint256 endTime,
            bool successful,
            string memory reason
        );
}
