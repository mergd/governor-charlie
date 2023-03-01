//SPDX-License-Identifier: MIT
import {BOARDv1} from "src/modules/BOARD/Board.V1.sol";
import "src/Kernel.sol";
pragma solidity 0.8.15;

contract BoardRoom is BOARDv1 {
    constructor(Kernel kernel_) Module(kernel_) {}

    /**
     * @notice Sets board
     * @param _members List of Safe owners.
     * @param _threshold Number of required confirmations for a Safe transaction.
     */
    function setBoard(
        address[] memory _members,
        uint256 _threshold
    ) external override permissioned {
        // Validate that threshold is smaller than number of added owners.
        require(_threshold <= _members.length, "GS201");
        // There has to be at least one Safe owner.
        require(_threshold >= 1, "GS202");
        // Initializing Safe owners.
        address currentMember = SENTINEL_MEMBERS;
        for (uint256 i = 0; i < _members.length; i++) {
            // Owner address cannot be null.
            address member = _members[i];
            require(
                member != address(0) &&
                    member != SENTINEL_MEMBERS &&
                    member != address(this) &&
                    currentMember != member,
                "GS203"
            );
            // No duplicate members allowed.
            require(members[member] == address(0), "GS204");
            members[currentMember] = member;
            currentMember = member;
        }
        members[currentMember] = SENTINEL_MEMBERS;
        memberCount = _members.length;
        threshold = _threshold;
    }

    /**
     * @notice Adds the member `member` to the Safe and updates the threshold to `_threshold`.
     * @dev This can only be done via a Safe transaction.
     * @param member New member address.
     * @param _threshold New threshold.
     */
    function addMemberWithThreshold(
        address member,
        uint256 _threshold
    ) external override permissioned {
        // member address cannot be null, the sentinel or the Safe itself.
        require(
            member != address(0) &&
                member != SENTINEL_MEMBERS &&
                member != address(this),
            "GS203"
        );
        // No duplicate members allowed.
        require(members[member] == address(0), "GS204");
        members[member] = members[SENTINEL_MEMBERS];
        members[SENTINEL_MEMBERS] = member;
        memberCount++;
        emit AddedMember(member);
        // Change threshold if threshold was changed.
        if (threshold != _threshold) changeThreshold(_threshold);
    }

    /**
     * @notice Removes the member `member` from the Safe and updates the threshold to `_threshold`.
     * @dev This can only be done via a Safe transaction.
     * @param prevmember member that pointed to the member to be removed in the linked list
     * @param member member address to be removed.
     * @param _threshold New threshold.
     */
    function removeMember(
        address prevmember,
        address member,
        uint256 _threshold
    ) external override permissioned {
        // Only allow to remove an member, if threshold can still be reached.
        require(memberCount - 1 >= _threshold, "GS201");
        // Validate member address and check that it corresponds to member index.
        require(member != address(0) && member != SENTINEL_MEMBERS, "GS203");
        require(members[prevmember] == member, "GS205");
        members[prevmember] = members[member];
        members[member] = address(0);
        memberCount--;
        emit RemovedMember(member);
        // Change threshold if threshold was changed.
        if (threshold != _threshold) changeThreshold(_threshold);
    }

    /**
     * @notice Replaces the owner `oldOwner` in the Safe with `newOwner`.
     * @dev This can only be done via a Safe transaction.
     * @param prevOwner Owner that pointed to the owner to be replaced in the linked list
     * @param oldOwner Owner address to be replaced.
     * @param newOwner New owner address.
     */
    function swapMember(
        address prevOwner,
        address oldOwner,
        address newOwner
    ) external override permissioned {
        // Owner address cannot be null, the sentinel or the Safe itself.
        require(
            newOwner != address(0) &&
                newOwner != SENTINEL_MEMBERS &&
                newOwner != address(this),
            "GS203"
        );
        // No duplicate owners allowed.
        require(members[newOwner] == address(0), "GS204");
        // Validate oldOwner address and check that it corresponds to owner index.
        require(
            oldOwner != address(0) && oldOwner != SENTINEL_MEMBERS,
            "GS203"
        );
        require(members[prevOwner] == oldOwner, "GS205");
        members[newOwner] = members[oldOwner];
        members[prevOwner] = newOwner;
        members[oldOwner] = address(0);
        emit RemovedMember(oldOwner);
        emit AddedMember(newOwner);
    }

    /**
     * @notice Changes the threshold of the Safe to `_threshold`.
     * @dev This can only be done via a Safe transaction.
     * @param _threshold New threshold.
     */
    function changeThreshold(uint256 _threshold) internal {
        // Validate that threshold is smaller than number of owners.
        require(_threshold <= memberCount, "GS201");
        // There has to be at least one Safe owner.
        require(_threshold >= 1, "GS202");
        threshold = _threshold;
        emit ChangedThreshold(threshold);
    }

    /**
     * @notice Returns if `owner` is an owner of the Safe.
     * @return Boolean if owner is an owner of the Safe.
     */
    function isMember(address member) public view override returns (bool) {
        return member != SENTINEL_MEMBERS && members[member] != address(0);
    }

    /**
     * @notice Returns a list of Safe owners.
     * @return Array of Safe owners.
     */
    function getMembers() public view override returns (address[] memory) {
        address[] memory array = new address[](memberCount);

        // populate return array
        uint256 index = 0;
        address currentMember = members[SENTINEL_MEMBERS];
        while (currentMember != SENTINEL_MEMBERS) {
            array[index] = currentMember;
            currentMember = members[currentMember];
            index++;
        }
        return array;
    }

    /**
     * @notice Returns the number of required confirmations for a Safe transaction aka the threshold.
     * @return Threshold number.
     */
    function getThreshold() public view override returns (uint256) {
        return threshold;
    }
}
