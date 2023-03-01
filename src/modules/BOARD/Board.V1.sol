// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "src/Kernel.sol";

/// @notice Caches and executes batched instructions for protocol upgrades in the Kernel.
abstract contract BOARDv1 is Module {
    // =========  EVENTS ========= //

    event AddedMember(address Member);
    event RemovedMember(address Member);
    event ChangedThreshold(uint256 threshold);

    // =========  ERRORS ========= //

    //todo

    // =========  STATE ========= //

    address internal constant SENTINEL_MEMBERS = address(0x1);

    mapping(address => address) internal members;
    uint256 internal memberCount;
    uint256 public threshold;

    // =========  FUNCTIONS ========= //

    function setBoard(
        address[] memory _Members,
        uint256 _threshold
    ) external virtual;

    function addMemberWithThreshold(
        address Member,
        uint256 threshold
    ) external virtual;

    function swapMember(
        address prevMember,
        address oldMember,
        address newMember
    ) external virtual;

    function removeMember(
        address prevMember,
        address Member,
        uint256 threshold
    ) external virtual;

    // =======  VIEW FUNCTIONS ======= //

    function isMember(address Member) external view virtual returns (bool);

    function getMembers() external view virtual returns (address[] memory);

    function getThreshold() external view virtual returns (uint256);
}
