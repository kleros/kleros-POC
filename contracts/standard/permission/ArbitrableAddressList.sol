/**
 *  @authors: [@mtsalenc]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.4.24;

import "../arbitration/Arbitrable.sol";
import "./PermissionInterface.sol";
import "../../libraries/CappedMath.sol";


/**
 *  @title ArbitrableAddressList
 *  This contract is arbitrable token curated list of addresses. Users can send requests to register or remove addresses from the list which can, in turn, be challenged by parties that disagree with the request.
 *  A crowdsourced insurance system allows parties to contribute to arbitration fees and win rewards if the side they backed ultimately wins a dispute.
 *  NOTE: This contract trusts the Arbitrator not to try to reenter or modify its costs during a call. The governor contract (which will be a DAO) is also to be trusted.
 */
contract ArbitrableAddressList is PermissionInterface, Arbitrable {
    using CappedMath for uint;
    /* solium-disable max-len*/
    /* solium-disable operator-whitespace*/

    /* Enums */

    enum AddressStatus {
        Absent, // The address is not on the list.
        Registered, // The address is on the list.
        RegistrationRequested, // The address has a request to be added to the list.
        ClearingRequested // The address has a request to be removed from the list.
    }

    enum RulingOption {
        Other, // Arbitrator did not rule or refused to rule.
        Accept, // Execute request. Rule in favor of requester.
        Refuse // Refuse request. Rule in favor of challenger.
    }

    enum Party {
        None,
        Requester, // Party that made a request to change an address status.
        Challenger // Party challenging a request.
    }

    // ************************ //
    // *  Request Life Cycle  * //
    // ************************ //
    // Changes to the address status are made via requests for either listing or removing an address from the TCR.
    // The total cost of a request varies depending on whether a party challenges that request and on the number of appeals.
    // To make or challenge a request, a party must pay a deposit. This value will be rewarded to the party that ultimately wins a dispute. If no one challenges the request, the value will be reimbursed to the requester.
    // Additionally to the challenge reward, in the case a party challenges a request, both sides must fully pay the amount of arbitration fees required to raise a dispute. The party that ultimately wins the case will be reimbursed.
    // Finally, arbitration fees can be crowdsourced. To incentivise insurers, an additional value must be deposited. Contributors that fund the side that ultimately wins a dispute will be reimbursed and rewarded with the other side's fee stake proportinally to their contribution.
    // In summary, costs for placing or challenging a request are the following:
    // - A challenge reward given to the party that wins a potential dispute.
    // - Arbitration fees used to pay jurors.
    // - Fee stake that is distributed among contributors of the side that ultimately wins a dispute.

    /* Structs */
    struct Address {
        AddressStatus status;
        Request[] requests; // List of status change requests made for the address.
        uint numberOfRequests;
    }

    // Some arrays below have 3 elements to map with the Party enums for better readability.
    // - 0 is unused, matches Party.None.
    // - 1 for Party.Requester.
    // - 2 for Party.Challenger.
    struct Request {
        bool disputed; // True if a dispute was raised.
        uint disputeID; // ID of the dispute, if any.
        uint submissionTime; // Time when the request was made. Used to track when the challenge period ends.
        uint challengeRewardBalance; // The summation of requester's and challenger's deposit. This value will be given to the party that ultimately wins a potential dispute, or be reimbursed to the requester if no one challenges.
        uint challengerDepositTime; // The time when a challenger paid the deposit. Used to track when the request left the challenge period and entered the arbitration fees funding period.
        bool resolved; // True if the request was executed and/or any disputes raised were resolved.
        address[3] parties; // Address of requester and challenger, if any.
        Round[] rounds; // Tracks each round of a dispute.
        RulingOption ruling; // The final ruling given, if any.
        Arbitrator arbitrator; // The arbitrator trusted to solve disputes for this request.
        bytes arbitratorExtraData; // The extra data for the trusted arbitrator of this request.
    }

    struct Round {
        bool appealed; // True if this round was appealed.
        uint oldWinnerTotalCost; // Governance changes on the second half of the appeal funding period create a difference between the amount that must be contributed by the winner and the loser. This variable tracks the amount that was required of the winner in the first round, before a change that happened on the second half of the funding period. It is used to calculate the amount that must be paid by the winner to fully fund his side, which is max(old total cost, new appeal cost).
        uint[3] paidFees; // Tracks the fees paid by each side on this round.
        uint[3] requiredForSide; // The total amount required to fully fund each side. It is the summation of the dispute or appeal cost and the fee stake.
        bool[3] requiredForSideSet; // Tracks if the required for each side was been set.
        uint feeRewards; // Summation of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint[3]) contributions; // Maps contributors to their contributions for each side.
    }

    struct ArbitratorData {

    }

    /* Modifiers */

    modifier onlyGovernor {require(msg.sender == governor, "The caller is not the governor."); _;}

    /* Events */

    /**
     *  @dev Emitted when a party makes a request, dispute or appeals are raised or when a request is resolved.
     *  @param _requester Address of the party that submitted the request.
     *  @param _challenger Address of the party that challenged the request, if any.
     *  @param _address The affected address.
     *  @param _status The status of the address.
     *  @param _disputed Whether the address is disputed.
     *  @param _appealed Whether the current round was appealed.
     */
    event AddressStatusChange(
        address indexed _requester,
        address indexed _challenger,
        address indexed _address,
        AddressStatus _status,
        bool _disputed,
        bool _appealed
    );

    /** @dev Emitted when a party makes a contribution.
     *  @param _address The address the contribution was made to.
     *  @param _contributor The contributor's address.
     *  @param _side The side the contribution was made to.
     *  @param _value The value of the contribution.
     */
    event Contribution(address indexed _address, address indexed _contributor, Party indexed _side, uint _value);

    /** @dev Emitted when a deposit is made to challenge a request.
     *  @param _address The address that has the challenged request.
     *  @param _challenger The address that paid the deposit.
     */
    event ChallengeDepositPlaced(address indexed _address, address indexed _challenger);

    /** @dev Emitted when a reimbursements and/or contribution rewards are withdrawn.
     *  @param _address The address from which the withdrawal was made.
     *  @param _contributor The address that sent the contribution.
     *  @param _request The request from which the withdrawal was made.
     *  @param _round The reward from which the reward was taken.
     *  @param _value The value of the reward.
     */
    event RewardWithdrawal(address indexed _address, address indexed _contributor, uint indexed _request, uint _round, uint _value);

    /* Storage */

    // Settings
    uint public challengeReward; // The deposit required for placing and/or challenging a request. A party that wins a disputed request will be reimbursed and will receive the other's deposit.
    uint public challengePeriodDuration; // The time before a request becomes executable if not challenged.
    uint public arbitrationFeesWaitingTime; // The time available to fund arbitration fees and fee stake for a potential dispute.
    address public governor; // The address that can make governance changes to the parameters of the Token Curated List.
    bool public appealPeriodSupported; // Whether the currently set arbitrator supports the appealPeriod function.

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    // The value is the percentage in 2 digits precision (e.g. a multiplier of 5000 results the fee stake being 50% of the arbitration cost for that round).
    uint public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where the previous round does not have a winner (e.g. when it's the first round or the arbitrator ruled "refused to rule"/"could not rule").
    uint public constant MULTIPLIER_PRECISION = 10000; // Precision parameter for multipliers.

    mapping(address => Address) public addresses; // Maps the address to its current state.
    mapping(uint => address) public disputeIDToAddress; // Maps a dispute ID to the affected address.
    address[] public addressList; // List of submitted addresses.

    /* Constructor */

    /**
     *  @dev Constructs the arbitrable token curated list.
     *  @param _arbitrator The trusted arbitrator to resolve potential disputes.
     *  @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     *  @param _registrationMetaEvidence The URI of the meta evidence object for registration requests.
     *  @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     *  @param _governor The trusted governor of this contract.
     *  @param _arbitrationFeesWaitingTime The maximum time to wait for arbitration fees if the dispute is raised.
     *  @param _challengeReward The amount in weis required to submit or a challenge a request.
     *  @param _challengePeriodDuration The time in seconds, parties have to challenge a request.
     *  @param _sharedStakeMultiplier Percentage of the arbitration cost that each party must pay as fee stake for a round when there isn't a winner/loser in the previous round (e.g. when it's the first round or the arbitrator refused to or did not rule). Value in 2 digits precision (e.g. 2500 results in 25% of the arbitration cost value of that round).
     *  @param _winnerStakeMultiplier Percentage of the arbitration cost that the winner has to pay as fee stake for a round. Value in 2 digits precision (e.g. 5000 results in 50% of the arbitration cost value of that round).
     *  @param _loserStakeMultiplier Percentage of the arbitration cost that the loser has to pay as fee stake for a round. Value in 2 digits precision (e.g. 10000 results in 100% of the arbitration cost value of that round).
     */
    constructor(
        Arbitrator _arbitrator,
        bytes _arbitratorExtraData,
        string _registrationMetaEvidence,
        string _clearingMetaEvidence,
        address _governor,
        uint _arbitrationFeesWaitingTime,
        uint _challengeReward,
        uint _challengePeriodDuration,
        uint _sharedStakeMultiplier,
        uint _winnerStakeMultiplier,
        uint _loserStakeMultiplier
    ) Arbitrable(_arbitrator, _arbitratorExtraData) public {
        emit MetaEvidence(0, _registrationMetaEvidence);
        emit MetaEvidence(1, _clearingMetaEvidence);
        governor = _governor;
        arbitrationFeesWaitingTime = _arbitrationFeesWaitingTime;
        challengeReward = _challengeReward;
        challengePeriodDuration = _challengePeriodDuration;
        sharedStakeMultiplier = _sharedStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /* Public */

    // ************************ //
    // *       Requests       * //
    // ************************ //

    /** @dev Submit a request to change an address status. Accepts enough ETH to fund a potential dispute considering the current required amount and reimburses the rest. TRUSTED
     *  @param _address The address to receive the request.
     */
    function requestStatusChange(address _address)
        external
        payable
    {
        require(msg.value >= challengeReward, "Not enough ETH.");
        Address storage addr = addresses[_address];
        if (addr.requests.length == 0)
            addressList.push(_address);

        // Update address status.
        if (addr.status == AddressStatus.Absent)
            addr.status = AddressStatus.RegistrationRequested;
        else if (addr.status == AddressStatus.Registered)
            addr.status = AddressStatus.ClearingRequested;
        else
            revert("Address is in wrong status for request.");

        // Setup request.
        addr.requests.length++;
        Request storage request = addr.requests[addr.requests.length - 1];
        request.parties[uint(Party.Requester)] = msg.sender;
        request.submissionTime = now;
        request.rounds.length++;
        request.challengeRewardBalance = challengeReward;
        request.arbitrator = arbitrator;
        request.arbitratorExtraData = arbitratorExtraData;

        // Calculate total amount required to fully fund the each side.
        Round storage round = request.rounds[request.rounds.length - 1];
        uint arbitrationCost = request.arbitrator.arbitrationCost(arbitratorExtraData);
        round.requiredForSide[uint(Party.Requester)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSide[uint(Party.Challenger)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSideSet[uint(Party.Requester)] = true;
        round.requiredForSideSet[uint(Party.Challenger)] = true;

        // Take up to the amount necessary to fund the current round at the current costs.
        uint contribution;
        uint remainingETH = msg.value - challengeReward;
        (contribution, remainingETH) = calculateContribution(remainingETH, round.requiredForSide[uint(Party.Requester)]);
        round.contributions[msg.sender][uint(Party.Requester)] = contribution;
        round.paidFees[uint(Party.Requester)] = contribution;
        round.feeRewards = contribution;
        if (contribution > 0)
            emit Contribution(_address, msg.sender, Party.Requester, contribution);

        // Reimburse leftover ETH.
        msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        emit AddressStatusChange(
            request.parties[uint(Party.Requester)],
            address(0x0),
            _address,
            addr.status,
            false,
            false
        );
    }

    /** @dev Challenges the latest request of an address. Accepts enough ETH to fund a potential dispute considering the current required amount and reimburses the rest. TRUSTED.
     *  @param _address The address with the request to execute.
     */
    function challengeRequest(address _address) external payable {
        Address storage addr = addresses[_address];
        require(
            addr.status == AddressStatus.RegistrationRequested || addr.status == AddressStatus.ClearingRequested,
            "Address does not have any pending requests."
        );
        Request storage request = addr.requests[addr.requests.length - 1];
        require(now - request.submissionTime < challengePeriodDuration, "The challenge period has already passed.");
        require(request.challengerDepositTime == 0, "Request should have only the requester's deposit.");
        require(msg.value >= request.challengeRewardBalance, "Not enough ETH. Party starting dispute must pay the deposit in full.");

        // Take the deposit and save the challenger's address.
        uint remainingETH = msg.value - request.challengeRewardBalance;
        request.challengeRewardBalance += request.challengeRewardBalance;
        request.parties[uint(Party.Challenger)] = msg.sender;
        request.challengerDepositTime = now; // Save the start of the first round arbitration fees funding period.
        emit ChallengeDepositPlaced(_address, msg.sender);

        // Update the total amount required to fully fund the each side.
        Round storage round = request.rounds[request.rounds.length - 1];
        uint arbitrationCost = request.arbitrator.arbitrationCost(arbitratorExtraData);
        round.requiredForSide[uint(Party.Requester)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSide[uint(Party.Challenger)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSideSet[uint(Party.Requester)] = true;
        round.requiredForSideSet[uint(Party.Challenger)] = true;

        // Take up to the amount necessary to fund the current round at the current costs.
        uint contribution;
        (contribution, remainingETH) = calculateContribution(remainingETH, round.requiredForSide[uint(Party.Challenger)]);
        round.contributions[msg.sender][uint(Party.Challenger)] = contribution;
        round.paidFees[uint(Party.Challenger)] = contribution;
        round.feeRewards += contribution;
        if (contribution > 0)
            emit Contribution(_address, msg.sender, Party.Challenger, contribution);

        // Reimburse leftover ETH.
        msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        // Raise dispute if both sides are fully funded.
        if (round.paidFees[uint(Party.Requester)] >= round.requiredForSide[uint(Party.Requester)] &&
            round.paidFees[uint(Party.Challenger)] >= round.requiredForSide[uint(Party.Challenger)]) {

            request.disputeID = request.arbitrator.createDispute.value(arbitrationCost)(2, arbitratorExtraData);
            disputeIDToAddress[request.disputeID] = _address;
            request.disputed = true;
            emit Dispute(arbitrator, request.disputeID, addr.status == AddressStatus.RegistrationRequested ? 0 : 1);

            request.rounds.length++;
            round.feeRewards -= arbitrationCost;

            emit AddressStatusChange(
                request.parties[uint(Party.Requester)],
                request.parties[uint(Party.Challenger)],
                _address,
                addr.status,
                true,
                false
            );
        }
    }

    /** @dev Takes up to the total required to fund a side of the latest round, reimburses the rest. TRUSTED.
     *  @param _address The address with the request to execute.
     *  @param _side The recipient of the contribution.
     */
    function fundDispute(address _address, Party _side) external payable {
        Address storage addr = addresses[_address];
        require(
            addr.status == AddressStatus.RegistrationRequested || addr.status == AddressStatus.ClearingRequested,
            "The Address does not have any pending requests."
        );
        Request storage request = addr.requests[addr.requests.length - 1];
        require(!request.disputed, "A dispute must have been raised to fund an appeal.");
        require(
            now - request.challengerDepositTime < arbitrationFeesWaitingTime,
            "The arbitration fees contribution period is over."
        );
        if (_side == Party.Challenger)
            require(
                request.challengerDepositTime > 0,
                "A challenge deposit must be paid before the challenger can accept contributions."
            );

        // Update the total amount required for each side.
        Round storage round = request.rounds[request.rounds.length - 1];
        uint arbitrationCost = request.arbitrator.arbitrationCost(arbitratorExtraData);
        round.requiredForSide[uint(Party.Requester)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSide[uint(Party.Challenger)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSideSet[uint(Party.Requester)] = true;
        round.requiredForSideSet[uint(Party.Challenger)] = true;

        // Take contribution.
        uint contribution;
        uint remainingETH = msg.value;
        (contribution, remainingETH) = calculateContribution(remainingETH, round.requiredForSide[uint(Party.Challenger)]);
        round.contributions[msg.sender][uint(_side)] += contribution;
        round.paidFees[uint(_side)] += contribution;
        round.feeRewards += contribution;
        if (contribution > 0)
            emit Contribution(_address, msg.sender, _side, contribution);

        // Reimburse leftover ETH.
        msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        // Raise dispute if both sides are fully funded.
        if (round.paidFees[uint(Party.Requester)] >= round.requiredForSide[uint(Party.Requester)] &&
            round.paidFees[uint(Party.Challenger)] >= round.requiredForSide[uint(Party.Challenger)]) {

            request.disputeID = request.arbitrator.createDispute.value(arbitrationCost)(2, arbitratorExtraData);
            disputeIDToAddress[request.disputeID] = _address;
            request.disputed = true;
            emit Dispute(arbitrator, request.disputeID, addr.status == AddressStatus.RegistrationRequested ? 0 : 1);

            request.rounds.length++;
            round.feeRewards -= arbitrationCost;

            emit AddressStatusChange(
                request.parties[uint(Party.Requester)],
                request.parties[uint(Party.Challenger)],
                _address,
                addr.status,
                true,
                false
            );
        }
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. TRUSTED.
     *  @param _address The address with the request to fund.
     *  @param _side The recipient of the contribution.
     */
    function fundAppeal(address _address, Party _side) external payable {
        require(
            _side == Party.Requester || _side == Party.Challenger,
            "Side must be either the requester or challenger."
        );
        Address storage addr = addresses[_address];
        require(
            addr.status == AddressStatus.RegistrationRequested || addr.status == AddressStatus.ClearingRequested,
            "The Address does not have any pending requests."
        );
        Request storage request = addr.requests[addr.requests.length - 1];
        require(request.disputed, "A dispute must have been raised to fund an appeal.");
        require(
            uint(request.arbitrator.disputeStatus(request.disputeID)) == 1, //
            "Dispute must be appealable to receive funds."
        );
        (uint appealPeriodStart, uint appealPeriodEnd) = request.arbitrator.appealPeriod(request.disputeID);
        require(now < appealPeriodEnd, "Appeal period ended.");

        // Calculate and total amount required to fully fund the each side.
        // The amount required to fully fund each side depends on the ruling given by the arbitrator.
        Party winner;
        Party loser;
        Round storage round = request.rounds[request.rounds.length - 1];
        RulingOption ruling = RulingOption(request.arbitrator.currentRuling(request.disputeID));
        if (ruling == RulingOption.Accept) {
            winner = Party.Requester;
            loser = Party.Challenger;
        } else if (ruling == RulingOption.Refuse) {
            winner = Party.Challenger;
            loser = Party.Requester;
        }

        uint appealCost = request.arbitrator.appealCost(request.disputeID, arbitratorExtraData);
        if (winner == Party.None) {
            // Arbitrator did not rule or refused to rule.
            round.requiredForSide[uint(Party.Requester)] =
                appealCost.addCap((appealCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
            round.requiredForSide[uint(Party.Challenger)] =
                appealCost.addCap((appealCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
            round.requiredForSideSet[uint(Party.Requester)] = true;
            round.requiredForSideSet[uint(Party.Challenger)] = true;
        } else {
            // Arbitrator gave a decisive ruling.
            if (_side == loser) {
                require(
                    now.subCap(appealPeriodStart) < (appealPeriodEnd.subCap(appealPeriodStart)) / 2,
                    "Contributions to the loser must be done in the first half of the appeal period."
                );
            }

            if (now.subCap(appealPeriodStart) < (appealPeriodEnd.subCap(appealPeriodStart)) / 2) {
                // In first half of the appeal period. Update the amount required for each side.
                round.requiredForSide[uint(loser)] = appealCost.addCap((appealCost.mulCap(loserStakeMultiplier)) / MULTIPLIER_PRECISION);
                round.requiredForSide[uint(winner)] = appealCost.addCap((appealCost.mulCap(winnerStakeMultiplier)) / MULTIPLIER_PRECISION);
                round.requiredForSideSet[uint(winner)] = true;
                round.requiredForSideSet[uint(loser)] = true;
            } else {
                // In second half of appeal period. Update only the amount required to fully fund the winner.
                // The amount that must be paid by the winner is max(old appeal cost + old winner stake, new appeal cost).
                round.requiredForSide[uint(winner)] = round.oldWinnerTotalCost > appealCost
                    ? round.oldWinnerTotalCost
                    : appealCost;

                round.requiredForSideSet[uint(winner)] = true;
            }
        }

        // Take only the necessary ETH.
        uint contribution;
        uint remainingETH = msg.value;
        uint amountStillRequired = round.requiredForSide[uint(_side)].subCap(round.paidFees[uint(_side)]);
        (contribution, remainingETH) = calculateContribution(remainingETH, amountStillRequired);
        round.contributions[msg.sender][uint(_side)] += contribution;
        round.paidFees[uint(_side)] += contribution;
        round.feeRewards += contribution;
        if (contribution > 0)
            emit Contribution(_address, msg.sender, _side, contribution);

        // Reimburse leftover ETH.
        msg.sender.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        // Raise appeal if both sides are fully funded.
        if (round.requiredForSideSet[uint(Party.Requester)] &&
            round.requiredForSideSet[uint(Party.Challenger)] &&
            round.paidFees[uint(Party.Requester)] >= round.requiredForSide[uint(Party.Requester)] &&
            round.paidFees[uint(Party.Challenger)] >= round.requiredForSide[uint(Party.Challenger)])
        {
            round.appealed = true;
            request.arbitrator.appeal.value(appealCost)(request.disputeID, arbitratorExtraData);

            request.rounds.length++;
            round.feeRewards -= appealCost;

            emit AddressStatusChange(
                request.parties[uint(Party.Requester)],
                request.parties[uint(Party.Challenger)],
                _address,
                addr.status,
                true,
                true
            );
        }
    }

    /** @dev Reimburses caller's contributions if no disputes were raised. If a dispute was raised,  withdraws the rewards and reimbursements proportional to the contribtutions made to the winner of a dispute.
     *  @param _beneficiary The address receiving the funds.
     *  @param _address The address from which to withdraw.
     *  @param _request The request from which to withdraw.
     *  @param _round The request from which to withdraw.
     */
    function withdrawFeesAndRewards(address _beneficiary, address _address, uint _request, uint _round) external {
        Address storage addr = addresses[_address];
        Request storage request = addr.requests[_request];
        Round storage round = request.rounds[_round];
        require(
            request.resolved,
            "The request was not executed and/or there are disputes pending resolution."
        );

        uint reward;
        if (!request.disputed || request.ruling == RulingOption.Other) {
            // No disputes were raised, or there isn't a winner and loser. Reimburse contributions.
            uint rewardRequester = round.paidFees[uint(Party.Requester)] > 0
                ? (round.contributions[_beneficiary][uint(Party.Requester)] * round.feeRewards) / round.paidFees[uint(Party.Requester)]
                : 0;
            uint rewardChallenger = round.paidFees[uint(Party.Challenger)] > 0
                ? (round.contributions[_beneficiary][uint(Party.Challenger)] * round.feeRewards) / round.paidFees[uint(Party.Challenger)]
                : 0;

            reward = rewardRequester + rewardChallenger;
            round.contributions[_beneficiary][uint(Party.Requester)] = 0;
            round.contributions[_beneficiary][uint(Party.Challenger)] = 0;
        } else {
            Party winner;
            if (request.ruling == RulingOption.Accept)
                winner = Party.Requester;
            else
                winner = Party.Challenger;

            // Take rewards for funding the winner.
            uint share = round.contributions[_beneficiary][uint(winner)] * MULTIPLIER_PRECISION / round.paidFees[uint(winner)];
            reward = (share * round.feeRewards) / MULTIPLIER_PRECISION;
            round.contributions[_beneficiary][uint(winner)] = 0;
        }

        emit RewardWithdrawal(_address, _beneficiary, _request, _round,  reward);
        _beneficiary.transfer(reward);
    }

    /** @dev Executes a requests if the challenge period passed and one challenged the request.
     *  @param _address The address with the request to execute.
     */
    function executeRequest(address _address) external {
        Address storage addr = addresses[_address];
        Request storage request = addr.requests[addr.requests.length - 1];
        require(request.challengerDepositTime == 0, "A party challenged the request.");
        require(
            now - request.submissionTime > challengePeriodDuration,
            "The time to challenge has not passed yet."
        );

        if (addr.status == AddressStatus.RegistrationRequested)
            addr.status = AddressStatus.Registered;
        else if (addr.status == AddressStatus.ClearingRequested)
            addr.status = AddressStatus.Absent;
        else
            revert("The address is in the wrong status for executing request.");

        // Deliberate use of send in order to not block the contract in case of reverting fallback.
        request.parties[uint(Party.Requester)].send(request.challengeRewardBalance);
        request.challengeRewardBalance = 0;
        request.resolved = true;

        emit AddressStatusChange(
            request.parties[uint(Party.Requester)],
            request.parties[uint(Party.Challenger)],
            _address,
            addr.status,
            false,
            false
        );
    }

    /** @dev Rules in favor of the side that received the most fee contributions. Raises a dispute if decreases in arbitration cost means both parties are fully funded. TRUSTED.
     *  @param _address The address with the request to execute.
     */
    function timeout(address _address) external {
        Address storage addr = addresses[_address];
        Request storage request = addr.requests[addr.requests.length - 1];
        require(!request.resolved, "The request is already resolved.");
        require(!request.disputed, "A dispute was raised for this request.");
        require(request.challengerDepositTime > 0, "A party must have challenged the request.");
        require(
            now - request.challengerDepositTime > arbitrationFeesWaitingTime,
            "There is still time to contribution."
        );

        // Decreases in arbitration costs could mean both sides are fully funded, in which case a dispute should be raised.
        // Update required amount for each side to check for this case.
        Round storage round = request.rounds[request.rounds.length - 1];
        uint arbitrationCost = request.arbitrator.arbitrationCost(arbitratorExtraData);
        round.requiredForSide[uint(Party.Requester)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);
        round.requiredForSide[uint(Party.Challenger)] =
            arbitrationCost.addCap((arbitrationCost.mulCap(sharedStakeMultiplier)) / MULTIPLIER_PRECISION);

        // Raise dispute if both sides are fully funded.
        if (round.paidFees[uint(Party.Requester)] >= round.requiredForSide[uint(Party.Requester)] && round.paidFees[uint(Party.Challenger)] >= round.requiredForSide[uint(Party.Challenger)]) {
            request.disputeID = request.arbitrator.createDispute.value(arbitrationCost)(2, arbitratorExtraData);
            disputeIDToAddress[request.disputeID] = _address;
            request.disputed = true;
            emit Dispute(arbitrator, request.disputeID, addr.status == AddressStatus.RegistrationRequested ? 0 : 1);

            request.rounds.length++;
            round.feeRewards -= arbitrationCost;

            emit AddressStatusChange(
                request.parties[uint(Party.Requester)],
                request.parties[uint(Party.Challenger)],
                _address,
                addr.status,
                true,
                false
            );
            return;
        }

        // Rule in favor of requester if he paid more or the same amount of the challenger. Rule in favor of challenger otherwise.
        Party winner;
        if (round.paidFees[uint(Party.Requester)] >= round.paidFees[uint(Party.Challenger)])
            winner = Party.Requester;
        else
            winner = Party.Challenger;

        // Update the address state
        if (winner == Party.Requester) // Execute Request
            if (addr.status == AddressStatus.RegistrationRequested)
                addr.status = AddressStatus.Registered;
            else
                addr.status = AddressStatus.Absent;
        else // Revert to previous state.
            if (addr.status == AddressStatus.RegistrationRequested)
                addr.status = AddressStatus.Absent;
            else if (addr.status == AddressStatus.ClearingRequested)
                addr.status = AddressStatus.Registered;

        // Reimburse deposit and send challenge reward.
        // Deliberate use of send in order to not block the contract in case the recipient refuses payments.
        if (winner == Party.Challenger)
            request.parties[uint(Party.Challenger)].send(request.challengeRewardBalance);
        else
            request.parties[uint(Party.Requester)].send(request.challengeRewardBalance);

        request.challengeRewardBalance = 0;
        request.resolved = true;

        emit AddressStatusChange(
            request.parties[uint(Party.Requester)],
            request.parties[uint(Party.Challenger)],
            _address,
            addr.status,
            false,
            false
        );
    }

    /** @dev Give a ruling for a dispute. Can only be called by the arbitrator. TRUSTED.
     *  Overrides parent function to account for the situation where the winner loses a case due to paying less appeal fees than expected.
     *  @param _disputeID ID of the dispute in the arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint _disputeID, uint _ruling) public onlyArbitrator {
        RulingOption resultRuling = RulingOption(_ruling);
        Address storage addr = addresses[disputeIDToAddress[_disputeID]];
        Request storage request = addr.requests[addr.requests.length - 1];
        Round storage round = request.rounds[request.rounds.length - 1];

        // Ruling may be inverted depending on the amount of fee contributions received by each side.
        // Rule in favor of the party that received more contributions if there were contributions, respect the ruling otherwise.
        // If the required amount for a party was never set, it means that side never received a contribution.
        if (round.requiredForSideSet[uint(Party.Requester)] && round.requiredForSideSet[uint(Party.Challenger)]) {
            // Both parties received contributions for an appeal.
            if (resultRuling == RulingOption.Other) {
                // Rule in favor of the requester if he received more or the same amount of contributions as the challenger. Rule in favor of the challenger otherwise.
                if (round.paidFees[uint(Party.Requester)] >= round.paidFees[uint(Party.Challenger)])
                    resultRuling = RulingOption.Accept;
                else
                    resultRuling = RulingOption.Refuse;
            } else {
                // Invert ruling if the loser fully funded but the winner did not.
                Party winner;
                Party loser;
                if (resultRuling == RulingOption.Accept) {
                    winner = Party.Requester;
                    loser = Party.Challenger;
                } else if (resultRuling == RulingOption.Refuse) {
                    winner = Party.Challenger;
                    loser = Party.Requester;
                }
                if (round.paidFees[uint(loser)] >= round.requiredForSide[uint(loser)]) {
                    if (resultRuling == RulingOption.Refuse)
                        resultRuling = RulingOption.Accept;
                    else
                        resultRuling = RulingOption.Refuse;
                }
            }
        } else if (round.requiredForSideSet[uint(Party.Requester)] || round.requiredForSideSet[uint(Party.Challenger)]) {
            // A party received a contribution but the other did not.
            // Rule in favor of the party that received the contribution.
            if (round.requiredForSideSet[uint(Party.Requester)])
                resultRuling = RulingOption.Accept;
            else
                resultRuling = RulingOption.Refuse;
        }

        emit Ruling(Arbitrator(msg.sender), _disputeID, uint(resultRuling));
        executeRuling(_disputeID, uint(resultRuling));
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(address _address, string _evidence) external {
        Address storage addr = addresses[_address];
        Request storage request = addr.requests[addr.requests.length - 1];
        require(request.disputed, "The request is not disputed.");
        require(!request.resolved, "The dispute was resolved.");

        emit Evidence(arbitrator, request.disputeID, msg.sender, _evidence);
    }

    // ************************ //
    // *      Governance      * //
    // ************************ //

    /** @dev Change the duration of the challenge period.
     *  @param _challengePeriodDuration The new duration of the challenge period.
     */
    function changeTimeToChallenge(uint _challengePeriodDuration) external onlyGovernor {
        challengePeriodDuration = _challengePeriodDuration;
    }

    /** @dev Change the required amount required as deposit to make or challenge a request.
     *  @param _challengeReward The new amount of wei required to make or challenge a request.
     */
    function changeChallengeReward(uint _challengeReward) external onlyGovernor {
        challengeReward = _challengeReward;
    }

    /** @dev Change the governor of the Token Curated List.
     *  @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /** @dev Change duration of the arbitration fees funding period.
     *  @param _arbitrationFeesWaitingTime The new duration of the arbitration fees funding period in seconds.
     */
    function changeArbitrationFeesWaitingTime(uint _arbitrationFeesWaitingTime) external onlyGovernor {
        arbitrationFeesWaitingTime = _arbitrationFeesWaitingTime;
    }

    /** @dev Change the percentage of arbitration fees that must be paid as fee stake by parties when there wasn't a winner or loser in the previous round.
     *  @param _sharedStakeMultiplier The new percentage of arbitration fees that must be paid as fee stake with 2 digits precision (e.g. a value of 1000 will result in 10% of the arbitration fees required in that round).
     */
    function changeSharedStakeMultiplier(uint _sharedStakeMultiplier) external onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Change the percentage of arbitration fees that must be paid as fee stake by winner of the previous round.
     *  @param _winnerStakeMultiplier The new percentage of arbitration fees that must be paid as fee stake with 2 digits precision (e.g. a value of 5000 will result in 50% of the arbitration fees required in that round).
     */
    function changeWinnerStakeMultiplier(uint _winnerStakeMultiplier) external onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Change the percentage of arbitration fees that must be paid as fee stake by party that lost the previous round.
     *  @param _loserStakeMultiplier The new percentage of arbitration fees that must be paid as fee stake with 2 digits precision (e.g. a value of 10000 will result in 100% of the arbitration fees required in that round).
     */
    function changeLoserStakeMultiplier(uint _loserStakeMultiplier) external onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Change the arbitrator to be used for disputes in the next requests.
     *  @param _arbitrator The new trusted arbitrator to be used in the next requests.
     *  @param _arbitratorExtraData The extra data used by the new arbitrator.
     */
    function changeArbitrator(
        Arbitrator _arbitrator,
        bytes _arbitratorExtraData
    ) external onlyGovernor {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /* Public Views */

    /** @dev Return true if the address is on the list.
     *  @param _value The address to be queried.
     *  @return allowed True if the address is allowed, false otherwise.
     */
    function isPermitted(bytes32 _value) external view returns (bool allowed) {
        Address storage addr = addresses[address(_value)];
        return addr.status == AddressStatus.Registered || addr.status == AddressStatus.ClearingRequested;
    }

    /** @dev Returns address information. Includes length of requests array.
     *  @param _address The queried address.
     *  @return The address information.
     */
    function getAddressInfo(address _address)
        external
        view
        returns (
            AddressStatus status,
            uint numberOfRequests
        )
    {
        Address storage addr = addresses[_address];
        return (addr.status, addr.numberOfRequests);
    }

    /** @dev Gets information on a request made for an address.
     *  @param _address The queried address
     *  @param _request The request to be queried.
     *  @return The request information.
     */
    function getRequestInfo(address _address, uint _request)
        external
        view
        returns (
            bool disputed,
            uint disputeID,
            uint submissionTime,
            uint challengeRewardBalance,
            uint challengerDepositTime,
            bool resolved,
            address[3] parties,
            uint numberOfRounds,
            RulingOption ruling,
            Arbitrator arbitrator,
            bytes arbitratorExtraData
        )
    {
        Request storage request = addresses[_address].requests[_request];
        return (
            request.disputed,
            request.disputeID,
            request.submissionTime,
            request.challengeRewardBalance,
            request.challengerDepositTime,
            request.resolved,
            request.parties,
            request.rounds.length,
            request.ruling,
            request.arbitrator,
            request.arbitratorExtraData
        );
    }

    /** @dev Gets the information on a round of a request.
     *  @param _address The queried address.
     *  @param _request The request to be queried.
     *  @param _round The round to be queried.
     *  @return The round information.
     */
    function getRoundInfo(address _address, uint _request, uint _round)
        external
        view
        returns (
            bool appealed,
            uint oldWinnerTotalCost,
            uint[3] paidFees,
            uint[3] requiredForSide,
            uint feeRewards
        )
    {
        Address storage addr = addresses[_address];
        Request storage request = addr.requests[_request];
        Round storage round = request.rounds[_round];
        return (
            round.appealed,
            round.oldWinnerTotalCost,
            round.paidFees,
            round.requiredForSide,
            round.feeRewards
        );
    }

    /** @dev Gets the contributions made by a party for a given request.
     *  @param _address The address to be queried.
     *  @param _request The position of the request.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @return The contributions.
     */
    function getContributions(
        address _address,
        uint _request,
        uint _round,
        address _contributor
    ) external view returns(uint[3] contributions) {
        Address storage addr = addresses[_address];
        Request storage request = addr.requests[_request];
        Round storage round = request.rounds[_round];
        contributions = round.contributions[_contributor];
    }

    /** @dev Return the numbers of addresses that were submitted. Includes addresses that never made it to the list or were later removed.
     *  @return The numbers of addresses in the list.
     */
    function addressCount() external view returns (uint count) {
        return addressList.length;
    }

    /* Internal */

    /**
     *  @dev Execute the ruling of a dispute.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function executeRuling(uint _disputeID, uint _ruling) internal {
        Address storage addr = addresses[disputeIDToAddress[_disputeID]];
        Request storage request = addr.requests[addr.requests.length - 1];

        Party winner;
        if (RulingOption(_ruling) == RulingOption.Accept)
            winner = Party.Requester;
        else if (RulingOption(_ruling) == RulingOption.Refuse)
            winner = Party.Challenger;

        // Update address state
        if (winner == Party.Requester) // Execute Request
            if (addr.status == AddressStatus.RegistrationRequested)
                addr.status = AddressStatus.Registered;
            else
                addr.status = AddressStatus.Absent;
        else // Revert to previous state.
            if (addr.status == AddressStatus.RegistrationRequested)
                addr.status = AddressStatus.Absent;
            else if (addr.status == AddressStatus.ClearingRequested)
                addr.status = AddressStatus.Registered;

        // Send challenge reward.
        // Deliberate use of send in order to not block the contract in case of reverting fallback.
        if (winner == Party.Challenger)
            request.parties[uint(Party.Challenger)].send(request.challengeRewardBalance);
        else if (winner == Party.Requester)
            request.parties[uint(Party.Requester)].send(request.challengeRewardBalance);
        else {
            // Reimburse parties.
            request.parties[uint(Party.Requester)].send(request.challengeRewardBalance / 2);
            request.parties[uint(Party.Challenger)].send(request.challengeRewardBalance / 2);
        }

        request.challengeRewardBalance = 0;
        request.resolved = true;
        request.ruling = RulingOption(_ruling);

        emit AddressStatusChange(
            request.parties[uint(Party.Requester)],
            request.parties[uint(Party.Challenger)],
            disputeIDToAddress[_disputeID],
            addr.status,
            request.disputed,
            false
        );
    }

     /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return The amount of ETH taken.
     *  @return The amount of ETH left from the contribution.
     */
    function calculateContribution(uint _available, uint _requiredAmount)
        internal
        pure
        returns(uint taken, uint remainder)
    {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    /* Interface Views */

    /** @dev Return the numbers of addresses with each status. This function is O(n) at worst, where n is the number of addresses. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @return The numbers of addresses in the list per status.
     */
    function countByStatus()
        external
        view
        returns (
            uint absent,
            uint registered,
            uint registrationRequest,
            uint clearingRequest,
            uint challengedRegistrationRequest,
            uint challengedClearingRequest
        )
    {
        for (uint i = 0; i < addressList.length; i++) {
            Address storage addr = addresses[addressList[i]];
            Request storage request = addr.requests[addr.requests.length - 1];

            if (addr.status == AddressStatus.Absent) absent++;
            else if (addr.status == AddressStatus.Registered) registered++;
            else if (addr.status == AddressStatus.RegistrationRequested && !request.disputed) registrationRequest++;
            else if (addr.status == AddressStatus.ClearingRequested && !request.disputed) clearingRequest++;
            else if (addr.status == AddressStatus.RegistrationRequested && request.disputed) challengedRegistrationRequest++;
            else if (addr.status == AddressStatus.ClearingRequested && request.disputed) challengedClearingRequest++;
        }
    }

    /** @dev Return the addresses the query finds. This function is O(n) at worst, where n is the number of addresses. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _cursor The address from which to start iterating. To start from either the oldest or newest item.
     *  @param _count The number of addresses to return.
     *  @param _filter The filter to use. Each element of the array in sequence means:
     *  - Include absent addresses in result.
     *  - Include registered addresses in result.
     *  - Include addresses with registration requests that are not disputed in result.
     *  - Include addresses with clearing requests that are not disputed in result.
     *  - Include disputed addresses with registration requests in result.
     *  - Include disputed addresses with clearing requests in result.
     *  - Include addresses submitted by the caller.
     *  - Include addresses challenged by the caller.
     *  @param _oldestFirst Whether to sort from oldest to the newest item.
     *  @return The addresses found and whether there are more addresses for the current filter and sort.
     */
    function queryAddresses(address _cursor, uint _count, bool[8] _filter, bool _oldestFirst)
        external
        view
        returns (address[] values, bool hasMore)
    {
        uint cursorIndex;
        values = new address[](_count);
        uint index = 0;

        if (_cursor == 0)
            cursorIndex = 0;
        else {
            for (uint j = 0; j < addressList.length; j++) {
                if (addressList[j] == _cursor) {
                    cursorIndex = j;
                    break;
                }
            }
            require(cursorIndex != 0, "The cursor is invalid.");
        }

        for (
                uint i = cursorIndex == 0 ? (_oldestFirst ? 0 : 1) : (_oldestFirst ? cursorIndex + 1 : addressList.length - cursorIndex + 1);
                _oldestFirst ? i < addressList.length : i <= addressList.length;
                i++
            ) { // Oldest or newest first.
            Address storage addr = addresses[addressList[_oldestFirst ? i : addressList.length - i]];
            Request storage request = addr.requests[addr.requests.length - 1];
            if (
                /* solium-disable operator-whitespace */
                (_filter[0] && addr.status == AddressStatus.Absent) ||
                (_filter[1] && addr.status == AddressStatus.Registered) ||
                (_filter[2] && addr.status == AddressStatus.RegistrationRequested && !request.disputed) ||
                (_filter[3] && addr.status == AddressStatus.ClearingRequested && !request.disputed) ||
                (_filter[4] && addr.status == AddressStatus.RegistrationRequested && request.disputed) ||
                (_filter[5] && addr.status == AddressStatus.ClearingRequested && request.disputed) ||
                (_filter[6] && request.parties[uint(Party.Requester)]== msg.sender) || // My Submissions.
                (_filter[7] && request.parties[uint(Party.Challenger)]== msg.sender) // My Challenges.
                /* solium-enable operator-whitespace */
            ) {
                if (index < _count) {
                    values[index] = addressList[_oldestFirst ? i : addressList.length - i];
                    index++;
                } else {
                    hasMore = true;
                    break;
                }
            }
        }
    }
}
