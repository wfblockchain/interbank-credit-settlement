// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { IDefaultManager } from "../../src/interfaces/IDefaultManager.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { ISettlementAttestor } from "../../src/interfaces/ISettlementAttestor.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

/// End-to-end flows of the design (§3) with Bank A, B and C.
contract ScenariosTest is CreditFixture {
    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
    }

    // ------------------------------------------------------------ cap hit, CHIPS

    function test_capHit_cut_plan_chips_finalize() public {
        _standardLimits();
        for (uint256 i = 0; i < 3; i++) {
            _pay(A, B, 25 * MN);
        }
        vm.expectEmit(address(ledger));
        emit IExposureLedger.CapReached(B);
        _pay(A, B, 25 * MN);
        assertEq(ledger.netPosition(B), int256(100 * MN));
        assertEq(tok[A].balanceOf(wallet[B]), 100 * MN);

        // Beyond the receiver cap a payment to B (here from C) is queued, not rejected.
        uint256 next = ledger.nextSeq();
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(next, 4);
        uint256 q = _pay(C, B, 1 * MN);
        assertEq(q, next);

        uint64 b = _cut(1);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.CUT));
        assertEq(batches.rfReference(b), "RF60CS1");
        ISettlementBatches.Leg[] memory legs = _submitPlan(b);
        assertEq(legs.length, 1);
        assertEq(legs[0].payer, A);
        assertEq(legs[0].payee, B);
        assertEq(legs[0].amount, 100 * MN);

        // Pending tokens are still exposure: the queued payment cannot drain yet.
        assertEq(ledger.drain(10), 0);

        // One CHIPS payment, 3 of 5 signatures.
        _attestPay(b, 0, CHIPS, 100 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));

        batches.finalize(b, 10);
        assertEq(tok[A].totalSupply(), 0);
        assertEq(_exposure(A, B), 0);
        assertEq(ledger.netPosition(A), 0);
        assertEq(ledger.netPosition(B), 0);
        assertEq(batches.batch(b).burned, 100 * MN);

        assertEq(ledger.drain(10), 1);
        assertEq(uint8(ledger.queueEntry(q).state), uint8(IExposureLedger.QueueState.PAID));
        assertEq(tok[C].balanceOf(wallet[B]), 1 * MN);
    }

    // ------------------------------------------------------------ end of day, multilateral

    function test_endOfDay_multilateral_allResidualsSettled() public {
        _standardLimits();
        _pay(A, B, 30 * MN);
        _pay(B, C, 20 * MN);
        _pay(C, A, 10 * MN);
        _pay(A, C, 5 * MN);
        _pay(B, A, 7 * MN);
        _pay(C, B, 12 * MN);
        // nets: A = 17 − 35 = −18, B = 42 − 27 = +15, C = 25 − 22 = +3
        assertEq(ledger.netPosition(A), -int256(18 * MN));
        assertEq(ledger.netPosition(B), int256(15 * MN));
        assertEq(ledger.netPosition(C), int256(3 * MN));

        uint64 b = _cut(3);
        assertEq(ledger.pendingPairCount(batches.batch(b).epoch), 6);
        ISettlementBatches.Leg[] memory legs = _submitPlan(b);
        assertEq(legs.length, 2);
        uint256 total;
        for (uint32 i = 0; i < legs.length; i++) {
            total += legs[i].amount;
            _attestPay(b, i, CHIPS, legs[i].amount);
        }
        assertEq(total, 18 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));

        // Paged finalization.
        assertEq(batches.finalize(b, 4), 4);
        assertFalse(batches.batch(b).finalized);
        assertEq(batches.finalize(b, 4), 2);
        assertTrue(batches.batch(b).finalized);
        for (uint256 i = 0; i < banks.length; i++) {
            assertEq(tok[banks[i]].totalSupply(), 0);
            assertEq(ledger.netPosition(banks[i]), 0);
        }
        assertEq(batches.batch(b).burned, 84 * MN);
        assertEq(ledger.pendingEpoch(), 0);
    }

    // ------------------------------------------------------------ off-hours, RTP

    function test_offHours_prefundOnly_tenRtpLegs() public {
        _standardLimits();
        _window(IExposureLedger.Window.OFF_HOURS);

        // No prefund: nothing on credit outside the business window.
        vm.prank(ops[A]);
        vm.expectRevert(
            abi.encodeWithSelector(IExposureLedger.OffHoursPrefundExceeded.selector, A, 0, 1 * MN, 0)
        );
        ledger.pay(B, 1 * MN, bytes32("r"));

        _fund(ICollateralRegister.Kind.RTP_PREFUND, A, 100 * MN);
        for (uint256 i = 0; i < 9; i++) {
            _pay(A, B, 10 * MN);
        }
        vm.expectEmit(address(ledger));
        emit IExposureLedger.CapReached(B);
        _pay(A, B, 10 * MN);
        assertEq(ledger.offHoursUsed(A), 100 * MN);

        vm.prank(ops[A]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExposureLedger.OffHoursPrefundExceeded.selector, A, 100 * MN, 1, 100 * MN
            )
        );
        ledger.pay(C, 1, bytes32("r"));

        uint64 b = _cut(1);
        _submitPlan(b);

        // RTP legs are at most $10M.
        ISettlementBatches.Payment memory big = _payment(b, 0, RTP, A, B, 10 * MN + 1);
        bytes32 digest = attestor.paymentDigest(big);
        bytes[] memory sigs = _sigs(digest, 3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.RtpLimitExceeded.selector, 10 * MN + 1));
        attestor.attestPayment(big, sigs);

        for (uint256 i = 0; i < 10; i++) {
            _attestPay(b, 0, RTP, 10 * MN);
            if (i < 9) {
                assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.PARTIAL));
            }
        }
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
        batches.finalize(b, 10);
        assertEq(tok[A].totalSupply(), 0);

        // Back to business: the off-hours usage resets.
        _window(IExposureLedger.Window.BUSINESS);
        assertEq(ledger.offHoursUsed(A), 0);
    }

    // ------------------------------------------------------------ payment matching

    function _oneLegBatch(uint256 amount) internal returns (uint64 b) {
        _standardLimits();
        _pay(A, B, amount);
        b = _cut(1);
        _submitPlan(b);
    }

    function test_overpayment_recorded() public {
        uint64 b = _oneLegBatch(50 * MN);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.Overpaid(b, 0, 10 * MN);
        _attestPay(b, 0, CHIPS, 60 * MN);
        assertEq(batches.overpaid(b, 0), 10 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
    }

    function test_underpayment_leavesPartial() public {
        uint64 b = _oneLegBatch(50 * MN);
        _attestPay(b, 0, CHIPS, 30 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.PARTIAL));
        assertEq(batches.leg(b, 0).paid, 30 * MN);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.PARTIAL));
        batches.finalize(b, 10);
        _attestPay(b, 0, CHIPS, 20 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
    }

    function test_wrongPayer_wrongPayee_reusedRailTx_refused() public {
        uint64 b = _oneLegBatch(50 * MN);

        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, C, B, 50 * MN);
        bytes[] memory sigs = _sigs(attestor.paymentDigest(p), 3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongPayer.selector, A, C));
        attestor.attestPayment(p, sigs);

        p = _payment(b, 0, CHIPS, A, C, 50 * MN);
        sigs = _sigs(attestor.paymentDigest(p), 3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongPayee.selector, B, C));
        attestor.attestPayment(p, sigs);

        p = _payment(b, 0, CHIPS, A, B, 20 * MN);
        _attest(p);
        ISettlementBatches.Payment memory again = p;
        again.amount = 30 * MN;
        sigs = _sigs(attestor.paymentDigest(again), 3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.RailTxUsed.selector, p.railTxId));
        attestor.attestPayment(again, sigs);
    }

    function test_signatureRules_refused() public {
        uint64 b = _oneLegBatch(50 * MN);
        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, A, B, 50 * MN);
        bytes32 digest = attestor.paymentDigest(p);

        bytes[] memory two = _sigs(digest, 2);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.InsufficientSignatures.selector, 2, 3));
        attestor.attestPayment(p, two);

        bytes[] memory dup = new bytes[](3);
        dup[0] = _sign(digest, signerKeys[0]);
        dup[1] = _sign(digest, signerKeys[1]);
        dup[2] = _sign(digest, signerKeys[1]);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.DuplicateSigner.selector, signerAddrs[1]));
        attestor.attestPayment(p, dup);

        bytes[] memory desc = new bytes[](3);
        desc[0] = _sign(digest, signerKeys[2]);
        desc[1] = _sign(digest, signerKeys[1]);
        desc[2] = _sign(digest, signerKeys[3]);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementAttestor.SignersNotAscending.selector, signerAddrs[2], signerAddrs[1])
        );
        attestor.attestPayment(p, desc);

        (address outsider, uint256 outsiderKey) = makeAddrAndKey("outsider");
        bytes[] memory foreign = _sigs(digest, 3);
        foreign[2] = _sign(digest, outsiderKey);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.UnknownSigner.selector, outsider));
        attestor.attestPayment(p, foreign);

        _attest(p);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
    }

    // ------------------------------------------------------------ limits

    function test_limit_bilateral_queues() public {
        _standardLimits();
        _elective(B, A, 0); // B grants A only the mandatory $5M
        assertEq(limits.bilateralLimit(B, A), 5 * MN);
        _pay(A, B, 5 * MN);
        uint256 next = ledger.nextSeq();
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(next, 3);
        _pay(A, B, 1);
        // B's own claims on A net against A's: B paying A 3 lets A pay B 3 more.
        _pay(B, A, 3 * MN);
        assertEq(ledger.bilateralNet(B, A), 2 * MN);
        assertEq(ledger.check(A, B, 3 * MN), 0);
    }

    function test_limit_debitCap_systemMax_queue_thenDrainAfterSettlement() public {
        _standardLimits();
        _elective(C, A, 0);
        assertEq(limits.debitCap(A), 105 * MN);
        vm.prank(gov);
        limits.setSystemMax(50 * MN);
        assertEq(limits.debitCap(A), 50 * MN);

        _pay(A, B, 40 * MN);
        _pay(A, C, 5 * MN);
        uint256 next = ledger.nextSeq();
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(next, 5);
        uint256 q = _pay(A, B, 10 * MN);
        assertEq(ledger.drain(5), 0);

        uint64 b = _cut(2);
        ISettlementBatches.Leg[] memory legs = _submitPlan(b);
        for (uint32 i = 0; i < legs.length; i++) {
            _attestPay(b, i, CHIPS, legs[i].amount);
        }
        batches.finalize(b, 10);
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Paid(q, A, B, 10 * MN, keccak256(abi.encode("ref", A, B, 10 * MN)));
        assertEq(ledger.drain(5), 1);
        assertEq(ledger.open(A, B), 10 * MN);
    }

    function test_limit_receiverCap_lowered_byMember() public {
        _standardLimits();
        vm.prank(ops[B]);
        limits.lowerReceiverCap(20 * MN);
        _pay(A, B, 20 * MN);
        uint256 next = ledger.nextSeq();
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(next, 4);
        _pay(C, B, 1);
    }

    function test_limit_regCap_and_restricted_cutMandatoryImmediately() public {
        _standardLimits();
        _elective(B, A, 0);
        _elective(C, A, 0);
        assertEq(limits.mandatory(A), 5 * MN);
        _pay(A, B, 2 * MN); // within B's mandatory limit to A

        // B's regulatory cap on A: limit 0 for new transfers; exposure already taken stays.
        vm.prank(ops[B]);
        limits.setRegCap(A, 0, bytes32("REG_F"));
        assertEq(limits.bilateralLimit(B, A), 0);
        assertEq(ledger.check(A, B, 1), 3);
        assertEq(_exposure(A, B), 2 * MN);

        // PCA: mandatory to A is 0 at once, for every grantor.
        assertEq(ledger.check(A, C, 1 * MN), 0);
        vm.prank(guardian);
        limits.restrict(A);
        assertEq(limits.mandatory(A), 0);
        assertEq(limits.bilateralLimit(C, A), 0);
        uint256 next = ledger.nextSeq();
        vm.expectEmit(address(ledger));
        emit IExposureLedger.Queued(next, 3);
        _pay(A, C, 1 * MN);
    }

    function test_limit_mandatory_euro1Formula() public {
        _standardLimits();
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 4 * MN);
        assertEq(limits.mandatory(A), 2 * MN); // 4M / (3 − 1)
        assertEq(limits.mandatoryBacking(A), 4 * MN);
        assertEq(register.collateralCommitted(A), 4 * MN);
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 40 * MN);
        assertEq(limits.mandatory(A), 5 * MN); // capped by mandatoryPerPair
        assertEq(limits.mandatoryBacking(A), 10 * MN);
        vm.prank(gov);
        limits.setMandatoryRemoved(true);
        assertEq(limits.mandatory(A), 0);
        assertEq(limits.bilateralLimit(B, A), 95 * MN);
    }

    function test_limit_prefundOnlyTier() public {
        _standardLimits();
        bytes32 D = bytes32("BNKDUS30");
        _addBank(D, "Bank D deposit token", "D-dT", IMemberRegistry.Tier.PREFUND_ONLY);
        _fund(ICollateralRegister.Kind.COLLATERAL, D, 8 * MN);

        // Neither grants nor receives mandatory limits.
        assertEq(limits.mandatory(D), 0);
        assertEq(limits.bilateralLimit(A, D), 0);
        assertEq(limits.bilateralLimit(D, A), 0);
        // Mandatory denominators count credit members only.
        assertEq(limits.mandatory(A), 5 * MN);

        // As payer: covered by its own collateral, no bilateral check.
        assertEq(limits.debitCap(D), 8 * MN);
        _pay(D, A, 6 * MN);
        assertEq(ledger.check(D, A, 2 * MN), 0);
        assertEq(ledger.check(D, A, 2 * MN + 1), 5);

        // As receiver: only within the elective limits it grants (after netting A's claim on D).
        assertEq(ledger.check(A, D, 6 * MN), 0);
        assertEq(ledger.check(A, D, 6 * MN + 1), 3);
        _elective(D, A, 1 * MN);
        assertEq(limits.bilateralLimit(D, A), 1 * MN);
        assertEq(ledger.check(A, D, 7 * MN), 0);
        assertEq(ledger.check(A, D, 7 * MN + 1), 3);
    }

    // ------------------------------------------------------------ default

    function test_default_waterfall_collateral_pool_survivors() public {
        _standardLimits();
        _elective(B, A, 55 * MN); // limit 60
        _elective(C, A, 35 * MN); // limit 40
        _fund(ICollateralRegister.Kind.POOL, B, 15 * MN);
        _fund(ICollateralRegister.Kind.POOL, C, 5 * MN);
        _fund(ICollateralRegister.Kind.POOL_REQUIRED, bytes32(0), 20 * MN);
        _pay(A, B, 60 * MN);
        _pay(A, C, 40 * MN);

        uint64 b = _cut(3);
        ISettlementBatches.Leg[] memory legs = _submitPlan(b);
        assertEq(legs.length, 2);
        assertEq(legs[0].payee, B);
        assertEq(legs[1].payee, C);

        vm.expectRevert(
            abi.encodeWithSelector(IDefaultManager.DeadlineNotPassed.selector, batches.batch(b).deadline)
        );
        dm.declare(b);
        vm.warp(batches.batch(b).deadline + 1);

        // Leg 0 (A→B 60): collateral 10, pool 20, survivors 30 pro rata 55:35.
        uint256 c0 = 30 * MN * 35 / 90;
        uint256 b0 = 30 * MN - c0;
        // Leg 1 (A→C 40): nothing left before survivors.
        uint256 c1 = 40 * MN * 35 / 90;
        uint256 b1 = 40 * MN - c1;
        vm.expectEmit(address(dm));
        emit IDefaultManager.CoverInstruction(b, 0, COLLATERAL, 10 * MN);
        vm.expectEmit(address(dm));
        emit IDefaultManager.CoverInstruction(b, 0, POOL, 20 * MN);
        vm.prank(stranger);
        dm.declare(b);

        assertEq(uint8(registry.member(A).status), uint8(IMemberRegistry.Status.DEFAULTED));
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.DEFAULTING));
        assertEq(dm.coverAmount(b, 0, COLLATERAL), 10 * MN);
        assertEq(dm.coverAmount(b, 0, POOL), 20 * MN);
        assertEq(dm.coverAmount(b, 0, C), c0);
        assertEq(dm.coverAmount(b, 0, B), b0);
        assertEq(dm.coverAmount(b, 1, B), b1);
        assertEq(dm.coverAmount(b, 1, C), c1);
        assertEq(dm.survivorCall(b, C), c0);
        assertEq(dm.survivorCall(b, B), b1);
        assertEq(dm.absorbed(b, B), b0);
        assertEq(dm.absorbed(b, C), c1);
        assertEq(register.collateral(A), 0);
        assertEq(register.poolTotal(), 0);

        // The defaulter can no longer pay or receive.
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayerNotInGoodStanding.selector, A));
        ledger.pay(B, 1, bytes32(0));

        // Cover payments complete the batch.
        _attest(_payment(b, 0, CHIPS, COLLATERAL, B, 10 * MN));
        _attest(_payment(b, 0, CHIPS, POOL, B, 20 * MN));
        _attest(_payment(b, 0, CHIPS, C, B, c0));
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.DEFAULTING));
        _attest(_payment(b, 1, CHIPS, B, C, b1));
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));

        batches.finalize(b, 10);
        assertEq(tok[A].totalSupply(), 0);
        assertEq(ledger.netPosition(B), 0);
        assertEq(ledger.netPosition(C), 0);

        // The pool must be re-attested before the next cut.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.PoolNotReplenished.selector, 0, 20 * MN));
        batches.cut(3);
        _fund(ICollateralRegister.Kind.POOL, B, 15 * MN);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.PoolNotReplenished.selector, 15 * MN, 20 * MN));
        batches.cut(3);
        _fund(ICollateralRegister.Kind.POOL, C, 5 * MN);
        _cut(3);
    }

    // ------------------------------------------------------------ plan verifier

    function test_planVerifier_rejectsMismatch() public {
        _standardLimits();
        _pay(A, B, 30 * MN);
        _pay(B, C, 10 * MN);
        uint64 b = _cut(3);
        uint64 deadline = uint64(block.timestamp + 1 hours);

        ISettlementBatches.Leg[] memory legs = new ISettlementBatches.Leg[](1);
        legs[0] = _leg(A, B, 30 * MN); // gross, not net: B's net is +20
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.PlanMismatch.selector, B));
        batches.submitPlan(b, legs, deadline);

        legs = new ISettlementBatches.Leg[](2);
        legs[0] = _leg(A, B, 20 * MN);
        legs[1] = _leg(A, C, 10 * MN);
        vm.prank(operator);
        batches.submitPlan(b, legs, deadline);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.PLANNED));
    }
}
