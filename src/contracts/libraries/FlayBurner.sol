// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {IFLETH} from '@flaunch-interfaces/IFLETH.sol';

/**
 * Allows a burn to be specified and routes FLETH through this single contract from
 * a range of managers and other sources.
 */
contract FlayBurner is Ownable {
    event BurnerUpdated(address payable _burner);

    /// The address that will receive FLETH to buy and burn $FLAY
    address public burner;

    /// The native FLETH token used by Flaunch
    IFLETH public immutable fleth;

    /**
     * Set our IFLETH contract and initialize the sender as the owner.
     *
     * @param _fleth The {IFLETH} contract address
     */
    constructor(
        address _fleth
    ) {
        fleth = IFLETH(_fleth);
        _initializeOwner(msg.sender);
    }

    /**
     * Allows the contract owner to update the address that will receive the FLETH tokens
     * to buy and burn $FLAY.
     *
     * @param _burner The new burner address
     */
    function setBurner(
        address payable _burner
    ) public onlyOwner {
        burner = _burner;
        emit BurnerUpdated(_burner);
    }

    /**
     * Transfers a specified amount of FLETH to the `burner`.
     *
     * @dev If there is no burner set, then we cannot safely transfer fleth. We instead hold
     * the flETH within this contract until one is set.
     *
     * @param _amount The amount of FLETH to transfer
     */
    function buyAndBurn(
        uint _amount
    ) public {
        // If no burner is set, then hold the flETH internally
        if (burner == address(0)) {
            fleth.transferFrom(msg.sender, address(this), _amount);
            return;
        }

        // Pull in the flETH tokens from the caller
        fleth.transferFrom(msg.sender, burner, _amount);

        // Additionally, if we have any flETH held in the contract, also transfer this to
        // the burner.
        fleth.transfer(burner, fleth.balanceOf(address(this)));
    }

    /**
     * Transfers the entire held balance of FLETH the `burner`.
     */
    function buyAndBurnBalanceOfSelf() public {
        buyAndBurn(fleth.balanceOf(msg.sender));
    }

    /**
     * Automatically convert any ETH sent to the contract into FLETH.
     */
    receive() external payable {
        fleth.deposit{value: msg.value}(0);
    }
}
