// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {MockERC20} from '@uniswap/v4-core/lib/forge-std/src/mocks/MockERC20.sol';

contract FlaunchMockERC20 is MockERC20 {
    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}


/**
 * Deploys MockERC20 contracts that can be used by the Token Importer
 */
contract MockERC20Factory is Ownable, Pausable {

    /// Event emitted when a new token is deployed
    event TokenDeployed(address indexed token, string name, string symbol, address indexed deployer);

    /// Mapping to track deployed tokens
    mapping (address _token => bool _exists) public deployedTokens;

    constructor() Ownable(msg.sender) {
        // ..
    }

    /**
     * Deploys a new FlaunchMockERC20 token.
     * 
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param decimals The number of decimals of the token
     *
     * @return token_ The address of the deployed token
     */
    function deployToken(string memory name, string memory symbol, uint8 decimals) public whenNotPaused returns (address token_) {
        // Deploy the new token
        FlaunchMockERC20 newToken = new FlaunchMockERC20();
        
        // Capture the address of the deployed token
        token_ = address(newToken);
        
        // Initialize the token with the given decimals
        newToken.initialize(name, symbol, decimals);
        
        // Track the deployed token
        deployedTokens[token_] = true;
        
        // Emit event
        emit TokenDeployed(token_, name, symbol, msg.sender);
    }

    /**
     * Pause the factory
     */
    function pause(bool _paused) public onlyOwner {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }
}
