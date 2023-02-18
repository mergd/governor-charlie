// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "src/Kernel.sol";

/// @notice Caches and executes batched instructions for protocol upgrades in the Kernel.
abstract contract Boardv1 is Module {
    // =========  EVENTS ========= //

    event InstructionsStored(uint256 instructionsId);

    // =========  ERRORS ========= //

    error INSTR_InstructionsCannotBeEmpty();
    error INSTR_InvalidAction();

    // =========  STATE ========= //

    /// @notice Safe address for the board
    address public boardMultisig;

    /// @notice All stored instructions per count in totalInstructions
    mapping(uint256 => Instruction[]) public storedInstructions;

    // =========  FUNCTIONS ========= //

    ///@notice Set members of the board
    function setMembers(address[] calldata members_) external virtual;

    ///@notice View members of the board
    function getMembers() external virtual returns (address[] memory);

    ///@notice Set the quorum of the board
    function setQuorum(uint256 quorum_) external virtual;
}
