// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { SettlementBatches } from "../../src/credit/SettlementBatches.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract SettlementBatchesTest is CreditFixture {
    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
    }

    function _unauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    function _status(uint64 b) internal view returns (uint8) {
        return uint8(batches.status(b));
    }

    function test_constructor_zeroAddress() public {
        address r = address(registry);
        address l = address(ledger);
        address g = address(register);
        address a = address(attestor);
        address d = address(dm);
        vm.expectRevert(ISettlementBatches.ZeroAddress.selector);
        new SettlementBatches(0, gov, address(0), l, g, a, d, operator);
        vm.expectRevert(ISettlementBatches.ZeroAddress.selector);
        new SettlementBatches(0, gov, r, address(0), g, a, d, operator);
        vm.expectRevert(ISettlementBatches.ZeroAddress.selector);
        new SettlementBatches(0, gov, r, l, address(0), a, d, operator);
        vm.expectRevert(ISettlementBatches.ZeroAddress.selector);
        new SettlementBatches(0, gov, r, l, g, address(0), d, operator);
        vm.expectRevert(ISettlementBatches.ZeroAddress.selector);
        new SettlementBatches(0, gov, r, l, g, a, address(0), operator);
        vm.expectRevert(ISettlementBatches.ZeroAddress.selector);
        new SettlementBatches(0, gov, r, l, g, a, d, address(0));
    }

    // ------------------------------------------------------------ cut

    function test_cut() public {
        bytes32 role = batches.OPERATOR_ROLE();
        vm.prank(stranger);
        _unauthorized(stranger, role);
        batches.cut(1);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.InvalidTrigger.selector, 0));
        batches.cut(0);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.InvalidTrigger.selector, 4));
        batches.cut(4);
        vm.stopPrank();

        _pay(A, B, 5 * MN);
        bytes32 h = ledger.epochHash();
        vm.prank(operator);
        ledger.setBusinessDay(20_000);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchCut(1, 1, h);
        uint64 b = _cut(2);
        ISettlementBatches.Batch memory bt = batches.batch(b);
        assertEq(bt.epoch, 1);
        assertEq(bt.epochHash, h);
        assertEq(bt.trigger, 2);
        assertEq(uint8(bt.status), uint8(ISettlementBatches.Status.CUT));
        assertEq(bt.cutAt, block.timestamp);
        assertEq(bt.businessDay, 20_000);
        assertEq(batches.batchCount(), 1);

        // One batch in flight.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.BatchOutstanding.selector, 1));
        batches.cut(1);
    }

    function test_cut_poolNotReplenished() public {
        _fund(ICollateralRegister.Kind.POOL_REQUIRED, bytes32(0), 1 * MN);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.PoolNotReplenished.selector, 0, 1 * MN));
        batches.cut(3);
        _fund(ICollateralRegister.Kind.POOL, C, 1 * MN);
        _cut(3);
    }

    function test_requestSettlement() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.NotIssuerOps.selector, stranger));
        batches.requestSettlement();
        vm.expectEmit(address(batches));
        emit ISettlementBatches.SettlementRequested(B);
        vm.prank(ops[B]);
        batches.requestSettlement();
        vm.prank(guardian);
        registry.suspend(B, bytes32("X"));
        vm.prank(ops[B]);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.NotInGoodStanding.selector, B));
        batches.requestSettlement();
    }

    // ------------------------------------------------------------ plan

    function test_submitPlan_errors() public {
        _pay(A, B, 10 * MN);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        ISettlementBatches.Leg[] memory legs = new ISettlementBatches.Leg[](1);
        legs[0] = _leg(A, B, 10 * MN);

        bytes32 role = batches.OPERATOR_ROLE();
        vm.prank(stranger);
        _unauthorized(stranger, role);
        batches.submitPlan(1, legs, deadline);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.UnknownBatch.selector, 1));
        batches.submitPlan(1, legs, deadline);
        uint64 b = batches.cut(1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.DeadlineInPast.selector, uint64(block.timestamp)));
        batches.submitPlan(b, legs, uint64(block.timestamp));

        ISettlementBatches.Leg[] memory bad = new ISettlementBatches.Leg[](1);
        bad[0] = _leg(A, A, 10 * MN);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.InvalidLeg.selector, 0));
        batches.submitPlan(b, bad, deadline);
        bad[0] = _leg(A, B, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.InvalidLeg.selector, 0));
        batches.submitPlan(b, bad, deadline);
        bad[0] = ISettlementBatches.Leg(A, B, 10 * MN, 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.InvalidLeg.selector, 0));
        batches.submitPlan(b, bad, deadline);
        bad[0] = _leg(A, POOL, 10 * MN);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.NotAMember.selector, POOL));
        batches.submitPlan(b, bad, deadline);
        // A leg beyond int256 cannot wrap into a reversed leg.
        bad[0] = _leg(B, A, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, type(uint256).max));
        batches.submitPlan(b, bad, deadline);
        bad[0] = _leg(A, B, 9 * MN);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.PlanMismatch.selector, A));
        batches.submitPlan(b, bad, deadline);
        ISettlementBatches.Leg[] memory none = new ISettlementBatches.Leg[](0);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.PlanMismatch.selector, A));
        batches.submitPlan(b, none, deadline);

        vm.expectEmit(address(batches));
        emit ISettlementBatches.PlanSubmitted(b, 1, deadline);
        batches.submitPlan(b, legs, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.PLANNED)
        );
        batches.submitPlan(b, legs, deadline);
        vm.stopPrank();
        assertEq(batches.batch(b).deadline, deadline);
        assertEq(batches.legCount(b), 1);
        assertEq(batches.legs(b)[0].amount, 10 * MN);
        assertEq(batches.batch(b).unpaidLegs, 1);
        assertTrue(ledger.isSealed(batches.batch(b).epoch));
    }

    function test_emptyBatch_completesAtPlan() public {
        uint64 b = _cut(3);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchComplete(b);
        _submitPlan(b);
        assertEq(_status(b), uint8(ISettlementBatches.Status.COMPLETE));
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchFinalized(b, 0);
        assertEq(batches.finalize(b, 0), 0);
        _cut(3);
    }

    // ------------------------------------------------------------ payments

    function test_recordPayment_rules() public {
        _pay(A, B, 30 * MN);
        _pay(C, B, 20 * MN);
        uint64 b = _cut(1);
        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, A, B, 30 * MN);

        bytes32 role = batches.ATTESTOR_ROLE();
        vm.prank(stranger);
        _unauthorized(stranger, role);
        batches.recordPayment(p);

        vm.startPrank(address(attestor));
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.CUT));
        batches.recordPayment(p);
        vm.stopPrank();
        ISettlementBatches.Leg[] memory legs = _submitPlan(b);
        assertEq(legs.length, 2);

        vm.startPrank(address(attestor));
        p.batch = 9;
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.UnknownBatch.selector, 9));
        batches.recordPayment(p);
        p.batch = b;
        p.leg = 2;
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.UnknownLeg.selector, b, 2));
        batches.recordPayment(p);
        p.leg = 0;
        p.payer = B;
        p.payee = B;
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongPayer.selector, A, B));
        batches.recordPayment(p);
        p.payer = COLLATERAL;
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongPayer.selector, A, COLLATERAL));
        batches.recordPayment(p);

        p.payer = A;
        p.amount = 10 * MN;
        vm.expectEmit(address(batches));
        emit ISettlementBatches.PaymentRecorded(b, 0, CHIPS, p.railTxId, A, 10 * MN);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchPartial(b);
        batches.recordPayment(p);
        assertEq(_status(b), uint8(ISettlementBatches.Status.PARTIAL));
        assertEq(batches.paidBy(b, 0, A), 10 * MN);

        p.amount = 20 * MN;
        vm.expectEmit(address(batches));
        emit ISettlementBatches.LegPaid(b, 0);
        batches.recordPayment(p);
        // A later payment to a paid leg is an overpayment.
        p.amount = 1 * MN;
        vm.expectEmit(address(batches));
        emit ISettlementBatches.Overpaid(b, 0, 1 * MN);
        batches.recordPayment(p);
        assertEq(batches.batch(b).unpaidLegs, 1);

        p = _payment(b, 1, CHIPS, C, B, 20 * MN);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchComplete(b);
        batches.recordPayment(p);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.COMPLETE)
        );
        batches.recordPayment(p);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ finalize

    function test_finalize() public {
        _pay(A, B, 30 * MN);
        _pay(B, C, 10 * MN);
        uint64 b = _cut(3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.CUT));
        batches.finalize(b, 10);
        _submitPlan(b);
        for (uint32 i = 0; i < batches.legCount(b); i++) {
            _attestPay(b, i, CHIPS, batches.leg(b, i).amount);
        }
        vm.expectEmit(address(batches));
        emit ISettlementBatches.PairSettled(b, A, B, 30 * MN, false);
        assertEq(batches.finalize(b, 1), 1);
        assertEq(tok[A].totalSupply(), 0);
        assertEq(tok[B].totalSupply(), 10 * MN);
        assertEq(batches.finalize(b, 0), 0);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchFinalized(b, 40 * MN);
        assertEq(batches.finalize(b, 5), 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.AlreadyFinalized.selector, b));
        batches.finalize(b, 1);
        assertEq(batches.batch(b).burned, 40 * MN);
        assertEq(batches.batch(b).cursor, 2);
    }

    // ------------------------------------------------------------ default hooks

    function test_markDefaulting_and_absorbLoss() public {
        _pay(A, B, 10 * MN);
        uint64 b = _cut(1);
        bytes32 role = batches.DEFAULT_MANAGER_ROLE();
        vm.prank(stranger);
        _unauthorized(stranger, role);
        batches.markDefaulting(b);
        vm.prank(stranger);
        _unauthorized(stranger, role);
        batches.absorbLoss(b, 0, B, 1);

        vm.startPrank(address(dm));
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.CUT));
        batches.markDefaulting(b);
        vm.stopPrank();
        _submitPlan(b);
        vm.startPrank(address(dm));
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongStatus.selector, b, ISettlementBatches.Status.PLANNED));
        batches.absorbLoss(b, 0, B, 1);
        uint64 deadline = batches.batch(b).deadline;
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.DeadlineNotPassed.selector, deadline));
        batches.markDefaulting(b);
        vm.warp(deadline + 1);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.BatchDefaulting(b);
        batches.markDefaulting(b);

        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.UnknownLeg.selector, b, 1));
        batches.absorbLoss(b, 1, B, 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.NotPayee.selector, C));
        batches.absorbLoss(b, 0, C, 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.AbsorbExceedsRemainder.selector, 10 * MN + 1, 10 * MN));
        batches.absorbLoss(b, 0, B, 10 * MN + 1);
        vm.expectEmit(address(batches));
        emit ISettlementBatches.LossAbsorbed(b, 0, B, 4 * MN);
        batches.absorbLoss(b, 0, B, 4 * MN);
        assertEq(_status(b), uint8(ISettlementBatches.Status.DEFAULTING));
        batches.absorbLoss(b, 0, B, 6 * MN);
        assertEq(_status(b), uint8(ISettlementBatches.Status.COMPLETE));
        vm.stopPrank();
    }

    function test_rfReference() public {
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.UnknownBatch.selector, 1));
        batches.rfReference(1);
        uint64 b = _cut(3);
        assertEq(batches.rfReference(b), "RF60CS1");
    }
}
