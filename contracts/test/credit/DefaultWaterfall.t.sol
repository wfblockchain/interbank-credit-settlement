// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

/// Survivor sharing with a PREFUND_ONLY member in the network: it is never charged for another
/// member's default, in either branch of the survivor rule.
contract PrefundOnlySurvivorTest is CreditFixture {
    bytes32 internal constant P = bytes32("BNKPUS30");

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _addBank(P, "Bank P deposit token", "P-dT", IMemberRegistry.Tier.PREFUND_ONLY);
        _standardLimits();
    }

    /// A paid B earlier (within limits); A's collateral is gone and it misses the deadline.
    function _defaultOnAToB() internal returns (uint64 b) {
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 0);
        b = _cut(1);
        _submitPlan(b);
        vm.warp(batches.batch(b).deadline + 1);
        dm.declare(b);
    }

    /// No survivor granted A an elective limit: the equal split runs over the CREDIT survivors only.
    function test_equalFallback_excludesPrefundOnly() public {
        _pay(A, B, 10 * MN);
        _elective(B, A, 0);
        _elective(C, A, 0);
        _elective(P, A, 0);
        uint64 b = _defaultOnAToB();
        assertEq(dm.coverAmount(b, 0, P), 0, "prefund-only member charged");
        assertEq(dm.survivorCall(b, P), 0, "prefund-only member called");
        assertEq(dm.absorbed(b, B), 5 * MN);
        assertEq(dm.survivorCall(b, C), 5 * MN);
        assertEq(batches.leg(b, 0).paid, 5 * MN);
    }

    /// Only the prefund-only member granted A an elective limit: its weight does not count, and the
    /// CREDIT survivors fall back to equal shares.
    function test_weighted_ignoresPrefundOnlyElective() public {
        _pay(A, B, 10 * MN);
        _elective(B, A, 0);
        _elective(C, A, 0);
        uint64 b = _defaultOnAToB();
        assertEq(dm.coverAmount(b, 0, P), 0, "prefund-only member charged");
        assertEq(dm.absorbed(b, B), 5 * MN);
        assertEq(dm.survivorCall(b, C), 5 * MN);
    }

    /// No eligible survivor (the other CREDIT member defaulted, the payee is prefund-only): the
    /// shortfall is booked as an explicit loss on the payee, and the batch completes.
    function test_noEligibleSurvivor_payeeAbsorbsShortfall() public {
        _pay(A, P, 10 * MN);
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 0);
        uint64 b = _cut(1);
        _submitPlan(b);
        vm.prank(address(dm));
        registry.markDefaulted(B);
        vm.prank(address(dm));
        registry.markDefaulted(C);
        vm.warp(batches.batch(b).deadline + 1);
        dm.declare(b);
        assertEq(dm.absorbed(b, P), 10 * MN, "shortfall not recorded on the payee");
        assertEq(dm.coverAmount(b, 0, P), 10 * MN);
        assertEq(uint8(batches.status(b)), uint8(ISettlementBatches.Status.COMPLETE));
    }
}

/// The COLLATERAL step draws only collateral not committed to public-spoke envelopes.
contract CollateralStepTest is CreditFixture {
    uint32 internal constant PUB = 3;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
        _fund(ICollateralRegister.Kind.COLLATERAL, A, 40 * MN);
        vm.prank(gov);
        ledger.setDomainKind(PUB, IExposureLedger.DomainKind.PUBLIC);
    }

    function test_collateralStep_leavesPublicCommitment() public {
        vm.prank(messenger);
        ledger.reserveEnvelope(PUB, A, C, 10 * MN);
        assertEq(register.publicCommitted(A), 10 * MN);
        _pay(A, B, 35 * MN);
        uint64 b = _cut(1);
        _submitPlan(b);
        vm.warp(batches.batch(b).deadline + 1);
        dm.declare(b);
        assertEq(dm.coverAmount(b, 0, COLLATERAL), 30 * MN, "drew committed collateral");
        assertEq(register.collateral(A), 10 * MN);
        assertLe(register.publicCommitted(A), register.collateral(A), "public envelope left uncovered");
        // The remaining $5M falls to the survivors (pool empty): B and C pro rata to $95M each.
        assertEq(dm.absorbed(b, B), 2_500_000e6);
        assertEq(dm.survivorCall(b, C), 2_500_000e6);
    }
}
