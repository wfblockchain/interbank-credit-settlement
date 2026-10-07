// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { CreditLimits } from "../../src/credit/CreditLimits.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { ICreditLimits } from "../../src/interfaces/ICreditLimits.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract CreditLimitsTest is CreditFixture {
    function setUp() public {
        _deployAll();
        _standardLimits();
    }

    function _unauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(ICreditLimits.ZeroAddress.selector);
        new CreditLimits(0, gov, address(0), address(register), guardian, operator);
        vm.expectRevert(ICreditLimits.ZeroAddress.selector);
        new CreditLimits(0, gov, address(registry), address(0), guardian, operator);
        vm.expectRevert(ICreditLimits.ZeroAddress.selector);
        new CreditLimits(0, gov, address(registry), address(register), address(0), operator);
        vm.expectRevert(ICreditLimits.ZeroAddress.selector);
        new CreditLimits(0, gov, address(registry), address(register), guardian, address(0));
    }

    function test_defaults() public view {
        assertEq(limits.mandatoryPerPair(), 5_000_000e6);
        assertEq(limits.systemMax(), 1_000_000_000e6);
        assertEq(limits.electiveMax(), 100_000_000e6);
        assertEq(limits.receiverCap(A), 100_000_000e6);
        assertEq(limits.triggerLevel(A), 100_000_000e6);
        assertFalse(limits.mandatoryRemoved());
    }

    function test_governanceSetters() public {
        vm.startPrank(stranger);
        _unauthorized(stranger, bytes32(0));
        limits.setMandatoryPerPair(1);
        _unauthorized(stranger, bytes32(0));
        limits.setSystemMax(1);
        _unauthorized(stranger, bytes32(0));
        limits.setElectiveMax(1);
        _unauthorized(stranger, bytes32(0));
        limits.setMandatoryRemoved(true);
        _unauthorized(stranger, bytes32(0));
        limits.setTriggerBps(1);
        _unauthorized(stranger, bytes32(0));
        limits.setReceiverCap(A, 1);
        _unauthorized(stranger, bytes32(0));
        limits.unrestrict(A);
        vm.stopPrank();

        vm.startPrank(gov);
        vm.expectEmit(address(limits));
        emit ICreditLimits.MandatoryPerPairSet(3 * MN);
        limits.setMandatoryPerPair(3 * MN);
        vm.expectEmit(address(limits));
        emit ICreditLimits.SystemMaxSet(7 * MN);
        limits.setSystemMax(7 * MN);
        vm.expectEmit(address(limits));
        emit ICreditLimits.ElectiveMaxSet(50 * MN);
        limits.setElectiveMax(50 * MN);
        vm.expectEmit(address(limits));
        emit ICreditLimits.MandatoryRemovedSet(true);
        limits.setMandatoryRemoved(true);
        vm.expectEmit(address(limits));
        emit ICreditLimits.TriggerBpsSet(8000);
        limits.setTriggerBps(8000);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.InvalidBps.selector, 0));
        limits.setTriggerBps(0);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.InvalidBps.selector, 10_001));
        limits.setTriggerBps(10_001);
        vm.expectEmit(address(limits));
        emit ICreditLimits.ReceiverCapSet(A, 200 * MN);
        limits.setReceiverCap(A, 200 * MN);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.UnknownMember.selector, bytes32("NOPE")));
        limits.setReceiverCap(bytes32("NOPE"), 1);
        vm.stopPrank();

        assertEq(limits.triggerLevel(A), 160 * MN);
        assertEq(limits.mandatory(A), 0);
        // Elective above a lowered max is clamped.
        assertEq(limits.bilateralLimit(B, A), 50 * MN);
    }

    function test_setElective() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.NotIssuerOps.selector, stranger));
        limits.setElective(A, 1);

        vm.startPrank(ops[B]);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.UnknownMember.selector, bytes32("NOPE")));
        limits.setElective(bytes32("NOPE"), 1);
        vm.expectRevert(ICreditLimits.SelfGrant.selector);
        limits.setElective(B, 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.ElectiveAboveMax.selector, 100 * MN + 1, 100 * MN));
        limits.setElective(A, 100 * MN + 1);
        vm.expectEmit(address(limits));
        emit ICreditLimits.ElectiveSet(B, A, 12 * MN);
        limits.setElective(A, 12 * MN);
        vm.stopPrank();
        assertEq(limits.elective(B, A), 12 * MN);
        assertEq(limits.bilateralLimit(B, A), 17 * MN);
    }

    function test_regCap() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.NotIssuerOps.selector, stranger));
        limits.setRegCap(A, 1, bytes32("SCCL"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.NotIssuerOps.selector, stranger));
        limits.clearRegCap(A, bytes32("SCCL"));

        vm.expectEmit(address(limits));
        emit ICreditLimits.RegCapSet(B, A, 30 * MN, bytes32("SCCL"));
        vm.prank(ops[B]);
        limits.setRegCap(A, 30 * MN, bytes32("SCCL"));
        (bool set, uint256 cap) = limits.regCap(B, A);
        assertTrue(set);
        assertEq(cap, 30 * MN);
        assertEq(limits.bilateralLimit(B, A), 30 * MN);
        // A cap above mandatory + elective does not raise the limit.
        vm.prank(ops[B]);
        limits.setRegCap(A, 500 * MN, bytes32("SCCL"));
        assertEq(limits.bilateralLimit(B, A), 100 * MN);

        vm.expectEmit(address(limits));
        emit ICreditLimits.RegCapCleared(B, A, bytes32("LIFT"));
        vm.prank(ops[B]);
        limits.clearRegCap(A, bytes32("LIFT"));
        (set,) = limits.regCap(B, A);
        assertFalse(set);
    }

    function test_lowerReceiverCap() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.NotIssuerOps.selector, stranger));
        limits.lowerReceiverCap(1);
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSelector(ICreditLimits.CanOnlyLower.selector, 100 * MN, 100 * MN + 1));
        limits.lowerReceiverCap(100 * MN + 1);
        vm.expectEmit(address(limits));
        emit ICreditLimits.ReceiverCapSet(A, 40 * MN);
        vm.prank(ops[A]);
        limits.lowerReceiverCap(40 * MN);
        assertEq(limits.receiverCap(A), 40 * MN);
    }

    function test_restrict() public {
        bytes32 role = limits.GUARDIAN_ROLE();
        vm.prank(stranger);
        _unauthorized(stranger, role);
        limits.restrict(A);

        vm.expectEmit(address(limits));
        emit ICreditLimits.RestrictedSet(A, true);
        vm.prank(operator);
        limits.restrict(A);
        assertTrue(limits.restricted(A));
        assertEq(limits.mandatory(A), 0);
        vm.prank(guardian);
        limits.restrict(B);

        // Lifting a restriction is governance only.
        vm.prank(guardian);
        _unauthorized(guardian, bytes32(0));
        limits.unrestrict(A);
        vm.expectEmit(address(limits));
        emit ICreditLimits.RestrictedSet(A, false);
        vm.prank(gov);
        limits.unrestrict(A);
        assertEq(limits.mandatory(A), 5 * MN);
    }

    function test_mandatory_cases() public {
        assertEq(limits.mandatory(A), 5 * MN);
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 3 * MN);
        assertEq(limits.mandatory(A), 1_500_000e6);
        assertEq(limits.collateralFreeForMandatory(A), 3 * MN);
        vm.prank(address(ledger));
        register.commitPublic(A, 0); // no-op commitment is allowed
        assertEq(limits.mandatory(bytes32("NOPE")), 0);

        vm.prank(guardian);
        registry.suspend(B, bytes32("X"));
        assertEq(limits.mandatory(B), 0);
        // Two active credit members: denominator 1.
        assertEq(limits.mandatory(A), 3 * MN);
        assertEq(limits.mandatoryBacking(A), 3 * MN);
        assertEq(limits.bilateralLimit(A, B), 0);
        assertEq(limits.bilateralLimit(B, A), 0);
        assertEq(limits.debitCap(B), 0);

        vm.prank(guardian);
        registry.suspend(C, bytes32("X"));
        assertEq(limits.mandatory(A), 0);
        assertEq(limits.mandatoryBacking(A), 0);
    }

    function test_bilateral_and_debitCap() public {
        assertEq(limits.bilateralLimit(A, A), 0);
        assertEq(limits.bilateralLimit(B, A), 100 * MN);
        assertEq(limits.debitCap(A), 200 * MN);
        vm.prank(gov);
        limits.setSystemMax(150 * MN);
        assertEq(limits.debitCap(A), 150 * MN);
    }

    function test_prefundOnly_debitCap_usesCollateral() public {
        bytes32 D = bytes32("BNKDUS30");
        _addBank(D, "Bank D deposit token", "D-dT", IMemberRegistry.Tier.PREFUND_ONLY);
        assertEq(limits.debitCap(D), 0);
        _fund(ICollateralRegister.Kind.COLLATERAL, D, 9 * MN);
        assertEq(limits.debitCap(D), 9 * MN);
        vm.prank(address(ledger));
        register.commitPublic(D, 4 * MN);
        assertEq(limits.debitCap(D), 5 * MN);
        _elective(A, D, 7 * MN);
        assertEq(limits.bilateralLimit(A, D), 7 * MN);
        vm.prank(gov);
        limits.setSystemMax(2 * MN);
        assertEq(limits.debitCap(D), 2 * MN);
    }
}
