// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Create3Factory} from '@flaunch/libraries/Create3Factory.sol';

/**
 * Mines salts for Uniswap V4 hooks deployed through the {Create3Factory}.
 *
 * Unlike {HookMiner} (CREATE2), the candidate addresses here are independent of the hook's init
 * code: they derive only from (factory, sender, salt). A salt mined once is therefore valid on
 * every chain where the factory sits at the same address and the same sender deploys — the hook
 * lands at an identical, flag-valid address everywhere, regardless of per-chain constructor args.
 */
library Create3HookMiner {

    /// Mask to slice out the bottom 14 bits of the address, where hook flags are encoded
    uint160 constant FLAG_MASK = 0x3FFF;

    /// Maximum number of iterations to find a salt, avoid infinite loops
    uint constant MAX_LOOP = 200_000;

    /**
     * Finds a salt for which `factory.deploy(salt, ...)` called by `_sender` produces an address
     * with the desired `_flags`. `_name` seeds the search so two hooks with identical flags
     * (e.g. PositionManager / AnyPositionManager) mine distinct addresses.
     *
     * @param _factory The {Create3Factory} the hook will be deployed through
     * @param _sender The account that will call `deploy` on the factory
     * @param _name A unique per-hook label mixed into the candidate salts
     * @param _flags The desired flags for the hook address
     *
     * @return hookAddress_ The mined, flag-valid hook address
     * @return salt_ The salt to pass to `factory.deploy`
     */
    function find(
        Create3Factory _factory,
        address _sender,
        string memory _name,
        uint160 _flags
    ) internal view returns (address hookAddress_, bytes32 salt_) {
        for (uint i; i < MAX_LOOP; ++i) {
            salt_ = keccak256(abi.encodePacked(_name, i));
            hookAddress_ = _factory.predict(salt_, _sender);
            if (uint160(hookAddress_) & FLAG_MASK == _flags) {
                return (hookAddress_, salt_);
            }
        }
        revert('Create3HookMiner: could not find salt');
    }
}
