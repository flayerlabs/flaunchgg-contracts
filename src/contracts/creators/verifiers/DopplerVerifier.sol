// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IImportVerifier} from '@flaunch-interfaces/IImportVerifier.sol';

interface IDopplerAirlock {
    struct AssetData {
        address numeraire;
        address timelock;
        address governance;
        address liquidityMigrator;
        address poolInitializer;
        address pool;
        address migrationPool;
        uint numTokensToSell;
        uint totalSupply;
        address integrator;
    }

    function getAssetData(
        address _asset
    ) external view returns (AssetData memory);
}

/**
 * Confirms that a memecoin has been deployed on Doppler.
 */
contract DopplerVerifier is IImportVerifier {
    /// The Clanker contract
    IDopplerAirlock public immutable doppler;

    /**
     * Registers the Doppler Airlock contract.
     *
     * @param _doppler The address of the Doppler Airlock contract
     */
    constructor(
        address _doppler
    ) {
        doppler = IDopplerAirlock(_doppler);
    }

    /**
     * Checks if a token exists on Doppler.
     *
     * @param _token The address of the token to verify
     * @param _sender The address of the sender
     *
     * @return bool True if the token exists on Doppler, false otherwise
     */
    function isValid(
        address _token,
        address _sender
    ) public view returns (bool) {
        // Confirm that the token is deployed on Doppler
        IDopplerAirlock.AssetData memory asset = doppler.getAssetData(_token);
        if (asset.poolInitializer == address(0)) {
            return false;
        }

        // Bind to the `integrator` as a DOCUMENTED FALLBACK. The Doppler `AssetData` exposes no
        // authoritative creator EOA: `timelock` and `governance` are per-token governance CONTRACTS
        // (not the creator), and the DERC20 `owner()` resolves to the Airlock itself. The
        // `integrator` is the closest identity-bearing field on the imported interface, but it is
        // the launch front-end/platform rather than the creator.
        // RESIDUAL (F-7): a platform that registers itself as `integrator` for multiple launches can
        // import any of those tokens. There is no cleaner authoritative field on `getAssetData` to
        // bind to, so this is accepted until a registry/signer gate is available.
        return asset.integrator == _sender;
    }
}
