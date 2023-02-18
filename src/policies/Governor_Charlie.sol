pragma solidity ^0.8.15;
import {VotingToken} from "src/modules/VOTES/VotingToken.sol";
import {VotesV1} from "src/modules/VOTES/Votes.V1.sol";
import {Roles} from "src/modules/ROLES/ROLES.v1.sol";
import {OlympusRoles} from "src/modules/Roles/OlympusRoles.sol";
//import {INSTRv1} from "src/modules/INSTR/INSTR.v1.sol";
import {BoardRoom} from "src/modules/BOARD/BoardRoom.sol";
import {BoardV1} from "src/modules/BOARD/Board.V1.sol";

import "src/kernel.sol";

// Make votes for who the board is going to be, and then also designate proposals to be voted on by the board

// Tokenholders can vote for board, and also vote on proposals such as enabling new perms for board
// Boards reset every epoch
// Board can take whatever action is necessary – board could even just be management, while the protocol is the core biz
contract GovernorCharlieDelegate is Policy {
    // =========  EVENTS ========= //

    event ProposalSubmitted(
        uint256 proposalId,
        string title,
        string proposalURI
    );
    event ProposalActivated(uint256 proposalId, uint256 timestamp);
    event VotesCast(
        uint256 proposalId,
        address voter,
        bool approve,
        uint256 userVotes
    );
    event ProposalExecuted(uint256 proposalId);
    event CollateralReclaimed(uint256 proposalId, uint256 tokensReclaimed_);

    // =========  ERRORS ========= //

    error NotAuthorized();
    error UnableToActivate();
    error ProposalAlreadyActivated();

    error WarmupNotCompleted();
    error UserAlreadyVoted();
    error UserHasNoVotes();

    error ProposalIsNotActive();
    error DepositedAfterActivation();
    error PastVotingPeriod();

    error ExecutorNotSubmitter();
    error NotEnoughVotesToExecute();
    error ProposalAlreadyExecuted();
    error ExecutionTimelockStillActive();
    error ExecutionWindowExpired();

    // =========  STATE ========= //
    /// @notice The name of this contract
    string public constant name = "Governor Charlie";

    /// @notice The maximum number of members on the board
    uint public constant BOARD_MAX = 10;

    /// @notice The minimum setable proposal threshold
    uint public constant MIN_PROPOSAL_THRESHOLD = 50000e18; // 50,000 Comp

    /// @notice The maximum setable proposal threshold
    uint public constant MAX_PROPOSAL_THRESHOLD = 100000e18; //100,000 Comp

    /// @notice The minimum setable voting period
    uint public constant MIN_VOTING_PERIOD = 5760; // About 24 hours

    /// @notice The max setable voting period
    uint public constant MAX_VOTING_PERIOD = 80640; // About 2 weeks

    /// @notice The min setable voting delay
    uint public constant MIN_VOTING_DELAY = 1;

    /// @notice The max setable voting delay
    uint public constant MAX_VOTING_DELAY = 40320; // About 1 week

    /// @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    uint public constant quorumVotes = 400000e18; // 400,000 = 4% of Comp

    /// @notice The maximum number of actions that can be included in a proposal
    uint public constant proposalMaxOperations = 10; // 10 actions

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
        address kernel_,
        address comp_,
        uint votingPeriod_,
        uint votingDelay_,
        uint proposalThreshold_
    ) Policy(kernel_) {
        require(
            timelock_ != address(0),
            "GovernorBravo::initialize: invalid timelock address"
        );
        // Ideally token isn't already deployed and issued
        require(
            comp_ != address(0),
            "GovernorBravo::initialize: invalid comp address"
        );
        require(
            votingPeriod_ >= MIN_VOTING_PERIOD &&
                votingPeriod_ <= MAX_VOTING_PERIOD,
            "GovernorBravo::initialize: invalid voting period"
        );
        require(
            votingDelay_ >= MIN_VOTING_DELAY &&
                votingDelay_ <= MAX_VOTING_DELAY,
            "GovernorBravo::initialize: invalid voting delay"
        );
        require(
            proposalThreshold_ >= MIN_PROPOSAL_THRESHOLD &&
                proposalThreshold_ <= MAX_PROPOSAL_THRESHOLD,
            "GovernorBravo::initialize: invalid proposal threshold"
        );
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
        // instr -> multiple instructions, kind of like sudo?
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
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("INSTR");
        dependencies[1] = toKeycode("VOTES");

        INSTR = INSTRv1(getModuleAddress(dependencies[0]));
        VOTES = VOTESv1(getModuleAddress(dependencies[1]));
    }

    /**
     * @notice Function used to propose a new proposal. Sender must have delegates above the proposal threshold
     * @param Instructions Instructions for proposal calls
     * @param values Eth values for proposal calls
     * @param signatures Function signatures for proposal calls
     * @param description String description of the proposal
     * @return Proposal id of new proposal
     */
    // todo: add more general instructions for extcalls – but what is key usecase?
    // If it's an interaction that is internal to the contract, then it's a call
    function propose(
        Instruction[] calldata instructions,
        string calldata title,
        string calldata description
    ) public returns (uint) {
        // Allow addresses above proposal threshold and whitelisted addresses to propose
        // Change
        require(
            comp.getPriorVotes(msg.sender, sub256(block.number, 1)) >
                proposalThreshold ||
                isWhitelisted(msg.sender),
            "GovernorBravo::propose: proposer votes below proposal threshold"
        );
        require(
            instructions.length != 0,
            "GovernorBravo::propose: must provide actions"
        );
        require(
            instructions.length <= proposalMaxOperations,
            "GovernorBravo::propose: too many actions"
        );
        // transfer 5% of the total vote supply in VOTES (min 10 VOTES)
        uint256 collateral = _max(
            (VOTES.totalSupply() * COLLATERAL_REQUIREMENT) / 10_000,
            COLLATERAL_MINIMUM
        );
        // VOTES.transferFrom(msg.sender, address(this), collateral);

        uint256 proposalId = INSTR.store(instructions_);
        ProposalMetadata storage proposal = getProposalMetadata[proposalId];

        proposal.submitter = msg.sender;
        proposal.collateralAmt = collateral;
        proposal.submissionTimestamp = block.timestamp;

        VOTES.resetActionTimestamp(msg.sender);

        emit ProposalSubmitted(proposalId, title_, proposalURI_);
    }

    // reset board, allow for running
    function runForBoard() external {}

    function beginBoard() external {}

    /**
     * @notice Queues a proposal of state succeeded
     * @param proposalId The id of the proposal to queue
     */
    function queue(uint proposalId) external {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "GovernorBravo::queue: proposal can only be queued if it is succeeded"
        );
        Proposal storage proposal = proposals[proposalId];
        uint eta = add256(block.timestamp, timelock.delay());
        for (uint i = 0; i < proposal.targets.length; i++) {
            queueOrRevertInternal(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                eta
            );
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    /**
     * @notice Executes a queued proposal if eta has passed
     * @param proposalId The id of the proposal to execute
     */
    function execute(uint proposalId) external payable {
        require(
            state(proposalId) == ProposalState.Queued,
            "GovernorBravo::execute: proposal can only be executed if it is queued"
        );
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        for (uint i = 0; i < proposal.targets.length; i++) {
            timelock.executeTransaction.value(proposal.values[i])(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancels a proposal only if sender is the proposer, or proposer delegates dropped below proposal threshold
     * @param proposalId The id of the proposal to cancel
     */
    function cancel(uint proposalId) external {
        require(
            state(proposalId) != ProposalState.Executed,
            "GovernorBravo::cancel: cannot cancel executed proposal"
        );

        Proposal storage proposal = proposals[proposalId];

        // Proposer can cancel
        if (msg.sender != proposal.proposer) {
            // Whitelisted proposers can't be canceled for falling below proposal threshold
            if (isWhitelisted(proposal.proposer)) {
                require(
                    (comp.getPriorVotes(
                        proposal.proposer,
                        sub256(block.number, 1)
                    ) < proposalThreshold) && msg.sender == whitelistGuardian,
                    "GovernorBravo::cancel: whitelisted proposer"
                );
            } else {
                require(
                    (comp.getPriorVotes(
                        proposal.proposer,
                        sub256(block.number, 1)
                    ) < proposalThreshold),
                    "GovernorBravo::cancel: proposer above threshold"
                );
            }
        }

        proposal.canceled = true;
        for (uint i = 0; i < proposal.targets.length; i++) {
            timelock.cancelTransaction(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Gets actions of a proposal
     * @param proposalId the id of the proposal
     * @return Targets, values, signatures, and calldatas of the proposal actions
     */
    function getActions(
        uint proposalId
    )
        external
        view
        returns (
            address[] memory targets,
            uint[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        Proposal memory p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    /**
     * @notice Gets the receipt for a voter on a given proposal
     * @param proposalId the id of proposal
     * @param voter The address of the voter
     * @return The voting receipt
     */
    function getReceipt(
        uint proposalId,
        address voter
    ) external view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }

    /**
     * @notice Gets the state of a proposal
     * @param proposalId The id of the proposal
     * @return Proposal state
     */
    function state(uint proposalId) public view returns (ProposalState) {
        require(
            proposalCount >= proposalId && proposalId > initialProposalId,
            "GovernorBravo::state: invalid proposal id"
        );
        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (
            proposal.forVotes <= proposal.againstVotes ||
            proposal.forVotes < quorumVotes
        ) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (
            block.timestamp >= add256(proposal.eta, timelock.GRACE_PERIOD())
        ) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
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
     * @notice Cast a vote for a proposal
     * @param proposalId The id of the proposal to vote on
     * @param support The support value for the vote. 0=against, 1=for, 2=abstain
     */
    function castVote(address[] boardVotes, uint8 support) external {
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
        require(
            signatory != address(0),
            "GovernorBravo::castVoteBySig: invalid signature"
        );
        emit VoteCast(
            signatory,
            proposalId,
            support,
            castVoteInternal(signatory, proposalId, support),
            ""
        );
    }

    /**
     * @notice Internal function that caries out voting logic
     * @param voter The voter that is casting their vote
     * @param proposalId The id of the proposal to vote on
     * @param support The support value for the vote. 0=against, 1=for, 2=abstain
     * @return The number of votes cast
     */
    function castVoteInternal(
        address voter,
        uint proposalId,
        uint8 support
    ) internal returns (uint96) {
        require(
            state(proposalId) == ProposalState.Active,
            "GovernorBravo::castVoteInternal: voting is closed"
        );
        require(
            support <= 2,
            "GovernorBravo::castVoteInternal: invalid vote type"
        );
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        require(
            receipt.hasVoted == false,
            "GovernorBravo::castVoteInternal: voter already voted"
        );
        uint96 votes = comp.getPriorVotes(voter, proposal.startBlock);

        if (support == 0) {
            proposal.againstVotes = add256(proposal.againstVotes, votes);
        } else if (support == 1) {
            proposal.forVotes = add256(proposal.forVotes, votes);
        } else if (support == 2) {
            proposal.abstainVotes = add256(proposal.abstainVotes, votes);
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        return votes;
    }

    /**
     * @notice View function which returns if an account is whitelisted
     * @param account Account to check white list status of
     * @return If the account is whitelisted
     */
    function isWhitelisted(address account) public view returns (bool) {
        return (whitelistAccountExpirations[account] > now);
    }

    /**
     * @notice Admin function for setting the voting delay
     * @param newVotingDelay new voting delay, in blocks
     */
    function _setVotingDelay(uint newVotingDelay) external {
        require(
            msg.sender == admin,
            "GovernorBravo::_setVotingDelay: admin only"
        );
        require(
            newVotingDelay >= MIN_VOTING_DELAY &&
                newVotingDelay <= MAX_VOTING_DELAY,
            "GovernorBravo::_setVotingDelay: invalid voting delay"
        );
        uint oldVotingDelay = votingDelay;
        votingDelay = newVotingDelay;

        emit VotingDelaySet(oldVotingDelay, votingDelay);
    }

    /**
     * @notice Admin function for setting the voting period
     * @param newVotingPeriod new voting period, in blocks
     */
    function _setVotingPeriod(uint newVotingPeriod) external {
        require(
            msg.sender == admin,
            "GovernorBravo::_setVotingPeriod: admin only"
        );
        require(
            newVotingPeriod >= MIN_VOTING_PERIOD &&
                newVotingPeriod <= MAX_VOTING_PERIOD,
            "GovernorBravo::_setVotingPeriod: invalid voting period"
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
    function _setProposalThreshold(uint newProposalThreshold) external {
        require(
            msg.sender == admin,
            "GovernorBravo::_setProposalThreshold: admin only"
        );
        require(
            newProposalThreshold >= MIN_PROPOSAL_THRESHOLD &&
                newProposalThreshold <= MAX_PROPOSAL_THRESHOLD,
            "GovernorBravo::_setProposalThreshold: invalid proposal threshold"
        );
        uint oldProposalThreshold = proposalThreshold;
        proposalThreshold = newProposalThreshold;

        emit ProposalThresholdSet(oldProposalThreshold, proposalThreshold);
    }

    /**
     * @notice Admin function for setting the whitelist expiration as a timestamp for an account. Whitelist status allows accounts to propose without meeting threshold
     * @param account Account address to set whitelist expiration for
     * @param expiration Expiration for account whitelist status as timestamp (if now < expiration, whitelisted)
     */
    function _setWhitelistAccountExpiration(
        address account,
        uint expiration
    ) external {
        require(
            msg.sender == admin || msg.sender == whitelistGuardian,
            "GovernorBravo::_setWhitelistAccountExpiration: admin only"
        );
        whitelistAccountExpirations[account] = expiration;

        emit WhitelistAccountExpirationSet(account, expiration);
    }

    /**
     * @notice Admin function for setting the whitelistGuardian. WhitelistGuardian can cancel proposals from whitelisted addresses
     * @param account Account to set whitelistGuardian to (0x0 to remove whitelistGuardian)
     */
    function _setWhitelistGuardian(address account) external {
        require(
            msg.sender == admin,
            "GovernorBravo::_setWhitelistGuardian: admin only"
        );
        address oldGuardian = whitelistGuardian;
        whitelistGuardian = account;

        emit WhitelistGuardianSet(oldGuardian, whitelistGuardian);
    }

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     */
    function _setPendingAdmin(address newPendingAdmin) external {
        // Check caller = admin
        require(
            msg.sender == admin,
            "GovernorBravo:_setPendingAdmin: admin only"
        );

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
    }

    function getChainIdInternal() internal pure returns (uint) {
        uint chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    function activateProposal(uint256 proposalId_) external {
        ProposalMetadata storage proposal = getProposalMetadata[proposalId_];

        if (msg.sender != proposal.submitter) {
            revert NotAuthorized();
        }

        if (
            block.timestamp <
            proposal.submissionTimestamp + ACTIVATION_TIMELOCK ||
            block.timestamp > proposal.submissionTimestamp + ACTIVATION_DEADLINE
        ) {
            revert UnableToActivate();
        }

        if (proposal.activationTimestamp != 0) {
            revert ProposalAlreadyActivated();
        }

        proposal.activationTimestamp = block.timestamp;
        proposal.totalRegisteredVotes = VOTES.totalSupply();

        VOTES.resetActionTimestamp(msg.sender);

        emit ProposalActivated(proposalId_, block.timestamp);
    }

    function vote(uint256 proposalId_, bool approve_) external {
        ProposalMetadata storage proposal = getProposalMetadata[proposalId_];
        uint256 userVotes = VOTES.balanceOf(msg.sender);

        if (proposal.activationTimestamp == 0) {
            revert ProposalIsNotActive();
        }

        if (
            VOTES.lastDepositTimestamp(msg.sender) + WARMUP_PERIOD >
            block.timestamp
        ) {
            revert WarmupNotCompleted();
        }

        if (
            VOTES.lastDepositTimestamp(msg.sender) >
            proposal.activationTimestamp
        ) {
            revert DepositedAfterActivation();
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

        if (approve_) {
            proposal.yesVotes += userVotes;
        } else {
            proposal.noVotes += userVotes;
        }

        proposal.votesCastByUser[msg.sender] = userVotes;
        VOTES.resetActionTimestamp(msg.sender);

        emit VotesCast(proposalId_, msg.sender, approve_, userVotes);
    }

    function executeProposal(uint256 proposalId_) external {
        ProposalMetadata storage proposal = getProposalMetadata[proposalId_];

        // if (msg.sender != proposal.submitter) {
        //     revert ExecutorNotSubmitter();
        // }

        if (
            (proposal.yesVotes - proposal.noVotes) * 100 <
            proposal.totalRegisteredVotes * EXECUTION_THRESHOLD
        ) {
            revert NotEnoughVotesToExecute();
        }

        if (proposal.isExecuted) {
            revert ProposalAlreadyExecuted();
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

        VOTES.resetActionTimestamp(msg.sender);

        emit ProposalExecuted(proposalId_);
    }

    function reclaimCollateral(uint256 proposalId_) external {
        ProposalMetadata storage proposal = getProposalMetadata[proposalId_];

        if (
            !proposal.isExecuted &&
            block.timestamp < proposal.submissionTimestamp + COLLATERAL_DURATION
        ) {
            revert UnmetCollateralDuration();
        }

        if (proposal.isCollateralReturned) {
            revert CollateralAlreadyReturned();
        }

        if (msg.sender != proposal.submitter) {
            revert NotAuthorized();
        }

        proposal.isCollateralReturned = true;
        VOTES.transfer(proposal.submitter, proposal.collateralAmt);

        emit CollateralReclaimed(proposalId_, proposal.collateralAmt);
    }
}
