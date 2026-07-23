// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProxyCheck} from '@flaunch/libraries/ProxyCheck.sol';

import {Test} from 'forge-std/Test.sol';

/// Thin harness to expose the internal library function.
contract ProxyCheckHarness {
    function getImplementation(
        address _proxy
    ) external view returns (address) {
        return ProxyCheck.getImplementation(_proxy);
    }
}

contract ProxyCheckTest is Test {
    // Canonical EIP-1167 minimal proxy prefix (10 bytes) and suffix (15 bytes)
    bytes internal constant PREFIX = hex'363d3d373d3d3d363d73';
    bytes internal constant SUFFIX = hex'5af43d82803e903d91602b57fd5bf3';

    address internal constant IMPL = 0xbECAe78D441FBa11017bB7A8798D018b0977F76d;

    ProxyCheckHarness internal harness;

    function setUp() public {
        harness = new ProxyCheckHarness();
    }

    /// A canonical 45-byte EIP-1167 clone resolves to its implementation.
    function test_ResolvesCanonicalClone() public {
        bytes memory code = abi.encodePacked(PREFIX, IMPL, SUFFIX);
        assertEq(code.length, 45, 'clone must be 45 bytes');

        address proxy = address(0xC10E);
        vm.etch(proxy, code);

        assertEq(harness.getImplementation(proxy), IMPL);
    }

    /// A forged clone (valid prefix + whitelisted impl, but attacker suffix) must be rejected.
    function test_RejectsForgedSuffix() public {
        // Same length (45 bytes) but the 15-byte delegatecall suffix is corrupted.
        bytes memory badSuffix = hex'5af43d82803e903d91602b57fd5bf4'; // last byte f3 -> f4
        bytes memory code = abi.encodePacked(PREFIX, IMPL, badSuffix);
        assertEq(code.length, 45, 'must remain 45 bytes');

        address proxy = address(0xBAD1);
        vm.etch(proxy, code);

        assertEq(harness.getImplementation(proxy), address(0));
    }

    /// A forged clone with the correct pattern but trailing attacker bytecode must be rejected.
    function test_RejectsExtraTrailingBytecode() public {
        bytes memory code = abi.encodePacked(PREFIX, IMPL, SUFFIX, hex'60006000fd');
        assertGt(code.length, 45, 'must exceed 45 bytes');

        address proxy = address(0xBAD2);
        vm.etch(proxy, code);

        assertEq(harness.getImplementation(proxy), address(0));
    }

    /// A corrupted prefix must be rejected.
    function test_RejectsForgedPrefix() public {
        bytes memory badPrefix = hex'373d3d373d3d3d363d73'; // first byte 36 -> 37
        bytes memory code = abi.encodePacked(badPrefix, IMPL, SUFFIX);

        address proxy = address(0xBAD3);
        vm.etch(proxy, code);

        assertEq(harness.getImplementation(proxy), address(0));
    }

    /// A non-proxy (arbitrary bytecode) and an EOA both resolve to the zero address.
    function test_RejectsNonProxy() public {
        address contractAddr = address(0xBAD4);
        vm.etch(contractAddr, hex'60806040');
        assertEq(harness.getImplementation(contractAddr), address(0));

        // An address with no code
        assertEq(harness.getImplementation(address(0xE0A)), address(0));
    }
}
