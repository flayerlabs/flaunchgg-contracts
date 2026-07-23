// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {Currency} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';

import {AnyFlaunch} from '@flaunch/AnyFlaunch.sol';
import {AnyPositionManager} from '@flaunch/AnyPositionManager.sol';
import {BidWall} from '@flaunch/bidwall/BidWall.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';

import {ERC20Mock} from 'test/tokens/ERC20Mock.sol';

import {FlaunchTest} from './FlaunchTest.sol';
import {IAnyFlaunch} from '@flaunch-interfaces/IAnyFlaunch.sol';
import {IAnyPositionManager} from '@flaunch-interfaces/IAnyPositionManager.sol';
import {IBidWall} from '@flaunch-interfaces/IBidWall.sol';
import {IFlaunch} from '@flaunch-interfaces/IFlaunch.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';

contract AnyPositionManagerTest is FlaunchTest {
    using PoolIdLibrary for PoolKey;

    address internal memecoin;

    constructor() {
        // Deploy our platform
        _deployPlatform();

        // deploy & mint ERC20Mock for tests
        memecoin = address(new ERC20Mock(address(this)));
        ERC20Mock(memecoin).mint(address(this), 100_000 ether);
    }

    function test_approveMemecoin_RevertsIfNotOwner(
        address _caller
    ) public {
        vm.assume(_caller != anyPositionManager.owner());

        vm.expectRevert(UNAUTHORIZED);
        vm.prank(_caller);
        anyPositionManager.approveCreator(address(this), true);
    }

    function test_approveCreator_SuccessIfOwner(
        address _creator,
        bool _isApproved
    ) public {
        anyPositionManager.approveCreator(_creator, _isApproved);
        assertEq(anyPositionManager.approvedMemecoinCreator(_creator), _isApproved);
    }

    function test_CannotFlaunchIfNotApproved() public {
        vm.expectRevert(IAnyPositionManager.CallerIsNotApprovedCreator.selector);
        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CanFlaunch(
        uint24 _creatorFeeAllocation,
        bool _flipped
    ) public flipTokens(_flipped) {
        vm.assume(_creatorFeeAllocation <= 100_00);
        _approveCreator(address(this));

        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: _creatorFeeAllocation,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        PoolKey memory poolKey = anyPositionManager.poolKey(memecoin);
        uint tokenId = anyFlaunch.tokenId(memecoin);

        assertEq(Currency.unwrap(poolKey.currency0), _flipped ? memecoin : address(WETH));
        assertEq(Currency.unwrap(poolKey.currency1), _flipped ? address(WETH) : memecoin);
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 60);
        assertEq(address(poolKey.hooks), address(anyPositionManager));

        assertEq(anyFlaunch.ownerOf(tokenId), address(this));
        assertEq(anyFlaunch.memecoin(tokenId), memecoin);
        assertEq(anyFlaunch.tokenURI(tokenId), 'https://api.flaunch.gg/token/1');
    }

    function test_CanMassFlaunch(
        uint8 flaunchCount,
        bool _flipped
    ) public flipTokens(_flipped) {
        for (uint i; i < flaunchCount; ++i) {
            memecoin = address(new ERC20Mock(address(this)));
            _approveCreator(address(this));

            anyPositionManager.flaunch(
                IAnyPositionManager.FlaunchParams({
                    memecoin: memecoin,
                    creator: address(this),
                    creatorFeeAllocation: 50_00,
                    initialPriceParams: abi.encode(''),
                    feeCalculatorParams: abi.encode(1_000)
                })
            );
        }
    }

    // Test that only the owner can call setInitialPrice
    function test_CanOnlySetInitialPriceAsOwner() public {
        // Call as non-owner, should revert
        vm.startPrank(address(1));
        vm.expectRevert(UNAUTHORIZED);
        anyPositionManager.setInitialPrice(address(initialPrice));
        vm.stopPrank();

        // Call as owner, should succeed
        anyPositionManager.setInitialPrice(address(initialPrice));
    }

    // Test setting a valid InitialPrice contract
    function test_CanSetValidInitialPrice() public {
        // Set valid InitialPrice contract
        anyPositionManager.setInitialPrice(address(initialPrice));

        // Ensure the contract state was updated correctly
        assertEq(address(anyPositionManager.initialPrice()), address(initialPrice), 'Initial price contract should be set correctly');
    }

    // Test that InitialPriceUpdated event is emitted when the initial price is set
    function test_CanGetInitialPriceUpdatedEvent() public {
        // Expect the InitialPriceUpdated event
        vm.expectEmit();
        emit IAnyPositionManager.InitialPriceUpdated(address(initialPrice));

        // Call as owner to set valid InitialPrice and emit event
        anyPositionManager.setInitialPrice(address(initialPrice));
    }

    function test_CanCaptureDelta() public {
        int amount0;
        int amount1;

        address TOKEN = address(1);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(anyPositionManager))
        });

        PoolKey memory flippedPoolKey = PoolKey({
            currency0: Currency.wrap(TOKEN),
            currency1: Currency.wrap(address(WETH)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(anyPositionManager))
        });

        // This is ETH -> TOKEN on an unflipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = anyPositionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), 1 ether
        );

        assertEq(amount0, 0);
        assertEq(amount1, -1 ether);

        // This is ETH -> TOKEN on an unflipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = anyPositionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), 1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is TOKEN -> ETH on an unflipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = anyPositionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), 1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is TOKEN -> ETH on an unflipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, 1 ether);
        assertEq(amount1, -1 ether);

        (amount0, amount1) = anyPositionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), 1 ether
        );

        assertEq(amount0, 0);
        assertEq(amount1, -1 ether);

        // This is ETH -> TOKEN on an flipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        (amount0, amount1) = anyPositionManager.captureDeltaSwapFee(
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}), 1 ether
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 0);

        // This is ETH -> TOKEN on an flipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        // This is TOKEN -> ETH on an flipped pool
        // TOKEN is specified, ETH is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(1 ether, -1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);

        // This is TOKEN -> ETH on an flipped pool
        // ETH is specified, TOKEN is unspecified
        (amount0, amount1) = anyPositionManager.captureDelta(
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBeforeSwapDelta(-1 ether, 1 ether)
        );

        assertEq(amount0, -1 ether);
        assertEq(amount1, 1 ether);
    }

    function test_CanBurn721IfCreator() public {
        _approveCreator(address(this));

        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = anyFlaunch.tokenId(memecoin);

        anyFlaunch.burn(tokenId);

        // Confirm our expected ERC721 responses. The owner should revert as is expected, but
        // our creator call should handle this and instead just return a zero address.
        vm.expectRevert();
        anyFlaunch.ownerOf(tokenId);

        assertEq(anyFlaunch.creator(memecoin), address(0));
    }

    function test_CanBurn721IfApproved() public {
        _approveCreator(address(this));

        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = anyFlaunch.tokenId(memecoin);

        address approvedCaller = address(1);
        anyFlaunch.approve(approvedCaller, tokenId);

        vm.prank(approvedCaller);
        anyFlaunch.burn(tokenId);
    }

    function test_CannotBurn721IfNotCreatorOrApproved() public {
        _approveCreator(address(this));

        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        uint tokenId = anyFlaunch.tokenId(memecoin);

        address unapprovedCaller = address(1);
        vm.prank(unapprovedCaller);
        vm.expectRevert(bytes4(0x4b6e7f18)); // NotOwnerNorApproved()
        anyFlaunch.burn(tokenId);
    }

    function test_CannotFlaunchWithInvalidCreatorFeeAllocation(
        uint24 _creatorFeeAllocation
    ) public {
        vm.assume(_creatorFeeAllocation > 100_00);
        _approveCreator(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAnyFlaunch.CreatorFeeAllocationInvalid.selector, _creatorFeeAllocation, anyFlaunch.MAX_CREATOR_ALLOCATION()
            )
        );
        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: _creatorFeeAllocation,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }

    function test_CanSwap(
        uint _seed
    ) public {
        _flaunch();

        // Ensure we have enough tokens for liquidity and approve them for our {PoolManager}
        deal(address(anyPositionManager.nativeToken()), address(this), 10e27);
        IERC20(anyPositionManager.nativeToken()).approve(address(poolModifyPosition), type(uint).max);
        IERC20(memecoin).approve(address(poolModifyPosition), type(uint).max);

        PoolKey memory poolKey = anyPositionManager.poolKey(memecoin);

        // Modify our position with additional ETH and tokens
        poolModifyPosition.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: 10 ether,
                salt: ''
            }),
            ''
        );

        IERC20(anyPositionManager.nativeToken()).approve(address(poolSwap), type(uint).max);
        IERC20(memecoin).approve(address(poolSwap), type(uint).max);

        for (uint i = 0; i < 32; i++) {
            // Generate a pseudo-random number using keccak256 with the seed and index. We wrap the value
            // into an int48 to protect us from hitting values outside the cast.
            int swapValue = int(int48(int(uint(keccak256(abi.encodePacked(_seed, i))))));

            // Determine the boolean value based on the least significant bit of the hash
            bool zeroForOne = (uint(keccak256(abi.encodePacked(_seed, i))) & 1) == 1;
            bool flipSwapValue = (uint(keccak256(abi.encodePacked(_seed / 2, i))) & 1) == 1;

            poolSwap.swap(
                poolKey,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: flipSwapValue ? swapValue : -swapValue,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                })
            );
        }
    }

    function test_CanSwapWithBidWall() public {
        _flaunch();

        // Ensure we have enough tokens for liquidity and approve them for our {PoolManager}
        deal(address(anyPositionManager.nativeToken()), address(this), 10e27);
        IERC20(anyPositionManager.nativeToken()).approve(address(poolModifyPosition), type(uint).max);
        IERC20(memecoin).approve(address(poolModifyPosition), type(uint).max);

        PoolKey memory poolKey = anyPositionManager.poolKey(memecoin);

        // Modify our position with additional ETH and tokens
        poolModifyPosition.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: 10 ether,
                salt: ''
            }),
            ''
        );

        IERC20(anyPositionManager.nativeToken()).approve(address(poolSwap), type(uint).max);
        IERC20(memecoin).approve(address(poolSwap), type(uint).max);

        // Make a swap big enough to trigger the BidWall
        poolSwap.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -1000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));

        // Now make a swap that will hit the BidWall liquidity
        poolSwap.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}));
    }

    function test_CanCloseBidWall() public {
        _flaunch();

        PoolKey memory poolKey = anyPositionManager.poolKey(memecoin);

        anyBidWall.setDisabledState(poolKey, true);
        (bool disabled,,,,,) = anyBidWall.poolInfo(poolKey.toId());
        assertEq(disabled, true);
    }

    /**
     * The BidWall is repositioned in one of two cases:
     *
     * 1. If the BidWall becomes stale through `checkStalePosition`
     * 2. If `deposit` is called on the BidWall and the amount of pending fees is greater than
     *    the threshold.
     *
     * For the purposes of this test, it is easier to trigger this through `checkStalePosition`.
     */
    function test_CanRepositionBidWall() public {
        _flaunch();

        // Ensure we have enough tokens for liquidity and approve them for our {PoolManager}
        deal(address(anyPositionManager.nativeToken()), address(this), 10e27);
        IERC20(anyPositionManager.nativeToken()).approve(address(poolModifyPosition), type(uint).max);
        IERC20(memecoin).approve(address(poolModifyPosition), type(uint).max);

        PoolKey memory poolKey = anyPositionManager.poolKey(memecoin);

        // Modify our position with additional ETH and tokens
        poolModifyPosition.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(poolKey.tickSpacing),
                tickUpper: TickMath.maxUsableTick(poolKey.tickSpacing),
                liquidityDelta: 10 ether,
                salt: ''
            }),
            ''
        );

        IERC20(anyPositionManager.nativeToken()).approve(address(poolSwap), type(uint).max);
        IERC20(memecoin).approve(address(poolSwap), type(uint).max);

        // Make a swap big enough to trigger the BidWall
        poolSwap.swap(poolKey, SwapParams({zeroForOne: true, amountSpecified: -1000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}));

        // Move past our timeout
        vm.warp(block.timestamp + bidWall.staleTimeWindow());

        // We can expect the emit of the `BidWallRepositioned` event to confirm that it has
        // been hit correctly.
        vm.expectEmit();
        emit IBidWall.BidWallRepositioned(poolKey.toId(), 4122467602127208476, -44160, -44100);

        // Now make a swap that will hit the BidWall liquidity
        poolSwap.swap(poolKey, SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}));
    }

    function _approveCreator(
        address _creator
    ) internal {
        anyPositionManager.approveCreator(_creator, true);
    }

    function _flaunch() internal {
        _approveCreator(address(this));

        anyPositionManager.flaunch(
            IAnyPositionManager.FlaunchParams({
                memecoin: memecoin,
                creator: address(this),
                creatorFeeAllocation: 50_00,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
    }
}
