// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "src/Kernel.sol";

/// @notice Caches and executes batched instructions for protocol upgrades in the Kernel.
abstract contract Boardv1 is Module {
    // =========  EVENTS ========= //

    event AddedOwner(address owner);
    event RemovedOwner(address owner);
    event ChangedThreshold(uint256 threshold);

    // =========  ERRORS ========= //

    error INSTR_InstructionsCannotBeEmpty();
    error INSTR_InvalidAction();

    // =========  STATE ========= //

    address internal constant SENTINEL_OWNERS = address(0x1);

    mapping(address => address) internal owners;
    uint256 internal ownerCount;
    uint256 public threshold;

    // =========  FUNCTIONS ========= //

    function setBoard(
        address[] memory _owners,
        uint256 _threshold
    ) external virtual;

    function addOwner(address owner, uint256 threshold) external virtual;

    function swapOwner(
        address prevOwner,
        address oldOwner,
        address newOwner
    ) external virtual;

    function removeOwner(address owner, uint256 threshold) external virtual;

    // =======  VIEW FUNCTIONS ======= //

    function isOwner(address owner) external view virtual returns (bool);

    function getOwners() external view virtual returns (address[] memory);
}
