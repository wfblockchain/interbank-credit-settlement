// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { CreditHandler } from "./utils/CreditHandler.sol";

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 150
/// forge-config: default.invariant.fail-on-revert = true
contract InvariantsTest is StdInvariant, Test {
    CreditHandler internal h;

    function setUp() public {
        h = new CreditHandler();
        // Weighted by repetition: payments and lifecycle steps dominate, limit changes are rarer.
        bytes4[] memory sel = new bytes4[](22);
        sel[0] = CreditHandler.pay.selector;
        sel[1] = CreditHandler.pay.selector;
        sel[2] = CreditHandler.pay.selector;
        sel[3] = CreditHandler.payWithinLimits.selector;
        sel[4] = CreditHandler.drain.selector;
        sel[5] = CreditHandler.drain.selector;
        sel[6] = CreditHandler.cut.selector;
        sel[7] = CreditHandler.plan.selector;
        sel[8] = CreditHandler.payLeg.selector;
        sel[9] = CreditHandler.payLeg.selector;
        sel[10] = CreditHandler.finalize.selector;
        sel[11] = CreditHandler.advance.selector;
        sel[12] = CreditHandler.advance.selector;
        sel[13] = CreditHandler.advance.selector;
        sel[14] = CreditHandler.setElective.selector;
        sel[15] = CreditHandler.setReceiverCap.selector;
        sel[16] = CreditHandler.setSystemMax.selector;
        sel[17] = CreditHandler.setRegCap.selector;
        sel[18] = CreditHandler.toggleRestricted.selector;
        sel[19] = CreditHandler.toggleSuspended.selector;
        sel[20] = CreditHandler.toggleWindow.selector;
        sel[21] = CreditHandler.nextDay.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        targetContract(address(h));
    }

    function invariant_supplyEqualsOpenPlusPending() public view {
        assertTrue(h.supplyMatchesPositions(), "token supply != open + pending");
    }

    function invariant_positionsConsistent() public view {
        assertTrue(h.positionsConsistent(), "net positions inconsistent");
    }

    function invariant_everyAcceptedPaySatisfiedLimits() public view {
        assertEq(h.limitViolations(), 0, "accepted payment broke a limit");
        assertEq(h.queueMismatches(), 0, "queue decision differs from the recomputed checks");
    }

    function invariant_burnedEqualsSettled() public view {
        assertEq(h.burnMismatches(), 0, "burned != batch positions");
        assertEq(h.attestMismatches(), 0, "attested != legs + overpaid");
    }

    function invariant_oneBatchInFlight() public view {
        assertTrue(h.oneBatchInFlight(), "pending epoch out of step with batches");
    }

    /// Coverage: each run must have moved money and completed settlements.
    function afterInvariant() external {
        console2.log(
            string.concat(
                "coverage calls=",
                vm.toString(h.calls()),
                " accepted=",
                vm.toString(h.paysAccepted()),
                " queued=",
                vm.toString(h.paysQueued()),
                " reverted=",
                vm.toString(h.paysReverted()),
                " drained=",
                vm.toString(h.drained())
            )
        );
        console2.log(
            string.concat(
                "coverage cuts=",
                vm.toString(h.cuts()),
                " plans=",
                vm.toString(h.plans()),
                " payments=",
                vm.toString(h.paymentsAttested()),
                " partial=",
                vm.toString(h.partialPayments()),
                " over=",
                vm.toString(h.overpayments()),
                " completed=",
                vm.toString(h.completed()),
                " finalized=",
                vm.toString(h.finalized()),
                " settledValue=",
                vm.toString(h.settledValue()),
                " limitChanges=",
                vm.toString(h.limitChanges())
            )
        );
        string memory stats = vm.envOr("INV_STATS_FILE", string(""));
        if (bytes(stats).length != 0) {
            vm.writeLine(
                stats,
                string.concat(
                    vm.toString(h.calls()), ",", vm.toString(h.paysAccepted()), ",", vm.toString(h.paysQueued()), ",",
                    vm.toString(h.paysReverted()), ",", vm.toString(h.drained()), ",", vm.toString(h.cuts()), ",",
                    vm.toString(h.plans()), ",", vm.toString(h.paymentsAttested()), ",", vm.toString(h.partialPayments()),
                    ",", vm.toString(h.overpayments()), ",", vm.toString(h.completed()), ",", vm.toString(h.finalized()),
                    ",", vm.toString(h.settledValue()), ",", vm.toString(h.limitChanges())
                )
            );
        }
        assertGt(h.paysAccepted(), 0, "no accepted payments");
        assertGt(h.finalized(), 0, "no completed settlement in this run");
        assertGt(h.settledValue(), 0, "no value settled in this run");
    }
}
