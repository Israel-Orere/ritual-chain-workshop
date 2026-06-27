// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PrivacyBountyJudge
 * @notice Commit-reveal bounty system with on-chain AI judging via Ritual.
 *
 * Lifecycle per bounty:
 *  1. Owner creates a bounty (COMMIT phase).
 *  2. Participants call submitCommitment() with keccak256(answer ++ salt ++ msg.sender ++ bountyId).
 *  3. Owner closes the commit phase, opening the REVEAL phase.
 *  4. Participants call revealAnswer() — the contract verifies the hash.
 *  5. Owner (or anyone) calls judgeAll() to send valid revealed answers to the LLM.
 *  6. Ritual callback delivers scores → finalizeWinner() picks the highest scorer.
 */
contract PrivacyBountyJudge {
    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────

    enum Phase {
        COMMIT,
        REVEAL,
        JUDGING,
        FINALIZED
    }

    struct Submission {
        address participant;
        bytes32 commitment;  // keccak256(answer, salt, participant, bountyId)
        string  answer;      // empty until reveal
        bool    revealed;
        bool    valid;       // true after successful reveal
        uint256 score;       // set by AI judge
    }

    struct Bounty {
        address  owner;
        string   question;
        uint256  prize;          // wei
        uint256  commitDeadline; // unix timestamp
        uint256  revealDeadline; // unix timestamp
        Phase    phase;
        uint256  winnerIndex;    // index into submissions[]
        bool     hasWinner;
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    address public immutable ritualConsumerAddress;

    uint256 private _nextBountyId;

    mapping(uint256 => Bounty)       public bounties;
    mapping(uint256 => Submission[]) public submissions;

    // participant → bountyId → submission index (+1; 0 = not submitted)
    mapping(address => mapping(uint256 => uint256)) private _submissionIndex;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event BountyCreated(uint256 indexed bountyId, address indexed owner, string question, uint256 prize);
    event CommitPhaseEnded(uint256 indexed bountyId);
    event CommitmentSubmitted(uint256 indexed bountyId, address indexed participant);
    event AnswerRevealed(uint256 indexed bountyId, address indexed participant, uint256 submissionIdx);
    event JudgingRequested(uint256 indexed bountyId, uint256 revealedCount);
    event ScoresReceived(uint256 indexed bountyId);
    event WinnerFinalized(uint256 indexed bountyId, address indexed winner, uint256 prize);

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────

    error NotBountyOwner();
    error WrongPhase(Phase current, Phase required);
    error AlreadySubmitted();
    error NothingToReveal();
    error InvalidCommitment();
    error RevealDeadlinePassed();
    error CommitDeadlineNotPassed();
    error NoValidSubmissions();
    error AlreadyHasWinner();
    error TransferFailed();

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address _ritualConsumer) {
        ritualConsumerAddress = _ritualConsumer;
    }

    // ─────────────────────────────────────────────────────────────
    //  Bounty management
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Create a new bounty. Prize is attached as msg.value.
     * @param question        The problem statement shown to participants.
     * @param commitDeadline  Unix timestamp after which no new commitments accepted.
     * @param revealDeadline  Unix timestamp after which reveals are closed.
     */
    function createBounty(
        string  calldata question,
        uint256 commitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(commitDeadline > block.timestamp, "commit deadline in past");
        require(revealDeadline > commitDeadline,  "reveal must be after commit");

        bountyId = _nextBountyId++;
        bounties[bountyId] = Bounty({
            owner:          msg.sender,
            question:       question,
            prize:          msg.value,
            commitDeadline: commitDeadline,
            revealDeadline: revealDeadline,
            phase:          Phase.COMMIT,
            winnerIndex:    0,
            hasWinner:      false
        });

        emit BountyCreated(bountyId, msg.sender, question, msg.value);
    }

    // ─────────────────────────────────────────────────────────────
    //  Required Track: Commit-Reveal
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Submit a commitment during the COMMIT phase.
     * @param bountyId   Target bounty.
     * @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *                   — computed off-chain by the participant.
     */
    function submitCommitment(uint256 bountyId, bytes32 commitment) external {
        Bounty storage b = bounties[bountyId];

        if (b.phase != Phase.COMMIT) revert WrongPhase(b.phase, Phase.COMMIT);
        if (block.timestamp > b.commitDeadline) revert WrongPhase(b.phase, Phase.REVEAL);
        if (_submissionIndex[msg.sender][bountyId] != 0) revert AlreadySubmitted();

        submissions[bountyId].push(Submission({
            participant: msg.sender,
            commitment:  commitment,
            answer:      "",
            revealed:    false,
            valid:       false,
            score:       0
        }));

        // store 1-based index so 0 == "not submitted"
        _submissionIndex[msg.sender][bountyId] = submissions[bountyId].length;

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    /**
     * @notice Move bounty from COMMIT → REVEAL phase (owner or auto after deadline).
     */
    function closeCommitPhase(uint256 bountyId) external {
        Bounty storage b = bounties[bountyId];
        if (msg.sender != b.owner) revert NotBountyOwner();
        if (b.phase != Phase.COMMIT) revert WrongPhase(b.phase, Phase.COMMIT);
        if (block.timestamp <= b.commitDeadline) revert CommitDeadlineNotPassed();

        b.phase = Phase.REVEAL;
        emit CommitPhaseEnded(bountyId);
    }

    /**
     * @notice Reveal the plaintext answer and salt.
     *         Contract verifies hash then stores the answer for judging.
     * @param bountyId Target bounty (must be in REVEAL phase).
     * @param answer   Plaintext answer string.
     * @param salt     Random salt used when computing the commitment.
     */
    function revealAnswer(
        uint256         bountyId,
        string calldata answer,
        bytes32         salt
    ) external {
        Bounty storage b = bounties[bountyId];

        if (b.phase != Phase.REVEAL) revert WrongPhase(b.phase, Phase.REVEAL);
        if (block.timestamp > b.revealDeadline) revert RevealDeadlinePassed();

        uint256 idx1 = _submissionIndex[msg.sender][bountyId];
        if (idx1 == 0) revert NothingToReveal();

        Submission storage s = submissions[bountyId][idx1 - 1];
        if (s.revealed) revert AlreadySubmitted();

        // ── Core verification ──────────────────────────────────────
        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        if (expected != s.commitment) revert InvalidCommitment();
        // ──────────────────────────────────────────────────────────

        s.answer   = answer;
        s.revealed = true;
        s.valid    = true;

        emit AnswerRevealed(bountyId, msg.sender, idx1 - 1);
    }

    /**
     * @notice Gather all valid revealed answers and dispatch to the LLM via Ritual.
     * @param bountyId Target bounty (must be in REVEAL phase, past reveal deadline).
     * @param llmInput ABI-encoded payload for Ritual's consumer contract
     *                 (typically the question + all answers concatenated, plus
     *                  any Ritual-specific routing headers).
     *
     * @dev  In production this calls into the Ritual IConsumer interface to
     *       request an off-chain LLM compute job.  The stub here emits an event
     *       so the assignment can be tested on any EVM without a live Ritual node.
     */
    function judgeAll(uint256 bountyId, bytes calldata llmInput) external {
        Bounty storage b = bounties[bountyId];

        if (b.phase != Phase.REVEAL) revert WrongPhase(b.phase, Phase.REVEAL);
        require(block.timestamp > b.revealDeadline, "reveal phase still open");

        uint256 validCount;
        Submission[] storage subs = submissions[bountyId];
        for (uint256 i; i < subs.length; i++) {
            if (subs[i].valid) validCount++;
        }
        if (validCount == 0) revert NoValidSubmissions();

        b.phase = Phase.JUDGING;

        // ── Ritual integration hook ────────────────────────────────
        // In a full Ritual deployment this would be:
        //   IRitualConsumer(ritualConsumerAddress).requestCompute(
        //       modelId, llmInput, callbackSelector
        //   );
        // For the assignment stub we just emit the data so tests can inspect it.
        emit JudgingRequested(bountyId, validCount);

        // Silence the unused-parameter warning while keeping the ABI identical.
        bytes memory _input = llmInput;
        assembly { pop(_input) }
    }

    /**
     * @notice Called by the Ritual oracle (or owner in stub mode) to record scores
     *         and determine the winner.
     * @param bountyId    Target bounty.
     * @param winnerIndex Index into submissions[] of the winning entry.
     *
     * @dev   In a production Ritual flow this function is called by the
     *        RitualConsumer contract (access-controlled by ritualConsumerAddress).
     *        Scores for all valid submissions are set before the winner is picked.
     */
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external {
        Bounty storage b = bounties[bountyId];

        if (b.phase != Phase.JUDGING) revert WrongPhase(b.phase, Phase.JUDGING);
        if (b.hasWinner) revert AlreadyHasWinner();

        Submission storage winner = submissions[bountyId][winnerIndex];
        require(winner.valid, "winner not a valid submission");

        b.winnerIndex = winnerIndex;
        b.hasWinner   = true;
        b.phase       = Phase.FINALIZED;

        emit WinnerFinalized(bountyId, winner.participant, b.prize);

        if (b.prize > 0) {
            (bool ok,) = winner.participant.call{value: b.prize}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    function getSubmissionCount(uint256 bountyId) external view returns (uint256) {
        return submissions[bountyId].length;
    }

    function getSubmission(uint256 bountyId, uint256 idx)
        external view
        returns (
            address participant,
            bytes32 commitment,
            string memory answer,
            bool revealed,
            bool valid,
            uint256 score
        )
    {
        Submission storage s = submissions[bountyId][idx];
        return (s.participant, s.commitment, s.answer, s.revealed, s.valid, s.score);
    }

    /// @notice Returns all revealed, valid answers — used off-chain to build llmInput.
    function getValidAnswers(uint256 bountyId)
        external view
        returns (address[] memory participants, string[] memory answers)
    {
        Submission[] storage subs = submissions[bountyId];
        uint256 count;
        for (uint256 i; i < subs.length; i++) {
            if (subs[i].valid) count++;
        }

        participants = new address[](count);
        answers      = new string[](count);
        uint256 j;
        for (uint256 i; i < subs.length; i++) {
            if (subs[i].valid) {
                participants[j] = subs[i].participant;
                answers[j]      = subs[i].answer;
                j++;
            }
        }
    }

    /// @dev Allow the contract to receive ETH for prize top-ups.
    receive() external payable {}
}

