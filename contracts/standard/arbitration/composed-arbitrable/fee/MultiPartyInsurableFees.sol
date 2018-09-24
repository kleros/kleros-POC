pragma solidity ^0.4.24;

import "../agreement/MultiPartyAgreements.sol";

/**
 *  @title MultiPartyInsurableFees
 *  @author Enrique Piqueras - <epiquerass@gmail.com>
 *  @dev Fee part of a composed arbitrable contract. Handles crowdinsured arbitration and appeal fees.
 */
contract MultiPartyInsurableFees is MultiPartyAgreements {
    /* Structs */

    struct PaidFees {
        uint firstContributionTime; // The time the first contribution was made at.
        uint[] stake; // The stake required in each round.
        uint[] totalValue; // The current held value in each round.
        uint[2][] totalContributedPerSide; // The total amount contributed per side in each round.
        mapping(address => uint)[] contributions; // The contributions in each round.
    }

    /* Events */

    /** @dev Emitted when a contribution is made.
     *  @param _agreementID The ID of the agreement that the contribution was made to.
     *  @param _round The round of the agreement that the contribution was made to.
     *  @param _contributor The address that sent the contribution.
     *  @param _value The value of the contribution.
     */
    event Contribution(bytes32 indexed _agreementID, uint indexed _round, address indexed _contributor, uint _value);

    /* Storage */

    address feeGovernor;
    uint public stake;
    mapping(bytes32 => PaidFees) internal paidFees;

    /* Constructor */

    /** @dev Constructs the `MultiPartyInsurableFees` contract.
     *  @param _feeGovernor The governor of this contract.
     *  @param _stake The stake parameter for sharing fees.
     */
    constructor(address _feeGovernor, uint _stake) public {
        feeGovernor = _feeGovernor;
        stake = _stake;
    }

    /* External */

    /** @dev Changes the `feeGovernor` storage variable.
     *  @param _feeGovernor The new `feeGovernor` storage variable.
     */
    function changeFeeGovernor(address _feeGovernor) external {
        require(msg.sender == feeGovernor, "The caller is not the fee governor.");
        feeGovernor = _feeGovernor;
    }

    /** @dev Changes the `stake` storage variable.
     *  @param _stake The new `stake` storage variable.
     */
    function changeStake(uint _stake) external {
        require(msg.sender == feeGovernor, "The caller is not the fee governor.");
        stake = _stake;
    }

    /** @dev Funds the specified side of a dispute for the specified agreement or times out the dispute if it is taking too long to fund.
     *  @param _agreementID The ID of the agreement.
     *  @param _side The side. 0 for the side that lost the previous round, if any, and 1 for the one that won.
     */
    function fundDispute(bytes32 _agreementID, uint _side) external payable {
        Agreement storage agreement = agreements[_agreementID];
        PaidFees storage _paidFees = paidFees[_agreementID];
        require(
            !agreement.disputed || agreement.arbitrator.disputeStatus(agreement.disputeID) == Arbitrator.DisputeStatus.Appealable,
            "The agreement is already disputed and is not appealable."
        );
        require(_side <= 1, "There are only two sides.");
        require(msg.value > 0, "The value of the contribution cannot be zero.");

        // Prepare storage for first call.
        if (_paidFees.firstContributionTime == 0) {
            _paidFees.firstContributionTime = now;
            _paidFees.stake.push(stake);
            _paidFees.totalValue.push(0);
            _paidFees.totalContributedPerSide.push([0, 0]);
            _paidFees.contributions.length++;
        }

        // Check time outs and requirements.
        uint _cost;
        if (_paidFees.stake.length == 1) { // First round.
            _cost = agreement.arbitrator.arbitrationCost(agreement.extraData);

            // Arbitration fees time out.
            if (now - _paidFees.firstContributionTime > agreement.arbitrationFeesWaitingTime) {
                executeAgreementRuling(_agreementID, 0);
                return;
            }
        } else { // Appeal.
            _cost = agreement.arbitrator.appealCost(agreement.disputeID, agreement.extraData);

            bool _appealing = true;
            (uint _appealPeriodStart, uint _appealPeriodEnd) = agreement.arbitrator.appealPeriod(agreement.disputeID);
            bool _appealPeriodSupported = _appealPeriodStart != 0 && _appealPeriodEnd != 0;
            if (_appealPeriodSupported) {
                if (now < _appealPeriodStart + ((_appealPeriodEnd - _appealPeriodStart) / 2)) // In the first half of the appeal period.
                    require(_side == 0, "It is the losing side's turn to fund the appeal.");
                else // In the second half of the appeal period.
                    require(
                        _side == 1 && _paidFees.totalContributedPerSide[_paidFees.totalContributedPerSide.length - 1][0] > 0,
                        "It is the winning side's turn to fund the appeal, only if the losing side already funded it."
                    );
            } else require(msg.value >= _cost, "Fees must be paid in full if the arbitrator does not support `appealPeriod`.");
        }

        // Compute required values for each side.
        uint[2] memory _valueRequiredPerSide;
        if (!_appealing) { // First round.
            _valueRequiredPerSide[0] = _cost / 2;
            _valueRequiredPerSide[1] = _valueRequiredPerSide[0];
        } else { // Appeal.
            _valueRequiredPerSide[0] = _cost + (2 * stake);
            _valueRequiredPerSide[1] = _cost + stake;
        }

        // Take contribution.
        uint _valueStillRequiredForSide;
        if (_paidFees.totalContributedPerSide[_paidFees.totalContributedPerSide.length - 1][_side] >= _valueRequiredPerSide[_side])
            _valueStillRequiredForSide = 0;
        else 
            _valueStillRequiredForSide = _valueRequiredPerSide[_side] - _paidFees.totalContributedPerSide[_paidFees.totalContributedPerSide.length - 1][_side];
        uint _keptValue = _valueStillRequiredForSide >= msg.value ? msg.value : _valueStillRequiredForSide;
        uint _refundedValue = msg.value - _keptValue;
        if (_keptValue > 0) {
            _paidFees.totalValue[_paidFees.totalValue.length - 1] += _keptValue;
            _paidFees.totalContributedPerSide[_paidFees.totalContributedPerSide.length - 1][_side] += _keptValue;
            _paidFees.contributions[_paidFees.contributions.length - 1][msg.sender] += _keptValue;
        }
        if (_refundedValue > 0) msg.sender.transfer(_refundedValue);

        // Check if enough funds have been gathered and act accordingly.
        if (
            (_paidFees.totalContributedPerSide[_paidFees.totalContributedPerSide.length - 1][0] >= _valueRequiredPerSide[0] && _paidFees.totalContributedPerSide[_paidFees.totalContributedPerSide.length - 1][1] >= _valueRequiredPerSide[1]) ||
            (_appealing && !_appealPeriodSupported)
            ) {
            if (!_appealing) { // First round.
                agreement.disputeID = agreement.arbitrator.createDispute.value(_cost)(agreement.numberOfChoices, agreement.extraData);
                agreement.disputed = true;
            } else { // Appeal.
                agreement.arbitrator.appeal.value(_cost)(agreement.disputeID, agreement.extraData);
                if (!agreement.appealed) agreement.appealed = true;
            }

            // Update the total value.
            _paidFees.totalValue[_paidFees.totalValue.length - 1] -= _cost;

            // Prepare for the next round.
            _paidFees.stake.push(stake);
            _paidFees.totalValue.push(0);
            _paidFees.totalContributedPerSide.push([0, 0]);
            _paidFees.contributions.length++;
        }
    }

    /* External Views */

    /** @dev Gets the info on fees paid for the specified round of the specified agreement.
     *  @param _agreementID The ID of the agreement.
     *  @param _round The round.
     */
    function getRoundInfo(
        bytes32 _agreementID,
        uint _round
    ) external view returns(uint roundStake, uint roundTotalValue, uint[2] roundTotalContributedPerSide) {
        PaidFees storage _paidFees = paidFees[_agreementID];
        roundStake = _paidFees.stake[_round];
        roundTotalValue = _paidFees.totalValue[_round];
        roundTotalContributedPerSide = _paidFees.totalContributedPerSide[_round];
    }

    /** @dev Gets the value contributed by the specified contributor in the specified round of the specified agreement.
     *  @param _agreementID The ID of the agreement.
     *  @param _round The round.
     *  @param _contributor The address of the contributor.
     */
    function getContribution(bytes32 _agreementID, uint _round, address _contributor) external view returns(uint value) {
        value = paidFees[_agreementID].contributions[_round][_contributor];
    }

    /* Public */



    /* Public Views */



    /* Internal */



    /* Internal Views */



    /* Private */



    /* Private Views */



}
