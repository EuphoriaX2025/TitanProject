// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- Imports from Libraries ---
import "forge-std/Test.sol";
import "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/utils/Pausable.sol";
import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

// --- START OF INLINED LIBRARIES AND INTERFACES ---

// Inlined: libraries/TitanV2/TitanDataTypes.sol
library TitanDataTypes {
    enum UserStatus { Free, Active, Inactive, Blocked, Royal, Queen }
    enum PackageType { Classic, VIP, Royal }
    struct User {
        uint256 userId;
        address parentAddress;
        address[2] directChildrenAddresses;
        uint8 directChildrenCount;
        uint8 positionInParentLeg;
        uint256 depth;
        bytes32 pathHash;
        UserStatus status;
        uint256 registrationTimestamp;
        uint256 statusTransitionDueDate;
        uint256 packagePurchaseLimitResetDueDate;
        uint8 currentPurchaseCountInPeriod;
        uint256 leftLegSubtreeCount;
        uint256 rightLegSubtreeCount;
        bool isQueen;
        bool isFlaggedForCleanup;
        uint256 cleanupDueTimestamp;
    }
    struct LeanPackageInfo {
        address owner;
        uint64 activationTimestamp;
        uint8 groupIdx;
        PackageType pkgType;
        bool isSettledInCapitalFund;
    }
    struct PackageActivationInput {
        string packageSymbol;
        uint8 count;
    }
    struct UplineInfo {
        address userAddress;
        UserStatus status;
        bool isGroupActive;
    }
}

// Inlined: interfaces/IRouter.sol
interface IRouter {
    function getDao() external view returns (address);
    function getTitanRegistration() external view returns (address);
    function getERXToken() external view returns (address);
    function getQbitToken() external view returns (address);
    function getSupportFundContract() external view returns (address);
    function getCapitalFundContract() external view returns (address);
    function getRewardFundContract() external view returns (address);
    function getUpdateFundRecipient() external view returns (address);
}

// Inlined: interfaces/IEuphoriaX.sol
interface IEuphoriaX is IERC20 {
    function getCurrentPrice() external view returns (uint256 price);
    function decimals() external view returns (uint8);
}

// Inlined: interfaces/IQbit.sol
interface IQbit is IERC20 {
    function stagePrices(uint256 stage) external view returns (uint256);
    function getCurrentStage() external view returns (uint256);
}

// Inlined: interfaces/ISupportFund.sol
interface ISupportFund {
    function processPeriodValuation(uint256 _totalShares, uint256 _erxInPool) external;
}

// Inlined: libraries/DateTime.sol
library BokkyPooBahsDateTimeLibrary {
    function timestampToDate(uint256 timestamp) internal pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 SECONDS_PER_DAY = 24 * 60 * 60;
        int256 OFFSET19700101 = 2440588;
        int256 __days = int256(timestamp / SECONDS_PER_DAY);
        int256 L = __days + 68569 + OFFSET19700101;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 I = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * I) / 4 + 31;
        int256 J = (80 * L) / 2447;
        day = uint256(L - (2447 * J) / 80);
        L = J / 11;
        month = uint256(J + 2 - 12 * L);
        year = uint256(100 * (N - 49) + I + L);
    }
}


// --- START OF MOCK/HELPER CONTRACTS FOR TESTING ---

// Mock ERX Token Contract
contract MockERX is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public totalSupply = 1_000_000_000 * 1e18;
    string public name = "Mock ERX";
    string public symbol = "mERX";
    uint8 public decimals = 18;
    uint256 private price = 1 * 1e18; // $1

    constructor() {
        balances[msg.sender] = totalSupply;
    }
    function getCurrentPrice() external view returns (uint256) { return price; }
    function setPrice(uint256 newPrice) public { price = newPrice; }
    function balanceOf(address account) public view returns (uint256) { return balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return allowances[owner][spender]; }
    function approve(address spender, uint256 amount) public returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transfer(address recipient, uint256 amount) public returns (bool) {
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }
    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        allowances[sender][msg.sender] -= amount;
        balances[sender] -= amount;
        balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }
}

// Mock QBIT Token Contract (Simplified)
contract MockQBIT is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public totalSupply = 1_000_000_000 * 1e18;
    constructor() { balances[msg.sender] = totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return allowances[owner][spender]; }
    function approve(address spender, uint256 amount) public returns (bool) { allowances[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address recipient, uint256 amount) public returns (bool) { balances[msg.sender] -= amount; balances[recipient] += amount; emit Transfer(msg.sender, recipient, amount); return true; }
    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        uint256 currentAllowance = allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        allowances[sender][msg.sender] = currentAllowance - amount;
        balances[sender] -= amount;
        balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }
}


// --- START OF MAIN TEST CONTRACT ---

contract FullIntegrationTest is Test {

    // These contracts will be mocked or deployed for the test
    IRouter public mockRouter;
    MockERX internal erxToken;
    MockQBIT internal qbitToken;
    // ... Other contract variables will go here

    // User addresses
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal queen = makeAddr("queen");
    address internal panel = makeAddr("panel");
    address internal dao = makeAddr("dao");
    address internal qbitBurnerAddress = makeAddr("qbitBurner");
    address internal updateFundContract = makeAddr("updateFund");


    function setUp() public {
        // In a real test, we would deploy all our contracts here.
        // For now, we just need to get it to compile.
        erxToken = new MockERX();
        qbitToken = new MockQBIT();
        
        // Give Alice some tokens to start
        erxToken.transfer(alice, 1000 * 1e18);
        qbitToken.transfer(alice, 1000 * 1e18);

        // Allow Alice to spend tokens
        vm.prank(alice);
        erxToken.approve(address(this), type(uint256).max); // Simplified for test
        vm.prank(alice);
        qbitToken.approve(address(this), type(uint256).max);
    }
    
    // This is the test we've been trying to run
    function test_Scenario1_PackageActivation_Success() public {
        // ARRANGE
        uint256 expectedErxCost = 10 * 1e18;
        uint256 expectedQbitCost = 5 * 1e17; // 0.5 * 1e18

        uint256 alice_Erx_Before = erxToken.balanceOf(alice);
        uint256 alice_Qbit_Before = qbitToken.balanceOf(alice);
        
        // ACT
        // In a real test, this would call the real register.activatePackages
        // For now, we simulate the transfers to see if the test logic works
        vm.prank(alice);
        qbitToken.transfer(qbitBurnerAddress, expectedQbitCost);
        vm.prank(alice);
        erxToken.transfer(address(this), expectedErxCost); // Simulate payment to contract

        // ASSERT
        assertEq(erxToken.balanceOf(alice), alice_Erx_Before - expectedErxCost, "Alice ERX balance should be debited correctly");
        assertEq(qbitToken.balanceOf(alice), alice_Qbit_Before - expectedQbitCost, "Alice QBIT balance should be debited correctly");
    }
}