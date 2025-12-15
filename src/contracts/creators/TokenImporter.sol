// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {MarketCappedPrice} from '@flaunch/price/MarketCappedPrice.sol';

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';


/**
 * This contract allows users to import their memecoin to the AnyPositionManager. When importing
 * a memecoin, we will call a specified verifier contract to verify that the memecoin is valid
 * to be imported.
 */
contract TokenImporter is Ownable {

    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidMemecoin();
    error VerifierAlreadyAdded();
    error VerifierNotAdded();
    error ZeroAddress();

    event AnyPositionManagerSet(address indexed _anyPositionManager);
    event TokenImported(address indexed _memecoin, address indexed _verifier);
    event VerifierAdded(address indexed _verifier);
    event VerifierRemoved(address indexed _verifier);

    /// The AnyPositionManager contract
    AnyPositionManager public anyPositionManager;
    
    /// Set of verifier addresses
    EnumerableSet.AddressSet private _verifiers;

    /**
     * Sets the required contract addresses and the owner of the contract.
     *
     * @param _anyPositionManager The address of the AnyPositionManager contract
     */
    constructor (address payable _anyPositionManager) {
        _initializeOwner(msg.sender);

        // Validate and set the AnyPositionManager contract
        setAnyPositionManager(_anyPositionManager);
    }

    /**
     * Initializes a non-native memecoin onto Flaunch.
     *
     * @param _memecoin The address of the memecoin
     * @param _creatorFeeAllocation The percentage of the fee to allocate to the creator
     * @param _initialMarketCap The initial market cap of the memecoin in USDC
     */
    function initialize(address _memecoin, uint24 _creatorFeeAllocation, uint _initialMarketCap) public {
        // Ensure that the memecoin is not a zero address
        if (_memecoin == address(0)) {
            revert ZeroAddress();
        }

        // Ensure that at least one verifier approved
        address verifier = verifyMemecoin(_memecoin);
        if (verifier == address(0)) {
            revert InvalidMemecoin();
        }

        _initialize(_memecoin, _creatorFeeAllocation, abi.encode(_initialMarketCap, _memecoin), verifier);
    }

    /**
     * Initializes a non-native memecoin onto Flaunch against a specific verifier.
     *
     * @param _memecoin The address of the memecoin
     * @param _creatorFeeAllocation The percentage of the fee to allocate to the creator
     * @param _initialMarketCap The initial market cap of the memecoin in USDC
     * @param _verifier The address of the verifier
     */
    function initialize(address _memecoin, uint24 _creatorFeeAllocation, uint _initialMarketCap, address _verifier) public {
        // Ensure that the memecoin is not a zero address
        if (_memecoin == address(0)) {
            revert ZeroAddress();
        }

        // Ensure that the verifier is valid
        if (!_verifiers.contains(_verifier)) {
            revert VerifierNotAdded();
        }

        // Ensure that the memecoin is valid against the specific verifier
        if (!IImportVerifier(_verifier).isValid(_memecoin, msg.sender)) {
            revert InvalidMemecoin();
        }

        _initialize(_memecoin, _creatorFeeAllocation, abi.encode(_initialMarketCap, _memecoin), _verifier);
    }

    /**
     * Initializes a non-native memecoin onto Flaunch against a specific verifier with additional initial price parameters.
     *
     * @param _memecoin The address of the memecoin
     * @param _creatorFeeAllocation The percentage of the fee to allocate to the creator
     * @param _initialMarketCap The initial market cap of the memecoin in USDC
     * @param _totalSupply The total supply of the memecoin
     * @param _verifier The address of the verifier
     */
    function initialize(address _memecoin, uint24 _creatorFeeAllocation, uint _initialMarketCap, uint _totalSupply, address _verifier) public {
        // Ensure that the memecoin is not a zero address
        if (_memecoin == address(0)) {
            revert ZeroAddress();
        }

        // If the verifier is a zero address, then we will need to try and verify it against all of them
        if (_verifier == address(0)) {
            // Set the verifier to the first verifier that validates the memecoin
            _verifier = verifyMemecoin(_memecoin);

            // If we still have a zero address, then the memecoin is invalid
            if (_verifier == address(0)) {
                revert InvalidMemecoin();
            }
        }
        // Otherwise, we can try and verify it against the specific verifier
        else {
            // Ensure that the verifier is valid
            if (!_verifiers.contains(_verifier)) {
                revert VerifierNotAdded();
            }

            // Ensure that the memecoin is valid against the specific verifier
            if (!IImportVerifier(_verifier).isValid(_memecoin, msg.sender)) {
                revert InvalidMemecoin();
            }
        }

        _initialize(_memecoin, _creatorFeeAllocation, abi.encode(_initialMarketCap, _memecoin, _totalSupply), _verifier);
    }

    /**
     * @dev Internal function to initialize a memecoin.
     *
     * @param _memecoin The address of the memecoin
     * @param _creatorFeeAllocation The percentage of the fee to allocate to the creator
     * @param _initialPriceParams The encoded parameters for the initial price
     * @param _verifier The address of the verifier
     */
    function _initialize(address _memecoin, uint24 _creatorFeeAllocation, bytes memory _initialPriceParams, address _verifier) internal {
        // Flaunch our token into the AnyPositionManager
        anyPositionManager.flaunch(
            AnyPositionManager.FlaunchParams({
                memecoin: _memecoin,
                creator: msg.sender,
                creatorFeeAllocation: _creatorFeeAllocation,
                initialPriceParams: _initialPriceParams,
                feeCalculatorParams: abi.encode('')
            })
        );

        emit TokenImported(_memecoin, _verifier);
    }

    /**
     * Add a verifier that will be used to verify memecoins.
     *
     * @param _verifier The address of the verifier
     */
    function addVerifier(address _verifier) public onlyOwner {
        // Ensure that the verifier is not the zero address
        if (_verifier == address(0)) revert ZeroAddress();

        // Add the verifier - will revert if already added
        if (!_verifiers.add(_verifier)) revert VerifierAlreadyAdded();
        emit VerifierAdded(_verifier);
    }

    /**
     * Remove a verifier that will no longer be used to verify memecoins.
     *
     * @param _verifier The address of the verifier
     */
    function removeVerifier(address _verifier) public onlyOwner {
        if (!_verifiers.remove(_verifier)) revert VerifierNotAdded();
        emit VerifierRemoved(_verifier);
    }

    /**
     * Get all verifiers that are used to verify memecoins.
     * 
     * @return verifiers_ Array of all registered verifier addresses
     */
    function getAllVerifiers() public view returns (address[] memory verifiers_) {
        verifiers_ = _verifiers.values();
    }

    /**
     * Verify that a memecoin is valid according to at least one verifier.
     *
     * @dev If no verifier is found, then the memecoin is invalid.
     *
     * @param _memecoin The address of the memecoin to verify
     *
     * @return verifier_ The address of the verifier that validated the memecoin
     */
    function verifyMemecoin(address _memecoin) public view returns (address verifier_) {
        uint length = _verifiers.length();
        for (uint i = 0; i < length; i++) {
            if (IImportVerifier(_verifiers.at(i)).isValid(_memecoin, msg.sender)) {
                return _verifiers.at(i);
            }
        }
    }

    /**
     * Set the AnyPositionManager contract.
     *
     * @param _anyPositionManager The address of the AnyPositionManager contract
     */
    function setAnyPositionManager(address payable _anyPositionManager) public onlyOwner {
        // Ensure that our required contracts are not the zero address
        if (_anyPositionManager == address(0)) revert ZeroAddress();

        // Set the AnyPositionManager contract
        anyPositionManager = AnyPositionManager(_anyPositionManager);
        emit AnyPositionManagerSet(_anyPositionManager);
    }

}
