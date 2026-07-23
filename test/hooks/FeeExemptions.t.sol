// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPoolManager} from '@uniswap/v4-core/src/PoolManager.sol';
import {LPFeeLibrary} from '@uniswap/v4-core/src/libraries/LPFeeLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {Vm} from 'forge-std/Vm.sol';

import {IInternalSwapPool} from '@flaunch-interfaces/IInternalSwapPool.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';
import {FeeExemptions} from '@flaunch/hooks/FeeExemptions.sol';

import {FlaunchTest} from '../FlaunchTest.sol';
import {IFeeExemptions} from '@flaunch-interfaces/IFeeExemptions.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract FeeExemptionsTest is FlaunchTest {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // Set a test-wide pool key
    PoolKey private _poolKey;

    // Store our memecoin created for the test
    address memecoin;

    constructor() {
        // Deploy our platform
        _deployPlatform();

        // Create our memecoin
        memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams('name', 'symbol', 'https://token.gg/', 0, address(this), 0, 0, abi.encode(''), abi.encode(1_000))
        );

        // Reference our `_poolKey` for later tests
        _poolKey = positionManager.poolKey(memecoin);

        // Skip FairLaunch
    }

    function test_CanSetFeeExemption(
        address _beneficiary,
        uint24 _validFee
    ) public {
        // Ensure that the valid fee is.. well.. valid
        vm.assume(_validFee.isValid());

        // Confirm that the position does not yet exist
        IFeeExemptions.FeeExemption memory feeExemption = feeExemptions.feeExemption(_beneficiary);
        assertEq(feeExemption.flatFee, 0);
        assertEq(feeExemption.enabled, false);

        vm.expectEmit();
        emit IFeeExemptions.BeneficiaryFeeSet(_beneficiary, _validFee);
        feeExemptions.setFeeExemption(_beneficiary, _validFee);

        // Get our stored fee override
        feeExemption = feeExemptions.feeExemption(_beneficiary);
        assertEq(feeExemption.flatFee, _validFee);
        assertEq(feeExemption.enabled, true);
    }

    function test_CannotSetFeeExemptionWithInvalidFee(
        address _beneficiary,
        uint24 _invalidFee
    ) public {
        // Ensure that the fee is invalid
        vm.assume(!_invalidFee.isValid());

        vm.expectRevert(abi.encodeWithSelector(IFeeExemptions.FeeExemptionInvalid.selector, _invalidFee, LPFeeLibrary.MAX_LP_FEE));

        feeExemptions.setFeeExemption(_beneficiary, _invalidFee);
    }

    function test_CannotSetFeeExemptionWithoutOwner(
        address _caller
    ) public {
        // Ensure that the caller is not the owner
        vm.assume(_caller != feeExemptions.owner());

        vm.startPrank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        feeExemptions.setFeeExemption(_caller, 0);
    }

    function test_CanRemoveFeeExemption(
        address _beneficiary
    ) public hasExemption(_beneficiary) {
        vm.expectEmit();
        emit IFeeExemptions.BeneficiaryFeeRemoved(_beneficiary);
        feeExemptions.removeFeeExemption(_beneficiary);

        // Confirm that the position does not exist
        IFeeExemptions.FeeExemption memory feeExemption = feeExemptions.feeExemption(_beneficiary);
        assertEq(feeExemption.flatFee, 0);
        assertEq(feeExemption.enabled, false);
    }

    function test_CannotRemoveFeeExemptionOfUnknownBeneficiary(
        address _beneficiary
    ) public {
        vm.expectRevert(abi.encodeWithSelector(IFeeExemptions.NoBeneficiaryExemption.selector, _beneficiary));

        feeExemptions.removeFeeExemption(_beneficiary);
    }

    function test_CannotRemoveFeeExemptionWithoutOwner(
        address _caller,
        address _beneficiary
    ) public hasExemption(_beneficiary) {
        // Ensure that the caller is not the owner
        vm.assume(_caller != feeExemptions.owner());

        vm.startPrank(_caller);
        vm.expectRevert(UNAUTHORIZED);
        feeExemptions.removeFeeExemption(_beneficiary);
    }

    function test_CanMakeSwapWithExemptFees_ExactInput() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (0.05%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 50);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        _assertPoolFeesReceivedLogged(logs1, 0, 9970020458800448);

        // Update our exemption
        feeExemptions.setFeeExemption(beneficiary, 75);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // In this second swap, we will be catching the fees in the Internal Swap Pool, so we will have
        // this `PoolFeesReceived` event fire first, and then a subsequent `PoolFeesReceived` event will
        // fire that shows the Uniswap fees received. The combined fees received should be about 50%
        // higher than that of the previous swap due to new fee exemption amount.

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        _assertPoolFeesSwappedLogged(logs2, true, 4985418185580322, 9970020458800448);
        _assertPoolFeesReceivedLogged(logs2, 0, 74775153441003);
        _assertPoolFeesReceivedLogged(logs2, 0, 14877575514447595);
    }

    function test_CanMakeSwapWithExemptFees_ExactOutput() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (0.05%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 50);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        _assertPoolFeesReceivedLogged(vm.getRecordedLogs(), 2507070676188275, 0);

        // Update our exemption
        feeExemptions.setFeeExemption(beneficiary, 75);

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        _assertPoolFeesReceivedLogged(vm.getRecordedLogs(), 3761950294486656, 0);
    }

    function test_CanMakeInternalSwapWithExemptFees() public {
        // Add some liquidity to the pool so we can action a swap, as the ISP uses the pool
        // price to determine the swap value.
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Add fees to the ISP that will be sourced from
        deal(memecoin, address(positionManager), 5e27);

        // Exempt a beneficiary with a set fee (0.05%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 50);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 10 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // From this swap we should expect to see 1e18 tokens given to the user for `-5.035e17` plus
        // fees, which at 50% should be `-2.517e15`. These will be moved into the pool via the
        // `PoolFeesReceived` event and shows the swap value via `PoolFeesSwapped`.

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        _assertPoolFeesReceivedLogged(vm.getRecordedLogs(), 2507070676508045, 0);

        // Update our exemption
        feeExemptions.setFeeExemption(beneficiary, 75);

        // The same amount will be swapped, as this has facilitated the internal value, but the amount
        // received will be higher as there is a reduced fee exemption (75% fees, rather than 50%).

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        _assertPoolFeesReceivedLogged(vm.getRecordedLogs(), 3761950296522336, 0);
    }

    function test_CanSwapWithZeroFeeExemption() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (0%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 0);

        // Give sufficient WETH to fill the swap. This will cost just over 1e18 as
        // it's a 1:1 pool and the tick will shift a little.
        deal(address(WETH), address(this), 1.5 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        // Remove any memecoins we may have
        deal(memecoin, address(this), 0);

        // Action our swap
        _swap(SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));

        // We should have received the entire amount with no fees
        assertEq(IERC20(memecoin).balanceOf(address(this)), 1 ether);
    }

    function test_CanUseLowerBaseFeeIfHigherExemptionFee() public {
        // Add some liquidity to the pool so we can action a swap
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Exempt a beneficiary with a set fee (100%)
        address beneficiary = address(poolSwap);
        feeExemptions.setFeeExemption(beneficiary, 100_0000);

        // Give tokens and approve for swap
        deal(address(WETH), address(this), 1 ether);
        WETH.approve(address(poolSwap), type(uint).max);

        vm.recordLogs();
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));
        _assertPoolFeesReceivedLogged(vm.getRecordedLogs(), 0, 19940040917600897);
    }

    modifier hasExemption(
        address _beneficiary
    ) {
        feeExemptions.setFeeExemption(_beneficiary, 0);
        _;
    }

    function _swap(
        SwapParams memory _swapParams
    ) internal {
        poolSwap.swap(_poolKey, _swapParams);
    }

    // Tolerance absorbs the small marginal-pricing drift introduced by the reflaunch
    // full-supply seed; the headline fee amounts are still pinned.
    uint internal constant _FEE_TOLERANCE = 1e13;

    function _assertPoolFeesReceivedLogged(
        Vm.Log[] memory logs,
        uint _amount0,
        uint _amount1
    ) internal view {
        bytes32 sig = IInternalSwapPool.PoolFeesReceived.selector;
        for (uint i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) {
                continue;
            }
            if (logs[i].emitter != address(internalSwapPool) && logs[i].emitter != address(positionManager)) {
                continue;
            }
            if (logs[i].topics[1] != PoolId.unwrap(_poolKey.toId())) {
                continue;
            }
            (uint loggedA0, uint loggedA1) = abi.decode(logs[i].data, (uint, uint));
            if (_approxEq(loggedA0, _amount0, _FEE_TOLERANCE) && _approxEq(loggedA1, _amount1, _FEE_TOLERANCE)) {
                return;
            }
        }
        revert('PoolFeesReceived not emitted with expected amounts');
    }

    function _assertPoolFeesSwappedLogged(
        Vm.Log[] memory logs,
        bool _zeroForOne,
        uint _ethIn,
        uint _tokenOut
    ) internal view {
        bytes32 sig = IInternalSwapPool.PoolFeesSwapped.selector;
        for (uint i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) {
                continue;
            }
            if (logs[i].emitter != address(internalSwapPool) && logs[i].emitter != address(positionManager)) {
                continue;
            }
            if (logs[i].topics[1] != PoolId.unwrap(_poolKey.toId())) {
                continue;
            }
            (bool loggedZfo, uint loggedEthIn, uint loggedTokenOut) = abi.decode(logs[i].data, (bool, uint, uint));
            if (
                loggedZfo == _zeroForOne && _approxEq(loggedEthIn, _ethIn, _FEE_TOLERANCE)
                    && _approxEq(loggedTokenOut, _tokenOut, _FEE_TOLERANCE)
            ) {
                return;
            }
        }
        revert('PoolFeesSwapped not emitted with expected amounts');
    }

    function _approxEq(
        uint _a,
        uint _b,
        uint _tol
    ) private pure returns (bool) {
        return _a > _b ? _a - _b <= _tol : _b - _a <= _tol;
    }
}
