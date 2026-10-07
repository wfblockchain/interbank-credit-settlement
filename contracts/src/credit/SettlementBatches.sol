// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ICrossChainHub } from "../interfaces/ICrossChainHub.sol";
import { IDefaultManager } from "../interfaces/IDefaultManager.sol";
import { IExposureLedger } from "../interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";
import { IObligationToken } from "../interfaces/IObligationToken.sol";
import { ISettlementBatches } from "../interfaces/ISettlementBatches.sol";
import { RfReference } from "./RfReference.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Net settlement batches (design §3.7). One batch in flight: a cut needs the previous
/// batch finalized. NONE → CUT → PLANNED → (PARTIAL) → COMPLETE, or PLANNED/PARTIAL → DEFAULTING →
/// COMPLETE. No function restores tokens or positions.
contract SettlementBatches is AccessControlDefaultAdminRules, ISettlementBatches {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    bytes32 public constant DEFAULT_MANAGER_ROLE = keccak256("DEFAULT_MANAGER_ROLE");

    uint8 public constant TRIGGER_CAP = 1;
    uint8 public constant TRIGGER_RECEIVER_CALL = 2;
    uint8 public constant TRIGGER_END_OF_DAY = 3;

    IMemberRegistry public immutable registry;
    IExposureLedger public immutable ledger;
    ICollateralRegister public immutable register;
    IDefaultManager public immutable defaultManager;

    uint64 public batchCount;
    mapping(uint64 => Batch) private _batches;
    mapping(uint64 => Leg[]) private _legs;
    mapping(uint64 => mapping(uint32 => uint256)) public overpaid;
    mapping(uint64 => mapping(uint32 => mapping(bytes32 => uint256))) public paidBy;

    /// The hub messenger (design §4.3); zero while no spoke is connected.
    ICrossChainHub public crossChain;

    constructor(
        uint48 adminDelay,
        address admin,
        address registry_,
        address ledger_,
        address register_,
        address attestor,
        address defaultManager_,
        address operator
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (
            registry_ == address(0) || ledger_ == address(0) || register_ == address(0) || attestor == address(0)
                || defaultManager_ == address(0) || operator == address(0)
        ) {
            revert ZeroAddress();
        }
        registry = IMemberRegistry(registry_);
        ledger = IExposureLedger(ledger_);
        register = ICollateralRegister(register_);
        defaultManager = IDefaultManager(defaultManager_);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(ATTESTOR_ROLE, attestor);
        _grantRole(DEFAULT_MANAGER_ROLE, defaultManager_);
    }

    function cut(uint8 trigger) external onlyRole(OPERATOR_ROLE) returns (uint64 b) {
        if (trigger < TRIGGER_CAP || trigger > TRIGGER_END_OF_DAY) {
            revert InvalidTrigger(trigger);
        }
        if (batchCount != 0 && !_batches[batchCount].finalized) {
            revert BatchOutstanding(batchCount);
        }
        uint256 total = register.poolTotal();
        uint256 required = register.poolRequired();
        if (total < required) {
            revert PoolNotReplenished(total, required);
        }
        (bytes32 hash, uint64 e) = ledger.snapshotForCut();
        b = ++batchCount;
        Batch storage bt = _batches[b];
        bt.epoch = e;
        bt.epochHash = hash;
        bt.trigger = trigger;
        bt.status = Status.CUT;
        bt.cutAt = uint64(block.timestamp);
        bt.businessDay = ledger.businessDay();
        emit BatchCut(b, e, hash);
        if (address(crossChain) != address(0)) {
            crossChain.broadcastCut(e);
        }
    }

    /// Wires the hub messenger: every later cut is broadcast to the spokes and its plan waits for
    /// their reports.
    function setCrossChain(address hub) external onlyRole(DEFAULT_ADMIN_ROLE) {
        crossChain = ICrossChainHub(hub);
        emit CrossChainSet(hub);
    }

    /// A receiver call: the operator answers with a cut (TRIGGER_RECEIVER_CALL).
    function requestSettlement() external {
        bytes32 id = registry.memberOfIssuerOps(msg.sender);
        if (id == bytes32(0)) {
            revert NotIssuerOps(msg.sender);
        }
        if (!registry.goodStanding(id)) {
            revert NotInGoodStanding(id);
        }
        emit SettlementRequested(id);
    }

    /// Accepts the plan iff, for every member, Σ legs in − Σ legs out equals its multilateral net
    /// position over the batch's pending pairs (home and remote).
    function submitPlan(uint64 b, Leg[] calldata legs_, uint64 deadline) external onlyRole(OPERATOR_ROLE) {
        Batch storage bt = _batch(b);
        if (bt.status != Status.CUT) {
            revert WrongStatus(b, bt.status);
        }
        if (deadline <= block.timestamp) {
            revert DeadlineInPast(deadline);
        }
        if (address(crossChain) != address(0) && !crossChain.spokesReported(bt.epoch)) {
            revert SpokesNotReported(bt.epoch);
        }
        ledger.sealBatch(bt.epoch);

        bytes32[] memory ids = registry.memberIds();
        int256[] memory net = new int256[](ids.length);
        (bytes32[] memory issuers, bytes32[] memory holders, uint256[] memory amounts) = ledger.pendingPairs(bt.epoch);
        for (uint256 k = 0; k < issuers.length; k++) {
            int256 a = SafeCast.toInt256(amounts[k]);
            net[_index(ids, holders[k])] += a;
            net[_index(ids, issuers[k])] -= a;
        }
        for (uint256 k = 0; k < legs_.length; k++) {
            Leg calldata l = legs_[k];
            if (l.payer == l.payee || l.amount == 0 || l.paid != 0) {
                revert InvalidLeg(k);
            }
            int256 a = SafeCast.toInt256(l.amount);
            net[_index(ids, l.payee)] -= a;
            net[_index(ids, l.payer)] += a;
            _legs[b].push(Leg({ payer: l.payer, payee: l.payee, amount: l.amount, paid: 0 }));
        }
        for (uint256 m = 0; m < ids.length; m++) {
            if (net[m] != 0) {
                revert PlanMismatch(ids[m]);
            }
        }
        bt.deadline = deadline;
        bt.unpaidLegs = uint32(legs_.length);
        bt.status = Status.PLANNED;
        emit PlanSubmitted(b, legs_.length, deadline);
        if (legs_.length == 0) {
            bt.status = Status.COMPLETE;
            emit BatchComplete(b);
        }
    }

    /// Called by the attestor after k-of-n signatures over a final rail payment.
    function recordPayment(Payment calldata p) external onlyRole(ATTESTOR_ROLE) {
        Batch storage bt = _batch(p.batch);
        Status s = bt.status;
        if (s != Status.PLANNED && s != Status.PARTIAL && s != Status.DEFAULTING) {
            revert WrongStatus(p.batch, s);
        }
        if (p.leg >= _legs[p.batch].length) {
            revert UnknownLeg(p.batch, p.leg);
        }
        Leg storage l = _legs[p.batch][p.leg];
        if (p.payee != l.payee) {
            revert WrongPayee(l.payee, p.payee);
        }
        if (p.payer == l.payee || (p.payer != l.payer && !defaultManager.allowedPayer(p.batch, p.leg, p.payer))) {
            revert WrongPayer(l.payer, p.payer);
        }
        bool wasPaid = l.paid >= l.amount;
        l.paid += p.amount;
        paidBy[p.batch][p.leg][p.payer] += p.amount;
        emit PaymentRecorded(p.batch, p.leg, p.rail, p.railTxId, p.payer, p.amount);
        if (l.paid > l.amount) {
            overpaid[p.batch][p.leg] = l.paid - l.amount;
            emit Overpaid(p.batch, p.leg, l.paid - l.amount);
        }
        _afterPayment(p.batch, bt, p.leg, wasPaid, l);
    }

    /// Pages the burns once COMPLETE. Home pairs burn here; remote pairs are burned on their
    /// spoke by BURN_BATCH (PairSettled with remote = true). Exposure is released only here.
    function finalize(uint64 b, uint256 maxPairs) external returns (uint256 settled) {
        Batch storage bt = _batch(b);
        if (bt.status != Status.COMPLETE) {
            revert WrongStatus(b, bt.status);
        }
        if (bt.finalized) {
            revert AlreadyFinalized(b);
        }
        uint256 total = ledger.pendingPairCount(bt.epoch);
        uint256 start = bt.cursor;
        settled = total - start;
        if (settled > maxPairs) {
            settled = maxPairs;
        }
        ledger.clearPending(bt.epoch, start, settled);
        for (uint256 k = start; k < start + settled; k++) {
            IExposureLedger.PendingPair memory pp = ledger.pendingPair(bt.epoch, k);
            if (!pp.remote) {
                IObligationToken(registry.member(pp.issuer).token).burn(registry.member(pp.holder).wallet, pp.amount);
                bt.burned += pp.amount;
            }
            emit PairSettled(b, pp.issuer, pp.holder, pp.amount, pp.remote);
        }
        bt.cursor = start + settled;
        if (bt.cursor == total) {
            bt.finalized = true;
            emit BatchFinalized(b, bt.burned);
        }
    }

    function markDefaulting(uint64 b) external onlyRole(DEFAULT_MANAGER_ROLE) {
        Batch storage bt = _batch(b);
        if (bt.status != Status.PLANNED && bt.status != Status.PARTIAL) {
            revert WrongStatus(b, bt.status);
        }
        if (block.timestamp <= bt.deadline) {
            revert DeadlineNotPassed(bt.deadline);
        }
        bt.status = Status.DEFAULTING;
        emit BatchDefaulting(b);
    }

    /// The payee's own pro-rata survivor share of a defaulter's leg: the payee bears it and the
    /// leg's remainder shrinks by it (nobody pays a leg to itself).
    function absorbLoss(uint64 b, uint32 legIndex, bytes32 member, uint256 amount)
        external
        onlyRole(DEFAULT_MANAGER_ROLE)
    {
        Batch storage bt = _batch(b);
        if (bt.status != Status.DEFAULTING) {
            revert WrongStatus(b, bt.status);
        }
        if (legIndex >= _legs[b].length) {
            revert UnknownLeg(b, legIndex);
        }
        Leg storage l = _legs[b][legIndex];
        if (member != l.payee) {
            revert NotPayee(member);
        }
        uint256 remainder = l.paid >= l.amount ? 0 : l.amount - l.paid;
        if (amount > remainder) {
            revert AbsorbExceedsRemainder(amount, remainder);
        }
        l.paid += amount;
        emit LossAbsorbed(b, legIndex, member, amount);
        _afterPayment(b, bt, legIndex, false, l);
    }

    // Views.

    function rfReference(uint64 b) external view returns (string memory) {
        _batch(b);
        return RfReference.forBatch(b);
    }

    function batch(uint64 b) external view returns (Batch memory) {
        return _batches[b];
    }

    function status(uint64 b) external view returns (Status) {
        return _batches[b].status;
    }

    function legCount(uint64 b) external view returns (uint256) {
        return _legs[b].length;
    }

    function leg(uint64 b, uint32 index) external view returns (Leg memory) {
        return _legs[b][index];
    }

    function legs(uint64 b) external view returns (Leg[] memory) {
        return _legs[b];
    }

    // Internals.

    function _afterPayment(uint64 b, Batch storage bt, uint32 legIndex, bool wasPaid, Leg storage l) private {
        if (!wasPaid && l.paid >= l.amount) {
            bt.unpaidLegs--;
            emit LegPaid(b, legIndex);
            if (bt.unpaidLegs == 0) {
                bt.status = Status.COMPLETE;
                emit BatchComplete(b);
                return;
            }
        }
        if (bt.status == Status.PLANNED) {
            bt.status = Status.PARTIAL;
            emit BatchPartial(b);
        }
    }

    function _batch(uint64 b) private view returns (Batch storage) {
        if (b == 0 || b > batchCount) {
            revert UnknownBatch(b);
        }
        return _batches[b];
    }

    /// registry.memberIds() holds every admitted member, whatever its status.
    function _index(bytes32[] memory ids, bytes32 id) private pure returns (uint256) {
        for (uint256 k = 0; k < ids.length; k++) {
            if (ids[k] == id) {
                return k;
            }
        }
        revert NotAMember(id);
    }
}
