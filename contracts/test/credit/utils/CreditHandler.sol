// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { ICollateralRegister } from "../../../src/interfaces/ICollateralRegister.sol";
import { IExposureLedger } from "../../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../../src/interfaces/IMemberRegistry.sol";
import { ISettlementBatches } from "../../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./CreditFixture.sol";

/// Random pays, drains, cuts, plans, attested payments, finalizes and limit changes over Bank A,
/// B and C. Checks the limits of every accepted payment independently of the ledger's caches and
/// counts what each run actually exercised.
contract CreditHandler is CreditFixture {
    // Coverage.
    uint256 public calls;
    uint256 public paysAccepted;
    uint256 public paysQueued;
    uint256 public paysReverted;
    uint256 public drained;
    uint256 public cuts;
    uint256 public plans;
    uint256 public paymentsAttested;
    uint256 public partialPayments;
    uint256 public overpayments;
    uint256 public completed;
    uint256 public finalized;
    uint256 public settledValue;
    uint256 public limitChanges;

    // Violations (must stay 0).
    uint256 public limitViolations;
    uint256 public queueMismatches;
    uint256 public burnMismatches;
    uint256 public attestMismatches;

    mapping(uint64 => uint256) public attestedSum;
    mapping(uint64 => uint256) public actualBurned;

    constructor() {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
    }

    // ------------------------------------------------------------ actions

    function pay(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        calls++;
        (bytes32 from, bytes32 to) = _pair(fromSeed, toSeed);
        amount = bound(amount, 1, 30 * MN);
        uint8 expected = _expectedReason(from, to, amount);
        uint256 qBefore = ledger.queueLength();
        bytes32 ref = bytes32(calls);
        vm.recordLogs();
        vm.prank(ops[from]);
        try ledger.pay(to, amount, ref) {
            if (ledger.queueLength() > qBefore) {
                paysQueued++;
                if (expected == 0) {
                    queueMismatches++;
                }
            } else {
                paysAccepted++;
                if (expected != 0) {
                    queueMismatches++;
                }
            }
        } catch {
            paysReverted++;
        }
        _checkPaid();
    }

    /// A payment sized inside the current headroom of a random pair, so every run moves money.
    function payWithinLimits(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        calls++;
        (bytes32 from, bytes32 to) = _pair(fromSeed, toSeed);
        if (!registry.goodStanding(from) || !registry.goodStanding(to)) {
            return;
        }
        uint256 room = _headroom(from, to);
        if (room == 0) {
            return;
        }
        amount = bound(amount, 1, room);
        if (_expectedReason(from, to, amount) != 0) {
            queueMismatches++;
            return;
        }
        uint256 qBefore = ledger.queueLength();
        vm.recordLogs();
        vm.prank(ops[from]);
        ledger.pay(to, amount, bytes32(calls));
        if (ledger.queueLength() != qBefore) {
            queueMismatches++;
        }
        paysAccepted++;
        _checkPaid();
    }

    function drain(uint256 max) public {
        calls++;
        vm.recordLogs();
        ledger.drain(bound(max, 1, 10));
        drained += _checkPaid();
    }

    function cut(uint8 trigger) public {
        calls++;
        if (!_canCut()) {
            return;
        }
        // An empty epoch still cuts (that path is tested), but first try to
        // put value in it, so a run cannot finalize only empty batches.
        if (ledger.epochHash() == bytes32(0)) {
            payWithinLimits(uint256(trigger) * 7 + calls, uint256(trigger) * 13 + 1, uint256(trigger) << 40);
        }
        vm.prank(operator);
        batches.cut(uint8(bound(trigger, 1, 3)));
        cuts++;
    }

    function plan() public {
        calls++;
        uint64 b = batches.batchCount();
        if (b == 0 || batches.status(b) != ISettlementBatches.Status.CUT) {
            return;
        }
        _submitPlan(b);
        plans++;
        if (batches.status(b) == ISettlementBatches.Status.COMPLETE) {
            completed++;
        }
    }

    function payLeg(uint256 legSeed, uint256 fracSeed, uint256 railSeed) public {
        calls++;
        uint64 b = batches.batchCount();
        if (b == 0) {
            return;
        }
        ISettlementBatches.Status s = batches.status(b);
        if (s != ISettlementBatches.Status.PLANNED && s != ISettlementBatches.Status.PARTIAL) {
            return;
        }
        uint256 n = batches.legCount(b);
        uint32 k = uint32(legSeed % n);
        for (uint256 i = 0; i < n; i++) {
            ISettlementBatches.Leg memory l = batches.leg(b, k);
            if (l.paid < l.amount) {
                break;
            }
            k = uint32((k + 1) % n);
        }
        ISettlementBatches.Leg memory leg = batches.leg(b, k);
        uint256 rem = leg.amount - leg.paid;
        uint256 amt = rem;
        if (fracSeed % 4 == 0) {
            amt = bound(fracSeed, 1, rem);
        } else if (fracSeed % 10 == 1) {
            amt = rem + bound(fracSeed, 1, 1 * MN);
        }
        uint8 rail = railSeed % 2 == 0 ? CHIPS : RTP;
        if (rail == RTP && amt > 10 * MN) {
            amt = 10 * MN;
        }
        _record(b, k, rail, leg, amt);
    }

    function finalize(uint256 maxPairs) public {
        calls++;
        uint64 b = batches.batchCount();
        if (b == 0 || batches.status(b) != ISettlementBatches.Status.COMPLETE || batches.batch(b).finalized) {
            return;
        }
        _finalize(b, bound(maxPairs, 1, 4));
    }

    /// Moves the batch lifecycle one step, so every run reaches completed settlements.
    function advance(uint256 seed) public {
        calls++;
        uint64 b = batches.batchCount();
        ISettlementBatches.Status s = b == 0 ? ISettlementBatches.Status.NONE : batches.status(b);
        if (_canCut()) {
            vm.prank(operator);
            batches.cut(uint8(bound(seed, 1, 3)));
            cuts++;
        } else if (s == ISettlementBatches.Status.CUT) {
            _submitPlan(b);
            plans++;
            if (batches.status(b) == ISettlementBatches.Status.COMPLETE) {
                completed++;
            }
        } else if (s == ISettlementBatches.Status.PLANNED || s == ISettlementBatches.Status.PARTIAL) {
            for (uint32 k = 0; k < batches.legCount(b); k++) {
                ISettlementBatches.Leg memory leg = batches.leg(b, k);
                if (leg.paid < leg.amount) {
                    _record(b, k, CHIPS, leg, leg.amount - leg.paid);
                    break;
                }
            }
        } else if (s == ISettlementBatches.Status.COMPLETE) {
            _finalize(b, 100);
        }
    }

    function setElective(uint256 gSeed, uint256 dSeed, uint256 amount) public {
        calls++;
        (bytes32 g, bytes32 d) = _pair(gSeed, dSeed);
        _elective(g, d, bound(amount, 0, 100 * MN));
        limitChanges++;
    }

    function setReceiverCap(uint256 seed, uint256 cap) public {
        calls++;
        bytes32 id = banks[seed % 3];
        cap = bound(cap, 10 * MN, 150 * MN);
        vm.prank(gov);
        limits.setReceiverCap(id, cap);
        limitChanges++;
    }

    function setSystemMax(uint256 value) public {
        calls++;
        value = bound(value, 20 * MN, 1_000 * MN);
        vm.prank(gov);
        limits.setSystemMax(value);
        limitChanges++;
    }

    function setRegCap(uint256 gSeed, uint256 dSeed, uint256 cap, bool clear) public {
        calls++;
        (bytes32 g, bytes32 d) = _pair(gSeed, dSeed);
        vm.prank(ops[g]);
        if (clear) {
            limits.clearRegCap(d, bytes32("LIFT"));
        } else {
            limits.setRegCap(d, bound(cap, 0, 100 * MN), bytes32("SCCL"));
        }
        limitChanges++;
    }

    function toggleRestricted(uint256 seed) public {
        calls++;
        bytes32 id = banks[seed % 3];
        if (limits.restricted(id)) {
            vm.prank(gov);
            limits.unrestrict(id);
        } else {
            vm.prank(guardian);
            limits.restrict(id);
        }
        limitChanges++;
    }

    /// At most one bank is suspended at a time.
    function toggleSuspended(uint256 seed) public {
        calls++;
        for (uint256 i = 0; i < 3; i++) {
            if (registry.member(banks[i]).status == IMemberRegistry.Status.SUSPENDED) {
                vm.prank(gov);
                registry.reinstate(banks[i]);
                return;
            }
        }
        vm.prank(guardian);
        registry.suspend(banks[seed % 3], bytes32("TEST"));
    }

    function toggleWindow(uint256 seed, uint256 prefund) public {
        calls++;
        if (ledger.window() == IExposureLedger.Window.BUSINESS) {
            _window(IExposureLedger.Window.OFF_HOURS);
            for (uint256 i = 0; i < 3; i++) {
                uint256 v = uint256(keccak256(abi.encode(seed, prefund, i))) % (50 * MN);
                _fund(ICollateralRegister.Kind.RTP_PREFUND, banks[i], v);
            }
        } else {
            _window(IExposureLedger.Window.BUSINESS);
        }
    }

    /// A new business day opens the business window.
    function nextDay(uint256 secs) public {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, 1 days));
        uint64 day = ledger.businessDay() + 1;
        vm.prank(operator);
        ledger.setBusinessDay(day);
        if (ledger.window() == IExposureLedger.Window.OFF_HOURS) {
            _window(IExposureLedger.Window.BUSINESS);
        }
    }

    // ------------------------------------------------------------ invariant views

    /// Per issuer: totalSupply = Σ open + Σ pending; per pair: holder balance = open + pending.
    function supplyMatchesPositions() external view returns (bool) {
        for (uint256 i = 0; i < 3; i++) {
            bytes32 iss = banks[i];
            uint256 sum;
            for (uint256 j = 0; j < 3; j++) {
                bytes32 h = banks[j];
                uint256 pos = ledger.open(iss, h) + ledger.pending(iss, h);
                if (tok[iss].balanceOf(wallet[h]) != pos) {
                    return false;
                }
                sum += pos;
            }
            if (tok[iss].totalSupply() != sum) {
                return false;
            }
        }
        return true;
    }

    /// The ledger's running gross sums match a recomputation, and net positions sum to zero.
    function positionsConsistent() external view returns (bool) {
        int256 total;
        for (uint256 i = 0; i < 3; i++) {
            int256 n = _net(banks[i]);
            if (n != ledger.netPosition(banks[i])) {
                return false;
            }
            total += n;
        }
        return total == 0;
    }

    /// pendingEpoch is set exactly while the latest batch is not finalized.
    function oneBatchInFlight() external view returns (bool) {
        uint64 b = batches.batchCount();
        bool inFlight = b != 0 && !batches.batch(b).finalized;
        return inFlight == (ledger.pendingEpoch() != 0);
    }

    // ------------------------------------------------------------ internals

    function _record(uint64 b, uint32 k, uint8 rail, ISettlementBatches.Leg memory leg, uint256 amt) internal {
        ISettlementBatches.Status before = batches.status(b);
        _attest(_payment(b, k, rail, leg.payer, leg.payee, amt));
        attestedSum[b] += amt;
        paymentsAttested++;
        if (amt < leg.amount - leg.paid) {
            partialPayments++;
        } else if (amt > leg.amount - leg.paid) {
            overpayments++;
        }
        if (before != ISettlementBatches.Status.COMPLETE && batches.status(b) == ISettlementBatches.Status.COMPLETE) {
            completed++;
        }
    }

    /// Measures the real supply change, independent of the batch's own `burned` counter.
    function _finalize(uint64 b, uint256 maxPairs) internal {
        uint256 before = _totalSupply();
        batches.finalize(b, maxPairs);
        actualBurned[b] += before - _totalSupply();
        _afterFinalize(b);
    }

    function _totalSupply() internal view returns (uint256 t) {
        for (uint256 i = 0; i < 3; i++) {
            t += tok[banks[i]].totalSupply();
        }
    }

    function _afterFinalize(uint64 b) internal {
        ISettlementBatches.Batch memory bt = batches.batch(b);
        if (!bt.finalized) {
            return;
        }
        finalized++;
        uint256 home;
        uint256 n = ledger.pendingPairCount(bt.epoch);
        for (uint256 k = 0; k < n; k++) {
            IExposureLedger.PendingPair memory p = ledger.pendingPair(bt.epoch, k);
            if (!p.remote) {
                home += p.amount;
            }
        }
        if (bt.burned != home || actualBurned[b] != home) {
            burnMismatches++;
        }
        settledValue += bt.burned;
        // Attested value = Σ leg amounts + recorded overpayments.
        ISettlementBatches.Leg[] memory legs = batches.legs(b);
        uint256 owed;
        uint256 over;
        for (uint32 k = 0; k < legs.length; k++) {
            owed += legs[k].amount;
            over += batches.overpaid(b, k);
            if (legs[k].paid < legs[k].amount) {
                attestMismatches++;
            }
        }
        if (attestedSum[b] != owed + over) {
            attestMismatches++;
        }
    }

    function _canCut() internal view returns (bool) {
        uint64 b = batches.batchCount();
        return b == 0 || batches.batch(b).finalized;
    }

    function _pair(uint256 a, uint256 b) internal view returns (bytes32 x, bytes32 y) {
        uint256 i = a % 3;
        uint256 j = b % 3;
        if (i == j) {
            j = (i + 1 + (b / 3) % 2) % 3;
        }
        x = banks[i];
        y = banks[j];
    }

    function _net(bytes32 m) internal view returns (int256 n) {
        for (uint256 j = 0; j < 3; j++) {
            n += int256(ledger.gross(banks[j], m));
            n -= int256(ledger.gross(m, banks[j]));
        }
    }

    /// The largest amount that passes checks (2)–(5) for from → to.
    function _headroom(bytes32 from, bytes32 to) internal view returns (uint256 room) {
        int256 a = int256(ledger.gross(to, from)) - int256(ledger.gross(from, to)) + int256(limits.bilateralLimit(to, from));
        int256 r = int256(limits.receiverCap(to)) - _net(to);
        int256 d = int256(limits.debitCap(from)) + _net(from);
        int256 m = a < r ? a : r;
        m = m < d ? m : d;
        if (m <= 0) {
            return 0;
        }
        room = uint256(m);
        if (ledger.window() == IExposureLedger.Window.OFF_HOURS) {
            uint256 pre = register.rtpPrefund(from);
            uint256 used = ledger.offHoursUsed(from);
            uint256 w = pre > used ? pre - used : 0;
            room = room < w ? room : w;
        }
    }

    /// Checks (3)–(5) recomputed from gross positions and the limit views.
    function _expectedReason(bytes32 from, bytes32 to, uint256 amount) internal view returns (uint8) {
        uint256 a = ledger.gross(from, to) + amount;
        uint256 b = ledger.gross(to, from);
        if ((a > b ? a - b : 0) > limits.bilateralLimit(to, from)) {
            return 3;
        }
        if (_net(to) + int256(amount) > int256(limits.receiverCap(to))) {
            return 4;
        }
        if (int256(amount) - _net(from) > int256(limits.debitCap(from))) {
            return 5;
        }
        return 0;
    }

    /// For every Paid in the recorded logs, the post-state satisfies every limit. Later payments
    /// in the same call only lower the exposures checked here, so this holds iff each payment
    /// satisfied the limits when it was made.
    function _checkPaid() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(ledger) || logs[i].topics[0] != IExposureLedger.Paid.selector) {
                continue;
            }
            count++;
            bytes32 payer = logs[i].topics[2];
            bytes32 to = logs[i].topics[3];
            bool ok = registry.goodStanding(payer) && registry.goodStanding(to);
            ok = ok && ledger.bilateralNet(to, payer) <= limits.bilateralLimit(to, payer);
            ok = ok && _net(to) <= int256(limits.receiverCap(to));
            ok = ok && -_net(payer) <= int256(limits.debitCap(payer));
            if (ledger.window() == IExposureLedger.Window.OFF_HOURS) {
                ok = ok && ledger.offHoursUsed(payer) <= register.rtpPrefund(payer);
            }
            if (!ok) {
                limitViolations++;
            }
        }
    }
}
