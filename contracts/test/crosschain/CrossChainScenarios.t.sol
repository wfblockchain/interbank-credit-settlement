// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { CrossChainMessenger } from "../../src/crosschain/CrossChainMessenger.sol";
import { HubMessenger } from "../../src/crosschain/HubMessenger.sol";
import { SpokeExposureGuard } from "../../src/crosschain/SpokeExposureGuard.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { ICrossChainMessenger } from "../../src/interfaces/ICrossChainMessenger.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IHubMessenger } from "../../src/interfaces/IHubMessenger.sol";
import { IRemoteObligationToken } from "../../src/interfaces/IRemoteObligationToken.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { ISpokeExposureGuard } from "../../src/interfaces/ISpokeExposureGuard.sol";
import { CrossChainFixture } from "./utils/CrossChainFixture.sol";
import { DvpAgent, TestBond } from "./utils/DvpAgent.sol";

/// Design §4 scenarios 11–18 across the hub (domain 1), a permissioned spoke (2) and a public
/// spoke (3). Scenario 10 (DvP on the public spoke) is in DvpScenarioTest below.
contract CrossChainScenariosTest is CrossChainFixture {
    uint8 internal constant K_MINT = 0;
    uint8 internal constant K_ACK = 1;
    uint8 internal constant K_CANCEL = 2;
    uint8 internal constant K_GRANT = 3;
    uint8 internal constant K_RELEASE = 4;
    uint8 internal constant K_CUT = 5;
    uint8 internal constant K_LOCKED = 6;
    uint8 internal constant K_BURN = 7;
    uint8 internal constant K_SUSPEND = 8;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployCrossChain();
        _standardLimits();
        // $40M collateral for Bank A: mandatory backing $10M, $30M free for public envelopes.
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 40 * MN);
    }

    // ------------------------------------------------------------ (11) one cut across three chains

    function test_11_cutSpanningHomeAndBothSpokes_oneFiatPayment_burnsOnAllThreeChains() public {
        _grant(PERM, A, B, 10 * MN);
        _grant(PERM, B, A, 4 * MN);
        _grant(PUB, A, B, 10 * MN);
        _deliverAll();
        assertEq(register.publicCommitted(A), 10 * MN, "public envelope drawn from collateral");

        _pay(A, B, 5 * MN); // home
        _spokePay(PERM, A, B, 6 * MN);
        _spokePay(PERM, B, A, 2 * MN);
        _spokePay(PUB, A, B, 3 * MN);

        uint64 b = _cutX(3);
        uint64 epoch = batches.batch(b).epoch;
        assertEq(_count(PERM, K_CUT) + _count(PUB, K_CUT), 2, "CUT to every spoke");

        // The plan waits for every spoke's report.
        ISettlementBatches.Leg[] memory early = new ISettlementBatches.Leg[](0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.SpokesNotReported.selector, epoch));
        batches.submitPlan(b, early, uint64(block.timestamp + 1 hours));

        _deliverAll();
        assertTrue(hub.spokesReported(epoch));
        assertEq(hub.remotePairs(epoch).length, 3);
        // Spoke positions moved out of the envelopes into the batch, at the hub and the spoke.
        assertEq(ledger.envelope(PERM, A, B), 4 * MN);
        assertEq(guardOf[PERM].env(A, B), 4 * MN);
        assertEq(guardOf[PERM].lockedTotal(A, B), 6 * MN);
        assertEq(ledger.pending(A, B), 5 * MN + 6 * MN + 3 * MN);

        ISettlementBatches.Leg[] memory legs = _submitPlan(b);
        assertEq(legs.length, 1, "one fiat payment");
        assertEq(legs[0].payer, A);
        assertEq(legs[0].payee, B);
        assertEq(legs[0].amount, 12 * MN); // 5 + 6 + 3 − 2

        _attestPay(b, 0, CHIPS, 12 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
        batches.finalize(b, 100);
        assertEq(tok[A].totalSupply(), 0, "home burned");
        assertEq(_exposure(A, B), 0);

        _sendBurns(epoch);
        assertEq(_count(PERM, K_BURN), 2);
        assertEq(_count(PUB, K_BURN), 1);
        vm.expectRevert(abi.encodeWithSelector(IHubMessenger.BurnsAlreadySent.selector, epoch));
        hub.sendBurns(epoch);
        _deliverAll();

        assertEq(_sumSupply(A), 0, "A-dT gone on all three chains");
        assertEq(_sumSupply(B), 0, "B-dT gone on all three chains");
        assertEq(guardOf[PERM].lockedTotal(A, B), 0);
        assertEq(guardOf[PUB].lockedTotal(A, B), 0);
        assertEq(register.publicCommitted(A), 7 * MN, "settled public part released");
    }

    // ------------------------------------------------------------ (12) slow spoke

    function test_12_slowSpoke_settledPendingBurn_lockedUntilBurnLands() public {
        _grant(PERM, A, B, 10 * MN);
        _grant(PUB, A, B, 10 * MN);
        _deliverAll();
        _spokePay(PERM, A, B, 3 * MN);
        _spokePay(PUB, A, B, 4 * MN);

        uint64 b1 = _cutX(3);
        uint64 e1 = batches.batch(b1).epoch;
        _deliverAll();
        _submitPlan(b1);
        _payAllLegs(b1);
        batches.finalize(b1, 100);
        _sendBurns(e1);
        _deliverAllExcept(PUB); // the public spoke is slow

        // Exposure is released at the hub; on the slow spoke the tokens are settled-pending-burn.
        assertEq(_exposure(A, B), 0);
        assertEq(rtok[PERM][A].totalSupply(), 0);
        IRemoteObligationToken t = rtok[PUB][A];
        assertEq(t.balanceOf(wallet[B]), 4 * MN);
        assertEq(t.lockedOf(wallet[B]), 4 * MN);
        assertEq(t.unlockedBalanceOf(wallet[B]), 0);
        assertEq(guardOf[PUB].locked(e1, A, B), 4 * MN);
        // They cannot move: nothing open to send home, and the token refuses mover transfers.
        vm.prank(wallet[B]);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.MoveExceedsOpen.selector, 4 * MN, 0));
        spokeM[PUB].sendMint(A, B, 4 * MN, HOME, wallet[B], uint64(block.timestamp + 1 days));
        vm.prank(wallet[B]);
        vm.expectRevert();
        t.transfer(wallet[C], 1);

        // Business goes on: a new payment inside the remaining envelope, and the next cut.
        _spokePay(PUB, A, B, 2 * MN);
        uint64 b2 = _cutX(3);
        uint64 e2 = batches.batch(b2).epoch;
        // The slow spoke processes the new CUT before the old BURN_BATCH (independent messages).
        assertFalse(hub.spokesReported(e2));
        _deliverData(PUB, _take(PUB, K_CUT));
        _deliverAllExcept(PUB);
        assertTrue(hub.spokesReported(e2));
        assertEq(t.lockedOf(wallet[B]), 6 * MN);

        // The old burn lands: exactly the epoch-1 part burns.
        _deliverData(PUB, _take(PUB, K_BURN));
        assertEq(t.balanceOf(wallet[B]), 2 * MN);
        assertEq(t.lockedOf(wallet[B]), 2 * MN);
        assertEq(guardOf[PUB].locked(e1, A, B), 0);

        _submitPlan(b2);
        _payAllLegs(b2);
        batches.finalize(b2, 100);
        _sendBurns(e2);
        _deliverAll();
        assertEq(_sumSupply(A), 0);
    }

    // ------------------------------------------------------------ (13) envelope exhaustion

    function test_13_envelopeExhaustion_queuesLocally_grantTopsUp_queueDrains() public {
        _grant(PERM, A, B, 5 * MN);
        _deliverAll();
        _spokePay(PERM, A, B, 4 * MN);

        uint256 next = guardOf[PERM].nextSeq();
        vm.expectEmit(address(guardOf[PERM]));
        emit ISpokeExposureGuard.Queued(next, 1);
        uint256 q = _spokePay(PERM, A, B, 3 * MN);
        assertEq(guardOf[PERM].drain(10), 0);

        // A grant beyond the hub's limits is refused at the hub before anything is sent.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.BilateralLimitExceeded.selector, B, A));
        hub.grantEnvelope(PERM, A, B, 96 * MN);

        _grant(PERM, A, B, 5 * MN);
        assertEq(ledger.envelope(PERM, A, B), 10 * MN, "headroom reserved at the hub first");
        assertEq(guardOf[PERM].drain(10), 0, "not before the grant lands");
        _deliverAll();
        assertEq(guardOf[PERM].env(A, B), 10 * MN);
        assertEq(guardOf[PERM].drain(10), 1);
        assertEq(uint8(guardOf[PERM].queueEntry(q).state), uint8(ISpokeExposureGuard.QueueState.PAID));
        assertEq(rtok[PERM][A].balanceOf(wallet[B]), 7 * MN);
        assertEq(guardOf[PERM].used(A, B), 7 * MN);
        assertLe(guardOf[PERM].used(A, B), guardOf[PERM].env(A, B));

        // Release the unused part: spoke first, then the hub.
        _release(PERM, A, B, 3 * MN);
        assertEq(guardOf[PERM].env(A, B), 7 * MN);
        assertEq(ledger.envelope(PERM, A, B), 10 * MN);
        _deliverAll();
        assertEq(ledger.envelope(PERM, A, B), 7 * MN);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.ReleaseExceedsFree.selector, 1, 0));
        spokeM[PERM].releaseEnvelope(A, B, 1);
    }

    // ------------------------------------------------------------ (14) attestation thresholds

    function test_14_belowThreshold_issuerKeyAlone_replay_noMint() public {
        _pay(A, B, 10 * MN);
        _moveOut(PERM, A, B, 4 * MN);
        bytes memory m = _take(PERM, K_MINT);
        CrossChainMessenger dst = _messenger(PERM);
        bytes memory iss = _issuerSig(PERM, m);

        // Two of five attesters.
        bytes[] memory s2 = _attSigs(PERM, m, 2);
        bytes[] memory s3ok = _attSigs(PERM, m, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NotEnoughAttestations.selector, 2, 3));
        dst.receiveMessage(m, s2, iss);

        // The issuer key alone.
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NotEnoughAttestations.selector, 0, 3));
        dst.receiveMessage(m, new bytes[](0), iss);
        // ... nor can it stand in for an attester.
        bytes[] memory withIssuer = new bytes[](3);
        withIssuer[0] = s2[0];
        withIssuer[1] = s2[1];
        withIssuer[2] = iss;
        vm.expectRevert();
        dst.receiveMessage(m, withIssuer, iss);

        // Majority without the issuer's signature.
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadIssuerSignature.selector, A, address(0)));
        dst.receiveMessage(m, s3ok, "");

        // Unsorted or repeated attesters.
        bytes[] memory s3 = _attSigs(PERM, m, 3);
        (s3[0], s3[1]) = (s3[1], s3[0]);
        vm.expectRevert(ICrossChainMessenger.SignersNotSorted.selector);
        dst.receiveMessage(m, s3, iss);
        bytes[] memory dup = _attSigs(PERM, m, 3);
        dup[2] = dup[1];
        vm.expectRevert(ICrossChainMessenger.SignersNotSorted.selector);
        dst.receiveMessage(m, dup, iss);

        // Sent to the wrong chain.
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.WrongDestination.selector, PERM));
        _messenger(PUB).receiveMessage(m, new bytes[](0), iss);

        assertEq(rtok[PERM][A].totalSupply(), 0, "nothing minted");

        vm.recordLogs();
        dst.receiveMessage(m, s3ok, iss);
        _collect();
        assertEq(rtok[PERM][A].balanceOf(wallet[B]), 4 * MN);
        assertEq(uint8(dst.inbound(HOME, _env(m).nonce)), uint8(ICrossChainMessenger.Inbound.MINTED));

        bytes[] memory again = _attSigs(PERM, m, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NonceUsed.selector, HOME, _env(m).nonce));
        dst.receiveMessage(m, again, iss);
        assertEq(rtok[PERM][A].totalSupply(), 4 * MN, "minted once");

        // The ACK burns the locked home tokens.
        assertEq(tok[A].balanceOf(address(hub)), 4 * MN);
        _deliverAll();
        assertEq(tok[A].balanceOf(address(hub)), 0);
        assertEq(_sumSupply(A), 10 * MN);
    }

    // ------------------------------------------------------------ (15) SUSPEND

    function test_15_suspend_zeroesEnvelopes_freezesTokenEverywhere_raisesNothing() public {
        _grant(PERM, A, B, 10 * MN);
        _grant(PERM, B, A, 5 * MN);
        _grant(PERM, C, B, 5 * MN);
        _grant(PUB, A, C, 5 * MN);
        _deliverAll();
        _spokePay(PERM, A, B, 3 * MN);
        _spokePay(PUB, A, C, 1 * MN);

        // Anyone may broadcast it once the member is out of good standing; not before.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHubMessenger.MemberInGoodStanding.selector, A));
        hub.sendSuspend(A);
        vm.prank(guardian);
        registry.suspend(A, bytes32("PCA"));
        vm.recordLogs();
        vm.prank(stranger);
        hub.sendSuspend(A);
        _collect();
        assertEq(_count(PERM, K_SUSPEND) + _count(PUB, K_SUSPEND), 2);
        _deliverAll();

        SpokeExposureGuard g2 = guardOf[PERM];
        SpokeExposureGuard g3 = guardOf[PUB];
        assertEq(g2.available(A, B), 0);
        assertEq(g2.env(A, B), 3 * MN, "cut to what is in use");
        assertEq(g2.env(B, A), 0);
        assertEq(g2.releasable(A, B), 7 * MN);
        assertEq(g2.releasable(B, A), 5 * MN);
        assertEq(g2.env(C, B), 5 * MN, "pairs without the member untouched");
        assertEq(g3.env(A, C), 1 * MN);
        assertEq(g3.available(A, C), 0);
        assertTrue(rtok[PERM][A].paused());
        assertTrue(rtok[PUB][A].paused());
        assertTrue(g2.member(A).suspended);

        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.MemberSuspended.selector, A));
        g2.pay(B, 1, bytes32(0));
        vm.prank(ops[C]);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.MemberSuspended.selector, A));
        g2.pay(A, 1, bytes32(0));

        // A second SUSPEND, and a forged one carrying amounts and parties, raise nothing.
        uint256 supplyBefore = _sumSupply(A);
        vm.recordLogs();
        vm.prank(guardian);
        hub.sendSuspend(A);
        _collect();
        _deliverAll();
        bytes memory forged = abi.encode(
            ICrossChainMessenger.Envelope({
                version: 4,
                kind: K_SUSPEND,
                source: HOME,
                dest: PERM,
                nonce: 9_999,
                member: A,
                counterparty: B,
                recipient: wallet[B],
                amount: BIG,
                epoch: 1,
                deadline: type(uint64).max,
                ref: bytes32(uint256(1))
            })
        );
        spokeM[PERM].receiveMessage(forged, _attSigs(PERM, forged, 3), "");
        assertEq(g2.env(A, B), 3 * MN);
        assertEq(g2.env(B, A), 0);
        assertEq(g2.env(C, B), 5 * MN);
        assertEq(_sumSupply(A), supplyBefore);
        assertTrue(rtok[PERM][A].paused());

        // Reinstated at home but still suspended on the spoke: a new grant is parked, not applied.
        vm.prank(gov);
        registry.reinstate(A);
        _grant(PERM, A, B, 2 * MN);
        _deliverAll();
        assertEq(g2.env(A, B), 3 * MN);
        assertEq(g2.releasable(A, B), 9 * MN);
        // A move of A-dT into the spoke is refused there and unlocked at home.
        _pay(A, B, 1 * MN);
        _moveOut(PERM, A, B, 1 * MN);
        _deliverAll();
        assertEq(rtok[PERM][A].balanceOf(wallet[B]), 3 * MN);
        assertEq(tok[A].balanceOf(wallet[B]), 1 * MN, "unlocked at home");

        // The operator hands the parked headroom back to the hub.
        uint256 hubEnv = ledger.envelope(PERM, A, B);
        _release(PERM, A, B, 9 * MN);
        _deliverAll();
        assertEq(ledger.envelope(PERM, A, B), hubEnv - 9 * MN);
        assertEq(ledger.envelope(PERM, A, B), g2.env(A, B));

        // Settlement still extinguishes the frozen issuer's tokens.
        _settleAll(3);
        assertEq(_sumSupply(A), 0);
    }

    // ------------------------------------------------------------ (16) lost spoke

    function test_16_lostSpoke_lossBoundedByEnvelope_supplyCap_rateLimit() public {
        _grant(PERM, A, B, 10 * MN);
        _deliverAll();
        _spokePay(PERM, A, B, 6 * MN);
        _pay(A, B, 20 * MN);
        _moveOut(PERM, A, B, 5 * MN);
        _deliverAll();
        assertEq(hub.sent(A, PERM), 5 * MN);
        assertEq(ledger.envelope(PERM, A, B), 15 * MN);
        assertEq(guardOf[PERM].env(A, B), 15 * MN);
        uint256 grossBefore = ledger.gross(A, B);

        // The permissioned spoke is lost: whatever it emits is attested as it stands, and Bank A's
        // key is assumed fooled too. Hub bound 1: the global accountant (sent 5, returned 0).
        vm.prank(gov);
        hub.setRateLimit(PERM, A, 2 * MN, 1 hours);
        bytes memory big = _forged(PERM, HOME, 50_001, K_MINT, A, B, wallet[B], 100 * MN, 0);
        hub.receiveMessage(big, _attSigs(HOME, big, 3), _issuerSig(HOME, big));
        assertEq(uint8(hub.inbound(PERM, 50_001)), uint8(ICrossChainMessenger.Inbound.CANCELLED));
        assertEq(tok[A].totalSupply(), 15 * MN, "refused: more than home sent");

        // Hub bound 2: the inbound rate limit (2 per hour).
        bytes memory m1 = _forged(PERM, HOME, 50_002, K_MINT, A, B, wallet[B], 3 * MN, 0);
        bytes[] memory s1 = _attSigs(HOME, m1, 3);
        bytes memory i1 = _issuerSig(HOME, m1);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.RateLimited.selector, PERM, A, 3 * MN, 2 * MN));
        hub.receiveMessage(m1, s1, i1);
        bytes memory m2 = _forged(PERM, HOME, 50_003, K_MINT, A, B, wallet[B], 2 * MN, 0);
        hub.receiveMessage(m2, _attSigs(HOME, m2, 3), _issuerSig(HOME, m2));
        assertEq(tok[A].totalSupply(), 17 * MN);
        vm.warp(block.timestamp + 1 hours);
        bytes memory m3 = _forged(PERM, HOME, 50_004, K_MINT, A, B, wallet[B], 2 * MN, 0);
        hub.receiveMessage(m3, _attSigs(HOME, m3, 3), _issuerSig(HOME, m3));
        vm.warp(block.timestamp + 1 hours);
        bytes memory m4 = _forged(PERM, HOME, 50_005, K_MINT, A, B, wallet[B], 2 * MN, 0);
        hub.receiveMessage(m4, _attSigs(HOME, m4, 3), _issuerSig(HOME, m4));
        assertEq(uint8(hub.inbound(PERM, 50_005)), uint8(ICrossChainMessenger.Inbound.CANCELLED), "4 + 2 > 5 sent");
        assertEq(tok[A].totalSupply(), 19 * MN);
        // What landed came out of the spoke's envelope: exposure at the hub never grew.
        assertEq(ledger.gross(A, B), grossBefore);
        assertEq(ledger.envelope(PERM, A, B), 11 * MN);

        // Hub bound 3: the envelope. A forged report larger than the envelope cannot enter a batch.
        uint64 b = _cutX(3);
        uint64 epoch = batches.batch(b).epoch;
        bytes memory rep = _forged(PERM, HOME, 50_006, K_LOCKED, A, B, address(0), 1_000 * MN, epoch);
        bytes[] memory rs = _attSigs(HOME, rep, 3);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.EnvelopeUnderflow.selector, 1_000 * MN, 11 * MN));
        hub.receiveMessage(rep, rs, "");

        // The guardian disconnects it: nothing more is accepted, plans no longer wait for it, and
        // its envelope stays reserved at the hub. The loss is bounded by that envelope.
        vm.prank(guardian);
        hub.disconnectSpoke(PERM);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.UntrustedSource.selector, PERM));
        hub.receiveMessage(rep, rs, "");
        _deliverTo(PUB);
        _deliverTo(HOME);
        assertTrue(hub.spokesReported(epoch));
        _submitPlan(b);
        _payAllLegs(b);
        batches.finalize(b, 100);
        assertEq(ledger.envelope(PERM, A, B), 11 * MN, "lost spoke's envelope still counted");
        assertEq(ledger.gross(A, B), 11 * MN);

        // Spoke-side bounds for forged inbound MINTs (the spoke's own contracts honest): supply cap
        // and the spoke's inbound rate limit.
        SpokeExposureGuard g3 = guardOf[PUB];
        vm.startPrank(gov);
        g3.setSupplyCap(A, 8 * MN);
        spokeM[PUB].setRateLimit(HOME, A, 3 * MN, 1 hours);
        vm.stopPrank();
        bytes memory f1 = _forged(HOME, PUB, 60_001, K_MINT, A, C, wallet[C], 9 * MN, 0);
        spokeM[PUB].receiveMessage(f1, _attSigs(PUB, f1, 3), _issuerSig(PUB, f1));
        assertEq(uint8(spokeM[PUB].inbound(HOME, 60_001)), uint8(ICrossChainMessenger.Inbound.CANCELLED));
        bytes memory f2 = _forged(HOME, PUB, 60_002, K_MINT, A, C, wallet[C], 4 * MN, 0);
        bytes[] memory fs2 = _attSigs(PUB, f2, 3);
        bytes memory fi2 = _issuerSig(PUB, f2);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.RateLimited.selector, HOME, A, 4 * MN, 3 * MN));
        spokeM[PUB].receiveMessage(f2, fs2, fi2);
        assertEq(rtok[PUB][A].totalSupply(), 0);
    }

    // ------------------------------------------------------------ (17) forged MINT

    function test_17_forgedMint_wrongIssuerKey_refused_bothKeys_cappedByRateAndAccountant() public {
        // Majority of attesters, but signed by Bank B's key for an A-dT mint.
        bytes memory m = _forged(PUB, HOME, 70_001, K_MINT, A, B, wallet[B], 5 * MN, 0);
        bytes memory wrong = _signWith(issuerKeyOf[B], HOME, m);
        bytes[] memory ms = _attSigs(HOME, m, 3);
        vm.expectRevert(
            abi.encodeWithSelector(ICrossChainMessenger.BadIssuerSignature.selector, A, vm.addr(issuerKeyOf[B]))
        );
        hub.receiveMessage(m, ms, wrong);
        // Or by an attester's key.
        bytes memory attAsIssuer = _signWith(attKeys[4], HOME, m);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadIssuerSignature.selector, A, attAddrs[4]));
        hub.receiveMessage(m, ms, attAsIssuer);

        // Both keys forced. At home, the global accountant: home never sent A-dT to the public spoke.
        vm.recordLogs();
        hub.receiveMessage(m, ms, _issuerSig(HOME, m));
        _collect();
        assertEq(uint8(hub.inbound(PUB, 70_001)), uint8(ICrossChainMessenger.Inbound.CANCELLED));
        assertEq(tok[A].totalSupply(), 0);
        assertEq(_count(PUB, K_CANCEL), 1, "refusal goes back as MINT_CANCEL");

        // On a spoke, the receiving chain's rate limit caps forged mints per window.
        vm.prank(gov);
        spokeM[PERM].setRateLimit(HOME, A, 5 * MN, 1 hours);
        uint256 minted;
        for (uint64 n = 0; n < 4; n++) {
            bytes memory f = _forged(HOME, PERM, 80_000 + n, K_MINT, A, B, wallet[B], 2 * MN, 0);
            bytes[] memory fs = _attSigs(PERM, f, 3);
            bytes memory fi = _issuerSig(PERM, f);
            try spokeM[PERM].receiveMessage(f, fs, fi) {
                minted += 2 * MN;
            } catch { }
        }
        assertEq(minted, 4 * MN, "two of four fit the 5-per-hour bucket");
        assertEq(rtok[PERM][A].totalSupply(), 4 * MN);
        assertEq(spokeM[PERM].rateAvailable(HOME, A), 1 * MN);
        // Burns are never rate limited: the bucket does not apply to BURN_BATCH or ACK/CANCEL.
        vm.warp(block.timestamp + 30 minutes);
        assertEq(spokeM[PERM].rateAvailable(HOME, A), 1 * MN + 5 * MN / 2);
    }

    // ------------------------------------------------------------ (18) destination never mints

    function test_18_destinationNeverMints_cancelAfterDeadline_sourceUnlocks_noLossNoDuplicate() public {
        _pay(A, B, 10 * MN);
        uint64 nonce = _moveOut(PERM, A, B, 4 * MN);
        bytes memory m = _take(PERM, K_MINT);
        assertEq(tok[A].balanceOf(wallet[B]), 6 * MN);
        assertEq(tok[A].balanceOf(address(hub)), 4 * MN, "locked, not burned");
        assertEq(ledger.open(A, B), 6 * MN);
        assertEq(ledger.envelope(PERM, A, B), 4 * MN);
        assertEq(ledger.gross(A, B), 10 * MN, "exposure moved, not dropped");
        assertEq(hub.sent(A, PERM), 4 * MN);
        assertEq(uint8(hub.move(nonce).status), uint8(ICrossChainMessenger.MoveStatus.PENDING));

        CrossChainMessenger dst = _messenger(PERM);
        bytes[] memory sigs = _attSigs(PERM, m, 3);
        uint64 deadline = _env(m).deadline;
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.DeadlineNotPassed.selector, deadline));
        dst.cancelExpired(m, sigs);

        vm.warp(uint256(deadline) + 1);
        vm.recordLogs();
        vm.prank(stranger);
        dst.cancelExpired(m, sigs);
        _collect();
        assertEq(uint8(dst.inbound(HOME, nonce)), uint8(ICrossChainMessenger.Inbound.CANCELLED));

        // It can never mint afterwards.
        bytes memory iss = _issuerSig(PERM, m);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NonceUsed.selector, HOME, nonce));
        dst.receiveMessage(m, sigs, iss);

        bytes memory cancel = _take(HOME, K_CANCEL);
        _deliverData(HOME, cancel);
        assertEq(uint8(hub.move(nonce).status), uint8(ICrossChainMessenger.MoveStatus.CANCELLED));
        assertEq(tok[A].balanceOf(wallet[B]), 10 * MN, "unlocked: no loss");
        assertEq(tok[A].balanceOf(address(hub)), 0);
        assertEq(rtok[PERM][A].totalSupply(), 0, "no duplicate");
        assertEq(ledger.open(A, B), 10 * MN);
        assertEq(ledger.envelope(PERM, A, B), 0);
        assertEq(hub.sent(A, PERM), 0);
        assertEq(_sumSupply(A), 10 * MN);

        // The cancel cannot be replayed, and a late ACK for the same move is refused.
        bytes[] memory cs = _attSigs(HOME, cancel, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NonceUsed.selector, PERM, _env(cancel).nonce));
        hub.receiveMessage(cancel, cs, "");
        bytes memory lateAck = _forged(PERM, HOME, 90_001, K_ACK, A, B, wallet[B], 4 * MN, 0);
        lateAck = _withRef(lateAck, bytes32(uint256(nonce)));
        bytes[] memory ls = _attSigs(HOME, lateAck, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.MoveMismatch.selector, nonce));
        hub.receiveMessage(lateAck, ls, "");

        // Settles normally afterwards.
        _settleAll(3);
        assertEq(_sumSupply(A), 0);
    }

    // ------------------------------------------------------------ moves both ways

    function test_moves_homeToSpokeAndBack_envelopeAccounting() public {
        _pay(A, B, 10 * MN);
        _moveOut(PERM, A, B, 6 * MN);
        _deliverAll();
        assertEq(rtok[PERM][A].balanceOf(wallet[B]), 6 * MN);
        assertEq(guardOf[PERM].env(A, B), 6 * MN);
        assertEq(guardOf[PERM].used(A, B), 6 * MN);
        assertEq(tok[A].totalSupply(), 4 * MN, "home escrow burned on ACK");

        _moveHome(PERM, A, B, 2 * MN);
        assertEq(guardOf[PERM].env(A, B), 4 * MN, "lowered at the spoke first");
        assertEq(rtok[PERM][A].lockedOf(wallet[B]), 2 * MN);
        _deliverAll();
        assertEq(tok[A].balanceOf(wallet[B]), 6 * MN);
        assertEq(rtok[PERM][A].balanceOf(wallet[B]), 4 * MN);
        assertEq(rtok[PERM][A].lockedOf(wallet[B]), 0);
        assertEq(hub.returned(A, PERM), 2 * MN);
        assertEq(ledger.envelope(PERM, A, B), 4 * MN);
        assertEq(ledger.open(A, B), 6 * MN);
        assertEq(ledger.gross(A, B), 10 * MN);

        // Spoke-native tokens (paid on the spoke, never sent from home) cannot go home: refused at
        // the hub by the accountant, unlocked on the spoke.
        _grant(PERM, C, B, 5 * MN);
        _deliverAll();
        _spokePay(PERM, C, B, 3 * MN);
        _moveHome(PERM, C, B, 3 * MN);
        _deliverAll();
        assertEq(tok[C].totalSupply(), 0);
        assertEq(rtok[PERM][C].unlockedBalanceOf(wallet[B]), 3 * MN);
        assertEq(guardOf[PERM].used(C, B), 3 * MN);

        _settleAll(3);
        assertEq(_sumSupply(A), 0);
        assertEq(_sumSupply(C), 0);
    }

    function test_moves_toPublicSpoke_drawFreeCollateral() public {
        _pay(B, A, 10 * MN);
        _pay(A, B, 10 * MN);
        _moveOut(PUB, A, B, 6 * MN);
        assertEq(register.publicCommitted(A), 6 * MN);
        _deliverAll();
        // Back home from the public spoke: credit checks run for the converted position.
        _moveHome(PUB, A, B, 6 * MN);
        _deliverAll();
        assertEq(register.publicCommitted(A), 0);
        assertEq(tok[A].balanceOf(wallet[B]), 10 * MN);
        // Above the issuer's free collateral the move is refused at the source.
        _pay(A, C, 40 * MN);
        vm.prank(wallet[C]);
        tok[A].approve(address(hub), 31 * MN);
        vm.prank(wallet[C]);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegister.InsufficientFreeCollateral.selector, A, 31 * MN, 30 * MN)
        );
        hub.sendMint(A, C, 31 * MN, PUB, wallet[C], uint64(block.timestamp + 1 days));
    }

    // ------------------------------------------------------------ helpers

    function _forged(
        uint32 src,
        uint32 dst,
        uint64 nonce,
        uint8 kind,
        bytes32 member,
        bytes32 counterparty,
        address recipient,
        uint256 amount,
        uint64 epoch
    ) internal view returns (bytes memory) {
        return abi.encode(
            ICrossChainMessenger.Envelope({
                version: 4,
                kind: kind,
                source: src,
                dest: dst,
                nonce: nonce,
                member: member,
                counterparty: counterparty,
                recipient: recipient,
                amount: amount,
                epoch: epoch,
                deadline: uint64(block.timestamp + 1 days),
                ref: bytes32(0)
            })
        );
    }

    function _withRef(bytes memory data, bytes32 ref) internal pure returns (bytes memory) {
        ICrossChainMessenger.Envelope memory e = abi.decode(data, (ICrossChainMessenger.Envelope));
        e.ref = ref;
        return abi.encode(e);
    }
}

