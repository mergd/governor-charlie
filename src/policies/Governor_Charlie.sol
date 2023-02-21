pragma solidity ^0.8.15;
import {VotingToken} from "src/modules/VOTES/VotingToken.sol";
import {VotesV1} from "src/modules/VOTES/Votes.V1.sol";
import {Roles} from "src/modules/ROLES/ROLES.v1.sol";
import {OlympusRoles} from "src/modules/Roles/OlympusRoles.sol";
import {INSTRv1} from "src/modules/INSTR/INSTR.v1.sol";
import {BoardRoom} from "src/modules/BOARD/BoardRoom.sol";
import {BoardV1} from "src/modules/BOARD/Board.V1.sol";

import "src/kernel.sol";

// Make votes for who the board is going to be, and then also designate proposals to be voted on by the board
// Detemine board composition offchain, onchain ratifies results
// Tokenholders can vote for board, and also vote on proposals such as enabling new perms for board
// Boards reset every epoch
// Board can take whatever action is necessary – board could even just be management, while the protocol is the core biz
contract GovernorCharlieDelegate is Policy, RolesConsumer {
    // =========  EVENTS ========= //

    event ProposalSubmitted(
        uint256 proposalId,
        string title,
        string proposalURI
    );
    event ProposalActivated(uint256 proposalId, uint256 timestamp);
    event VoteCast(
        uint256 proposalId,
        address voter,
        uint8 support,
        uint256 userVotes
    );
    event ProposalExecuted(uint256 proposalId);
    event ProposalCanceled(uint256 proposalId);

    event ProposalThresholdSet(uint256 proposalThreshold);
    event VotingDelaySet(uint256 votingDelay);
    event VotingPeriodSet(uint256 votingPeriod);

    // =========  ERRORS ========= //
    error setVotingPeriodInvalid();
    error setVotingDelayInvalid();
    error setProposalThresholdInvalid();

    error UnableToActivate();
    error ProposalAlreadyActivated();

    error SignatureNotValid();
    error UserAlreadyVoted();
    error UserHasNoVotes();

    error ProposerAboveThreshold();
    error ProposerWhitelisted();

    error ProposerBelowThreshold();
    error ProposalIsNotActive();
    error DepositedAfterActivation();
    error PastVotingPeriod();

    error ExecutorNotSubmitter();
    error NotEnoughVotesToExecute();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyCanceled();
    error ExecutionTimelockStillActive();
    error ExecutionWindowExpired();

    // =========  STATE ========= //

    struct ProposalMetadata {
        address submitter;
        uint256 submissionTimestamp;
        uint256 collateralAmt;
        uint256 activationTimestamp;
        uint256 totalRegisteredVotes;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 abstainVotes;
        bool isExecuted;
        bool isCanceled;
        mapping(address => uint256) votesCastByUser;
    }

    /// @notice Return a proposal metadata object for a given proposal id.
    mapping(uint256 => ProposalMetadata) public getProposalMetadata;
    /// @notice The name of this contract
    string public constant name = "Governor Charlie";

    /// @notice The minimum setable voting period
    uint public constant MIN_VOTING_PERIOD = 5760; // About 24 hours

    /// @notice The max setable voting period
    uint public constant MAX_VOTING_PERIOD = 80640; // About 2 weeks

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,uint256 chainId,address verifyingContract)"
        );

    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH =
        keccak256("Ballot(uint256 proposalId,uint8 support)");

    /**
     * @param kernel_ Address of the Kernel
     * @param values Eth values for proposal calls
     * @param signatures Function signatures for proposal calls
     * @param calldatas Calldatas for proposal calls
     * @param description String description of the proposal
     * @return Proposal id of new proposal
     */
    constructor(
        address admin_,
        address kernel_,
        address comp_,
        uint votingPeriod_,
        uint votingDelay_,
        uint proposalThreshold_
    ) Policy(kernel_) {
        // Token should be the voting token
        admin = admin_;
        comp = VotingToken(comp_);
        votingPeriod = votingPeriod_;
        votingDelay = votingDelay_;
        proposalThreshold = proposalThreshold_;
    }

    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](4);
        requests[0] = Permissions(toKeycode("INSTR"), INSTR.store.selector);
        requests[1] = Permissions(toKeycode("VOTES"), VOTES.delegate.selector);
        requests[2] = Permissions(toKeycode("VOTES"), VOTES.transfer.selector);
        requests[3] = Permissions(
            toKeycode("VOTES"),
            VOTES.transferFrom.selector
        );
    }

    function configureDependencies()
        external
        override
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](3);
        dependencies[0] = toKeycode("INSTR");
        dependencies[1] = toKeycode("VOTES");
        // dependencies[2] = toKeycode("BOARD");

        INSTR = INSTRv1(getModuleAddress(dependencies[0]));
        VOTES = VOTESv1(getModuleAddress(dependencies[1]));
        // BOARD = BOARDv1(getModuleAddress(dependencies[2]));
    }

    /**
     * @notice Function used to propose a new proposal. Sender must have delegates above the proposal threshold
     * @param Instructions Instructions for proposal calls
     * @param values Eth values for proposal calls
     * @param signatures Function signatures for proposal calls
     * @param description String description of the proposal
     * @return Proposal id of new proposal
     */
    function propose(
        Instruction[] calldata instructions,
        string calldata title,
        string calldata description
    ) public returns (uint) {
        // Allow addresses above proposal threshold and whitelisted addresses to propose
        // Change
        require(
            comp.getPriorVotes(msg.sender, --block.number) >
                proposalThreshold ||
                hasRole("guardian", msg.sender),
            ProposerBelowThreshold()
        );
        require(instructions.length != 0, UnableToActivate());

        uint256 proposalId = INSTR.store(instructions_);
        ProposalMetadata storage proposal = getProposalMetadata[proposalId];

        proposal.submitter = msg.sender;
        proposal.collateralAmt = collateral;
        proposal.submissionTimestamp = block.timestamp;

        emit ProposalSubmitted(proposalId, title_, proposalURI_);
    }

    /**
     * @notice Cancels a proposal only if sender is the proposer, or proposer delegates dropped below proposal threshold
     * @param proposalId The id of the proposal to cancel
     */
    function cancel(uint proposalId) external {
        require(
            state(proposalId) != ProposalState.Executed,
            ProposalAlreadyActivated()
        );

        ProposalMetadata storage proposal = getProposalMetadata[proposalId];

        // Proposer can cancel
        if (msg.sender != proposal.proposer) {
            // Whitelisted proposers can't be canceled for falling below proposal threshold
            if (hasRole("proposer", proposal.proposer)) {
                require(
                    (comp.getPriorVotes(proposal.proposer, --block.number) <
                        proposalThreshold) && hasRole("guardian", msg.sender),
                    ProposerWhitelisted()
                );
            } else {
                require(
                    (comp.getPriorVotes(proposal.proposer, --block.number) <
                        proposalThreshold),
                    ProposerAboveThreshold()
                );
            }
        }

        proposal.isCanceled = true;

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Gets actions of a proposal
     * @param proposalId the id of the proposal
     * @return Proposal Metadata
     */
    function getActions(
        uint proposalId
    ) external view returns (Instructions[] memory instructions) {
        ProposalMetadata memory p = getProposalMetadata[proposalId];
    }

    /**
     * @notice Cast a vote for a proposal
     * @param proposalId The id of the proposal to vote on
     * @param support The support value for the vote. 0=against, 1=for, 2=abstain
     */
    function castVote(uint proposalId, uint8 support) external {
        emit VoteCast(
            msg.sender,
            proposalId,
            support,
            castVoteInternal(msg.sender, proposalId, support),
            ""
        );
    }

    /**
     * @notice Cast a vote for a proposal with a reason
     * @param proposalId The id of the proposal to vote on
     * @param support The support value for the vote. 0=against, 1=for, 2=abstain
     * @param reason The reason given for the vote by the voter
     */
    function castVoteWithReason(
        uint proposalId,
        uint8 support,
        string calldata reason
    ) external {
        emit VoteCast(
            msg.sender,
            proposalId,
            support,
            castVoteInternal(msg.sender, proposalId, support),
            reason
        );
    }

    /**
     * @notice Cast a vote for a proposal by signature
     * @dev External function that accepts EIP-712 signatures for voting on proposals.
     */
    function castVoteBySig(
        uint proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                getChainIdInternal(),
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(BALLOT_TYPEHASH, proposalId, support)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), SignatureNotValid());
        emit VoteCast(
            signatory,
            proposalId,
            support,
            castVoteInternal(signatory, proposalId, support),
            ""
        );
    }

    /**
     * @notice Admin function for setting the voting delay
     * @param newVotingDelay new voting delay, in blocks
     */
    function _setVotingDelay(uint newVotingDelay) external onlyRole("admin") {
        require(
            newVotingDelay >= MIN_VOTING_DELAY &&
                newVotingDelay <= MAX_VOTING_DELAY,
            setVotingDelayInvalid()
        );
        uint oldVotingDelay = votingDelay;
        votingDelay = newVotingDelay;

        emit VotingDelaySet(oldVotingDelay, votingDelay);
    }

    /**
     * @notice Admin function for setting the voting period
     * @param newVotingPeriod new voting period, in blocks
     */
    function _setVotingPeriod(uint newVotingPeriod) external onlyRole("admin") {
        require(
            newVotingPeriod >= MIN_VOTING_PERIOD &&
                newVotingPeriod <= MAX_VOTING_PERIOD,
            setVotingDelayInvalid()
        );
        uint oldVotingPeriod = votingPeriod;
        votingPeriod = newVotingPeriod;

        emit VotingPeriodSet(oldVotingPeriod, votingPeriod);
    }

    /**
     * @notice Admin function for setting the proposal threshold
     * @dev newProposalThreshold must be greater than the hardcoded min
     * @param newProposalThreshold new proposal threshold
     */
    function _setProposalThreshold(
        uint newProposalThreshold
    ) external onlyRole("admin") {
        require(
            newProposalThreshold >= MIN_PROPOSAL_THRESHOLD &&
                newProposalThreshold <= MAX_PROPOSAL_THRESHOLD,
            setProposalThresholdInvalid()
        );
        uint oldProposalThreshold = proposalThreshold;
        proposalThreshold = newProposalThreshold;

        emit ProposalThresholdSet(oldProposalThreshold, proposalThreshold);
    }

    function getChainIdInternal() internal pure returns (uint) {
        uint chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    function castVoteInternal(
        address voter,
        uint256 proposalId_,
        uint8 support
    ) internal {
        ProposalMetadata storage proposal = getProposalMetadata[proposalId_];

        uint256 userVotes = uint256(
            VOTES.getPriorVotes(msg.sender, proposal.activationTimestamp)
        );

        if (proposal.activationTimestamp == 0) {
            revert ProposalIsNotActive();
        }

        if (proposal.votesCastByUser[msg.sender] > 0) {
            revert UserAlreadyVoted();
        }

        if (userVotes == 0) {
            revert UserHasNoVotes();
        }

        if (block.timestamp > proposal.activationTimestamp + VOTING_PERIOD) {
            revert PastVotingPeriod();
        }

        if (support == 0) {
            proposal.noVotes += votes;
        } else if (support == 1) {
            proposal.yesVotes += votes;
        } else if (support == 2) {
            proposal.abstainVotes += votes;
        }

        proposal.votesCastByUser[voter] = userVotes;

        emit VoteCast(proposalId_, voter, support, userVotes);
    }

    function executeProposal(uint256 proposalId_) external {
        ProposalMetadata storage proposal = getProposalMetadata[proposalId_];

        if (msg.sender != proposal.submitter) {
            revert ExecutorNotSubmitter();
        }

        if (
            (proposal.yesVotes - proposal.noVotes) * 100 <
            proposal.totalRegisteredVotes * EXECUTION_THRESHOLD
        ) {
            revert NotEnoughVotesToExecute();
        }

        if (proposal.isExecuted) {
            revert ProposalAlreadyExecuted();
        }

        if (proposal.isCanceled) {
            revert ProposalAlreadyCanceled();
        }

        /// @dev    2 days after the voting period ends
        if (
            block.timestamp < proposal.activationTimestamp + EXECUTION_TIMELOCK
        ) {
            revert ExecutionTimelockStillActive();
        }

        /// @dev    7 days after the voting period ends
        if (
            block.timestamp > proposal.activationTimestamp + EXECUTION_DEADLINE
        ) {
            revert ExecutionWindowExpired();
        }

        proposal.isExecuted = true;

        Instruction[] memory instructions = INSTR.getInstructions(proposalId_);
        uint256 totalInstructions = instructions.length;

        for (uint256 step; step < totalInstructions; ) {
            kernel.executeAction(
                instructions[step].action,
                instructions[step].target
            );
            unchecked {
                ++step;
            }
        }

        emit ProposalExecuted(proposalId_);
    }
}
