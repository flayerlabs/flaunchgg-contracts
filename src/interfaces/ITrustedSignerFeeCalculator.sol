// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';

interface ITrustedSignerFeeCalculator {
  function setTrustedPoolKeySigner(PoolKey calldata _poolKey, address _signer) external;
}