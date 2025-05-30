// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

// Libraries
import {
    Position,
    Hash,
    GameType,
    VMStatus,
    Timestamp,
    Duration,
    Clock,
    GameId,
    Claim,
    LibGameId,
    LibClock
} from "src/dispute/lib/LibUDT.sol";

/// @notice The current status of the dispute game.
enum GameStatus {
    // The game is currently in progress, and has not been resolved.
    IN_PROGRESS,
    // The game has concluded, and the `rootClaim` was challenged successfully.
    CHALLENGER_WINS,
    // The game has concluded, and the `rootClaim` could not be contested.
    DEFENDER_WINS
}

/// @notice The game's bond distribution type. Games are expected to start in the `UNDECIDED`
///         state, and then choose either `NORMAL` or `REFUND`.
enum BondDistributionMode {
    // Bond distribution strategy has not been chosen.
    UNDECIDED,
    // Bonds should be distributed as normal.
    NORMAL,
    // Bonds should be refunded to claimants.
    REFUND
}

/// @notice Represents an L2 root and the L2 sequence number at which it was generated.
/// @custom:field root The output root.
/// @custom:field l2SequenceNumber The L2 Sequence Number ( e.g. block number / timestamp) at which the root was
/// generated.
struct Proposal {
    Hash root;
    uint256 l2SequenceNumber;
}

/// @title GameTypes
/// @notice A library that defines the IDs of games that can be played.
library GameTypes {
    /// @dev A dispute game type the uses the cannon vm.
    GameType internal constant CANNON = GameType.wrap(0);

    /// @dev A permissioned dispute game type that uses the cannon vm.
    GameType internal constant PERMISSIONED_CANNON = GameType.wrap(1);

    /// @notice A dispute game type that uses the asterisc vm.
    GameType internal constant ASTERISC = GameType.wrap(2);

    /// @notice A dispute game type that uses the asterisc vm with Kona.
    GameType internal constant ASTERISC_KONA = GameType.wrap(3);

    /// @notice A dispute game type that uses the cannon vm (Super Roots).
    GameType internal constant SUPER_CANNON = GameType.wrap(4);

    /// @notice A dispute game type that uses the permissioned cannon vm (Super Roots).
    GameType internal constant SUPER_PERMISSIONED_CANNON = GameType.wrap(5);

    /// @notice A dispute game type that uses OP Succinct
    GameType internal constant OP_SUCCINCT = GameType.wrap(6);

    /// @notice A dispute game type with short game duration for testing withdrawals.
    ///         Not intended for production use.
    GameType internal constant FAST = GameType.wrap(254);

    /// @notice A dispute game type that uses an alphabet vm.
    ///         Not intended for production use.
    GameType internal constant ALPHABET = GameType.wrap(255);

    /// @notice A dispute game type that uses RISC Zero's Kailua
    GameType internal constant KAILUA = GameType.wrap(1337);
}

/// @title VMStatuses
/// @notice Named type aliases for the various valid VM status bytes.
library VMStatuses {
    /// @notice The VM has executed successfully and the outcome is valid.
    VMStatus internal constant VALID = VMStatus.wrap(0);

    /// @notice The VM has executed successfully and the outcome is invalid.
    VMStatus internal constant INVALID = VMStatus.wrap(1);

    /// @notice The VM has paniced.
    VMStatus internal constant PANIC = VMStatus.wrap(2);

    /// @notice The VM execution is still in progress.
    VMStatus internal constant UNFINISHED = VMStatus.wrap(3);
}

/// @title LocalPreimageKey
/// @notice Named type aliases for local `PreimageOracle` key identifiers.
library LocalPreimageKey {
    /// @notice The identifier for the L1 head hash.
    uint256 internal constant L1_HEAD_HASH = 0x01;

    /// @notice The identifier for the starting output root.
    uint256 internal constant STARTING_OUTPUT_ROOT = 0x02;

    /// @notice The identifier for the disputed output root.
    uint256 internal constant DISPUTED_OUTPUT_ROOT = 0x03;

    /// @notice The identifier for the disputed L2 block number.
    uint256 internal constant DISPUTED_L2_BLOCK_NUMBER = 0x04;

    /// @notice The identifier for the chain ID.
    uint256 internal constant CHAIN_ID = 0x05;
}
