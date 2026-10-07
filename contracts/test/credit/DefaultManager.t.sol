// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DefaultManager } from "../../src/credit/DefaultManager.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { IDefaultManager } from "../../src/interfaces/IDefaultManager.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract DefaultManagerTest is CreditFixture {
    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
    }

    function test_constructor_zeroAddress() public {
        address r = address(registry);
        address g = address(register);
        address l = address(limits);
        address b = address(batches);
        vm.expectRevert(IDefaultManager.ZeroAddress.selector);
        new DefaultManager(0, gov, address(0), g, l, b);
        vm.expectRevert(IDefaultManager.ZeroAddress.selector);
        new DefaultManager(0, gov, r, address(0), l, b);
        vm.expectRevert(IDefaultManager.ZeroAddress.selector);
        new DefaultManager(0, gov, r, g, address(0), b);
        vm.expectRevert(IDefaultManager.ZeroAddress.selector);
        new DefaultManager(0, gov, r, g, l, address(0));
    }

    function test_declare_notDeclarable() public {
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.NotDeclarable.selector, 1));
        dm.declare(1);
        _pay(A, B, 10 * MN);
        uint64 b = _cut(1);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.NotDeclarable.selector, b));
        dm.declare(b);
        _submitPlan(b);
        _attestPay(b, 0, CHIPS, 10 * MN);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.NotDeclarable.selector, b));
        dm.declare(b);
    }

    function test_declare_partialLeg_collateralOnly_andSecondDeclareRefused() public {
        _pay(A, B, 10 * MN);
        uint64 b = _cut(1);
        _submitPlan(b);
        _attestPay(b, 0, RTP, 4 * MN);
        vm.warp(batches.batch(b).deadline + 1);
        vm.expectEmit(address(dm));
        emit IDefaultManager.Declared(b);
        vm.expectEmit(address(dm));
        emit IDefaultManager.CoverInstruction(b, 0, COLLATERAL, 6 * MN);
        dm.declare(b);
        assertEq(register.collateral(A), 4 * MN);
        assertTrue(dm.allowedPayer(b, 0, COLLATERAL));
        assertFalse(dm.allowedPayer(b, 0, POOL));
        assertFalse(dm.allowedPayer(b, 0, C));
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.NotDeclarable.selector, b));
        dm.declare(b);

        // A pool payment for this leg is refused: only the instructed source may pay.
        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, POOL, B, 6 * MN);
        bytes[] memory sigs = _sigs(attestor.paymentDigest(p), 3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementBatches.WrongPayer.selector, A, POOL));
        attestor.attestPayment(p, sigs);
        _attest(_payment(b, 0, CHIPS, COLLATERAL, B, 6 * MN));
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
    }

    function test_declare_equalWeights_whenNoElective() public {
        _pay(A, B, 10 * MN);
        _elective(B, A, 0);
        _elective(C, A, 0);
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 0);
        uint64 b = _cut(1);
        _submitPlan(b);
        vm.warp(batches.batch(b).deadline + 1);
        dm.declare(b);
        assertEq(dm.absorbed(b, B), 5 * MN);
        assertEq(dm.survivorCall(b, C), 5 * MN);
        assertEq(batches.leg(b, 0).paid, 5 * MN);
    }

    function test_declare_noSurvivors() public {
        _pay(A, B, 10 * MN);
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 0);
        uint64 b = _cut(1);
        _submitPlan(b);
        vm.prank(guardian);
        registry.suspend(C, bytes32("X"));
        vm.prank(address(dm));
        registry.markDefaulted(C);
        vm.prank(address(dm));
        registry.markDefaulted(B);
        vm.warp(batches.batch(b).deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IDefaultManager.NoSurvivors.selector, b, 0));
        dm.declare(b);
    }

    function test_declare_twoDefaulters_survivorsExcludeBoth() public {
        _pay(A, C, 10 * MN);
        _pay(B, C, 10 * MN);
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 0);
        _fund(ICollateralRegister.Kind.COLLATERAL, B, 0);
        uint64 b = _cut(3);
        _submitPlan(b);
        vm.warp(batches.batch(b).deadline + 1);
        dm.declare(b);
        assertEq(uint8(registry.member(A).status), uint8(IMemberRegistry.Status.DEFAULTED));
        assertEq(uint8(registry.member(B).status), uint8(IMemberRegistry.Status.DEFAULTED));
        // C is the only survivor and the payee: it bears both losses.
        assertEq(dm.absorbed(b, C), 20 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
        batches.finalize(b, 10);
        assertEq(tok[A].totalSupply() + tok[B].totalSupply(), 0);
    }
}
