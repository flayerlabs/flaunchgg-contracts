// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Flaunch} from '@flaunch/Flaunch.sol';
import {ITreasuryManager} from '@flaunch-interfaces/ITreasuryManager.sol';
import {IManagerPermissions} from '@flaunch-interfaces/IManagerPermissions.sol';
import {IFeeEscrowRegistry} from '@flaunch-interfaces/IFeeEscrowRegistry.sol';

/**
 * Mock manager that implements the ITreasuryManager interface.
 * This manager supports the deposit function and should work with the FlaunchZap.
 */
contract CompatibleManagerMock is ITreasuryManager {
    
    address public managerOwner;
    IManagerPermissions public permissions;
    IFeeEscrowRegistry public feeEscrowRegistry;
    
    // Track deposits for testing
    mapping(address => uint) public balances;
    ITreasuryManager.FlaunchToken public depositedToken;
    address public lastCreator;
    bytes public lastDepositData;
    
    event TokenDeposited(address indexed creator, uint tokenId, bytes data);
    event TokenRescued(address indexed recipient, uint tokenId);
    
    constructor(address _owner, address _feeEscrowRegistry) {
        managerOwner = _owner;
        feeEscrowRegistry = IFeeEscrowRegistry(_feeEscrowRegistry);
    }
    
    function initialize(address _owner, bytes calldata _data) external override {
        managerOwner = _owner;
        // Could process initialization data here
    }
    
    function deposit(
        ITreasuryManager.FlaunchToken calldata _flaunchToken, 
        address _creator, 
        bytes calldata _data
    ) external override {
        // Transfer the token from the caller to this contract
        _flaunchToken.flaunch.transferFrom(msg.sender, address(this), _flaunchToken.tokenId);
        
        // Store the deposit information
        depositedToken = _flaunchToken;
        lastCreator = _creator;
        lastDepositData = _data;
        
        // Update balances (mock implementation)
        balances[_creator] += 1000; // Mock balance increase
        
        emit TokenDeposited(_creator, _flaunchToken.tokenId, _data);
    }
    
    function rescue(
        ITreasuryManager.FlaunchToken calldata _flaunchToken, 
        address _recipient
    ) external override {
        require(msg.sender == managerOwner, "Only owner can rescue");
        
        // Transfer the token to the recipient
        _flaunchToken.flaunch.transferFrom(address(this), _recipient, _flaunchToken.tokenId);
        
        emit TokenRescued(_recipient, _flaunchToken.tokenId);
    }
    
    function isValidCreator(address _creator, bytes calldata _data) external pure override returns (bool) {
        // Mock implementation - always returns true
        return true;
    }
    
    function claim() external override returns (uint amount_) {
        // Mock implementation - return some amount
        amount_ = balances[msg.sender];
        balances[msg.sender] = 0;
        return amount_;
    }
    
    function setPermissions(address _permissions) external override {
        require(msg.sender == managerOwner, "Only owner can set permissions");
        permissions = IManagerPermissions(_permissions);
    }
    
    function transferManagerOwnership(address _newManagerOwner) external override {
        require(msg.sender == managerOwner, "Only owner can transfer ownership");
        managerOwner = _newManagerOwner;
    }
}

/**
 * Mock manager that does NOT implement the ITreasuryManager interface.
 * This manager does not have a deposit function and should trigger the fallback behavior.
 */
contract IncompatibleManagerMock {
    
    address public owner;
    string public name = "IncompatibleManager";
    
    event TokenReceived(address indexed from, uint indexed tokenId);
    event FallbackCalled();
    
    constructor(address _owner) {
        owner = _owner;
    }
    
    // This contract intentionally does NOT have a deposit function
    // It will receive tokens via direct transfer (ERC721 transferFrom)
    
    // Mock function to simulate some other functionality
    function doSomething() external pure returns (string memory) {
        return "This manager doesn't support deposits";
    }
    
    // Fallback function to handle any calls to non-existent functions
    fallback() external payable {
        emit FallbackCalled();
    }
    
    // Receive function for ETH
    receive() external payable {
        // Accept ETH
    }
}
