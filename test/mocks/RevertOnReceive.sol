// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Test helper that always reverts when ETH is sent to it. Used to prove that the
 * detach-payout sites in {StakingManager.escrowWithdraw} and
 * {SupportsCreatorTokens._removeCreatorToken} cannot be bricked by a misbehaving
 * creator contract – i.e. that switching from `SafeTransferLib.safeTransferETH` to
 * a fire-and-forget low-level `.call` keeps the surrounding flow live even when the
 * recipient refuses the transfer.
 *
 * `Flaunch.flaunch` mints with `_mint` (not `_safeMint`), so this contract does not
 * need to implement `onERC721Received` to receive a flaunched NFT.
 */
contract RevertOnReceive {
    error EthRefused();

    receive() external payable {
        revert EthRefused();
    }
}
