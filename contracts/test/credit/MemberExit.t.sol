// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IDefaultManager } from "../../src/interfaces/IDefaultManager.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

/// Orderly exit: governance sets EXITED only for a member with no position left anywhere at home.
contract MemberExitTest is CreditFixture {
    uint32 internal constant PERM = 2;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
        vm.prank(gov);
        ledger.setDomainKind(PERM, IExposureLedger.DomainKind.PERMISSIONED);
    }

    function _exit(bytes32 id) internal {
        vm.prank(gov);
        dm.exit(id);
    }

    function _expectPositions(bytes32 id, uint256 gIn, uint256 gOut, uint256 queued) internal {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.MemberHasPositions.selector, id, gIn, gOut, queued));
        dm.exit(id);
    }

    function test_exit_onlyGovernance() public {
        bytes32 adminRole = dm.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        dm.exit(C);
        vm.prank(address(dm));
        registry.markExited(C); // the registry hook is DEFAULT_MANAGER_ROLE only
        vm.prank(stranger);
        vm.expectRevert();
        registry.markExited(B);
    }

    function test_exit_cleanMember_isTerminal() public {
        assertEq(registry.activeCount(), 3);
        assertEq(registry.activeCreditCount(), 3);
        vm.expectEmit(address(registry));
        emit IMemberRegistry.Exited(C);
        _exit(C);
        assertEq(uint8(registry.member(C).status), uint8(IMemberRegistry.Status.EXITED));
        assertFalse(registry.goodStanding(C));
        assertEq(registry.activeCount(), 2);
        assertEq(registry.activeCreditCount(), 2);
        // Terminal: nothing leaves EXITED.
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotSuspended.selector, C));
        registry.reinstate(C);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotActive.selector, C));
        registry.suspend(C, bytes32("X"));
        vm.prank(address(dm));
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.CannotDefault.selector, C, IMemberRegistry.Status.EXITED)
        );
        registry.markDefaulted(C);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.CannotExit.selector, C, IMemberRegistry.Status.EXITED));
        dm.exit(C);
        // An exited member neither pays nor receives.
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(IExposureLedger.PayeeNotInGoodStanding.selector, C));
        ledger.pay(C, 1 * MN, bytes32("r"));
    }

    function test_exit_suspendedMember() public {
        vm.prank(guardian);
        registry.suspend(C, bytes32("X"));
        assertEq(registry.activeCount(), 2);
        _exit(C);
        assertEq(uint8(registry.member(C).status), uint8(IMemberRegistry.Status.EXITED));
        assertEq(registry.activeCount(), 2, "counted twice");
    }

    function test_exit_defaultedRefused() public {
        vm.prank(address(dm));
        registry.markDefaulted(C);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.CannotExit.selector, C, IMemberRegistry.Status.DEFAULTED)
        );
        dm.exit(C);
    }

    /// Open as issuer and as holder, then pending (in the batch), all refuse; after settlement the
    /// member can leave.
    function test_exit_refusedWhileOpenOrPending() public {
        _pay(A, B, 2 * MN);
        _expectPositions(A, 0, 2 * MN, 0); // issuer
        _expectPositions(B, 2 * MN, 0, 0); // holder
        uint64 b = _cut(1);
        assertEq(ledger.pending(A, B), 2 * MN);
        _expectPositions(A, 0, 2 * MN, 0);
        _submitPlan(b);
        _attestPay(b, 0, CHIPS, 2 * MN);
        batches.finalize(b, 10);
        _exit(A);
        _exit(B);
        assertEq(registry.activeCount(), 1);
    }

    function test_exit_refusedWithEnvelope() public {
        vm.prank(messenger);
        ledger.reserveEnvelope(PERM, C, A, 3 * MN);
        _expectPositions(C, 0, 3 * MN, 0);
        _expectPositions(A, 3 * MN, 0, 0);
        vm.prank(messenger);
        ledger.releaseEnvelope(PERM, C, A, 3 * MN);
        _exit(C);
    }

    function test_exit_refusedWithQueuedPayment() public {
        vm.prank(ops[C]);
        uint256 seq = ledger.pay(A, 500 * MN, bytes32("big")); // beyond every limit: queued
        assertEq(uint8(ledger.queueEntry(seq).state), uint8(IExposureLedger.QueueState.QUEUED));
        _expectPositions(C, 0, 0, 1); // payer
        _expectPositions(A, 0, 0, 1); // payee
        vm.prank(ops[C]);
        ledger.cancel(seq);
        _exit(C);
    }
}
