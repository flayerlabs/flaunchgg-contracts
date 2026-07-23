// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FlaunchTest} from 'test/FlaunchTest.sol';

import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';
import {IPositionManager} from '@flaunch-interfaces/IPositionManager.sol';
import {Memecoin} from '@flaunch/Memecoin.sol';
import {PositionManager} from '@flaunch/PositionManager.sol';

import {IERC165, IERC7802} from '@optimism/interfaces/L2/IERC7802.sol';
import {ISuperchainERC20} from '@optimism/interfaces/L2/ISuperchainERC20.sol';
import {Predeploys} from '@optimism/src/libraries/Predeploys.sol';

import {IERC5267Upgradeable} from '@openzeppelin/contracts-upgradeable/interfaces/IERC5267Upgradeable.sol';
import {IERC5805Upgradeable} from '@openzeppelin/contracts-upgradeable/interfaces/IERC5805Upgradeable.sol';
import {IERC20PermitUpgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract MemecoinTest is FlaunchTest {
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

    address internal constant ZERO_ADDRESS = address(0);
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = Predeploys.SUPERCHAIN_TOKEN_BRIDGE;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    Memecoin internal memecoin;
    Memecoin internal strictMemecoin;

    function setUp() public {
        _deployPlatform();

        address memecoinAddress = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Old Name',
                symbol: 'OLD',
                tokenUri: 'https://token.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 20_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        memecoin = Memecoin(memecoinAddress);

        Memecoin strictMemecoinImplementation = new Memecoin();
        flaunch.setMemecoinImplementation(address(strictMemecoinImplementation));

        address strictMemecoinAddress = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: 'Strict Name',
                symbol: 'STRICT',
                tokenUri: 'https://token.gg/',
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 20_00,
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );

        strictMemecoin = Memecoin(strictMemecoinAddress);
    }

    function test_CanUpdateMetadata() public {
        vm.expectEmit(address(memecoin));
        emit Memecoin.MetadataUpdated('New Name', 'NEW');

        vm.expectEmit(address(memecoin));
        emit IERC5267Upgradeable.EIP712DomainChanged();

        flaunch.setMemecoinMetadata(address(memecoin), 'New Name', 'NEW');

        assertEq(memecoin.name(), 'New Name');
        assertEq(memecoin.symbol(), 'NEW');
    }

    function test_CanPermitAfterMetadataRename() public {
        bytes32 oldDomainSeparator = memecoin.DOMAIN_SEPARATOR();

        flaunch.setMemecoinMetadata(address(memecoin), 'New Name', 'NEW');

        bytes32 expectedDomainSeparator = _domainSeparator('New Name', address(memecoin));
        assertEq(memecoin.DOMAIN_SEPARATOR(), expectedDomainSeparator);
        assertTrue(expectedDomainSeparator != oldDomainSeparator);

        uint ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);
        address spender = address(0xBEEF);
        uint value = 1 ether;
        uint deadline = block.timestamp + 1 days;
        uint nonce = memecoin.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01', expectedDomainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        memecoin.permit(owner, spender, value, deadline, v, r, s);

        assertEq(memecoin.allowance(owner, spender), value);
    }

    function test_MintRevertsForNonFlaunchCaller(
        address _caller,
        address _to,
        uint _amount
    ) public {
        vm.assume(_caller != address(flaunch));

        vm.expectRevert(Memecoin.CallerNotFlaunch.selector);
        vm.prank(_caller);
        strictMemecoin.mint(_to, _amount);
    }

    function test_MintRevertsForZeroAddress() public {
        vm.expectRevert(Memecoin.MintAddressIsZero.selector);
        vm.prank(address(flaunch));
        strictMemecoin.mint(address(0), 1 ether);
    }

    function test_SetMetadataRevertsForNonFlaunchCaller(
        address _caller
    ) public {
        vm.assume(_caller != address(flaunch));

        vm.expectRevert(Memecoin.CallerNotFlaunch.selector);
        vm.prank(_caller);
        strictMemecoin.setMetadata('x', 'y');
    }

    function test_CanBurnOwnTokens(
        uint _amount
    ) public {
        _amount = bound(_amount, 1, 1_000_000 ether);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        memecoin.crosschainMint(address(this), _amount);

        uint supplyBefore = memecoin.totalSupply();
        memecoin.burn(_amount);

        assertEq(memecoin.balanceOf(address(this)), 0);
        assertEq(memecoin.totalSupply(), supplyBefore - _amount);
    }

    function test_CanBurnFromWithAllowance(
        uint _amount
    ) public {
        _amount = bound(_amount, 1, 1_000_000 ether);

        address tokenOwner = address(0xABCD);
        address spender = address(0xBEEF);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        memecoin.crosschainMint(tokenOwner, _amount);

        vm.prank(tokenOwner);
        memecoin.approve(spender, _amount);

        vm.prank(spender);
        memecoin.burnFrom(tokenOwner, _amount);

        assertEq(memecoin.balanceOf(tokenOwner), 0);
        assertEq(memecoin.allowance(tokenOwner, spender), 0);
    }

    function test_AllowancesForPermit2AreAlwaysInfinite() public view {
        assertEq(memecoin.allowance(address(this), PERMIT2), type(uint).max);
    }

    function test_ApprovePermit2RejectsFiniteAmount(
        uint _amount
    ) public {
        vm.assume(_amount != type(uint).max);

        vm.expectRevert(Memecoin.Permit2AllowanceIsFixedAtInfinity.selector);
        memecoin.approve(PERMIT2, _amount);
    }

    function test_ApprovePermit2AllowsMaxValue() public {
        bool approved = memecoin.approve(PERMIT2, type(uint).max);

        assertTrue(approved);
        assertEq(memecoin.allowance(address(this), PERMIT2), type(uint).max);
    }

    function test_ApproveNonPermit2UsesStandardAllowance(
        uint _amount
    ) public {
        _amount = bound(_amount, 0, 1_000_000 ether);

        address spender = address(0xCAFE);
        bool approved = memecoin.approve(spender, _amount);

        assertTrue(approved);
        assertEq(memecoin.allowance(address(this), spender), _amount);
    }

    function test_ReportsCreatorAndTreasury() public view {
        uint tokenId = flaunch.tokenId(address(memecoin));

        assertEq(memecoin.creator(), address(this));
        assertEq(memecoin.treasury(), flaunch.memecoinTreasury(tokenId));
    }

    function test_ReportsClockAndVersion() public view {
        assertEq(memecoin.clock(), uint48(block.timestamp));
        assertEq(memecoin.CLOCK_MODE(), 'mode=timestamp&from=default');
        assertEq(memecoin.version(), '1.0.2');
    }

    function testFuzz_crosschainMint_callerNotBridge_reverts(
        address _caller,
        address _to,
        uint224 _amount
    ) public {
        vm.assume(_caller != SUPERCHAIN_TOKEN_BRIDGE);

        vm.expectRevert(ISuperchainERC20.Unauthorized.selector);
        vm.prank(_caller);
        memecoin.crosschainMint(_to, _amount);
    }

    function testFuzz_crosschainMint_succeeds(
        address _to,
        uint128 _amount
    ) public {
        vm.assume(_to != ZERO_ADDRESS);

        uint totalSupplyBefore = memecoin.totalSupply();
        uint toBalanceBefore = memecoin.balanceOf(_to);

        vm.expectEmit(address(memecoin));
        emit IERC20.Transfer(ZERO_ADDRESS, _to, _amount);

        vm.expectEmit(address(memecoin));
        emit IERC7802.CrosschainMint(_to, _amount, SUPERCHAIN_TOKEN_BRIDGE);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        memecoin.crosschainMint(_to, _amount);

        assertEq(memecoin.totalSupply(), totalSupplyBefore + _amount);
        assertEq(memecoin.balanceOf(_to), toBalanceBefore + _amount);
    }

    function testFuzz_crosschainBurn_callerNotBridge_reverts(
        address _caller,
        address _from,
        uint224 _amount
    ) public {
        vm.assume(_caller != SUPERCHAIN_TOKEN_BRIDGE);

        vm.expectRevert(ISuperchainERC20.Unauthorized.selector);
        vm.prank(_caller);
        memecoin.crosschainBurn(_from, _amount);
    }

    function testFuzz_crosschainBurn_succeeds(
        address _from,
        uint128 _amount
    ) public {
        vm.assume(_from != ZERO_ADDRESS);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        memecoin.crosschainMint(_from, _amount);

        uint totalSupplyBefore = memecoin.totalSupply();
        uint fromBalanceBefore = memecoin.balanceOf(_from);

        vm.expectEmit(address(memecoin));
        emit IERC20.Transfer(_from, ZERO_ADDRESS, _amount);

        vm.expectEmit(address(memecoin));
        emit IERC7802.CrosschainBurn(_from, _amount, SUPERCHAIN_TOKEN_BRIDGE);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        memecoin.crosschainBurn(_from, _amount);

        assertEq(memecoin.totalSupply(), totalSupplyBefore - _amount);
        assertEq(memecoin.balanceOf(_from), fromBalanceBefore - _amount);
    }

    function test_SupportsExpectedInterfaces() public view {
        assertTrue(memecoin.supportsInterface(type(IERC165).interfaceId));
        assertTrue(memecoin.supportsInterface(type(IERC7802).interfaceId));
        assertTrue(memecoin.supportsInterface(type(IERC20).interfaceId));
        assertTrue(memecoin.supportsInterface(type(IERC20PermitUpgradeable).interfaceId));
        assertTrue(memecoin.supportsInterface(type(IERC5805Upgradeable).interfaceId));
        assertTrue(memecoin.supportsInterface(type(IMemecoin).interfaceId));
    }

    function _domainSeparator(
        string memory name_,
        address verifyingContract_
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(_EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name_)), keccak256(bytes('1')), block.chainid, verifyingContract_)
            );
    }
}
