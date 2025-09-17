// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdJson} from 'forge-std/StdJson.sol';

import {PositionManager} from '@flaunch/PositionManager.sol';
import {InitialPrice} from '@flaunch/price/InitialPrice.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';
import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {MerkleAirdrop} from "@flaunch/creator-tools/MerkleAirdrop.sol";
import {IMerkleAirdrop} from '@flaunch-interfaces/IMerkleAirdrop.sol';
import {IBaseAirdrop} from '@flaunch-interfaces/IBaseAirdrop.sol';

import {FlaunchTest} from 'test/FlaunchTest.sol';


contract MerkleAirdropTest is FlaunchTest {

    using stdJson for string;

    struct MerkleJSON {
        bytes32 root;
        address creator;
        uint256 airdropIndex;
        address token;
        string tokenSymbol;
        uint256 tokenDecimals;
        uint256 totalTokensToAirdropInWei;
        string totalTokensToAirdropFormatted;
        mapping(address userAddress => UserData) userData;
    }

    address[] userAddresses;

    struct UserData {
        uint256 airdropAmountInWei;
        string airdropAmountFormatted;
        bytes32[] proof;
    }

    MerkleJSON merkleJSON;

    function setUp() public {
        _deployPlatform();

        _setMerkleJSON();
    }

    /// addAirdrop()
    function test_addAirdrop_RevertsForNonApprovedCaller(address _caller) external {
        vm.assume(_caller != address(0));

        // deploy memecoin and send to the caller
        _deployMemecoin();
        IERC20(merkleJSON.token).transfer(_caller, IERC20(merkleJSON.token).balanceOf(address(this)));

        vm.startPrank(_caller);
        IERC20(merkleJSON.token).approve(address(merkleAirdrop), merkleJSON.totalTokensToAirdropInWei);

        vm.expectRevert(IBaseAirdrop.NotApprovedAirdropCreator.selector);
        _addAirdrop();
    }

    function test_addAirdrop_SuccessForApprovedCaller(address _caller) external {
        vm.assume(_caller != address(0));

        merkleAirdrop.setApprovedAirdropCreators(_caller, true);
        
        // deploy memecoin and send to the caller
        _deployMemecoin();
        IERC20(merkleJSON.token).transfer(_caller, IERC20(merkleJSON.token).balanceOf(address(this)));

        vm.startPrank(_caller);
        IERC20(merkleJSON.token).approve(address(merkleAirdrop), merkleJSON.totalTokensToAirdropInWei);
        _addAirdrop();
    }

    function test_addAirdrop_SuccessForManagerDeployedViaTreasuryManager(address _managerImplementation) external {
        vm.assume(_managerImplementation != address(0));

        treasuryManagerFactory.approveManager(_managerImplementation);
        address manager = treasuryManagerFactory.deployManager(_managerImplementation);
        merkleAirdrop.setApprovedAirdropCreators(_managerImplementation, true);

        // deploy memecoin and send to the manager
        _deployMemecoin();
        IERC20(merkleJSON.token).transfer(manager, IERC20(merkleJSON.token).balanceOf(address(this)));

        vm.startPrank(manager);
        IERC20(merkleJSON.token).approve(address(merkleAirdrop), merkleJSON.totalTokensToAirdropInWei);
        _addAirdrop();
    }

    function test_addAirdrop_RevertsForInvalidAirdropIndex(uint256 _airdropIndex) external {
        _isApprovedAirdropCreator();

        vm.assume(_airdropIndex != merkleAirdrop.airdropsCount(merkleJSON.creator));
        vm.expectRevert(IMerkleAirdrop.InvalidAirdropIndex.selector);
        merkleAirdrop.addAirdrop({
            _creator: merkleJSON.creator,
            _airdropIndex: _airdropIndex,
            _token: merkleJSON.token,
            _amount: merkleJSON.totalTokensToAirdropInWei,
            _airdropEndTime: block.timestamp + 30 days,
            _merkleRoot: merkleJSON.root,
            _merkleDataIPFSHash: 'Qabc'
        });
    }

    function test_addAirdrop_RevertsWhenAirdropAlreadyExists() external {
        _deployAndAddAirdrop();
        // `AirdropAlreadyExists` is not possible due to airdropIndex check
        vm.expectRevert(IMerkleAirdrop.InvalidAirdropIndex.selector);
        _addAirdrop();
    }

    // addAirdrop()::token airdrop
    function test_addAirdrop_RevertsWhenETHSentForTokenAirdrop() external {
        _isApprovedAirdropCreator();

        vm.expectRevert(IBaseAirdrop.ETHSentForTokenAirdrop.selector);
        merkleAirdrop.addAirdrop{value: 1 ether}({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _token: merkleJSON.token,
            _amount: merkleJSON.totalTokensToAirdropInWei,
            _airdropEndTime: block.timestamp + 30 days,
            _merkleRoot: merkleJSON.root,
            _merkleDataIPFSHash: 'Qabc'
        });
    }

    function test_addAirdrop_SuccessForTokenAirdrop() external {
        _isApprovedAirdropCreator();
        _deployMemecoin();

        uint prevMemecoinBalance = IERC20(merkleJSON.token).balanceOf(address(merkleAirdrop));
        uint prevAirdropsCount = merkleAirdrop.airdropsCount(merkleJSON.creator);

        vm.expectEmit(true, true, false, true);
        emit IMerkleAirdrop.NewAirdrop(merkleJSON.creator, merkleJSON.airdropIndex, merkleJSON.token, merkleJSON.totalTokensToAirdropInWei, block.timestamp + 30 days);
        _addAirdrop();

        assertEq(IERC20(merkleJSON.token).balanceOf(address(merkleAirdrop)) - prevMemecoinBalance, merkleJSON.totalTokensToAirdropInWei, "Token balance mismatch");
        assertEq(merkleAirdrop.airdropsCount(merkleJSON.creator), prevAirdropsCount + 1, "Airdrops count mismatch");

        IMerkleAirdrop.AirdropData memory airdropData = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex);
        assertEq(airdropData.token, merkleJSON.token, "Token mismatch");
        assertEq(airdropData.airdropEndTime, block.timestamp + 30 days, "Airdrop end time mismatch");
        assertEq(airdropData.amountLeft, merkleJSON.totalTokensToAirdropInWei, "Airdrop amount left mismatch");
        assertEq(airdropData.merkleRoot, merkleJSON.root, "Merkle root mismatch");
        assertEq(airdropData.merkleDataIPFSHash, 'Qabc', "Merkle data IPFS hash mismatch");
    }

    // addAirdrop()::ETH airdrop

    function test_addAirdrop_SuccessForETHAirdrop() external {
        _isApprovedAirdropCreator();

        // verify that it uses the msg.value amount and not the amount passes as params
        uint msgValue = merkleJSON.totalTokensToAirdropInWei + 1 ether;
        address token = address(0);

        uint prevFLETHBalance = flETH.balanceOf(address(merkleAirdrop));
        uint prevAirdropsCount = merkleAirdrop.airdropsCount(merkleJSON.creator);

        vm.expectEmit(true, true, false, true);
        emit IMerkleAirdrop.NewAirdrop(merkleJSON.creator, merkleJSON.airdropIndex, token, msgValue, block.timestamp + 30 days);
        merkleAirdrop.addAirdrop{value: msgValue}({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _token: token,
            _amount: merkleJSON.totalTokensToAirdropInWei,
            _airdropEndTime: block.timestamp + 30 days,
            _merkleRoot: merkleJSON.root,
            _merkleDataIPFSHash: 'Qabc'
        });

        assertEq(flETH.balanceOf(address(merkleAirdrop)) - prevFLETHBalance, msgValue, "FLETH balance mismatch");
        assertEq(merkleAirdrop.airdropsCount(merkleJSON.creator), prevAirdropsCount + 1, "Airdrops count mismatch");

        IMerkleAirdrop.AirdropData memory airdropData = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex);
        assertEq(airdropData.token, token, "Token mismatch");
        assertEq(airdropData.airdropEndTime, block.timestamp + 30 days, "Airdrop end time mismatch");
        assertEq(airdropData.amountLeft, msgValue, "Airdrop amount left mismatch");
        assertEq(airdropData.merkleRoot, merkleJSON.root, "Merkle root mismatch");
        assertEq(airdropData.merkleDataIPFSHash, 'Qabc', "Merkle data IPFS hash mismatch");
    }

    /// claim()
    function test_claim_RevertsWhenAirdropEnded() external {
        _deployAndAddAirdrop();

        vm.warp(block.timestamp + 31 days);
        vm.prank(userAddresses[0]);
        vm.expectRevert(IBaseAirdrop.AirdropEnded.selector);
        merkleAirdrop.claim({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _amount: merkleJSON.userData[userAddresses[0]].airdropAmountInWei,
            _merkleProof: merkleJSON.userData[userAddresses[0]].proof
        });
    }

    function test_claim_RevertsWhenAirdropAlreadyClaimed() external {
        _deployAndAddAirdrop();

        vm.startPrank(userAddresses[0]);
        merkleAirdrop.claim({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _amount: merkleJSON.userData[userAddresses[0]].airdropAmountInWei,
            _merkleProof: merkleJSON.userData[userAddresses[0]].proof
        });

        vm.expectRevert(IBaseAirdrop.AirdropAlreadyClaimed.selector);
        merkleAirdrop.claim({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _amount: merkleJSON.userData[userAddresses[0]].airdropAmountInWei,
            _merkleProof: merkleJSON.userData[userAddresses[0]].proof
        });
    }

    function test_claim_RevertsWhenMerkleProofIsInvalid() external {
        _deployAndAddAirdrop();

        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = bytes32(0);

        vm.prank(userAddresses[0]);
        vm.expectRevert(IMerkleAirdrop.MerkleVerificationFailed.selector);
        merkleAirdrop.claim({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _amount: merkleJSON.userData[userAddresses[0]].airdropAmountInWei,
            _merkleProof: invalidProof
        });
    }
    
    // claim()::token airdrop
    function test_claim_SuccessForTokenAirdrop() external {
        _deployAndAddAirdrop();

        uint prevTokenBalance = IERC20(merkleJSON.token).balanceOf(userAddresses[0]);
        uint prevAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        vm.prank(userAddresses[0]);
        vm.expectEmit(true, true, true, true);
        emit IMerkleAirdrop.AirdropClaimed(userAddresses[0], merkleJSON.creator, merkleJSON.airdropIndex, merkleJSON.token, merkleJSON.userData[userAddresses[0]].airdropAmountInWei);
        merkleAirdrop.claim({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _amount: merkleJSON.userData[userAddresses[0]].airdropAmountInWei,
            _merkleProof: merkleJSON.userData[userAddresses[0]].proof
        });

        uint postAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        assertEq(IERC20(merkleJSON.token).balanceOf(userAddresses[0]) - prevTokenBalance, merkleJSON.userData[userAddresses[0]].airdropAmountInWei, "Claimed amount mismatch");
        assertEq(merkleAirdrop.isAirdropClaimed(merkleJSON.creator, merkleJSON.airdropIndex, userAddresses[0]), true, "Airdrop claimed status mismatch");
        assertEq(prevAirdropAmountLeft - postAirdropAmountLeft, merkleJSON.userData[userAddresses[0]].airdropAmountInWei, "Airdrop amount left mismatch");
    }

    function test_claim_AllUsers_SuccessForTokenAirdrop() external {
        _deployAndAddAirdrop();

        // loop through each user and claim
        for (uint256 i = 0; i < userAddresses.length; i++) {
            vm.prank(userAddresses[i]);
            merkleAirdrop.claim({
                _creator: merkleJSON.creator,
                _airdropIndex: merkleJSON.airdropIndex,
                _amount: merkleJSON.userData[userAddresses[i]].airdropAmountInWei,
                _merkleProof: merkleJSON.userData[userAddresses[i]].proof
            });

            assertEq(IERC20(merkleJSON.token).balanceOf(userAddresses[i]), merkleJSON.userData[userAddresses[i]].airdropAmountInWei, "Claimed amount mismatch");
        }
    }

    // claim()::ETH airdrop
    function test_claim_SuccessForETHAirdrop_withdrawETH() external {
        _isApprovedAirdropCreator();
        address token = address(0);

        // add airdrop
        merkleAirdrop.addAirdrop{value: merkleJSON.totalTokensToAirdropInWei}({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _token: token,
            _amount: merkleJSON.totalTokensToAirdropInWei,
            _airdropEndTime: block.timestamp + 30 days,
            _merkleRoot: merkleJSON.root,
            _merkleDataIPFSHash: 'Qabc'
        });

        uint prevETHBalance = userAddresses[0].balance;
        uint prevAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        // claim
        vm.prank(userAddresses[0]);
        vm.expectEmit(true, true, true, true);
        emit IMerkleAirdrop.AirdropClaimed(
            userAddresses[0],
            merkleJSON.creator,
            merkleJSON.airdropIndex,
            token, // ETH claimed here
            merkleJSON.userData[userAddresses[0]].airdropAmountInWei
        );
        merkleAirdrop.claim({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _amount: merkleJSON.userData[userAddresses[0]].airdropAmountInWei,
            _merkleProof: merkleJSON.userData[userAddresses[0]].proof
        });

        uint postAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        assertEq(userAddresses[0].balance - prevETHBalance, merkleJSON.userData[userAddresses[0]].airdropAmountInWei, "Claimed amount mismatch");
        assertEq(prevAirdropAmountLeft - postAirdropAmountLeft, merkleJSON.userData[userAddresses[0]].airdropAmountInWei, "Airdrop amount left mismatch");
    }

    /// creatorWithdraw()
    function test_creatorWithdraw_RevertsWhenCallerIsNotCreator(address _caller) external {
        vm.assume(_caller != merkleJSON.creator);

        _deployAndAddAirdrop();
        uint airdropEndTime = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);

        vm.prank(_caller);
        vm.expectRevert(IBaseAirdrop.InvalidAirdrop.selector);
        merkleAirdrop.creatorWithdraw(merkleJSON.airdropIndex);
    }

    function test_creatorWithdraw_RevertsWhenAirdropIsActive() external {
        _deployAndAddAirdrop();

        vm.prank(merkleJSON.creator);
        vm.expectRevert(IBaseAirdrop.AirdropInProgress.selector);
        merkleAirdrop.creatorWithdraw(merkleJSON.airdropIndex);
    }

    // creatorWithdraw()::token airdrop
    function test_creatorWithdraw_SuccessForTokenAirdrop() external {
        _deployAndAddAirdrop();
        uint airdropEndTime = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);

        uint prevTokenBalance = IERC20(merkleJSON.token).balanceOf(merkleJSON.creator);
        uint prevAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        vm.prank(merkleJSON.creator);
        vm.expectEmit(true, true, false, true);
        emit IMerkleAirdrop.CreatorWithdraw(
            merkleJSON.creator,
            merkleJSON.airdropIndex,
            merkleJSON.token,
            prevAirdropAmountLeft
        );
        merkleAirdrop.creatorWithdraw(merkleJSON.airdropIndex);

        uint postAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        assertEq(IERC20(merkleJSON.token).balanceOf(merkleJSON.creator) - prevTokenBalance, prevAirdropAmountLeft, "Token balance mismatch");
        assertEq(postAirdropAmountLeft, 0, "Airdrop amount left mismatch");
    }

    // creatorWithdraw()::ETH airdrop
    function test_creatorWithdraw_SuccessForETHAirdrop_withdrawETH() external {
        _isApprovedAirdropCreator();
        address token = address(0);

        // add airdrop
        merkleAirdrop.addAirdrop{value: merkleJSON.totalTokensToAirdropInWei}({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _token: token,
            _amount: merkleJSON.totalTokensToAirdropInWei,
            _airdropEndTime: block.timestamp + 30 days,
            _merkleRoot: merkleJSON.root,
            _merkleDataIPFSHash: 'Qabc'
        });

        uint airdropEndTime = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).airdropEndTime;
        vm.warp(airdropEndTime + 1);

        uint prevETHBalance = merkleJSON.creator.balance;
        uint prevAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        vm.prank(merkleJSON.creator);
        vm.expectEmit(true, true, false, true);
        emit IMerkleAirdrop.CreatorWithdraw(
            merkleJSON.creator,
            merkleJSON.airdropIndex,
            token, // ETH withdrawn here
            prevAirdropAmountLeft
        );
        merkleAirdrop.creatorWithdraw(merkleJSON.airdropIndex);

        uint postAirdropAmountLeft = merkleAirdrop.airdropData(merkleJSON.creator, merkleJSON.airdropIndex).amountLeft;

        assertEq(merkleJSON.creator.balance - prevETHBalance, prevAirdropAmountLeft, "ETH balance mismatch");
        assertEq(postAirdropAmountLeft, 0, "Airdrop amount left mismatch");
    }

    /// setApprovedAirdropCreators()

    function test_setApprovedAirdropCreators_RevertsWhenCallerIsNotOwner(address _caller) external {
        vm.assume(_caller != merkleAirdrop.owner());

        vm.prank(_caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        merkleAirdrop.setApprovedAirdropCreators(address(this), true);
    }

    function test_setApprovedAirdropCreators_RevertsWhenAlreadyApproved() external {
        _isApprovedAirdropCreator();
        vm.expectRevert(IBaseAirdrop.ApprovedAirdropCreatorAlreadyAdded.selector);
        merkleAirdrop.setApprovedAirdropCreators(address(this), true);
    }
    
    function test_setApprovedAirdropCreators_Success() external {
        vm.expectEmit(true, false, false, true);
        emit IBaseAirdrop.ApprovedAirdropCreatorAdded(address(this));
        merkleAirdrop.setApprovedAirdropCreators(address(this), true);

        assertEq(merkleAirdrop.isApprovedAirdropCreator(address(this)), true);
    }

    function test_setApprovedAirdropCreators_RevertsWhenCreatorNotPresent() external {
        vm.expectRevert(IBaseAirdrop.ApprovedAirdropCreatorNotPresent.selector);
        merkleAirdrop.setApprovedAirdropCreators(address(this), false);
    }
    
    function test_setApprovedAirdropCreators_Success_Remove() external {
        _isApprovedAirdropCreator();
        vm.expectEmit(true, false, false, true);
        emit IBaseAirdrop.ApprovedAirdropCreatorRemoved(address(this));
        merkleAirdrop.setApprovedAirdropCreators(address(this), false);

        assertEq(merkleAirdrop.isApprovedAirdropCreator(address(this)), false);
    }

    
    function _setMerkleJSON() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script/offchain/output/test-memecoin-merkle.json");

        string memory _merkleJson = vm.readFile(path);

        merkleJSON.root = _merkleJson.readBytes32('.root');
        merkleJSON.creator = _merkleJson.readAddress('.creator');
        merkleJSON.airdropIndex = _merkleJson.readUint('.airdropIndex');
        merkleJSON.token = _merkleJson.readAddress('.token');
        merkleJSON.tokenSymbol = _merkleJson.readString('.tokenSymbol');
        merkleJSON.tokenDecimals = _merkleJson.readUint('.tokenDecimals');
        merkleJSON.totalTokensToAirdropInWei = _merkleJson.readUint('.totalTokensToAirdropInWei');
        merkleJSON.totalTokensToAirdropFormatted = _merkleJson.readString('.totalTokensToAirdropFormatted');

        // Get all keys (addresses) from userData object
        string[] memory userAddressesString = vm.parseJsonKeys(_merkleJson, ".userData");

        userAddresses = new address[](userAddressesString.length);
        
        // Iterate through each address and parse their data
        for (uint256 i = 0; i < userAddressesString.length; i++) {
            address userAddress = address(vm.parseAddress(userAddressesString[i]));
            userAddresses[i] = userAddress;
            
            string memory userPath = string.concat('.userData.', userAddressesString[i]);
            
            UserData storage userData = merkleJSON.userData[userAddress];
            userData.airdropAmountInWei = _merkleJson.readUint(string.concat(userPath, '.airdropAmountInWei'));
            userData.airdropAmountFormatted = _merkleJson.readString(string.concat(userPath, '.airdropAmountFormatted'));
            
            bytes32[] memory proof = vm.parseJsonBytes32Array(
                _merkleJson,
                string.concat(userPath, '.proof')
            );

            userData.proof = proof;
        }
    }

    function _deployMemecoin() internal {
        // Set a market cap tick that is roughly equal to 2e18 : 1e27
        initialPrice.setSqrtPriceX96(InitialPrice.InitialSqrtPriceX96({
            unflipped: TickMath.getSqrtPriceAtTick(200703),
            flipped: TickMath.getSqrtPriceAtTick(-200704)
        }));

        // {PoolManager} must have some initial flETH balance to serve `take()` requests in our hook
        deal(address(flETH), address(poolManager), 1000e27 ether);

        // Calculate the fee with 0% slippage
        uint ethRequired = flaunchZap.calculateFee(merkleJSON.totalTokensToAirdropInWei, 0, abi.encode(''));

        // Flaunch the memecoin and premine the airdrop amount
        (address memecoin,,) = flaunchZap.flaunch{value: ethRequired}(PositionManager.FlaunchParams({
            name: "TEST",
            symbol: "TEST",
            tokenUri: 'https://token.gg/',
            initialTokenFairLaunch: 0.25e27,
            fairLaunchDuration: 30 minutes,
            premineAmount: merkleJSON.totalTokensToAirdropInWei,
            creator: address(this),
            creatorFeeAllocation: 0,
            flaunchAt: 0,
            initialPriceParams: abi.encode(''),
            feeCalculatorParams: abi.encode(1_000)
        }), address(0), bytes(''));
        assertEq(memecoin, merkleJSON.token, "Token address mismatch");

        IERC20(memecoin).approve(address(merkleAirdrop), merkleJSON.totalTokensToAirdropInWei);
    }

    function _addAirdrop() internal {
        merkleAirdrop.addAirdrop({
            _creator: merkleJSON.creator,
            _airdropIndex: merkleJSON.airdropIndex,
            _token: merkleJSON.token,
            _amount: merkleJSON.totalTokensToAirdropInWei,
            _airdropEndTime: block.timestamp + 30 days,
            _merkleRoot: merkleJSON.root,
            _merkleDataIPFSHash: 'Qabc'
        });
    }

    function _isApprovedAirdropCreator() internal {
        merkleAirdrop.setApprovedAirdropCreators(address(this), true);
    }

    function _deployAndAddAirdrop() internal {
        _isApprovedAirdropCreator();
        _deployMemecoin();
        _addAirdrop();
    }
}
