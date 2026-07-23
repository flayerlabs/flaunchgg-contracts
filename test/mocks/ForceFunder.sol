// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Test / operational helper that force-sends its entire ETH balance to a target
 * contract via `selfdestruct`.
 *
 * The point of this helper is the one property a normal transfer cannot give you:
 * a `selfdestruct` balance transfer credits the beneficiary's balance WITHOUT
 * invoking its `receive()` / `fallback()`. For a {FeeSplitManager} (and therefore
 * {StakingManager}) this matters because its `receive()` books every inbound wei
 * into `splitFees`, which inflates the amount every staker can claim. Force-funding
 * sidesteps `receive()`, so it can top up the manager's *native ETH* balance to
 * cover an existing claim shortfall without moving the claim target.
 *
 * Deploy with the ETH to inject as the constructor value, then call {fund} with the
 * manager as the beneficiary:
 *
 *   ForceFunder funder = new ForceFunder{value: shortfall}();
 *   funder.fund(payable(stakingManager));
 *
 * `fund` runs in a separate call from construction so, under EIP-6780 (Cancun), the
 * helper account is not deleted but the balance transfer to the beneficiary still
 * happens and still bypasses `receive()` — matching the on-chain runbook where the
 * funder is deployed in one transaction and triggered in another.
 *
 * NOTE: forced ETH is not tracked by any manager accounting, so it cannot be swept
 * back out. Fund the shortfall (plus a small buffer), not a large excess.
 */
contract ForceFunder {
    constructor() payable {}

    function fund(
        address payable _target
    ) external {
        selfdestruct(_target);
    }
}
