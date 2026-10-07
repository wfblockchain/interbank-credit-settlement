// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { HubMessenger } from "../../src/crosschain/HubMessenger.sol";
import { RemoteObligationToken } from "../../src/crosschain/RemoteObligationToken.sol";
import { SpokeExposureGuard } from "../../src/crosschain/SpokeExposureGuard.sol";
import { SpokeMessenger } from "../../src/crosschain/SpokeMessenger.sol";
import { ICrossChainMessenger } from "../../src/interfaces/ICrossChainMessenger.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IHubMessenger } from "../../src/interfaces/IHubMessenger.sol";
import { IObligationToken } from "../../src/interfaces/IObligationToken.sol";
import { IRemoteObligationToken } from "../../src/interfaces/IRemoteObligationToken.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { ISpokeExposureGuard } from "../../src/interfaces/ISpokeExposureGuard.sol";
import { CrossChainFixture } from "./utils/CrossChainFixture.sol";

contract CrossChainUnitsTest is CrossChainFixture {
    function setUp() public {
        vm.warp(1_760_000_000);
        _deployCrossChain();
        _standardLimits();
    }

    // ------------------------------------------------------------ RemoteObligationToken

    function _bareToken() internal returns (RemoteObligationToken t, address g) {
        g = makeAddr("bare-guard");
        t = new RemoteObligationToken(0, gov, "Bank A deposit token", "A-dT", A, g, issuerAdmin[A], guardian);
    }

    function test_token_rolesAndNoUserTransfers() public {
        (RemoteObligationToken t, address g) = _bareToken();
        assertEq(t.decimals(), 6);
        assertEq(t.issuer(), A);
        vm.expectRevert();
        t.mint(wallet[B], 1);
        vm.prank(g);
        t.mint(wallet[B], 10);
        vm.prank(wallet[B]);
        vm.expectRevert(IObligationToken.TransfersDisabled.selector);
        t.transfer(wallet[C], 1);
        vm.prank(wallet[B]);
        vm.expectRevert(IObligationToken.TransfersDisabled.selector);
        t.approve(wallet[C], 1);
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.NotBurner.selector, address(this)));
        t.burn(wallet[B], 1);
    }

    function test_token_locks() public {
        (RemoteObligationToken t, address g) = _bareToken();
        vm.startPrank(g);
        t.mint(wallet[B], 10);
        t.lock(wallet[B], 6);
        assertEq(t.unlockedBalanceOf(wallet[B]), 4);
        vm.expectRevert(abi.encodeWithSelector(IRemoteObligationToken.ExceedsUnlocked.selector, wallet[B], 5, 4));
        t.lock(wallet[B], 5);
        vm.expectRevert(abi.encodeWithSelector(IRemoteObligationToken.ExceedsUnlocked.selector, wallet[B], 5, 4));
        t.burn(wallet[B], 5);
        t.unlock(wallet[B], 2);
        assertEq(t.lockedOf(wallet[B]), 4);
        vm.expectRevert(abi.encodeWithSelector(IRemoteObligationToken.ExceedsLocked.selector, wallet[B], 5, 4));
        t.burnLocked(wallet[B], 5);
        t.burnLocked(wallet[B], 4);
        vm.stopPrank();
        assertEq(t.balanceOf(wallet[B]), 6);
        assertEq(t.lockedOf(wallet[B]), 0);
        // A mover cannot take a locked balance.
        bytes32 mover = t.MOVER_ROLE();
        vm.prank(gov);
        t.grantRole(mover, address(this));
        vm.prank(g);
        t.lock(wallet[B], 6);
        vm.prank(wallet[B]);
        t.approve(address(this), 6);
        vm.expectRevert(abi.encodeWithSelector(IRemoteObligationToken.ExceedsUnlocked.selector, wallet[B], 1, 0));
        t.transferFrom(wallet[B], address(this), 1);
    }

    function test_token_pauseRestrictOnly_settlementBurnsWhilePaused() public {
        (RemoteObligationToken t, address g) = _bareToken();
        vm.startPrank(g);
        t.mint(wallet[B], 10);
        t.lock(wallet[B], 10);
        t.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        t.mint(wallet[B], 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, g, t.ISSUER_ADMIN_ROLE())
        );
        t.unpause();
        t.burnLocked(wallet[B], 10);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.NotPauser.selector, stranger));
        vm.prank(stranger);
        t.pause();
        vm.prank(issuerAdmin[A]);
        t.unpause();
        vm.prank(guardian);
        t.setFrozen(wallet[C], true);
        vm.prank(g);
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.HolderFrozen.selector, wallet[C]));
        t.mint(wallet[C], 1);
    }

    // ------------------------------------------------------------ SpokeExposureGuard

    function test_guard_setMember_checks() public {
        SpokeExposureGuard g = guardOf[PERM];
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.MemberAlreadySet.selector, A));
        g.setMember(A, makeAddr("w"), makeAddr("o"), address(rtok[PERM][A]));
        bytes32 d = bytes32("BNKDUS30");
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.TokenIssuerMismatch.selector, d, A));
        g.setMember(d, makeAddr("w"), makeAddr("o"), address(rtok[PERM][A]));
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.AddressInUse.selector, wallet[A]));
        g.setMember(d, wallet[A], makeAddr("o"), address(rtok[PERM][A]));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert();
        g.setMember(d, makeAddr("w"), makeAddr("o"), address(rtok[PERM][A]));
    }

    function test_guard_pay_rejects() public {
        SpokeExposureGuard g = guardOf[PERM];
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.NotIssuerOps.selector, stranger));
        g.pay(B, 1, 0);
        vm.startPrank(ops[A]);
        vm.expectRevert(ISpokeExposureGuard.ZeroAmount.selector);
        g.pay(B, 0, 0);
        vm.expectRevert(ISpokeExposureGuard.SelfPayment.selector);
        g.pay(A, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.UnknownMember.selector, bytes32("NOPE")));
        g.pay(bytes32("NOPE"), 1, 0);
        vm.stopPrank();
    }

    function test_guard_queue_supplyCap_cancel_drain() public {
        SpokeExposureGuard g = guardOf[PERM];
        _grant(PERM, A, B, 10 * MN);
        _deliverAll();
        vm.prank(gov);
        g.setSupplyCap(A, 3 * MN);
        uint256 next = g.nextSeq();
        vm.expectEmit(address(g));
        emit ISpokeExposureGuard.Queued(next, 2);
        uint256 q = _spokePay(PERM, A, B, 4 * MN);
        vm.prank(ops[B]);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.NotPayer.selector, q));
        g.cancel(q);
        assertEq(g.drain(5), 0);
        vm.prank(gov);
        g.setSupplyCap(A, 10 * MN);
        assertEq(g.drain(5), 1);
        uint256 q2 = _spokePay(PERM, A, B, 7 * MN);
        vm.prank(ops[A]);
        g.cancel(q2);
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.NotQueued.selector, q2));
        g.cancel(q2);
        // A queued payment of a member later suspended is cancelled by drain.
        uint256 q3 = _spokePay(PERM, A, B, 7 * MN);
        vm.prank(address(spokeM[PERM]));
        g.suspend(A);
        assertEq(g.drain(5), 0);
        assertEq(uint8(g.queueEntry(q3).state), uint8(ISpokeExposureGuard.QueueState.CANCELLED));
        // Guardian may only lower a supply cap.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.NotALowering.selector, 10 * MN, 11 * MN));
        g.lowerSupplyCap(A, 11 * MN);
        vm.prank(guardian);
        g.lowerSupplyCap(A, 1);
        assertEq(g.supplyCap(A), 1);
    }

    function test_guard_hooksOnlyMessenger_cutOnce_burnExact() public {
        SpokeExposureGuard g = guardOf[PERM];
        bytes32 role = g.MESSENGER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role));
        g.grant(A, B, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role));
        g.suspend(A);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role));
        g.burnBatch(1, A, B, 1);

        vm.startPrank(address(spokeM[PERM]));
        g.grant(A, B, 10 * MN);
        vm.stopPrank();
        _spokePay(PERM, A, B, 4 * MN);
        vm.startPrank(address(spokeM[PERM]));
        (bytes32[] memory is_,, uint256[] memory amts) = g.cut(7);
        assertEq(is_.length, 1);
        assertEq(amts[0], 4 * MN);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.EpochAlreadyLocked.selector, 7));
        g.cut(7);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.BurnMismatch.selector, 7, A, B, 3 * MN, 4 * MN));
        g.burnBatch(7, A, B, 3 * MN);
        g.burnBatch(7, A, B, 4 * MN);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.BurnMismatch.selector, 7, A, B, 4 * MN, 0));
        g.burnBatch(7, A, B, 4 * MN);
        // Grants for unknown members are parked, never applied.
        assertFalse(g.grant(A, bytes32("NOPE"), 5));
        assertEq(g.releasable(A, bytes32("NOPE")), 5);
        vm.expectRevert(abi.encodeWithSelector(ISpokeExposureGuard.NotHolderWallet.selector, B, wallet[C]));
        g.moveOut(A, B, wallet[C], 1);
        vm.stopPrank();
        assertEq(g.env(A, B), 6 * MN);
        assertEq(rtok[PERM][A].totalSupply(), 0);
    }

    // ------------------------------------------------------------ messenger configuration

    function test_messenger_thresholdIsStrictMajority() public {
        address[] memory five = attAddrs;
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadThreshold.selector, 2, 5));
        new SpokeMessenger(0, gov, 9, HOME, makeAddr("g"), guardian, operator, five, 2);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadThreshold.selector, 6, 5));
        new SpokeMessenger(0, gov, 9, HOME, makeAddr("g"), guardian, operator, five, 6);
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadThreshold.selector, 3, 6));
        hub.setAttester(makeAddr("sixth"), true);
        hub.setThreshold(4);
        hub.setAttester(makeAddr("sixth"), true);
        assertEq(hub.attesterCount(), 6);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadThreshold.selector, 3, 6));
        hub.setThreshold(3);
        vm.stopPrank();
        // The guardian disables one at once, but never below a reachable threshold.
        vm.prank(guardian);
        hub.disableAttester(makeAddr("sixth"));
        vm.prank(guardian);
        hub.disableAttester(attAddrs[0]); // 4 of 4 is still reachable
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadThreshold.selector, 4, 3));
        hub.disableAttester(attAddrs[1]);
    }

    function test_messenger_keysHoldOneRole() public {
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.KeyHasOtherRole.selector, attAddrs[0]));
        hub.setIssuerKey(A, attAddrs[0]);
        address bKey = vm.addr(issuerKeyOf[B]);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.KeyHasOtherRole.selector, bKey));
        hub.setIssuerKey(A, bKey);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.KeyHasOtherRole.selector, bKey));
        hub.setAttester(bKey, true);
        address rotated = makeAddr("a-key-2");
        hub.setIssuerKey(A, rotated);
        assertEq(hub.issuerKey(A), rotated);
        assertEq(hub.issuerOfKey(vm.addr(issuerKeyOf[A])), bytes32(0));
        vm.stopPrank();
    }

    function test_spoke_talksOnlyToHome() public {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.SpokeToSpoke.selector, PUB));
        spokeM[PERM].setRemote(PUB, address(spokeM[PUB]));
        vm.prank(wallet[B]);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.SpokeToSpoke.selector, PUB));
        spokeM[PERM].sendMint(A, B, 1, PUB, wallet[B], uint64(block.timestamp + 1));
    }

    function test_hub_permissions() public {
        vm.expectRevert();
        hub.grantEnvelope(PERM, A, B, 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IHubMessenger.NotASpoke.selector, 9));
        hub.grantEnvelope(9, A, B, 1);
        vm.expectRevert(abi.encodeWithSelector(IHubMessenger.NotBatches.selector, address(this)));
        hub.broadcastCut(1);
        vm.expectRevert(abi.encodeWithSelector(IHubMessenger.BatchNotComplete.selector, 1));
        hub.sendBurns(1);
        vm.prank(stranger);
        vm.expectRevert();
        hub.disconnectSpoke(PERM);
        vm.prank(stranger);
        vm.expectRevert();
        batches.setCrossChain(address(0));
    }

    function test_sendMint_checks() public {
        _pay(A, B, 5 * MN);
        vm.startPrank(wallet[B]);
        vm.expectRevert(ICrossChainMessenger.ZeroAmount.selector);
        hub.sendMint(A, B, 0, PERM, wallet[B], uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.DeadlineInPast.selector, uint64(block.timestamp)));
        hub.sendMint(A, B, 1, PERM, wallet[B], uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.UnknownDestination.selector, 9));
        hub.sendMint(A, B, 1, 9, wallet[B], uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NotHolderWallet.selector, C, wallet[B]));
        hub.sendMint(A, C, 1, PERM, wallet[B], uint64(block.timestamp + 1));
        tok[A].approve(address(hub), 6 * MN);
        vm.stopPrank();
        // More than the open position: pending tokens cannot move.
        _cutX(3);
        _pay(A, B, 1 * MN);
        vm.prank(wallet[B]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.MoveExceedsOpen.selector, 2 * MN, 1 * MN));
        hub.sendMint(A, B, 2 * MN, PERM, wallet[B], uint64(block.timestamp + 1));
    }

    function test_kindsAcceptedOnlyInTheirDirection() public {
        bytes memory g = _msg(PERM, HOME, 1_000, 3, A, B, 1, 0, 0);
        bytes[] memory gs = _attSigs(HOME, g, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.KindNotAccepted.selector, 3));
        hub.receiveMessage(g, gs, "");
        bytes memory r = _msg(HOME, PERM, 1_000, 4, A, B, 1, 0, 0);
        bytes[] memory rs = _attSigs(PERM, r, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.KindNotAccepted.selector, 4));
        spokeM[PERM].receiveMessage(r, rs, "");
        bytes memory rep = _msg(PERM, HOME, 1_001, 6, A, B, 1, 5, 0);
        bytes[] memory reps = _attSigs(HOME, rep, 3);
        vm.expectRevert(abi.encodeWithSelector(IHubMessenger.UnexpectedReport.selector, 5, PERM));
        hub.receiveMessage(rep, reps, "");
        // A MINT_ACK for no move, and one that does not match the move.
        bytes memory ack = _msg(PERM, HOME, 1_002, 1, A, B, 1, 0, bytes32(uint256(77)));
        bytes[] memory acks = _attSigs(HOME, ack, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.UnknownMove.selector, 77));
        hub.receiveMessage(ack, acks, "");
        _pay(A, B, 5 * MN);
        uint64 n = _moveOut(PERM, A, B, 2 * MN);
        bytes memory bad = _msg(PERM, HOME, 1_003, 1, A, B, 1 * MN, 0, bytes32(uint256(n)));
        bytes[] memory bads = _attSigs(HOME, bad, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.MoveMismatch.selector, n));
        hub.receiveMessage(bad, bads, "");
        // Old version, unknown source.
        bytes memory v3 = abi.encode(
            ICrossChainMessenger.Envelope(3, 3, HOME, PERM, 1_004, A, B, address(0), 1, 0, 0, bytes32(0))
        );
        bytes[] memory v3s = _attSigs(PERM, v3, 3);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.BadVersion.selector, 3));
        spokeM[PERM].receiveMessage(v3, v3s, "");
        bytes memory unk = _msg(9, HOME, 1, 4, A, B, 1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.UntrustedSource.selector, 9));
        hub.receiveMessage(unk, new bytes[](0), "");
    }

    function test_rateLimit_refillAndLower() public {
        vm.prank(gov);
        hub.setRateLimit(PERM, A, 6 * MN, 0);
        assertEq(hub.rateLimit(PERM, A).window, 1 hours, "default window");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ICrossChainMessenger.NotALowering.selector, 6 * MN, 7 * MN));
        hub.lowerRateLimit(PERM, A, 7 * MN);
        vm.prank(guardian);
        hub.lowerRateLimit(PERM, A, 4 * MN);
        assertEq(hub.rateAvailable(PERM, A), 4 * MN);
        assertEq(hub.rateAvailable(PERM, C), BIG, "per issuer");
        assertEq(hub.rateAvailable(PUB, B), BIG);
        assertEq(hub.rateAvailable(9, A), 0, "unset = closed");
    }

    // ------------------------------------------------------------ ledger hooks

    function test_ledger_moveHooks() public {
        vm.startPrank(messenger);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.UnknownDomain.selector, 9));
        ledger.moveOut(9, A, B, 1);
        vm.expectRevert(IExposureLedger.ZeroAmount.selector);
        ledger.moveOut(PERM, A, B, 0);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.MoveExceedsOpen.selector, 1, 0));
        ledger.moveOut(PERM, A, B, 1);
        vm.stopPrank();
        vm.expectRevert();
        ledger.moveIn(PERM, A, B, 1);

        _pay(A, B, 10 * MN);
        vm.startPrank(messenger);
        ledger.moveOut(PERM, A, B, 10 * MN);
        assertEq(ledger.open(A, B), 0);
        assertEq(ledger.envelope(PERM, A, B), 10 * MN);
        assertEq(ledger.gross(A, B), 10 * MN);
        assertEq(ledger.moveInCheck(PERM, A, B, 11 * MN), 7);
        assertEq(ledger.moveInCheck(PUB, A, B, 1), 7);
        assertEq(ledger.moveInCheck(PERM, A, B, 10 * MN), 0);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.MoveRefused.selector, 7));
        ledger.moveIn(PERM, A, B, 11 * MN);
        vm.stopPrank();

        // A pair whose open position all moved out is not snapshotted.
        uint64 b = _cutX(3);
        assertEq(ledger.pendingPairCount(batches.batch(b).epoch), 0);

        vm.prank(messenger);
        ledger.moveCancelled(PERM, A, B, 4 * MN);
        assertEq(ledger.open(A, B), 4 * MN);
        assertEq(ledger.envelope(PERM, A, B), 6 * MN);
        assertEq(ledger.gross(A, B), 10 * MN);
    }

    function _msg(
        uint32 src,
        uint32 dst,
        uint64 nonce,
        uint8 kind,
        bytes32 member,
        bytes32 counterparty,
        uint256 amount,
        uint64 epoch,
        bytes32 ref
    ) internal pure returns (bytes memory) {
        return abi.encode(
            ICrossChainMessenger.Envelope(4, kind, src, dst, nonce, member, counterparty, address(0), amount, epoch, 0, ref)
        );
    }
}
