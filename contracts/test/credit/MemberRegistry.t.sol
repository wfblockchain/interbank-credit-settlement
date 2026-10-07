// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IAccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import { MemberRegistry } from "../../src/credit/MemberRegistry.sol";
import { ObligationToken } from "../../src/credit/ObligationToken.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract MemberRegistryTest is CreditFixture {
    bytes32 internal constant D = bytes32("BNKDUS30");
    address internal dWallet = makeAddr("d-wallet");
    address internal dOps = makeAddr("d-ops");
    ObligationToken internal dTok;

    function setUp() public {
        _deployAll();
        dTok = _newToken(D, "Bank D deposit token", "D-dT");
    }

    function _admitD(IMemberRegistry.Tier tier) internal {
        vm.prank(gov);
        registry.admit(D, dWallet, dOps, address(dTok), tier);
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(IMemberRegistry.ZeroAddress.selector);
        new MemberRegistry(0, gov, address(0), address(dm));
        vm.expectRevert(IMemberRegistry.ZeroAddress.selector);
        new MemberRegistry(0, gov, guardian, address(0));
    }

    function test_admit_indexesAndEmits() public {
        vm.expectEmit(address(registry));
        emit IMemberRegistry.Admitted(D, dWallet, dOps, address(dTok), IMemberRegistry.Tier.PREFUND_ONLY);
        _admitD(IMemberRegistry.Tier.PREFUND_ONLY);
        IMemberRegistry.Member memory m = registry.member(D);
        assertEq(m.wallet, dWallet);
        assertEq(m.issuerOps, dOps);
        assertEq(m.token, address(dTok));
        assertEq(uint8(m.tier), uint8(IMemberRegistry.Tier.PREFUND_ONLY));
        assertEq(uint8(m.status), uint8(IMemberRegistry.Status.ACTIVE));
        assertEq(registry.memberOfWallet(dWallet), D);
        assertEq(registry.memberOfIssuerOps(dOps), D);
        assertEq(registry.memberOfToken(address(dTok)), D);
        assertEq(registry.memberOfWallet(stranger), bytes32(0));
        assertEq(registry.memberIds().length, 4);
        assertEq(registry.activeCount(), 4);
        assertEq(registry.activeCreditCount(), 3);
        assertTrue(registry.goodStanding(D));
    }

    function test_admit_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        registry.admit(D, dWallet, dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
    }

    function test_admit_errors() public {
        vm.startPrank(gov);
        vm.expectRevert(IMemberRegistry.ZeroId.selector);
        registry.admit(bytes32(0), dWallet, dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.ReservedId.selector, COLLATERAL));
        registry.admit(COLLATERAL, dWallet, dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.ReservedId.selector, POOL));
        registry.admit(POOL, dWallet, dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(IMemberRegistry.ZeroAddress.selector);
        registry.admit(D, address(0), dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(IMemberRegistry.ZeroAddress.selector);
        registry.admit(D, dWallet, address(0), address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(IMemberRegistry.ZeroAddress.selector);
        registry.admit(D, dWallet, dOps, address(0), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(IMemberRegistry.InvalidTier.selector);
        registry.admit(D, dWallet, dOps, address(dTok), IMemberRegistry.Tier.NONE);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.AlreadyAdmitted.selector, A));
        registry.admit(A, dWallet, dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.AddressInUse.selector, wallet[A]));
        registry.admit(D, wallet[A], dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.AddressInUse.selector, ops[A]));
        registry.admit(D, dWallet, ops[A], address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.AddressInUse.selector, address(tok[A])));
        registry.admit(D, dWallet, dOps, address(tok[A]), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.AddressInUse.selector, dWallet));
        registry.admit(D, dWallet, dWallet, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.TokenIssuerMismatch.selector, bytes32("BNKEUS30"), D));
        registry.admit(bytes32("BNKEUS30"), dWallet, dOps, address(dTok), IMemberRegistry.Tier.CREDIT);
        vm.stopPrank();
    }

    function test_suspend_reinstate() public {
        bytes32 role = registry.GUARDIAN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        registry.suspend(A, bytes32("PCA"));

        vm.expectEmit(address(registry));
        emit IMemberRegistry.Suspended(A, bytes32("PCA"));
        vm.prank(guardian);
        registry.suspend(A, bytes32("PCA"));
        assertFalse(registry.goodStanding(A));
        assertEq(registry.activeCount(), 2);
        assertEq(registry.activeCreditCount(), 2);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotActive.selector, A));
        registry.suspend(A, bytes32("PCA"));

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        registry.reinstate(A);

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotSuspended.selector, B));
        registry.reinstate(B);

        vm.expectEmit(address(registry));
        emit IMemberRegistry.Reinstated(A);
        vm.prank(gov);
        registry.reinstate(A);
        assertTrue(registry.goodStanding(A));
        assertEq(registry.activeCount(), 3);
        assertEq(registry.activeCreditCount(), 3);
    }

    function test_markDefaulted() public {
        bytes32 role = registry.DEFAULT_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        registry.markDefaulted(A);

        vm.expectEmit(address(registry));
        emit IMemberRegistry.Defaulted(A);
        vm.prank(address(dm));
        registry.markDefaulted(A);
        assertEq(uint8(registry.member(A).status), uint8(IMemberRegistry.Status.DEFAULTED));
        assertEq(registry.activeCount(), 2);

        vm.prank(guardian);
        registry.suspend(B, bytes32("X"));
        vm.prank(address(dm));
        registry.markDefaulted(B);
        assertEq(registry.activeCount(), 1);
        assertEq(registry.activeCreditCount(), 1);

        vm.prank(address(dm));
        vm.expectRevert(
            abi.encodeWithSelector(IMemberRegistry.CannotDefault.selector, A, IMemberRegistry.Status.DEFAULTED)
        );
        registry.markDefaulted(A);
        vm.prank(address(dm));
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.CannotDefault.selector, D, IMemberRegistry.Status.NONE));
        registry.markDefaulted(D);

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IMemberRegistry.NotSuspended.selector, A));
        registry.reinstate(A);
    }

    /// OZ AccessControlDefaultAdminRules: accepting needs a later block even with a zero delay.
    function test_adminTransfer_needsLaterTimestamp() public {
        address next = makeAddr("next-admin");
        vm.prank(gov);
        registry.beginDefaultAdminTransfer(next);
        (, uint48 schedule) = registry.pendingDefaultAdmin();
        vm.prank(next);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule)
        );
        registry.acceptDefaultAdminTransfer();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(next);
        registry.acceptDefaultAdminTransfer();
        assertEq(registry.defaultAdmin(), next);
    }
}
