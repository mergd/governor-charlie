// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {VotesV1} from "src/modules/VOTES/Votes.V1.sol";

contract VotingToken is VotesV1 {
    constructor(
        Kernel kernel_,
        ERC20 token
    ) Module(kernel_) ERC4626("Voting Token", "VOTE") {}
}
