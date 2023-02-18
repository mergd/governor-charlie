//SPDX-License-Identifier: MIT
import {Boardv1} from "src/modules/BOARD/Board.V1.sol";
import "./src/Kernel.sol";
pragma solidity 0.8.15;

contract BoardRoom is Boardv1 {
    address public boardMultisig;
    address[] public members;
    uint256 public quorum;

    function setMembers(address[] calldata members_) external permissioned {
        members = members_;
    }

    function getMembers() external returns (address[] memory) {
        return members;
    }

    function setQuorum(uint256 quorum_) external permissioned {
        quorum = quorum_;
    }

    function callElection() external {
        require(
            msg.sender == boardMultisig,
            "BoardRoom: Only board can call election"
        );
        // call election contract
    }
}
