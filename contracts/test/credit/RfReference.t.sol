// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { RfReference } from "../../src/credit/RfReference.sol";

contract RfHarness {
    function compute(string memory body) external pure returns (string memory) {
        return RfReference.compute(body);
    }

    function forBatch(uint64 b) external pure returns (string memory) {
        return RfReference.forBatch(b);
    }

    function isValid(string memory r) external pure returns (bool) {
        return RfReference.isValid(r);
    }
}

contract RfReferenceTest is Test {
    RfHarness internal h = new RfHarness();

    /// ISO 11649 published example.
    function test_isoVector() public view {
        assertEq(h.compute("539007547034"), "RF18539007547034");
        assertTrue(h.isValid("RF18539007547034"));
        assertFalse(h.isValid("RF19539007547034"));
        assertFalse(h.isValid("RF18539007547035"));
    }

    /// Batch references; vectors computed independently (98 − n mod 97 over body + "RF00").
    function test_batchVectors() public view {
        assertEq(h.forBatch(1), "RF60CS1");
        assertEq(h.forBatch(42), "RF88CS42");
        assertEq(h.forBatch(123_456_789), "RF48CS123456789");
        assertEq(h.compute("A"), "RF25A");
        assertTrue(h.isValid("RF60CS1"));
    }

    function test_invalid() public {
        vm.expectRevert(RfReference.InvalidBody.selector);
        h.compute("");
        vm.expectRevert(RfReference.InvalidBody.selector);
        h.compute("ABCDEFGHIJKLMNOPQRSTUV"); // 22 characters
        vm.expectRevert(RfReference.InvalidBody.selector);
        h.compute("cs1");
        assertFalse(h.isValid("RF6"));
        assertFalse(h.isValid("XX60CS1"));
        assertFalse(h.isValid("RFA0CS1"));
        assertFalse(h.isValid("RF60cs1"));
    }

    /// The body "CS" + batch fits ISO 11649's 21 characters for batch numbers below 10^19.
    function testFuzz_forBatch_isValid(uint64 b) public {
        if (b >= 1e19) {
            vm.expectRevert(RfReference.InvalidBody.selector);
            h.forBatch(b);
            return;
        }
        assertTrue(h.isValid(h.forBatch(b)));
    }
}
