// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

/// Every change to home `open` enters the epoch commitment, so a nonzero open position always
/// comes with a nonzero epochHash (the operator skips a cut whose epochHash is zero).
contract EpochCommitmentTest is CreditFixture {
    uint32 internal constant PERM = 2;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
        vm.prank(gov);
        ledger.setDomainKind(PERM, IExposureLedger.DomainKind.PERMISSIONED);
    }

    function test_moveIn_entersEpochHash() public {
        vm.prank(messenger);
        ledger.reserveEnvelope(PERM, A, B, 5 * MN);
        assertEq(ledger.epochHash(), bytes32(0));
        vm.prank(messenger);
        ledger.moveIn(PERM, A, B, 3 * MN);
        assertEq(ledger.open(A, B), 3 * MN);
        assertTrue(ledger.epochHash() != bytes32(0), "move home not committed");
    }

    function test_moveCancelled_entersEpochHash() public {
        _pay(A, B, 5 * MN);
        vm.prank(messenger);
        ledger.moveOut(PERM, A, B, 5 * MN);
        _cut(1); // the epoch's payment moved out: nothing open, the new epoch starts empty
        assertEq(ledger.epochHash(), bytes32(0));
        vm.prank(messenger);
        ledger.moveCancelled(PERM, A, B, 5 * MN);
        assertEq(ledger.open(A, B), 5 * MN);
        assertTrue(ledger.epochHash() != bytes32(0), "returned move not committed");
    }

    /// A move record differs from a payment record of the same pair and amount.
    function test_moveRecord_distinctFromPayment() public {
        vm.prank(messenger);
        ledger.reserveEnvelope(PERM, A, B, 5 * MN);
        vm.prank(messenger);
        ledger.moveIn(PERM, A, B, 1 * MN);
        bytes32 afterMove = ledger.epochHash();
        _pay(A, B, 1 * MN);
        bytes32 afterPay = ledger.epochHash();
        assertTrue(afterMove != bytes32(0) && afterPay != afterMove);
    }
}
