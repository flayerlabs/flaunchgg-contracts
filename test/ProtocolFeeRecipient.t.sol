// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {ProtocolFeeRecipient} from '@flaunch/ProtocolFeeRecipient.sol';
import {FeeEscrow} from '@flaunch/escrows/FeeEscrow.sol';

import {FlaunchTest} from './FlaunchTest.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract ProtocolFeeRecipientTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    ProtocolFeeRecipient protocolFeeRecipient;

    constructor() {
        _deployPlatform();

        // Deploy our {ProtocolFeeRecipient}
        protocolFeeRecipient = new ProtocolFeeRecipient();

        // Deposit some flETH that we can use during tests so that we can unwrap it
        deal(address(this), type(uint128).max);
        flETH.deposit{value: type(uint128).max}(0);
    }

    function test_CanGetAvailable(
        uint64 _eth,
        uint64 _pm1,
        uint64 _pm2
    ) public {
        deal(address(protocolFeeRecipient), _eth);

        FeeEscrow feeEscrow1 = new FeeEscrow(address(flETH), address(indexer));
        FeeEscrow feeEscrow2 = new FeeEscrow(address(flETH), address(indexer));

        // Approve fees to be transferred to the escrows
        flETH.approve(address(feeEscrow1), type(uint).max);
        flETH.approve(address(feeEscrow2), type(uint).max);

        protocolFeeRecipient.setFeeEscrow(address(feeEscrow1), true);
        protocolFeeRecipient.setFeeEscrow(address(feeEscrow2), true);

        PoolId poolId = _flaunchToken();

        if (_pm1 != 0) {
            flETH.transfer(address(feeEscrow1), _pm1);
            feeEscrow1.allocateFees(poolId, address(protocolFeeRecipient), _pm1);
        }

        if (_pm2 != 0) {
            flETH.transfer(address(feeEscrow2), _pm2);
            feeEscrow2.allocateFees(poolId, address(protocolFeeRecipient), _pm2);
        }

        // We should be able to see the total amount available
        assertEq(protocolFeeRecipient.available(), uint(_eth) + _pm1 + _pm2);

        // We should only hold the ETH value, and not have claimed any fees
        assertEq(payable(address(protocolFeeRecipient)).balance, uint(_eth));
    }

    function test_CanClaim(
        uint64 _eth,
        uint64 _pm1,
        uint64 _pm2
    ) public {
        // Set a recipient and ensure they start with zero ETH
        address payable _recipient = payable(address(420));
        deal(_recipient, 0);

        deal(address(protocolFeeRecipient), _eth);

        FeeEscrow feeEscrow1 = new FeeEscrow(address(flETH), address(indexer));
        FeeEscrow feeEscrow2 = new FeeEscrow(address(flETH), address(indexer));

        // Approve fees to be transferred to the escrows
        flETH.approve(address(feeEscrow1), type(uint).max);
        flETH.approve(address(feeEscrow2), type(uint).max);

        protocolFeeRecipient.setFeeEscrow(address(feeEscrow1), true);
        protocolFeeRecipient.setFeeEscrow(address(feeEscrow2), true);

        PoolId poolId = _flaunchToken();

        if (_pm1 != 0) {
            flETH.transfer(address(feeEscrow1), _pm1);
            feeEscrow1.allocateFees(poolId, address(protocolFeeRecipient), _pm1);
        }

        if (_pm2 != 0) {
            flETH.transfer(address(feeEscrow2), _pm2);
            feeEscrow2.allocateFees(poolId, address(protocolFeeRecipient), _pm2);
        }

        // We should be able to see the total amount available
        uint available = protocolFeeRecipient.available();

        // Make our claim
        uint sentAmount = protocolFeeRecipient.claim(_recipient);

        // Confirm that we have claimed the correct amount
        assertEq(sentAmount, available, 'sentAmount != available');
        assertEq(sentAmount, uint(_eth) + _pm1 + _pm2, 'sentAmount != sum of fuzz');

        // Confirm that our recipient received the full amount of eth
        assertEq(payable(address(_recipient)).balance, sentAmount, 'Incorrect recipient ETH received');
    }

    function test_CanAddFeeEscrow() public {
        FeeEscrow feeEscrow = new FeeEscrow(address(flETH), address(indexer));

        vm.expectEmit();
        emit ProtocolFeeRecipient.FeeEscrowUpdated(address(feeEscrow), true);

        protocolFeeRecipient.setFeeEscrow(address(feeEscrow), true);
    }

    function test_CanRemoveFeeEscrow() public {
        FeeEscrow feeEscrow = new FeeEscrow(address(flETH), address(indexer));

        protocolFeeRecipient.setFeeEscrow(address(feeEscrow), true);

        vm.expectEmit();
        emit ProtocolFeeRecipient.FeeEscrowUpdated(address(feeEscrow), false);

        protocolFeeRecipient.setFeeEscrow(address(feeEscrow), false);
    }

    function _flaunchToken() internal returns (PoolId poolId_) {
        address memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000))
        );
        return positionManager.poolKey(memecoin).toId();
    }
}
