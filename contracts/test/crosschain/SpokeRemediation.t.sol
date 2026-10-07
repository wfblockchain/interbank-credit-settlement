// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { ISpokeExposureGuard } from "../../src/interfaces/ISpokeExposureGuard.sol";
import { CrossChainFixture } from "./utils/CrossChainFixture.sol";

/// Public-spoke collateral is held from the cut until the batch settles.
contract PublicCollateralHoldTest is CrossChainFixture {
    function setUp() public {
        vm.warp(1_760_000_000);
        _deployCrossChain();
        _standardLimits();
        // $40M: mandatory backing $10M, $30M free for public envelopes.
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 40 * MN);
    }

    function test_publicCollateral_heldFromCutUntilFinalize() public {
        _grant(PUB, A, B, 10 * MN);
        _deliverAll();
        _spokePay(PUB, A, B, 4 * MN);
        assertEq(register.publicCommitted(A), 10 * MN);
        uint256 freeBefore = register.freeCollateral(A);
        assertEq(freeBefore, 20 * MN);

        uint64 b = _cutX(3);
        _deliverAll(); // BATCH_LOCKED: the locked $4M joins the batch
        assertEq(ledger.envelope(PUB, A, B), 6 * MN);
        assertEq(ledger.pending(A, B), 4 * MN);
        assertEq(register.publicCommitted(A), 10 * MN, "locked public amount released at the cut");
        assertEq(register.freeCollateral(A), freeBefore, "collateral freed while the batch is in flight");

        // The issuer cannot re-commit the in-flight part.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegister.InsufficientFreeCollateral.selector, A, freeBefore + 1, freeBefore)
        );
        hub.grantEnvelope(PUB, A, C, freeBefore + 1);

        _submitPlan(b);
        _payAllLegs(b);
        assertEq(register.publicCommitted(A), 10 * MN, "released before the batch settled");
        batches.finalize(b, 100);
        assertEq(register.publicCommitted(A), 6 * MN, "settled public part not released");
        _sendBurns(batches.batch(b).epoch);
        _deliverAll();
        assertEq(register.publicCommitted(A), 6 * MN);
    }

    /// A cancelled home → public-spoke move returns its commitment at once.
    function test_cancelledPublicMove_returnsCommitment() public {
        _pay(A, B, 5 * MN);
        _moveOut(PUB, A, B, 5 * MN);
        assertEq(register.publicCommitted(A), 5 * MN);
        vm.prank(guardian);
        guardOf[PUB].lowerSupplyCap(A, 0); // the spoke refuses the MINT
        _deliverAll();
        assertEq(register.publicCommitted(A), 0);
        assertEq(ledger.open(A, B), 5 * MN);
    }
}

/// Permissioned spokes keep the home window rule: no local credit outside the business window.
contract SpokeWindowTest is CrossChainFixture {
    uint8 internal constant BUSINESS = 0;
    uint8 internal constant OFF_HOURS = 1;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployCrossChain();
        _standardLimits();
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 40 * MN);
        _grant(PERM, A, B, 10 * MN);
        _grant(PUB, A, B, 10 * MN);
        _deliverAll();
    }

    /// Typed-free on purpose: the call fails on a guard without a window.
    function _spokeWindow(uint32 d, uint8 w) internal {
        vm.prank(operator);
        (bool ok,) = address(guardOf[d]).call(abi.encodeWithSignature("setWindow(uint8)", w));
        require(ok, "spoke setWindow failed");
    }

    function test_permissioned_offHours_payReverts_publicUnaffected() public {
        _window(IExposureLedger.Window.OFF_HOURS); // the end-of-day cut at home
        _spokeWindow(PERM, OFF_HOURS);
        _spokeWindow(PUB, OFF_HOURS);
        vm.prank(ops[A]);
        vm.expectRevert(abi.encodeWithSignature("OffHoursCredit(bytes32,uint256)", A, 1 * MN));
        guardOf[PERM].pay(B, 1 * MN, bytes32("late"));
        assertEq(rtok[PERM][A].totalSupply(), 0);
        // Public spoke: collateral-backed, the window does not apply.
        _spokePay(PUB, A, B, 1 * MN);
        assertEq(rtok[PUB][A].totalSupply(), 1 * MN);
        // Back in the business window, the permissioned spoke pays again.
        _spokeWindow(PERM, BUSINESS);
        _spokePay(PERM, A, B, 1 * MN);
        assertEq(rtok[PERM][A].totalSupply(), 1 * MN);
    }

    function test_permissioned_offHours_drainDoesNotMint() public {
        uint256 seq = _spokePay(PERM, A, B, 12 * MN); // beyond the $10M envelope: queued
        assertEq(uint8(guardOf[PERM].queueEntry(seq).state), uint8(ISpokeExposureGuard.QueueState.QUEUED));
        _grant(PERM, A, B, 5 * MN);
        _deliverAll();
        _spokeWindow(PERM, OFF_HOURS);
        assertEq(guardOf[PERM].drain(10), 0, "drained off-hours");
        assertEq(rtok[PERM][A].totalSupply(), 0);
        assertEq(uint8(guardOf[PERM].queueEntry(seq).state), uint8(ISpokeExposureGuard.QueueState.QUEUED));
        _spokeWindow(PERM, BUSINESS);
        assertEq(guardOf[PERM].drain(10), 1);
        assertEq(rtok[PERM][A].totalSupply(), 12 * MN);
    }
}
