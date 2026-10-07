// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ExposureLedger } from "../../src/credit/ExposureLedger.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract ExposureLedgerTest is CreditFixture {
    uint32 internal constant PERM = 2;
    uint32 internal constant PUB = 3;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
        vm.startPrank(gov);
        ledger.setDomainKind(PERM, IExposureLedger.DomainKind.PERMISSIONED);
        ledger.setDomainKind(PUB, IExposureLedger.DomainKind.PUBLIC);
        vm.stopPrank();
    }

    function _unauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    function test_constructor_zeroAddress() public {
        address r = address(registry);
        address l = address(limits);
        address g = address(register);
        address b = address(batches);
        vm.expectRevert(IExposureLedger.ZeroAddress.selector);
        new ExposureLedger(0, gov, address(0), l, g, b, operator);
        vm.expectRevert(IExposureLedger.ZeroAddress.selector);
        new ExposureLedger(0, gov, r, address(0), g, b, operator);
        vm.expectRevert(IExposureLedger.ZeroAddress.selector);
        new ExposureLedger(0, gov, r, l, address(0), b, operator);
        vm.expectRevert(IExposureLedger.ZeroAddress.selector);
        new ExposureLedger(0, gov, r, l, g, address(0), operator);
        vm.expectRevert(IExposureLedger.ZeroAddress.selector);
        new ExposureLedger(0, gov, r, l, g, b, address(0));
    }

    // ------------------------------------------------------------ pay

    function test_pay_success() public {
        bytes32 ref = bytes32("INV-1");
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Paid(1, A, B, 7 * MN, ref);
        vm.prank(ops[A]);
        uint256 seq = ledger.pay(B, 7 * MN, ref);
        assertEq(seq, 1);
        assertEq(ledger.open(A, B), 7 * MN);
        assertEq(ledger.gross(A, B), 7 * MN);
        assertEq(ledger.bilateralNet(B, A), 7 * MN);
        assertEq(ledger.netPosition(B), int256(7 * MN));
        assertEq(ledger.netPosition(A), -int256(7 * MN));
        assertEq(tok[A].balanceOf(wallet[B]), 7 * MN);
        assertEq(ledger.epochHash(), keccak256(abi.encode(bytes32(0), uint256(1), A, B, 7 * MN, ref)));
        assertEq(ledger.nextSeq(), 2);
    }

    function test_pay_revertingChecks() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.NotIssuerOps.selector, stranger));
        ledger.pay(B, 1, 0);
        vm.prank(wallet[A]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.NotIssuerOps.selector, wallet[A]));
        ledger.pay(B, 1, 0);

        vm.startPrank(ops[A]);
        vm.expectRevert(IExposureLedger.ZeroAmount.selector);
        ledger.pay(B, 0, 0);
        vm.expectRevert(IExposureLedger.SelfPayment.selector);
        ledger.pay(A, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayeeNotInGoodStanding.selector, bytes32("NOPE")));
        ledger.pay(bytes32("NOPE"), 1, 0);
        vm.stopPrank();

        vm.prank(guardian);
        registry.suspend(B, bytes32("X"));
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayeeNotInGoodStanding.selector, B));
        ledger.pay(B, 1, 0);
        vm.prank(ops[B]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayerNotInGoodStanding.selector, B));
        ledger.pay(A, 1, 0);
    }

    function test_pay_queues_reasons() public {
        _elective(B, A, 0);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(1, 3);
        _pay(A, B, 5 * MN + 1);
        IExposureLedger.QueueEntry memory e = ledger.queueEntry(1);
        assertEq(e.payer, A);
        assertEq(e.to, B);
        assertEq(e.amount, 5 * MN + 1);
        assertEq(uint8(e.state), uint8(IExposureLedger.QueueState.QUEUED));
        assertEq(e.enqueuedAt, block.timestamp);
        assertEq(ledger.queueLength(), 1);
        assertEq(ledger.queueSeqAt(0), 1);
        assertEq(tok[A].totalSupply(), 0);

        vm.prank(gov);
        limits.setReceiverCap(C, 1 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(2, 4);
        _pay(A, C, 1 * MN + 1);

        vm.prank(gov);
        limits.setSystemMax(2 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(3, 5);
        _pay(A, B, 2 * MN + 1);
        assertEq(ledger.check(A, C, 1 * MN), 0);
        assertEq(ledger.check(A, A, 1), 1);
    }

    /// Amounts beyond int256 cannot wrap the signed checks (a prefund-only payer skips check 3).
    function test_pay_hugeAmountRefused() public {
        bytes32 D = bytes32("BNKDUS30");
        _addBank(D, "Bank D deposit token", "D-dT", IMemberRegistry.Tier.PREFUND_ONLY);
        _fund(ICollateralRegister.Kind.COLLATERAL, D, 1 * MN);
        uint256 huge = uint256(type(int256).max) + 1;
        vm.prank(ops[D]);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, huge));
        ledger.pay(A, huge, 0);
        // Limits set above int256's range act as unbounded rather than wrapping negative.
        vm.prank(gov);
        limits.setReceiverCap(A, type(uint256).max);
        assertEq(ledger.check(D, A, 1 * MN), 0);
    }

    function test_capReached_atTriggerFraction() public {
        vm.prank(gov);
        limits.setTriggerBps(5000);
        _pay(A, B, 49 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.CapReached(B);
        _pay(A, B, 1 * MN);
    }

    // ------------------------------------------------------------ window

    function test_window_setters() public {
        _unauthorized(stranger, ledger.OPERATOR_ROLE());
        vm.prank(stranger);
        ledger.setWindow(IExposureLedger.Window.OFF_HOURS);
        bytes32 role = ledger.OPERATOR_ROLE();
        vm.prank(stranger);
        _unauthorized(stranger, role);
        ledger.setBusinessDay(1);

        uint64 session = ledger.offHoursSession();
        vm.expectEmit(address(ledger));
        emit IExposureLedger.WindowSet(IExposureLedger.Window.OFF_HOURS, session);
        _window(IExposureLedger.Window.OFF_HOURS);
        assertEq(uint8(ledger.window()), uint8(IExposureLedger.Window.OFF_HOURS));
        _fund(ICollateralRegister.Kind.RTP_PREFUND, A, 3 * MN);
        _pay(A, B, 2 * MN);
        assertEq(ledger.check(A, B, 2 * MN), 2);
        assertEq(ledger.offHoursUsed(A), 2 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.WindowSet(IExposureLedger.Window.BUSINESS, session + 1);
        _window(IExposureLedger.Window.BUSINESS);
        assertEq(ledger.offHoursUsed(A), 0);

        vm.startPrank(operator);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.BusinessDaySet(5);
        ledger.setBusinessDay(5);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.BusinessDayRegress.selector, 5, 4));
        ledger.setBusinessDay(4);
        vm.stopPrank();
    }

    function test_window_defaultsToOffHours() public {
        ExposureLedger fresh = new ExposureLedger(
            0, gov, address(registry), address(limits), address(register), address(batches), operator
        );
        assertEq(uint8(fresh.window()), uint8(IExposureLedger.Window.OFF_HOURS));
    }

    function test_setDomainKind() public {
        vm.prank(stranger);
        _unauthorized(stranger, bytes32(0));
        ledger.setDomainKind(9, IExposureLedger.DomainKind.PUBLIC);
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.InvalidDomain.selector, 0));
        ledger.setDomainKind(0, IExposureLedger.DomainKind.PUBLIC);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.InvalidDomain.selector, 9));
        ledger.setDomainKind(9, IExposureLedger.DomainKind.NONE);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.DomainAlreadySet.selector, PERM));
        ledger.setDomainKind(PERM, IExposureLedger.DomainKind.PUBLIC);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.DomainKindSet(9, IExposureLedger.DomainKind.PUBLIC);
        ledger.setDomainKind(9, IExposureLedger.DomainKind.PUBLIC);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ queue

    function test_drain_stopsAtHead_thenExecutes() public {
        _elective(B, A, 0);
        _pay(A, B, 5 * MN);
        uint256 q1 = _pay(A, B, 1 * MN); // queued: bilateral
        uint256 q2 = _pay(C, B, 1 * MN); // passes at once: a new payment is not held behind the queue
        assertEq(uint8(ledger.queueEntry(q2).state), uint8(IExposureLedger.QueueState.NONE));
        assertEq(ledger.queueLength(), 1);
        uint256 q3 = _pay(A, B, 2 * MN);
        assertEq(ledger.drain(10), 0);
        assertEq(ledger.queueHead(), 0);

        _elective(B, A, 3 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Paid(q1, A, B, 1 * MN, keccak256(abi.encode("ref", A, B, 1 * MN)));
        assertEq(ledger.drain(1), 1);
        assertEq(ledger.drain(10), 1);
        assertEq(uint8(ledger.queueEntry(q3).state), uint8(IExposureLedger.QueueState.PAID));
        assertEq(ledger.queueHead(), 2);
        assertEq(ledger.open(A, B), 8 * MN);
    }

    function test_drain_cancelsNotInGoodStanding_skipsCancelled() public {
        _elective(B, A, 0);
        _elective(C, A, 0);
        _pay(A, B, 5 * MN);
        _pay(A, C, 5 * MN);
        uint256 q1 = _pay(A, B, 1 * MN);
        uint256 q2 = _pay(A, C, 6 * MN);
        uint256 q3 = _pay(A, C, 1 * MN);
        assertEq(ledger.queueLength(), 3);

        vm.prank(ops[A]);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.QueueCancelled(q2, 0);
        ledger.cancel(q2);
        _elective(C, A, 20 * MN);

        vm.prank(guardian);
        registry.suspend(B, bytes32("X"));
        vm.expectEmit(address(ledger));
        emit IExposureLedger.QueueCancelled(q1, 1);
        assertEq(ledger.drain(10), 1);
        assertEq(uint8(ledger.queueEntry(q1).state), uint8(IExposureLedger.QueueState.CANCELLED));
        assertEq(uint8(ledger.queueEntry(q3).state), uint8(IExposureLedger.QueueState.PAID));
    }

    function test_drain_waitsWhileTokenPausedOrWindowShut() public {
        _elective(B, A, 0);
        _pay(A, B, 5 * MN);
        uint256 q = _pay(A, B, 1 * MN);
        _elective(B, A, 10 * MN);
        vm.prank(guardian);
        tok[A].pause();
        assertEq(ledger.drain(10), 0);
        vm.prank(issuerAdmin[A]);
        tok[A].unpause();
        vm.prank(guardian);
        tok[A].setFrozen(wallet[B], true);
        assertEq(ledger.drain(10), 0);
        vm.prank(guardian);
        tok[A].setFrozen(wallet[B], false);
        _window(IExposureLedger.Window.OFF_HOURS);
        assertEq(ledger.drain(10), 0);
        _fund(ICollateralRegister.Kind.RTP_PREFUND, A, 1 * MN);
        assertEq(ledger.drain(10), 1);
        assertEq(uint8(ledger.queueEntry(q).state), uint8(IExposureLedger.QueueState.PAID));
        assertEq(ledger.offHoursUsed(A), 1 * MN);
    }

    function test_cancel_errors() public {
        _elective(B, A, 0);
        _pay(A, B, 5 * MN);
        uint256 q = _pay(A, B, 1 * MN);
        vm.prank(ops[B]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.NotPayer.selector, q));
        ledger.cancel(q);
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.NotQueued.selector, 1));
        ledger.cancel(1); // executed, not queued
        vm.prank(ops[A]);
        ledger.cancel(q);
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.NotQueued.selector, q));
        ledger.cancel(q);
    }

    function test_queueExpiresAtNextBusinessDayCut() public {
        _elective(B, A, 0);
        _pay(A, B, 5 * MN);
        uint256 q = _pay(A, B, 1 * MN);
        _cut(3); // same business day: survives
        assertEq(uint8(ledger.queueEntry(q).state), uint8(IExposureLedger.QueueState.QUEUED));
        _settleLatest();
        vm.prank(operator);
        ledger.setBusinessDay(1);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.QueueExpired(q);
        _cut(3);
        assertEq(uint8(ledger.queueEntry(q).state), uint8(IExposureLedger.QueueState.EXPIRED));
        assertEq(ledger.queueHead(), 1);
    }

    function _settleLatest() internal {
        uint64 b = batches.batchCount();
        _submitPlan(b);
        for (uint32 i = 0; i < batches.legCount(b); i++) {
            _attestPay(b, i, CHIPS, batches.leg(b, i).amount);
        }
        batches.finalize(b, 100);
    }

    // ------------------------------------------------------------ settlement hooks

    function test_settlementHooks_roles() public {
        bytes32 role = ledger.BATCHES_ROLE();
        vm.startPrank(stranger);
        _unauthorized(stranger, role);
        ledger.snapshotForCut();
        _unauthorized(stranger, role);
        ledger.sealBatch(1);
        _unauthorized(stranger, role);
        ledger.clearPending(1, 0, 0);
        vm.stopPrank();
    }

    function test_snapshot_seal_clear() public {
        _pay(A, B, 3 * MN);
        _pay(B, C, 2 * MN);
        _pay(A, B, 1 * MN);
        bytes32 h = ledger.epochHash();

        vm.startPrank(address(batches));
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Snapshot(1, h, 2);
        (bytes32 hash, uint64 e) = ledger.snapshotForCut();
        assertEq(hash, h);
        assertEq(e, 1);
        assertEq(ledger.epoch(), 2);
        assertEq(ledger.epochHash(), bytes32(0));
        assertEq(ledger.pendingEpoch(), 1);
        assertEq(ledger.open(A, B), 0);
        assertEq(ledger.pending(A, B), 4 * MN);
        assertEq(ledger.netPosition(B), int256(2 * MN));
        (bytes32[] memory is_, bytes32[] memory hs, uint256[] memory amts) = ledger.pendingPairs(1);
        assertEq(is_.length, 2);
        assertEq(is_[0], A);
        assertEq(hs[0], B);
        assertEq(amts[0], 4 * MN);
        assertFalse(ledger.pendingPair(1, 1).remote);

        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.BatchInFlight.selector, 1));
        ledger.snapshotForCut();
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EpochNotSealed.selector, 1));
        ledger.clearPending(1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EpochMismatch.selector, 1, 2));
        ledger.sealBatch(2);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.BatchSealed(1);
        ledger.sealBatch(1);
        assertTrue(ledger.isSealed(1));

        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PageOutOfOrder.selector, 0, 1));
        ledger.clearPending(1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PageOutOfRange.selector, 3, 2));
        ledger.clearPending(1, 0, 3);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.PendingCleared(1, 0, 1);
        ledger.clearPending(1, 0, 1);
        assertEq(ledger.pending(A, B), 0);
        assertEq(ledger.clearedPairs(1), 1);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.EpochSettled(1);
        ledger.clearPending(1, 1, 1);
        assertEq(ledger.pendingEpoch(), 0);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EpochMismatch.selector, 0, 1));
        ledger.clearPending(1, 2, 0);
        vm.stopPrank();
        assertEq(ledger.netPosition(B), 0);
    }

    // ------------------------------------------------------------ cross-chain hooks

    function test_crossChainHooks_roles() public {
        bytes32 role = ledger.MESSENGER_ROLE();
        vm.startPrank(stranger);
        _unauthorized(stranger, role);
        ledger.reserveEnvelope(PERM, A, B, 1);
        _unauthorized(stranger, role);
        ledger.releaseEnvelope(PERM, A, B, 1);
        _unauthorized(stranger, role);
        ledger.envelopeToPending(PERM, A, B, 1, 1);
        _unauthorized(stranger, role);
        ledger.addRemoteToBatch(1, A, B, 1);
        vm.stopPrank();
    }

    function test_reserveEnvelope_permissioned() public {
        vm.startPrank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.UnknownDomain.selector, 7));
        ledger.reserveEnvelope(7, A, B, 1);
        vm.expectRevert(IExposureLedger.ZeroAmount.selector);
        ledger.reserveEnvelope(PERM, A, B, 0);
        vm.expectRevert(IExposureLedger.SelfPayment.selector);
        ledger.reserveEnvelope(PERM, A, A, 1);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayerNotInGoodStanding.selector, bytes32("NOPE")));
        ledger.reserveEnvelope(PERM, bytes32("NOPE"), B, 1);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayeeNotInGoodStanding.selector, bytes32("NOPE")));
        ledger.reserveEnvelope(PERM, A, bytes32("NOPE"), 1);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.BilateralLimitExceeded.selector, B, A));
        ledger.reserveEnvelope(PERM, A, B, 100 * MN + 1);

        vm.expectEmit(address(ledger));
        emit IExposureLedger.EnvelopeReserved(PERM, A, B, 30 * MN);
        ledger.reserveEnvelope(PERM, A, B, 30 * MN);
        vm.stopPrank();
        assertEq(ledger.envelope(PERM, A, B), 30 * MN);
        assertEq(ledger.envelopeTotal(A, B), 30 * MN);
        assertEq(ledger.gross(A, B), 30 * MN);
        // Envelopes count as used for home payments.
        assertEq(ledger.check(A, B, 70 * MN), 0);
        assertEq(ledger.check(A, B, 70 * MN + 1), 3);

        vm.prank(gov);
        limits.setReceiverCap(C, 1 * MN);
        vm.prank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.ReceiverCapExceeded.selector, C));
        ledger.reserveEnvelope(PERM, A, C, 2 * MN);
        vm.prank(gov);
        limits.setSystemMax(31 * MN);
        vm.prank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.DebitCapExceeded.selector, A));
        ledger.reserveEnvelope(PERM, A, B, 2 * MN);

        vm.startPrank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EnvelopeUnderflow.selector, 31 * MN, 30 * MN));
        ledger.releaseEnvelope(PERM, A, B, 31 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.EnvelopeReleased(PERM, A, B, 10 * MN);
        ledger.releaseEnvelope(PERM, A, B, 10 * MN);
        vm.stopPrank();
        assertEq(ledger.gross(A, B), 20 * MN);
        assertEq(ledger.netPosition(B), int256(20 * MN));
    }

    function test_reserveEnvelope_public_drawsFreeCollateral() public {
        // A: collateral 10M, mandatory backing 10M → nothing free.
        vm.prank(messenger);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegister.InsufficientFreeCollateral.selector, A, 1, 0));
        ledger.reserveEnvelope(PUB, A, B, 1);

        _fund(ICollateralRegister.Kind.COLLATERAL, A, 30 * MN);
        assertEq(register.freeCollateral(A), 20 * MN);
        // Credit limits do not apply on a public spoke: B grants A nothing here.
        _elective(B, A, 0);
        vm.prank(messenger);
        ledger.reserveEnvelope(PUB, A, B, 15 * MN);
        assertEq(register.publicCommitted(A), 15 * MN);
        assertEq(register.freeCollateral(A), 5 * MN); // mandatory min(5, 15 / 2) → backing 10; committed 25
        vm.prank(messenger);
        ledger.releaseEnvelope(PUB, A, B, 5 * MN);
        assertEq(register.publicCommitted(A), 10 * MN);
    }

    function test_envelopeToPending_addRemote() public {
        vm.prank(messenger);
        ledger.reserveEnvelope(PERM, A, B, 30 * MN);
        _pay(A, C, 1 * MN);

        vm.prank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EpochMismatch.selector, 0, 1));
        ledger.envelopeToPending(PERM, A, B, 1, 1);

        uint64 b = _cut(3);
        uint64 e = batches.batch(b).epoch;
        vm.startPrank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EnvelopeUnderflow.selector, 31 * MN, 30 * MN));
        ledger.envelopeToPending(PERM, A, B, 31 * MN, e);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.EnvelopeToPending(PERM, A, B, 12 * MN, e);
        ledger.envelopeToPending(PERM, A, B, 12 * MN, e);
        assertEq(ledger.envelope(PERM, A, B), 18 * MN);
        assertEq(ledger.pending(A, B), 12 * MN);
        assertEq(ledger.gross(A, B), 30 * MN);
        vm.stopPrank();

        // The plan cannot be accepted while locked amounts are unrecorded.
        ISettlementBatches.Leg[] memory legs = _plan(b);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.RemoteUnrecorded.selector, e, 12 * MN));
        batches.submitPlan(b, legs, deadline);

        vm.startPrank(messenger);
        vm.expectRevert(IExposureLedger.ZeroAmount.selector);
        ledger.addRemoteToBatch(e, A, B, 0);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.RemoteExceedsLocked.selector, 13 * MN, 12 * MN));
        ledger.addRemoteToBatch(e, A, B, 13 * MN);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.RemoteAddedToBatch(e, A, B, 12 * MN);
        ledger.addRemoteToBatch(e, A, B, 12 * MN);
        vm.stopPrank();
        assertTrue(ledger.pendingPair(e, 1).remote);

        // Plan covers home and remote pairs; finalize burns home only.
        _submitPlan(b);
        vm.startPrank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EpochSealed.selector, e));
        ledger.envelopeToPending(PERM, A, B, 1, e);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EpochSealed.selector, e));
        ledger.addRemoteToBatch(e, A, B, 1);
        vm.stopPrank();
        for (uint32 i = 0; i < batches.legCount(b); i++) {
            _attestPay(b, i, CHIPS, batches.leg(b, i).amount);
        }
        batches.finalize(b, 10);
        assertEq(batches.batch(b).burned, 1 * MN);
        assertEq(ledger.pending(A, B), 0);
        assertEq(ledger.gross(A, B), 18 * MN);
    }
}
