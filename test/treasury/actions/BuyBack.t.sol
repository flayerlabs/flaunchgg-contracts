// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from 'forge-std/Vm.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {MemecoinTreasury} from '@flaunch/treasury/MemecoinTreasury.sol';
import {BuyBackAction, ITreasuryAction} from '@flaunch/treasury/actions/BuyBack.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

import {FlaunchTest} from '../../FlaunchTest.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract BuyBackActionTest is FlaunchTest {
    PoolKey poolKey;
    BuyBackAction action;
    MemecoinTreasury memecoinTreasury;

    address memecoin;

    function setUp() public {
        _deployPlatform();

        // Flaunch a new token
        memecoin = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Token Name',
                symbol: 'TOKEN',
                tokenUri: 'https://flaunch.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        // Get our Treasury contract
        memecoinTreasury = MemecoinTreasury(IMemecoin(memecoin).treasury());

        poolKey = positionManager.poolKey(memecoin);

        // Deploy our action
        action = new BuyBackAction(positionManager.nativeToken(), address(poolSwap));

        // Approve our action in the ActionManager
        positionManager.actionManager().approveAction(address(action));
    }

    function test_CanGetConstructorVariables() public view {
        assertEq(Currency.unwrap(action.nativeToken()), positionManager.nativeToken());
        assertEq(address(action.poolSwap()), address(poolSwap));
    }

    function test_CanBuyBackWithZeroNativeTokens() public {
        // If the user has zero balance, then the event will return without reverting, but
        // it won't emit any events.
        memecoinTreasury.executeAction(address(action), abi.encode(TickMath.MIN_SQRT_PRICE));
    }

    function test_CanBuyBack() public {
        uint _amount = 1 ether;

        // Add token liquidity
        _addLiquidityToPool(memecoin, 100 ether, false);

        // Deal and approve
        deal(Currency.unwrap(poolKey.currency0), address(memecoinTreasury), _amount);

        // vm.expectEmit's strict next-emit check hits an ERC20 Approval before
        // ActionExecuted under the reflaunch flow; scan recorded logs instead.
        vm.recordLogs();
        memecoinTreasury.executeAction(address(action), abi.encode(TickMath.MIN_SQRT_PRICE + 1));
        _assertActionExecutedLogged(vm.getRecordedLogs(), -1000000000000000000, 1974064050842613584);
    }

    /**
     * F-2 regression: a residual parked on the action contract (e.g. from a prior caller whose
     * `sqrtPriceLimitX96` stopped the swap short) must NOT be swept by the next caller. Before
     * the fix, `execute` ended by transferring `balanceOfSelf()` of both currencies to msg.sender,
     * so any stranded native from a previous call would silently leak across treasuries.
     */
    function test_F2_BuyBackPreservesParkedResidual() public {
        address nativeAddr = positionManager.nativeToken();

        // Seed a "residual" directly onto the action, as if a prior partial-fill caller left
        // unspent native behind.
        uint stranded = 0.4 ether;
        deal(nativeAddr, address(action), stranded);

        // Stand up a normal buy-back for this test's treasury
        _addLiquidityToPool(memecoin, 100 ether, false);
        deal(nativeAddr, address(memecoinTreasury), 1 ether);

        uint actionBefore = IERC20(nativeAddr).balanceOf(address(action));
        assertEq(actionBefore, stranded, 'stranded seed precondition');

        // Run a normal buy-back; the action MUST forward only THIS call's delta to the caller
        // and leave the stranded residual parked.
        memecoinTreasury.executeAction(address(action), abi.encode(TickMath.MIN_SQRT_PRICE + 1));

        uint actionAfter = IERC20(nativeAddr).balanceOf(address(action));
        assertEq(actionAfter, stranded, 'stranded residual leaked to caller');
    }

    function _assertActionExecutedLogged(
        Vm.Log[] memory logs,
        int _token0,
        int _token1
    ) internal view {
        // Tolerance absorbs marginal-pricing drift from the reflaunch full-supply seed
        uint tolerance = 1e6;
        bytes32 sig = ITreasuryAction.ActionExecuted.selector;
        for (uint i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(action)) {
                continue;
            }
            (PoolKey memory loggedKey, int loggedT0, int loggedT1) = abi.decode(logs[i].data, (PoolKey, int, int));
            loggedKey;
            if (loggedT0 != _token0) {
                continue;
            }
            uint absDiff = loggedT1 > _token1 ? uint(loggedT1 - _token1) : uint(_token1 - loggedT1);
            if (absDiff <= tolerance) {
                return;
            }
        }
        revert('ActionExecuted not emitted with expected token amounts');
    }
}
