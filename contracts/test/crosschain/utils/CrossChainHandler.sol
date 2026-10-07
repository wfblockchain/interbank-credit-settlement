// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { CrossChainMessenger } from "../../../src/crosschain/CrossChainMessenger.sol";
import { SpokeExposureGuard } from "../../../src/crosschain/SpokeExposureGuard.sol";
import { ICollateralRegister } from "../../../src/interfaces/ICollateralRegister.sol";
import { ICrossChainMessenger } from "../../../src/interfaces/ICrossChainMessenger.sol";
import { IExposureLedger } from "../../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../../src/interfaces/IMemberRegistry.sol";
import { ISettlementBatches } from "../../../src/interfaces/ISettlementBatches.sol";
import { ISpokeExposureGuard } from "../../../src/interfaces/ISpokeExposureGuard.sol";
import { CrossChainFixture } from "./CrossChainFixture.sol";

/// Random home pays, spoke pays, grants, releases, moves both ways, relays in random order,
/// deadline cancels, cuts, plans, legs, finalizes and burns, suspensions, forged and replayed
/// messages, over Bank A, B and C on the hub and both spokes. Tracks every token move and the
/// escrow it holds, checks each credit-taking action against the limits independently, and counts
/// what each run exercised.
contract CrossChainHandler is CrossChainFixture {
    struct Tracked {
        uint32 src;
        uint32 dst;
        uint64 nonce;
        bytes32 issuer;
        bytes32 holder;
        uint256 amount;
    }

    struct Sent {
        uint32 dest;
        bytes data;
    }

    // Coverage.
    uint256 public calls;
    uint256 public homePays;
    uint256 public spokePays;
    uint256 public spokeQueued;
    uint256 public spokeDrained;
    uint256 public spokeCancels;
    uint256 public grantsPerm;
    uint256 public grantsPub;
    uint256 public grantsRefused;
    uint256 public releases;
    uint256 public movesOut;
    uint256 public movesHome;
    uint256 public movesOutDone;
    uint256 public movesHomeDone;
    uint256 public movesCancelled;
    uint256 public mintsRefused;
    uint256 public expiries;
    uint256 public delivered;
    uint256 public cuts;
    uint256 public plans;
    uint256 public legsPaid;
    uint256 public finalized;
    uint256 public xBatches; // finalized batches with at least one remote pair
    uint256 public remoteBurns;
    uint256 public remoteBurnValue;
    uint256 public homeBurnValue;
    uint256 public suspends;
    uint256 public reinstates;
    uint256 public forgedRejected;
    uint256 public replaysRejected;

    // Violations (must stay 0).
    uint256 public limitViolations;
    uint256 public publicCollateralViolations;
    uint256 public forgedAccepted;
    uint256 public replayAccepted;
    uint256 public suspendRaised;
    uint256 public deliveryReverts;

    Tracked[] internal _tracked;
    Sent[] internal _delivered;
    bytes32 internal _suspendedMember;

    constructor() {
        vm.warp(1_760_000_000);
        _deployCrossChain();
        _standardLimits();
        for (uint256 i = 0; i < 3; i++) {
            // $40M each: $30M free for public envelopes and public moves.
            _fund(ICollateralRegister.Kind.COLLATERAL, banks[i], 40 * MN);
        }
    }

    // ------------------------------------------------------------ actions

    function homePay(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        calls++;
        (bytes32 from, bytes32 to) = _pair(fromSeed, toSeed);
        if (!registry.goodStanding(from) || !registry.goodStanding(to)) {
            return;
        }
        uint256 room = _headroom(from, to);
        if (room == 0) {
            return;
        }
        amount = bound(amount, 1, room < 20 * MN ? room : 20 * MN);
        vm.recordLogs();
        vm.prank(ops[from]);
        ledger.pay(to, amount, bytes32(calls));
        _afterAction();
        homePays++;
    }

    /// Mostly inside the pair's free envelope; one in four overshoots and queues. When no pair can
    /// pay, the hub first grants one an envelope (relayed at once), so every run pays on spokes.
    function spokePay(uint256 dSeed, uint256 pairSeed, uint256 amount) public {
        calls++;
        uint32 d = _domain(dSeed);
        SpokeExposureGuard g = guardOf[d];
        (bytes32 from, bytes32 to, bool found) = _scanPairs(pairSeed, d, _PICK_PAYABLE);
        if (!found) {
            (from, to, found) = _scanPairs(pairSeed, d, _PICK_ELIGIBLE);
            if (!found || !_grantNow(d, from, to, amount)) {
                return;
            }
        }
        uint256 avail = g.available(from, to);
        uint256 hi = amount % 4 == 0 ? avail + 5 * MN : avail;
        amount = bound(amount, 1, hi);
        uint256 qBefore = g.queueLength();
        _spokePay(d, from, to, amount);
        if (g.queueLength() > qBefore) {
            spokeQueued++;
        } else {
            spokePays++;
        }
    }

    function spokeDrain(uint256 dSeed) public {
        calls++;
        spokeDrained += guardOf[_domain(dSeed)].drain(5);
    }

    function spokeCancel(uint256 dSeed, uint256 seqSeed) public {
        calls++;
        SpokeExposureGuard g = guardOf[_domain(dSeed)];
        uint256 last = g.nextSeq() - 1;
        for (uint256 k = 0; k < last && k < 8; k++) {
            uint256 seq = 1 + (seqSeed % last + k) % last;
            ISpokeExposureGuard.QueueEntry memory e = g.queueEntry(seq);
            if (e.state == ISpokeExposureGuard.QueueState.QUEUED) {
                vm.prank(ops[e.payer]);
                g.cancel(seq);
                spokeCancels++;
                return;
            }
        }
    }

    function grant(uint256 dSeed, uint256 iSeed, uint256 hSeed, uint256 amount) public {
        calls++;
        uint32 d = _domain(dSeed);
        (bytes32 i, bytes32 h) = _pair(iSeed, hSeed);
        if (!registry.goodStanding(i) || !registry.goodStanding(h)) {
            return;
        }
        uint256 room;
        if (d == PERM) {
            room = _headroom(i, h);
        } else {
            room = register.freeCollateral(i);
        }
        if (room == 0) {
            return;
        }
        amount = bound(amount, 1, room < 15 * MN ? room : 15 * MN);
        uint256 freeBefore = register.freeCollateral(i);
        vm.recordLogs();
        vm.prank(operator);
        try hub.grantEnvelope(d, i, h, amount) {
            if (d == PUB) {
                grantsPub++;
                if (amount > freeBefore) {
                    publicCollateralViolations++; // invariant 6
                }
            } else {
                grantsPerm++;
            }
        } catch {
            grantsRefused++;
        }
        _afterAction();
    }

    function release(uint256 dSeed, uint256 pairSeed, uint256 amount) public {
        calls++;
        uint32 d = _domain(dSeed);
        (bytes32 i, bytes32 h, bool found) = _scanPairs(pairSeed, d, _PICK_RELEASABLE);
        if (!found) {
            return;
        }
        SpokeExposureGuard g = guardOf[d];
        uint256 free = g.releasable(i, h) + g.env(i, h) - g.used(i, h);
        amount = bound(amount, 1, free);
        _release(d, i, h, amount);
        releases++;
    }

    /// Home → spoke: some of the holder's open home tokens.
    function moveOut(uint256 dSeed, uint256 pairSeed, uint256 amount) public {
        calls++;
        uint32 d = _domain(dSeed);
        (bytes32 i, bytes32 h, bool found) = _scanPairs(pairSeed, d, _PICK_MOVABLE);
        if (!found) {
            (i, h, found) = _scanPairs(pairSeed, d, _PICK_ELIGIBLE);
            if (!found || !registry.goodStanding(i) || !registry.goodStanding(h)) {
                return;
            }
            uint256 room = _headroom(i, h);
            if (room == 0) {
                return;
            }
            vm.recordLogs();
            vm.prank(ops[i]);
            ledger.pay(h, room < 5 * MN ? room : 5 * MN, bytes32(calls));
            _afterAction();
            homePays++;
        }
        uint256 max = ledger.open(i, h);
        if (d == PUB) {
            uint256 free = register.freeCollateral(i);
            max = max < free ? max : free;
        }
        if (max == 0) {
            return;
        }
        amount = bound(amount, 1, max);
        uint64 nonce = _moveOut(d, i, h, amount);
        _tracked.push(Tracked({ src: HOME, dst: d, nonce: nonce, issuer: i, holder: h, amount: amount }));
        movesOut++;
    }

    /// Spoke → home: within what home sent that spoke (others are refused by the accountant;
    /// one in eight tries anyway to exercise the refusal).
    function moveHome(uint256 dSeed, uint256 pairSeed, uint256 amount) public {
        calls++;
        uint32 d = _domain(dSeed);
        (bytes32 i, bytes32 h, bool found) = _scanPairs(pairSeed, d, _PICK_SPOKE_OPEN);
        if (!found) {
            return;
        }
        if (rtok[d][i].paused()) {
            return;
        }
        uint256 max = guardOf[d].used(i, h);
        uint256 room = _accountantRoom(i, d);
        if (amount % 8 != 0) {
            max = max < room ? max : room;
        }
        if (max == 0) {
            return;
        }
        amount = bound(amount, 1, max);
        uint64 nonce = _moveHome(d, i, h, amount);
        _tracked.push(Tracked({ src: d, dst: HOME, nonce: nonce, issuer: i, holder: h, amount: amount }));
        movesHome++;
    }

    /// Home → spoke, relayed at once, then part of it straight back home: both directions of
    /// lock-then-burn complete in one step.
    function roundTrip(uint256 dSeed, uint256 pairSeed, uint256 amount) public {
        calls++;
        uint32 d = _domain(dSeed);
        (bytes32 i, bytes32 h, bool found) = _scanPairs(pairSeed, d, _PICK_MOVABLE);
        if (!found) {
            (i, h, found) = _scanPairs(pairSeed, d, _PICK_ELIGIBLE);
            if (!found || !registry.goodStanding(i) || !registry.goodStanding(h)) {
                return;
            }
            uint256 room = _headroom(i, h);
            if (room == 0) {
                return;
            }
            vm.recordLogs();
            vm.prank(ops[i]);
            ledger.pay(h, room < 5 * MN ? room : 5 * MN, bytes32(calls));
            _afterAction();
            homePays++;
        }
        uint256 max = ledger.open(i, h);
        if (d == PUB) {
            uint256 free = register.freeCollateral(i);
            max = max < free ? max : free;
        }
        if (max == 0) {
            return;
        }
        amount = bound(amount, 1, max);
        uint64 nonce = _moveOut(d, i, h, amount);
        _tracked.push(Tracked({ src: HOME, dst: d, nonce: nonce, issuer: i, holder: h, amount: amount }));
        movesOut++;
        _flush();
        if (spokeM[d].inbound(HOME, nonce) != ICrossChainMessenger.Inbound.MINTED || rtok[d][i].paused()) {
            return;
        }
        uint256 back = amount / 2 + 1;
        uint256 room = _accountantRoom(i, d);
        uint256 u = guardOf[d].used(i, h);
        back = back < room ? back : room;
        back = back < u ? back : u;
        if (back == 0) {
            return;
        }
        uint64 n2 = _moveHome(d, i, h, back);
        _tracked.push(Tracked({ src: d, dst: HOME, nonce: n2, issuer: i, holder: h, amount: back }));
        movesHome++;
        _flush();
    }

    /// Delivers one outbox message chosen at random (out of order across and within chains).
    function relay(uint256 seed) public {
        calls++;
        if (outbox.length == 0) {
            return;
        }
        _deliverOne(seed % outbox.length);
    }

    /// A MINT still undelivered: let its deadline pass and cancel it at the destination.
    function expire(uint256 seed) public {
        calls++;
        uint256 n = outbox.length;
        for (uint256 k = 0; k < n; k++) {
            uint256 idx = (seed % n + k) % n;
            if (outbox[idx].kind != 0) {
                continue;
            }
            Msg memory m = _removeAt(idx);
            ICrossChainMessenger.Envelope memory e = _env(m.data);
            if (block.timestamp <= e.deadline) {
                vm.warp(uint256(e.deadline) + 1);
            }
            bytes[] memory sigs = _attSigs(m.dest, m.data, 3);
            vm.recordLogs();
            _messenger(m.dest).cancelExpired(m.data, sigs);
            _afterAction();
            _delivered.push(Sent({ dest: m.dest, data: m.data }));
            expiries++;
            return;
        }
    }

    /// One step of the settlement lifecycle; flushes the outbox first.
    function advance(uint256 seed) public {
        calls++;
        _flush();
        uint64 b = batches.batchCount();
        ISettlementBatches.Status s = b == 0 ? ISettlementBatches.Status.NONE : batches.status(b);
        if (b == 0 || batches.batch(b).finalized) {
            if (b != 0 && !hub.burnsSent(batches.batch(b).epoch)) {
                _sendBurns(batches.batch(b).epoch);
                return;
            }
            _cutX(uint8(bound(seed, 1, 3)));
            cuts++;
            _flush();
        } else if (s == ISettlementBatches.Status.CUT) {
            if (!hub.spokesReported(batches.batch(b).epoch)) {
                return;
            }
            _submitPlan(b);
            plans++;
        } else if (s == ISettlementBatches.Status.PLANNED || s == ISettlementBatches.Status.PARTIAL) {
            for (uint32 k = 0; k < batches.legCount(b); k++) {
                ISettlementBatches.Leg memory l = batches.leg(b, k);
                if (l.paid < l.amount) {
                    _attestPay(b, k, CHIPS, l.amount - l.paid);
                    legsPaid++;
                    break;
                }
            }
        } else if (s == ISettlementBatches.Status.COMPLETE) {
            uint256 before = _homeSupply();
            batches.finalize(b, 100);
            homeBurnValue += before - _homeSupply();
            finalized++;
            if (hub.remotePairs(batches.batch(b).epoch).length > 0) {
                xBatches++;
            }
            _sendBurns(batches.batch(b).epoch);
        }
    }

    /// Wrongly signed or malformed MINTs: none may be accepted.
    function forge(uint256 seed, uint256 mode, uint256 amount) public {
        calls++;
        uint32 dst = _domainOrHome(seed);
        uint32 src = dst == HOME ? _domain(seed >> 4) : HOME;
        (bytes32 i, bytes32 h) = _pair(seed >> 8, seed >> 16);
        bytes memory data = abi.encode(
            ICrossChainMessenger.Envelope({
                version: mode % 5 == 4 ? 3 : 4,
                kind: 0,
                source: src,
                dest: dst,
                nonce: uint64(1e12 + calls),
                member: i,
                counterparty: h,
                recipient: wallet[h],
                amount: bound(amount, 1, 1_000 * MN),
                epoch: 0,
                deadline: uint64(block.timestamp + 1 days),
                ref: bytes32(0)
            })
        );
        bytes[] memory sigs;
        bytes memory iss;
        uint256 m = mode % 5;
        if (m == 0) {
            sigs = _attSigs(dst, data, 2);
            iss = _signWith(issuerKeyOf[i], dst, data);
        } else if (m == 1) {
            sigs = _attSigs(dst, data, 3);
        } else if (m == 2) {
            sigs = _attSigs(dst, data, 3);
            iss = _signWith(issuerKeyOf[h], dst, data);
        } else if (m == 3) {
            sigs = new bytes[](0);
            iss = _signWith(issuerKeyOf[i], dst, data);
        } else {
            sigs = _attSigs(dst, data, 3);
            iss = _signWith(issuerKeyOf[i], dst, data);
        }
        try _messenger(dst).receiveMessage(data, sigs, iss) {
            forgedAccepted++;
        } catch {
            forgedRejected++;
        }
    }

    /// Redelivers an already delivered message with fresh valid signatures.
    function replay(uint256 seed) public {
        calls++;
        if (_delivered.length == 0) {
            return;
        }
        Sent memory s = _delivered[seed % _delivered.length];
        bytes[] memory sigs = _attSigs(s.dest, s.data, 3);
        bytes memory iss = _issuerSig(s.dest, s.data);
        try _messenger(s.dest).receiveMessage(s.data, sigs, iss) {
            replayAccepted++;
        } catch {
            replaysRejected++;
        }
    }

    /// Suspends a member (registry + SUSPEND delivered to both spokes at once, checked to raise
    /// nothing), or lifts the suspension everywhere.
    function suspendCycle(uint256 seed) public {
        calls++;
        if (_suspendedMember == bytes32(0)) {
            bytes32 m = banks[seed % 3];
            uint256[2][3][3] memory envBefore;
            uint256[2][3][3] memory usedBefore;
            uint256[3] memory supplyBefore;
            for (uint256 k = 0; k < 2; k++) {
                for (uint256 a = 0; a < 3; a++) {
                    for (uint256 b = 0; b < 3; b++) {
                        envBefore[a][b][k] = guardOf[spokeDomains[k]].env(banks[a], banks[b]);
                        usedBefore[a][b][k] = guardOf[spokeDomains[k]].used(banks[a], banks[b]);
                    }
                }
            }
            for (uint256 a = 0; a < 3; a++) {
                supplyBefore[a] = _sumSupply(banks[a]);
            }
            vm.prank(guardian);
            registry.suspend(m, bytes32("TEST"));
            vm.recordLogs();
            hub.sendSuspend(m);
            _collect();
            for (uint256 k = 0; k < 2; k++) {
                bytes memory data = _take(spokeDomains[k], 8);
                _deliverChecked(spokeDomains[k], data);
            }
            for (uint256 k = 0; k < 2; k++) {
                SpokeExposureGuard g = guardOf[spokeDomains[k]];
                if (!rtok[spokeDomains[k]][m].paused() || !g.member(m).suspended) {
                    suspendRaised++;
                }
                for (uint256 a = 0; a < 3; a++) {
                    for (uint256 b = 0; b < 3; b++) {
                        uint256 e = g.env(banks[a], banks[b]);
                        if (e > envBefore[a][b][k] || g.used(banks[a], banks[b]) != usedBefore[a][b][k]) {
                            suspendRaised++;
                        }
                        if ((banks[a] == m || banks[b] == m) && e != usedBefore[a][b][k]) {
                            suspendRaised++; // the member's envelopes are cut to what is in use
                        }
                    }
                }
            }
            for (uint256 a = 0; a < 3; a++) {
                if (_sumSupply(banks[a]) != supplyBefore[a]) {
                    suspendRaised++;
                }
            }
            _suspendedMember = m;
            suspends++;
        } else {
            bytes32 m = _suspendedMember;
            vm.startPrank(gov);
            registry.reinstate(m);
            guardOf[PERM].reinstate(m);
            guardOf[PUB].reinstate(m);
            vm.stopPrank();
            vm.startPrank(issuerAdmin[m]);
            rtok[PERM][m].unpause();
            rtok[PUB][m].unpause();
            vm.stopPrank();
            _suspendedMember = bytes32(0);
            reinstates++;
        }
    }

    function warp(uint256 secs) public {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
    }

    // ------------------------------------------------------------ invariant views

    /// Invariant 1, per pair and per issuer: every token on every chain is accounted for by
    /// exactly one of home open, home part of pending, spoke open (= used), spoke locked
    /// (settled-pending-burn included), or a pending move's escrow at its source.
    function supplyAccounted() external view returns (bool) {
        for (uint256 a = 0; a < 3; a++) {
            bytes32 i = banks[a];
            uint256 lhs = tok[i].totalSupply();
            uint256 rhs;
            for (uint256 b = 0; b < 3; b++) {
                bytes32 h = banks[b];
                uint256 homePart = ledger.open(i, h) + ledger.pending(i, h) - _remotePendingAtHub(i, h);
                if (tok[i].balanceOf(wallet[h]) != homePart) {
                    return false;
                }
                rhs += homePart;
            }
            uint256 homeEscrow = _escrow(HOME, i, bytes32(0));
            if (tok[i].balanceOf(address(hub)) != homeEscrow) {
                return false;
            }
            rhs += homeEscrow;
            for (uint256 k = 0; k < 2; k++) {
                uint32 d = spokeDomains[k];
                SpokeExposureGuard g = guardOf[d];
                uint256 spokeSum;
                for (uint256 b = 0; b < 3; b++) {
                    bytes32 h = banks[b];
                    uint256 esc = _escrow(d, i, h);
                    uint256 lt = g.lockedTotal(i, h);
                    if (rtok[d][i].balanceOf(wallet[h]) != g.used(i, h) + lt + esc) {
                        return false;
                    }
                    if (rtok[d][i].lockedOf(wallet[h]) != lt + esc) {
                        return false;
                    }
                    spokeSum += g.used(i, h) + lt + esc;
                }
                if (rtok[d][i].totalSupply() != spokeSum) {
                    return false;
                }
                lhs += rtok[d][i].totalSupply();
                rhs += spokeSum;
            }
            if (lhs != rhs) {
                return false;
            }
        }
        return true;
    }

    /// Invariant 2: used ≤ env on the spoke, and env on the spoke ≤ envelope at the hub.
    function envelopesNested() external view returns (bool) {
        for (uint256 k = 0; k < 2; k++) {
            uint32 d = spokeDomains[k];
            for (uint256 a = 0; a < 3; a++) {
                for (uint256 b = 0; b < 3; b++) {
                    uint256 e = guardOf[d].env(banks[a], banks[b]);
                    if (guardOf[d].used(banks[a], banks[b]) > e) {
                        return false;
                    }
                    if (e > ledger.envelope(d, banks[a], banks[b])) {
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// The ledger's running gross sums match a recomputation; net positions sum to zero.
    function positionsConsistent() external view returns (bool) {
        int256 total;
        for (uint256 a = 0; a < 3; a++) {
            int256 n = _net(banks[a]);
            if (n != ledger.netPosition(banks[a])) {
                return false;
            }
            total += n;
        }
        return total == 0;
    }

    /// Every change to home `open` enters the epoch commitment: a nonzero open position implies a
    /// nonzero epochHash, so the operator never skips an epoch that holds positions.
    function openImpliesEpochHash() external view returns (bool) {
        if (ledger.epochHash() != bytes32(0)) {
            return true;
        }
        for (uint256 a = 0; a < 3; a++) {
            for (uint256 b = 0; b < 3; b++) {
                if (ledger.open(banks[a], banks[b]) != 0) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Invariant 4: no move both minted and cancelled; a cancelled destination nonce never mints;
    /// a source settles a move only the way its destination decided.
    function movesExclusive() external view returns (bool) {
        for (uint256 k = 0; k < _tracked.length; k++) {
            Tracked storage t = _tracked[k];
            ICrossChainMessenger.MoveStatus st = _messenger(t.src).move(t.nonce).status;
            ICrossChainMessenger.Inbound ib = _messenger(t.dst).inbound(t.src, t.nonce);
            if (st == ICrossChainMessenger.MoveStatus.COMPLETED && ib != ICrossChainMessenger.Inbound.MINTED) {
                return false;
            }
            if (st == ICrossChainMessenger.MoveStatus.CANCELLED && ib != ICrossChainMessenger.Inbound.CANCELLED) {
                return false;
            }
            if (ib == ICrossChainMessenger.Inbound.DONE) {
                return false;
            }
        }
        return true;
    }

    function trackedCount() external view returns (uint256) {
        return _tracked.length;
    }

    // ------------------------------------------------------------ internals

    uint8 internal constant _PICK_AVAILABLE = 0;
    uint8 internal constant _PICK_RELEASABLE = 1;
    uint8 internal constant _PICK_HOME_OPEN = 2;
    uint8 internal constant _PICK_SPOKE_OPEN = 3;
    uint8 internal constant _PICK_PAYABLE = 4; // free envelope on d, neither party blocked there
    uint8 internal constant _PICK_ELIGIBLE = 5; // neither party blocked on d nor out of standing
    uint8 internal constant _PICK_MOVABLE = 6; // open at home, neither party blocked on d

    /// The first ordered pair, from a seeded start, that has something to act on.
    function _scanPairs(uint256 seed, uint32 d, uint8 what) internal view returns (bytes32 i, bytes32 h, bool found) {
        for (uint256 k = 0; k < 6; k++) {
            uint256 idx = (seed % 6 + k) % 6;
            uint256 a = idx / 2;
            uint256 b = (a + 1 + idx % 2) % 3;
            i = banks[a];
            h = banks[b];
            uint256 v;
            if (what == _PICK_AVAILABLE) {
                v = guardOf[d].available(i, h);
            } else if (what == _PICK_RELEASABLE) {
                v = guardOf[d].releasable(i, h) + guardOf[d].available(i, h);
            } else if (what == _PICK_HOME_OPEN) {
                v = ledger.open(i, h);
            } else if (what == _PICK_SPOKE_OPEN) {
                v = guardOf[d].used(i, h);
            } else if (what == _PICK_PAYABLE) {
                v = _blockedOn(d, i, h) ? 0 : guardOf[d].available(i, h);
            } else if (what == _PICK_ELIGIBLE) {
                v = _blockedOn(d, i, h) || !registry.goodStanding(i) || !registry.goodStanding(h) ? 0 : 1;
            } else {
                v = _blockedOn(d, i, h) ? 0 : ledger.open(i, h);
            }
            if (v > 0) {
                return (i, h, true);
            }
        }
        return (bytes32(0), bytes32(0), false);
    }

    /// Delivers the outbox FIFO (and what that sends) until empty, a delivery fails, or a budget.
    function _flush() internal {
        for (uint256 budget = 0; outbox.length > 0 && budget < 64; budget++) {
            uint256 before = deliveryReverts;
            _deliverOne(0);
            if (deliveryReverts != before) {
                break;
            }
        }
    }

    function _blockedOn(uint32 d, bytes32 i, bytes32 h) internal view returns (bool) {
        SpokeExposureGuard g = guardOf[d];
        return g.member(i).suspended || g.member(h).suspended || rtok[d][i].paused();
    }

    /// The hub grants (i, h) an envelope on d within its limits (PERMISSIONED) or the issuer's
    /// free collateral (PUBLIC), relayed at once.
    function _grantNow(uint32 d, bytes32 i, bytes32 h, uint256 seed) internal returns (bool) {
        uint256 room = d == PERM ? _headroom(i, h) : register.freeCollateral(i);
        if (room == 0) {
            return false;
        }
        uint256 amount = bound(seed, 1, room < 10 * MN ? room : 10 * MN);
        uint256 freeBefore = register.freeCollateral(i);
        vm.recordLogs();
        vm.prank(operator);
        hub.grantEnvelope(d, i, h, amount);
        _afterAction();
        if (d == PUB) {
            grantsPub++;
            if (amount > freeBefore) {
                publicCollateralViolations++;
            }
        } else {
            grantsPerm++;
        }
        _flush();
        return guardOf[d].available(i, h) > 0;
    }

    function _deliverOne(uint256 idx) internal {
        Msg memory m = _removeAt(idx);
        _deliverChecked(m.dest, m.data);
    }

    function _deliverChecked(uint32 dest, bytes memory data) internal {
        bytes[] memory sigs = _attSigs(dest, data, 3);
        bytes memory iss = _issuerSig(dest, data);
        vm.recordLogs();
        try _messenger(dest).receiveMessage(data, sigs, iss) {
            delivered++;
            _delivered.push(Sent({ dest: dest, data: data }));
        } catch {
            deliveryReverts++;
            outbox.push(Msg({ dest: dest, kind: _env(data).kind, data: data }));
        }
        _afterAction();
    }

    /// Collects messages and checks the limits after every credit-taking event in the logs:
    /// home Paid, a PERMISSIONED grant, a public-spoke move landing at home as credit.
    function _afterAction() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k = 0; k < logs.length; k++) {
            Vm.Log memory l = logs[k];
            bytes32 t0 = l.topics[0];
            if (t0 == ICrossChainMessenger.MessageSent.selector) {
                outbox.push(
                    Msg({
                        dest: uint32(uint256(l.topics[1])),
                        kind: uint8(uint256(l.topics[3])),
                        data: abi.decode(l.data, (bytes))
                    })
                );
            } else if (l.emitter == address(ledger) && t0 == IExposureLedger.Paid.selector) {
                _checkLimits(l.topics[2], l.topics[3]);
            } else if (l.emitter == address(ledger) && t0 == IExposureLedger.EnvelopeReserved.selector) {
                if (uint32(uint256(l.topics[1])) == PERM) {
                    _checkLimits(l.topics[2], l.topics[3]);
                }
            } else if (l.emitter == address(ledger) && t0 == IExposureLedger.MovedIn.selector) {
                if (uint32(uint256(l.topics[1])) == PUB) {
                    _checkLimits(l.topics[2], l.topics[3]);
                }
            } else if (t0 == ICrossChainMessenger.MoveCompleted.selector) {
                if (l.emitter == address(hub)) {
                    movesOutDone++;
                } else {
                    movesHomeDone++;
                }
            } else if (t0 == ICrossChainMessenger.MoveCancelled.selector) {
                movesCancelled++;
            } else if (t0 == ICrossChainMessenger.MintRefused.selector) {
                mintsRefused++;
            } else if (t0 == ISpokeExposureGuard.PairBurned.selector) {
                remoteBurns++;
                remoteBurnValue += abi.decode(l.data, (uint256));
            }
        }
        vm.recordLogs();
    }

    /// Invariant 3 for one accepted credit-taking action (payer/issuer i, receiver/holder h),
    /// envelopes counted as fully used.
    function _checkLimits(bytes32 i, bytes32 h) internal {
        bool ok = ledger.bilateralNet(h, i) <= limits.bilateralLimit(h, i);
        ok = ok && _net(h) <= int256(limits.receiverCap(h));
        ok = ok && -_net(i) <= int256(limits.debitCap(i));
        if (!ok) {
            limitViolations++;
        }
    }

    /// Escrow of PENDING moves at `src` for issuer i (and holder h, or every holder when 0).
    function _escrow(uint32 src, bytes32 i, bytes32 h) internal view returns (uint256 s) {
        CrossChainMessenger m = _messenger(src);
        for (uint256 k = 0; k < _tracked.length; k++) {
            Tracked storage t = _tracked[k];
            if (t.src != src || t.issuer != i || (h != bytes32(0) && t.holder != h)) {
                continue;
            }
            if (m.move(t.nonce).status == ICrossChainMessenger.MoveStatus.PENDING) {
                s += t.amount;
            }
        }
    }

    /// Remote pairs of the in-flight batch not yet cleared: their tokens live on a spoke.
    function _remotePendingAtHub(bytes32 i, bytes32 h) internal view returns (uint256 s) {
        uint64 e = ledger.pendingEpoch();
        if (e == 0) {
            return 0;
        }
        uint256 n = ledger.pendingPairCount(e);
        for (uint256 k = ledger.clearedPairs(e); k < n; k++) {
            IExposureLedger.PendingPair memory p = ledger.pendingPair(e, k);
            if (p.remote && p.issuer == i && p.holder == h) {
                s += p.amount;
            }
        }
    }

    /// Home → spoke sent net of what came back and what is on its way back.
    function _accountantRoom(bytes32 i, uint32 d) internal view returns (uint256) {
        uint256 inFlight;
        for (uint256 k = 0; k < _tracked.length; k++) {
            Tracked storage t = _tracked[k];
            if (t.src == d && t.issuer == i && _messenger(d).move(t.nonce).status == ICrossChainMessenger.MoveStatus.PENDING) {
                inFlight += t.amount;
            }
        }
        uint256 used_ = hub.returned(i, d) + inFlight;
        uint256 s = hub.sent(i, d);
        return s > used_ ? s - used_ : 0;
    }

    function _homeSupply() internal view returns (uint256 t) {
        for (uint256 a = 0; a < 3; a++) {
            t += tok[banks[a]].totalSupply();
        }
    }

    function _domain(uint256 seed) internal pure returns (uint32) {
        return seed % 2 == 0 ? PERM : PUB;
    }

    function _domainOrHome(uint256 seed) internal pure returns (uint32) {
        uint256 x = seed % 3;
        return x == 0 ? HOME : x == 1 ? PERM : PUB;
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

    /// The largest amount that passes checks (3)–(5) for from → to (business window).
    function _headroom(bytes32 from, bytes32 to) internal view returns (uint256) {
        if (registry.member(from).status != IMemberRegistry.Status.ACTIVE) {
            return 0;
        }
        int256 a =
            int256(ledger.gross(to, from)) - int256(ledger.gross(from, to)) + int256(limits.bilateralLimit(to, from));
        int256 r = int256(limits.receiverCap(to)) - _net(to);
        int256 d = int256(limits.debitCap(from)) + _net(from);
        int256 m = a < r ? a : r;
        m = m < d ? m : d;
        return m <= 0 ? 0 : uint256(m);
    }
}