/// (10) Delivery versus payment on the public spoke, paid in Bank A's token drawn from its
/// collateral envelope.
contract DvpScenarioTest is CrossChainFixture {
    DvpAgent internal agent;
    TestBond internal bond;

    function _opsOn(uint32 d, bytes32 id) internal view override returns (address) {
        if (d == PUB && id == A) {
            return address(agent);
        }
        return ops[id];
    }

    function setUp() public {
        vm.warp(1_760_000_000);
        bond = new TestBond();
        agent = new DvpAgent(bond);
        _deployCrossChain();
        agent.bind(guardOf[PUB], ops[A]);
        _standardLimits();
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 40 * MN);
    }

    function test_10_dvpOnPublicSpoke_paidFromCollateralEnvelope() public {
        assertEq(register.freeCollateral(A), 30 * MN);
        // Default credit on a public spoke is zero: nothing can be paid there without an envelope.
        assertEq(guardOf[PUB].env(A, B), 0);

        _grant(PUB, A, B, 20 * MN);
        assertEq(register.publicCommitted(A), 20 * MN, "drawn one-for-one from free collateral");
        assertEq(register.freeCollateral(A), 10 * MN);
        _deliverAll();
        assertEq(guardOf[PUB].env(A, B), 20 * MN);
        // A grant above the free collateral is refused at the hub.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegister.InsufficientFreeCollateral.selector, A, 11 * MN, 10 * MN)
        );
        hub.grantEnvelope(PUB, A, C, 11 * MN);

        // Bank B's customer sells a bond to Bank A; B's wallet escrows it with the agent.
        bond.mint(wallet[B], 100);
        vm.startPrank(wallet[B]);
        bond.approve(address(agent), 100);
        uint256 d1 = agent.offer(B, 60, 7 * MN);
        uint256 d2 = agent.offer(B, 40, 14 * MN);
        vm.stopPrank();

        vm.prank(ops[A]);
        agent.settle(d1, wallet[A]);
        assertEq(bond.balanceOf(wallet[A]), 60, "delivered");
        assertEq(rtok[PUB][A].balanceOf(wallet[B]), 7 * MN, "paid");
        assertEq(guardOf[PUB].used(A, B), 7 * MN);

        // 14 > 13 left in the envelope: the payment would queue, so nothing is delivered.
        vm.prank(ops[A]);
        vm.expectRevert();
        agent.settle(d2, wallet[A]);
        assertEq(bond.balanceOf(address(agent)), 40);
        assertEq(guardOf[PUB].queueLength(), 0);

        // The position settles in the next cut like any other; the settled part of the
        // collateral envelope is released.
        _settleAll(3);
        assertEq(rtok[PUB][A].totalSupply(), 0);
        assertEq(register.publicCommitted(A), 13 * MN);
        assertEq(ledger.envelope(PUB, A, B), 13 * MN);
    }
}
