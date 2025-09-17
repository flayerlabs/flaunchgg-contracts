// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionManager} from '@flaunch/PositionManager.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {Ownable} from '@solady/auth/Ownable.sol';
import {Memecoin} from '@flaunch/Memecoin.sol';

import {ISnapshotAirdrop} from '@flaunch-interfaces/ISnapshotAirdrop.sol';
import {IBaseAirdrop} from '@flaunch-interfaces/IBaseAirdrop.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';

contract SnapshotAirdropTest is FlaunchTest {    
    address memecoin;
    address creator;
    uint airdropAmount = 200 ether;
    uint tokensToPremine = airdropAmount * 3;
    
    function setUp() public {
        _deployPlatform();
        
        creator = address(this);
        
        // Deploy a memecoin for testing
        memecoin = _deployMemecoin();
    }

    /// addAirdrop()
    function test_addAirdrop_RevertsForNonApprovedCaller(address _caller) external {
        vm.prank(_caller);
        vm.expectRevert(IBaseAirdrop.NotApprovedAirdropCreator.selector);
        _addAirdrop();
    }

    function test_addAirdrop_SuccessForApprovedCaller(address _caller) external {
        vm.assume(_caller != address(0));

        snapshotAirdrop.setApprovedAirdropCreators(_caller, true);
        
        // Send tokens to the caller
        IERC20(memecoin).transfer(_caller, airdropAmount);

        vm.startPrank(_caller);
        IERC20(memecoin).approve(address(snapshotAirdrop), airdropAmount);
        _addAirdrop();
    }

    function test_addAirdrop_SuccessForManagerDeployedViaTreasuryManager(address _managerImplementation) external {
        vm.assume(_managerImplementation != address(0));

        treasuryManagerFactory.approveManager(_managerImplementation);
        snapshotAirdrop.setApprovedAirdropCreators(_managerImplementation, true);

        address payable _manager = treasuryManagerFactory.deployManager(_managerImplementation);

        // Send tokens to the manager
        IERC20(memecoin).transfer(_manager, airdropAmount);

        vm.startPrank(_manager);
        IERC20(memecoin).approve(address(snapshotAirdrop), airdropAmount);
        _addAirdrop();
    }

    function test_addAirdrop_RevertsForInvalidMemecoin() external {
        _isApprovedAirdropCreator();
        
        address invalidMemecoin = address(0x123); // Not a memecoin deployed by PositionManager
        
        vm.expectRevert(ISnapshotAirdrop.InvalidMemecoin.selector);
        snapshotAirdrop.addAirdrop({
            _memecoin: invalidMemecoin,
            _creator: creator,
            _token: memecoin,
            _amount: airdropAmount,
            _airdropEndTime: block.timestamp + 30 days
        });
    }

    // addAirdrop()::token airdrop
    function test_addAirdrop_RevertsWhenETHSentForTokenAirdrop() external {
        _isApprovedAirdropCreator();

        vm.expectRevert(IBaseAirdrop.ETHSentForTokenAirdrop.selector);
        snapshotAirdrop.addAirdrop{value: 1 ether}({
            _memecoin: memecoin,
            _creator: creator,
            _token: memecoin,
            _amount: airdropAmount,
            _airdropEndTime: block.timestamp + 30 days
        });
    }

    function test_addAirdrop_SuccessForTokenAirdrop() external {
        _isApprovedAirdropCreator();

        uint prevMemecoinBalance = IERC20(memecoin).balanceOf(address(snapshotAirdrop));
        uint prevAirdropsCount = snapshotAirdrop.airdropsCount(memecoin);

        uint eligibleSupplySnapshot = IERC20(memecoin).totalSupply() - (
            IERC20(memecoin).balanceOf(address(positionManager)) +
            IERC20(memecoin).balanceOf(address(positionManager.poolManager()))
        );

        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.NewAirdrop(memecoin, prevAirdropsCount, ISnapshotAirdrop.AirdropData({
            creator: creator,
            token: memecoin,
            totalTokensToAirdrop: airdropAmount,
            memecoinHoldersTimestamp: block.timestamp,
            eligibleSupplySnapshot: eligibleSupplySnapshot,
            airdropEndTime: block.timestamp + 30 days,
            amountLeft: airdropAmount
        }));
        uint airdropIndex = _addAirdrop();

        assertEq(airdropIndex, prevAirdropsCount, "Airdrop index mismatch");

        assertEq(IERC20(memecoin).balanceOf(address(snapshotAirdrop)) - prevMemecoinBalance, airdropAmount, "Token balance mismatch");
        assertEq(snapshotAirdrop.airdropsCount(memecoin), airdropIndex + 1, "Airdrops count mismatch");

        ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoin, airdropIndex);
        assertEq(airdropData.creator, creator, "Creator mismatch");
        assertEq(airdropData.token, memecoin, "Token mismatch");
        assertEq(airdropData.airdropEndTime, block.timestamp + 30 days, "Airdrop end time mismatch");
        assertEq(airdropData.amountLeft, airdropAmount, "Airdrop amount left mismatch");
        assertEq(airdropData.totalTokensToAirdrop, airdropAmount, "Total tokens to airdrop mismatch");
        assertEq(airdropData.memecoinHoldersTimestamp, block.timestamp, "Memecoin holders timestamp mismatch");
    }

    // addAirdrop()::ETH airdrop
    function test_addAirdrop_SuccessForETHAirdrop() external {
        _isApprovedAirdropCreator();

        // verify that it uses the msg.value amount and not the amount passes as params
        uint msgValue = airdropAmount + 1 ether;
        address token = address(0);

        uint prevFLETHBalance = flETH.balanceOf(address(snapshotAirdrop));
        uint prevAirdropsCount = snapshotAirdrop.airdropsCount(memecoin);

        uint eligibleSupplySnapshot = IERC20(memecoin).totalSupply() - (
            IERC20(memecoin).balanceOf(address(positionManager)) +
            IERC20(memecoin).balanceOf(address(positionManager.poolManager()))
        );

        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.NewAirdrop(memecoin, prevAirdropsCount, ISnapshotAirdrop.AirdropData({
            creator: creator,
            token: token,
            totalTokensToAirdrop: msgValue,
            memecoinHoldersTimestamp: block.timestamp,
            eligibleSupplySnapshot: eligibleSupplySnapshot,
            airdropEndTime: block.timestamp + 30 days,
            amountLeft: msgValue
        }));
        uint airdropIndex = snapshotAirdrop.addAirdrop{value: msgValue}({
            _memecoin: memecoin,
            _creator: creator,
            _token: token,
            _amount: airdropAmount, // This will be ignored since we're sending ETH
            _airdropEndTime: block.timestamp + 30 days
        });

        assertEq(airdropIndex, prevAirdropsCount, "Airdrop index mismatch");

        assertEq(flETH.balanceOf(address(snapshotAirdrop)) - prevFLETHBalance, msgValue, "FLETH balance mismatch");
        assertEq(snapshotAirdrop.airdropsCount(memecoin), airdropIndex + 1, "Airdrops count mismatch");

        ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoin, airdropIndex);
        assertEq(airdropData.token, token, "Token mismatch");
        assertEq(airdropData.airdropEndTime, block.timestamp + 30 days, "Airdrop end time mismatch");
        assertEq(airdropData.amountLeft, msgValue, "Airdrop amount left mismatch");
    }

    /// claim()
    function test_claim_RevertsWhenAirdropEnded() external {
        address user = makeAddr("user");

        // Give the user some memecoin tokens to make them eligible
        _giveMemecoinToUser(user, 10e18);
        uint airdropIndex = _deployAndAddAirdrop();

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        _transferOutUserBalance(user);

        vm.warp(block.timestamp + 31 days);
        vm.prank(user);
        vm.expectRevert(IBaseAirdrop.AirdropEnded.selector);
        snapshotAirdrop.claim(memecoin, airdropIndex);
    }

    function test_claim_RevertsWhenAirdropAlreadyClaimed() external {
        address user = makeAddr("user");

        // Give the user some memecoin tokens to make them eligible
        _giveMemecoinToUser(user, 10e18);

        _isApprovedAirdropCreator();
        uint airdropIndex = _addAirdrop();

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        _transferOutUserBalance(user);

        vm.startPrank(user);
        snapshotAirdrop.claim(memecoin, airdropIndex);

        vm.expectRevert(IBaseAirdrop.AirdropAlreadyClaimed.selector);
        snapshotAirdrop.claim(memecoin, airdropIndex);
    }

    function test_claim_RevertsWhenNotEligible() external {
        uint airdropIndex = _deployAndAddAirdrop();
        // update timestamp by 1 second so the ERC20Votes::getPastVotes() doesn't revert
        vm.warp(block.timestamp + 1);
        
        address user = makeAddr("user");
        // User has no memecoin tokens

        vm.prank(user);
        vm.expectRevert(ISnapshotAirdrop.NotEligible.selector);
        snapshotAirdrop.claim(memecoin, airdropIndex);
    }
    
    // claim()::token airdrop
    function test_claim_SuccessForTokenAirdrop() external {        
        address user = makeAddr("user");
        uint userBalance = 10e18;

        // Give the user some memecoin tokens to make them eligible
        _giveMemecoinToUser(user, userBalance);

        _isApprovedAirdropCreator();
        uint airdropIndex = _addAirdrop();

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        _transferOutUserBalance(user);

        uint prevTokenBalance = IERC20(memecoin).balanceOf(user);
        uint prevAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;
        
        // Calculate expected claim amount
        ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoin, airdropIndex);
        uint expectedClaimAmount = (airdropAmount * userBalance) / airdropData.eligibleSupplySnapshot;

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.AirdropClaimed(user, memecoin, airdropIndex, memecoin, expectedClaimAmount);
        snapshotAirdrop.claim(memecoin, airdropIndex);

        uint postAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;

        assertEq(IERC20(memecoin).balanceOf(user) - prevTokenBalance, expectedClaimAmount, "Claimed amount mismatch");
        assertEq(snapshotAirdrop.isAirdropClaimed(memecoin, airdropIndex, user), true, "Airdrop claimed status mismatch");
        assertEq(prevAirdropAmountLeft - postAirdropAmountLeft, expectedClaimAmount, "Airdrop amount left mismatch");
    }

    function test_claim_MultipleUsers_SuccessForTokenAirdrop() external {
        address[] memory users = new address[](3);
        uint[] memory balances = new uint[](3);
        
        users[0] = makeAddr("user1");
        users[1] = makeAddr("user2");
        users[2] = makeAddr("user3");
        
        balances[0] = 10e18;
        balances[1] = 20e18;
        balances[2] = 30e18;
        
        // Give users some memecoin tokens to make them eligible
        for (uint i = 0; i < users.length; i++) {
            _giveMemecoinToUser(users[i], balances[i]);
        }

        // Add airdrop
        _isApprovedAirdropCreator();
        uint airdropIndex = _addAirdrop();

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        for (uint i = 0; i < users.length; i++) {
            _transferOutUserBalance(users[i]);
        }
        
        // Calculate total eligible supply
        ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoin, airdropIndex);
        
        // Have each user claim
        for (uint i = 0; i < users.length; i++) {
            uint expectedClaimAmount = (airdropAmount * balances[i]) / airdropData.eligibleSupplySnapshot;
            uint prevBalance = IERC20(memecoin).balanceOf(users[i]);
            
            vm.prank(users[i]);
            snapshotAirdrop.claim(memecoin, airdropIndex);
            
            assertEq(IERC20(memecoin).balanceOf(users[i]) - prevBalance, expectedClaimAmount, "Claimed amount mismatch");
            assertEq(snapshotAirdrop.isAirdropClaimed(memecoin, airdropIndex, users[i]), true, "Airdrop claimed status mismatch");
        }
    }

    // claim()::ETH airdrop
    function test_claim_SuccessForETHAirdrop() external {
        _isApprovedAirdropCreator();

        address token = address(0);
        uint ethAmount = 5 ether;

        address user = makeAddr("user");
        uint userBalance = 10e18;

        // Give the user some memecoin tokens to make them eligible
        _giveMemecoinToUser(user, userBalance);

        // add airdrop
        uint airdropIndex = snapshotAirdrop.addAirdrop{value: ethAmount}(
            memecoin,
            creator,
            token,
            ethAmount,
            block.timestamp + 30 days
        );

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        _transferOutUserBalance(user);

        uint prevETHBalance = user.balance;
        uint prevAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;
        
        // Calculate expected claim amount
        ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoin, airdropIndex);
        uint expectedClaimAmount = (ethAmount * userBalance) / airdropData.eligibleSupplySnapshot;

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.AirdropClaimed(user, memecoin, airdropIndex, token, expectedClaimAmount);
        snapshotAirdrop.claim(memecoin, airdropIndex);

        uint postAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;

        assertEq(user.balance - prevETHBalance, expectedClaimAmount, "Claimed amount mismatch");
        assertEq(prevAirdropAmountLeft - postAirdropAmountLeft, expectedClaimAmount, "Airdrop amount left mismatch");
    }

    /// claimMultiple()
    function test_claimMultiple_RevertsWhenIndexLengthMismatch() external {
        address[] memory memecoins = new address[](1);
        memecoins[0] = memecoin;
        uint[] memory airdropIndices = new uint[](2);
        airdropIndices[0] = 0;

        vm.expectRevert(ISnapshotAirdrop.IndexLengthMismatch.selector);
        snapshotAirdrop.claimMultiple(memecoins, airdropIndices);
    }

    // claimMultiple()::token airdrop
    function test_claimMultiple_SuccessForTokenAirdrop() external {
        _isApprovedAirdropCreator();
        address user = makeAddr("user");

        address[] memory memecoins = new address[](3);
        uint[] memory balances = new uint[](3);
        uint[] memory airdropIndices = new uint[](3);

        for (uint i = 0; i < memecoins.length; i++) {
            memecoins[i] = _deployMemecoin();
            balances[i] = 10e18;
            _giveMemecoinToUser(memecoins[i], user, balances[i]);
            airdropIndices[i] = _addAirdrop(memecoins[i]);
        }

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        for (uint i = 0; i < memecoins.length; i++) {
            _transferOutUserBalance(memecoins[i], user);
        }

        uint[] memory prevTokenBalances = new uint[](memecoins.length);
        for (uint i = 0; i < memecoins.length; i++) {
            prevTokenBalances[i] = IERC20(memecoins[i]).balanceOf(user);
        }
        
        uint[] memory expectedClaimAmounts = new uint[](memecoins.length);
        for (uint i = 0; i < memecoins.length; i++) {
            ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoins[i], airdropIndices[i]);
            expectedClaimAmounts[i] = (airdropAmount * balances[i]) / airdropData.eligibleSupplySnapshot;
        }
        
        vm.prank(user);
        snapshotAirdrop.claimMultiple(memecoins, airdropIndices);

        for (uint i = 0; i < memecoins.length; i++) {
            assertEq(IERC20(memecoins[i]).balanceOf(user) - prevTokenBalances[i], expectedClaimAmounts[i], "Claimed amount mismatch");
        }
    }

    // claimMultiple()::ETH airdrop
    function test_claimMultiple_SuccessForETHAirdrop() external {
        _isApprovedAirdropCreator();
        address user = makeAddr("user");
        address token = address(0);
        uint ethAmount = 5 ether;

        address[] memory memecoins = new address[](3);
        uint[] memory balances = new uint[](3);
        uint[] memory airdropIndices = new uint[](3);

        for (uint i = 0; i < memecoins.length; i++) {
            memecoins[i] = _deployMemecoin();
            balances[i] = 10e18;
            _giveMemecoinToUser(memecoins[i], user, balances[i]);
            airdropIndices[i] = snapshotAirdrop.addAirdrop{value: ethAmount}(
                memecoins[i],
                creator,
                token,
                ethAmount,
                block.timestamp + 30 days
            );
        }

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        for (uint i = 0; i < memecoins.length; i++) {
            _transferOutUserBalance(memecoins[i], user);
        }

        uint prevETHBalance = user.balance;
        
        uint expectedClaimAmount;
        for (uint i = 0; i < memecoins.length; i++) {
            ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoins[i], airdropIndices[i]);
            expectedClaimAmount += (ethAmount * balances[i]) / airdropData.eligibleSupplySnapshot;
        }
        
        vm.prank(user);
        snapshotAirdrop.claimMultiple(memecoins, airdropIndices);

        assertEq(user.balance - prevETHBalance, expectedClaimAmount, "Claimed amount mismatch");
    }

    // claimMultiple():: token + ETH airdrop
    function test_claimMultiple_SuccessForTokenAndETHAirdrop() external {
        _isApprovedAirdropCreator();
        address user = makeAddr("user");
        uint ethAmount = 5 ether;

        address[] memory memecoins = new address[](2);
        uint[] memory balances = new uint[](2);
        uint[] memory airdropIndices = new uint[](2);

        // Token airdrop
        memecoins[0] = _deployMemecoin();
        balances[0] = 10e18;
        _giveMemecoinToUser(memecoins[0], user, balances[0]);
        airdropIndices[0] = _addAirdrop(memecoins[0]);

        // ETH airdrop
        memecoins[1] = _deployMemecoin();
        balances[1] = 10e18;
        _giveMemecoinToUser(memecoins[1], user, balances[1]);
        airdropIndices[1] = snapshotAirdrop.addAirdrop{value: ethAmount}(
            memecoins[1],
            creator,
            address(0),
            ethAmount,
            block.timestamp + 30 days
        );

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        for (uint i = 0; i < memecoins.length; i++) {
            _transferOutUserBalance(memecoins[i], user);
        }

        uint prevTokenBalance = IERC20(memecoins[0]).balanceOf(user);
        uint prevETHBalance = user.balance;

        ISnapshotAirdrop.AirdropData memory tokenAirdropData = snapshotAirdrop.airdropData(memecoins[0], airdropIndices[0]);
        uint expectedTokenClaimAmount = (airdropAmount * balances[0]) / tokenAirdropData.eligibleSupplySnapshot;

        ISnapshotAirdrop.AirdropData memory ethAirdropData = snapshotAirdrop.airdropData(memecoins[1], airdropIndices[1]);
        uint expectedETHClaimAmount = (ethAmount * balances[1]) / ethAirdropData.eligibleSupplySnapshot;

        vm.prank(user);
        snapshotAirdrop.claimMultiple(memecoins, airdropIndices);

        assertEq(IERC20(memecoins[0]).balanceOf(user) - prevTokenBalance, expectedTokenClaimAmount, "Token claim amount mismatch");
        assertEq(user.balance - prevETHBalance, expectedETHClaimAmount, "ETH claim amount mismatch");
    }

    /// proxyClaim()
    function test_proxyClaim_RevertsForNonApprovedCaller() external {
        address user = makeAddr("user");
        address caller = makeAddr("caller");

        // Give the user some memecoin tokens to make them eligible
        _giveMemecoinToUser(user, 10e18);
        uint airdropIndex = _deployAndAddAirdrop();

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        _transferOutUserBalance(user);
        
        vm.prank(caller);
        vm.expectRevert(IBaseAirdrop.NotApprovedAirdropCreator.selector);
        snapshotAirdrop.proxyClaim(user, memecoin, airdropIndex);
    }

    function test_proxyClaim_Success() external {
        address user = makeAddr("user");
        uint userBalance = 10e18;

        // Give the user some memecoin tokens to make them eligible
        _giveMemecoinToUser(user, userBalance);

        _isApprovedAirdropCreator();
        uint airdropIndex = _addAirdrop();

        // After some time, transfer out the user's balance to verify that the snapshot was taken correctly
        vm.warp(block.timestamp + 1 days);
        _transferOutUserBalance(user);
        
        uint prevTokenBalance = IERC20(memecoin).balanceOf(address(this));
        
        // Calculate expected claim amount
        ISnapshotAirdrop.AirdropData memory airdropData = snapshotAirdrop.airdropData(memecoin, airdropIndex);
        uint expectedClaimAmount = (airdropAmount * userBalance) / airdropData.eligibleSupplySnapshot;
        
        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.AirdropClaimed(user, memecoin, airdropIndex, memecoin, expectedClaimAmount);
        snapshotAirdrop.proxyClaim(user, memecoin, airdropIndex);
        
        assertEq(IERC20(memecoin).balanceOf(address(this)) - prevTokenBalance, expectedClaimAmount, "Claimed amount mismatch");
        assertEq(snapshotAirdrop.isAirdropClaimed(memecoin, airdropIndex, user), true, "Airdrop claimed status mismatch");
    }

    /// creatorWithdraw()
    function test_creatorWithdraw_RevertsWhenCallerIsNotCreator(address _caller) external {
        vm.assume(_caller != creator);

        uint airdropIndex = _deployAndAddAirdrop();
        uint airdropEndTime = snapshotAirdrop.airdropData(memecoin, airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);

        vm.prank(_caller);
        vm.expectRevert(ISnapshotAirdrop.CallerIsNotCreator.selector);
        snapshotAirdrop.creatorWithdraw(memecoin, airdropIndex);
    }

    function test_creatorWithdraw_RevertsWhenAirdropIsActive() external {
        uint airdropIndex = _deployAndAddAirdrop();

        vm.prank(creator);
        vm.expectRevert(IBaseAirdrop.AirdropInProgress.selector);
        snapshotAirdrop.creatorWithdraw(memecoin, airdropIndex);
    }

    // creatorWithdraw()::token airdrop
    function test_creatorWithdraw_SuccessForTokenAirdrop() external {
        uint airdropIndex = _deployAndAddAirdrop();
        uint airdropEndTime = snapshotAirdrop.airdropData(memecoin, airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);

        uint prevTokenBalance = IERC20(memecoin).balanceOf(creator);
        uint prevAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;

        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.CreatorWithdraw(
            memecoin,
            airdropIndex,
            creator,
            memecoin,
            prevAirdropAmountLeft
        );
        uint tokensWithdrawn = snapshotAirdrop.creatorWithdraw(memecoin, airdropIndex);

        uint postAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;

        assertEq(tokensWithdrawn, prevAirdropAmountLeft, "Tokens withdrawn mismatch");
        assertEq(IERC20(memecoin).balanceOf(creator) - prevTokenBalance, prevAirdropAmountLeft, "Token balance mismatch");
        assertEq(postAirdropAmountLeft, 0, "Airdrop amount left mismatch");
    }

    // creatorWithdraw()::ETH airdrop
    function test_creatorWithdraw_SuccessForETHAirdrop() external {
        _isApprovedAirdropCreator();
        address token = address(0);
        uint ethAmount = 5 ether;

        // add airdrop
        uint airdropIndex = snapshotAirdrop.addAirdrop{value: ethAmount}({
            _memecoin: memecoin,
            _creator: creator,
            _token: token,
            _amount: ethAmount,
            _airdropEndTime: block.timestamp + 30 days
        });

        uint airdropEndTime = snapshotAirdrop.airdropData(memecoin, airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);

        uint prevETHBalance = creator.balance;
        uint prevAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;

        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit ISnapshotAirdrop.CreatorWithdraw(
            memecoin,
            airdropIndex,
            creator,
            token,
            prevAirdropAmountLeft
        );
        uint tokensWithdrawn = snapshotAirdrop.creatorWithdraw(memecoin, airdropIndex);

        uint postAirdropAmountLeft = snapshotAirdrop.airdropData(memecoin, airdropIndex).amountLeft;

        assertEq(tokensWithdrawn, prevAirdropAmountLeft, "Tokens withdrawn mismatch");
        assertEq(creator.balance - prevETHBalance, prevAirdropAmountLeft, "ETH balance mismatch");
        assertEq(postAirdropAmountLeft, 0, "Airdrop amount left mismatch");
    }

    /// isAirdropActive()
    function test_isAirdropActive() external {
        uint airdropIndex = _deployAndAddAirdrop();
        
        // Should be active initially
        assertEq(snapshotAirdrop.isAirdropActive(memecoin, airdropIndex), true, "Airdrop should be active");
        
        // Should be inactive after end time
        uint airdropEndTime = snapshotAirdrop.airdropData(memecoin, airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);
        assertEq(snapshotAirdrop.isAirdropActive(memecoin, airdropIndex), false, "Airdrop should be inactive");
    }

    /// setApprovedAirdropCreators()
    function test_setApprovedAirdropCreators_RevertsWhenCallerIsNotOwner(address _caller) external {
        vm.assume(_caller != snapshotAirdrop.owner());

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        snapshotAirdrop.setApprovedAirdropCreators(address(this), true);
    }

    function test_setApprovedAirdropCreators_RevertsWhenAlreadyApproved() external {
        _isApprovedAirdropCreator();
        vm.expectRevert(IBaseAirdrop.ApprovedAirdropCreatorAlreadyAdded.selector);
        snapshotAirdrop.setApprovedAirdropCreators(address(this), true);
    }
    
    function test_setApprovedAirdropCreators_Success() external {
        vm.expectEmit(true, false, false, true);
        emit IBaseAirdrop.ApprovedAirdropCreatorAdded(address(this));
        snapshotAirdrop.setApprovedAirdropCreators(address(this), true);

        assertEq(snapshotAirdrop.isApprovedAirdropCreator(address(this)), true);
    }

    function test_setApprovedAirdropCreators_RevertsWhenCreatorNotPresent() external {
        vm.expectRevert(IBaseAirdrop.ApprovedAirdropCreatorNotPresent.selector);
        snapshotAirdrop.setApprovedAirdropCreators(address(this), false);
    }
    
    function test_setApprovedAirdropCreators_Success_Remove() external {
        _isApprovedAirdropCreator();
        vm.expectEmit(true, false, false, true);
        emit IBaseAirdrop.ApprovedAirdropCreatorRemoved(address(this));
        snapshotAirdrop.setApprovedAirdropCreators(address(this), false);

        assertEq(snapshotAirdrop.isApprovedAirdropCreator(address(this)), false);
    }

    function _deployMemecoin() internal returns (address _memecoin) {
        // Set a market cap tick that is roughly equal to 2e18 : 1e27
        initialPrice.setSqrtPriceX96(InitialPrice.InitialSqrtPriceX96({
            unflipped: TickMath.getSqrtPriceAtTick(200703),
            flipped: TickMath.getSqrtPriceAtTick(-200704)
        }));

        // {PoolManager} must have some initial flETH balance to serve `take()` requests in our hook
        deal(address(flETH), address(poolManager), 1000e27 ether);

        // Calculate the fee with 0% slippage
        uint ethRequired = flaunchZap.calculateFee(tokensToPremine, 0, abi.encode(''));

        // Flaunch the memecoin and premine the airdrop amount
        (_memecoin,,) = flaunchZap.flaunch{value: ethRequired}(PositionManager.FlaunchParams({
            name: "TEST",
            symbol: "TEST",
            tokenUri: 'https://token.gg/',
            initialTokenFairLaunch: 0.25e27,
            fairLaunchDuration: 30 minutes,
            premineAmount: tokensToPremine,
            creator: creator,
            creatorFeeAllocation: 0,
            flaunchAt: 0,
            initialPriceParams: abi.encode(''),
            feeCalculatorParams: abi.encode(1_000)
        }), address(0), bytes(''));

        IERC20(_memecoin).approve(address(snapshotAirdrop), airdropAmount);
    }

    function _giveMemecoinToUser(address user, uint amount) internal {
        // Transfer memecoin to the user
        vm.startPrank(creator);
        IERC20(memecoin).transfer(user, amount);
        vm.stopPrank();
    }

    function _giveMemecoinToUser(address _memecoin, address user, uint amount) internal {
        // Transfer memecoin to the user
        vm.startPrank(creator);
        IERC20(_memecoin).transfer(user, amount);
        vm.stopPrank();
    }

    function _transferOutUserBalance(address user) internal {
        vm.startPrank(user);
        IERC20(memecoin).transfer(address(this), IERC20(memecoin).balanceOf(user));
        vm.stopPrank();
    }

    function _transferOutUserBalance(address _memecoin, address user) internal {
        vm.startPrank(user);
        IERC20(_memecoin).transfer(address(this), IERC20(memecoin).balanceOf(user));
        vm.stopPrank();
    }

    function _addAirdrop() internal returns (uint airdropIndex) {
        airdropIndex = snapshotAirdrop.addAirdrop({
            _memecoin: memecoin,
            _creator: creator,
            _token: memecoin,
            _amount: airdropAmount,
            _airdropEndTime: block.timestamp + 30 days
        });
    }

    function _addAirdrop(address _memecoin) internal returns (uint airdropIndex) {
        airdropIndex = snapshotAirdrop.addAirdrop({
            _memecoin: _memecoin,
            _creator: creator,
            _token: _memecoin,
            _amount: airdropAmount,
            _airdropEndTime: block.timestamp + 30 days
        });
    }

    function _isApprovedAirdropCreator() internal {
        snapshotAirdrop.setApprovedAirdropCreators(address(this), true);
    }

    function _deployAndAddAirdrop() internal returns (uint airdropIndex) {
        _isApprovedAirdropCreator();
        memecoin = _deployMemecoin();
        airdropIndex = _addAirdrop();
    }
}
