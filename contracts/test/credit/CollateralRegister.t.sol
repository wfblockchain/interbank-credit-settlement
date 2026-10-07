// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { CollateralRegister } from "../../src/credit/CollateralRegister.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract CollateralRegisterTest is CreditFixture {
    function setUp() public {
        _deployAll();
    }

    function _attest(ICollateralRegister.Kind kind, bytes32 id, uint256 value, uint64 asOf) internal {
        vm.prank(address(attestor));
        register.attest(kind, id, value, asOf);
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(ICollateralRegister.ZeroAddress.selector);
        new CollateralRegister(0, gov, address(0), address(ledger), address(dm), address(limits));
        vm.expectRevert(ICollateralRegister.ZeroAddress.selector);
        new CollateralRegister(0, gov, address(attestor), address(0), address(dm), address(limits));
        vm.expectRevert(ICollateralRegister.ZeroAddress.selector);
        new CollateralRegister(0, gov, address(attestor), address(ledger), address(0), address(limits));
        vm.expectRevert(ICollateralRegister.ZeroAddress.selector);
        new CollateralRegister(0, gov, address(attestor), address(ledger), address(dm), address(0));
    }

    function test_attest_eachKind() public {
        vm.expectEmit(address(register));
        emit ICollateralRegister.Attested(ICollateralRegister.Kind.COLLATERAL, A, 7 * MN, 1);
        _attest(ICollateralRegister.Kind.COLLATERAL, A, 7 * MN, 1);
        _attest(ICollateralRegister.Kind.POOL, A, 3 * MN, 1);
        _attest(ICollateralRegister.Kind.POOL, B, 2 * MN, 1);
        _attest(ICollateralRegister.Kind.RTP_PREFUND, A, 9 * MN, 1);
        _attest(ICollateralRegister.Kind.POOL_REQUIRED, bytes32(0), 4 * MN, 1);
        assertEq(register.collateral(A), 7 * MN);
        assertEq(register.poolShare(A), 3 * MN);
        assertEq(register.rtpPrefund(A), 9 * MN);
        assertEq(register.poolRequired(), 4 * MN);
        assertEq(register.poolTotal(), 5 * MN);
        assertEq(register.lastAsOf(ICollateralRegister.Kind.POOL, B), 1);
        // Re-attesting replaces the value in the total.
        _attest(ICollateralRegister.Kind.POOL, A, 1 * MN, 2);
        assertEq(register.poolTotal(), 3 * MN);
        assertEq(register.poolContributors().length, 2);
    }

    function test_attest_onlyAttestor() public {
        bytes32 role = register.ATTESTOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        register.attest(ICollateralRegister.Kind.COLLATERAL, A, 1, 1);
    }

    function test_attest_staleAndIdRules() public {
        _attest(ICollateralRegister.Kind.COLLATERAL, A, 1, 5);
        vm.startPrank(address(attestor));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegister.StaleAttestation.selector, ICollateralRegister.Kind.COLLATERAL, A, 5, 5
            )
        );
        register.attest(ICollateralRegister.Kind.COLLATERAL, A, 2, 5);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegister.StaleAttestation.selector, ICollateralRegister.Kind.COLLATERAL, A, 4, 5
            )
        );
        register.attest(ICollateralRegister.Kind.COLLATERAL, A, 2, 4);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralRegister.StaleAttestation.selector, ICollateralRegister.Kind.COLLATERAL, B, 0, 0
            )
        );
        register.attest(ICollateralRegister.Kind.COLLATERAL, B, 2, 0);
        vm.expectRevert(ICollateralRegister.InvalidAttestationId.selector);
        register.attest(ICollateralRegister.Kind.POOL_REQUIRED, A, 1, 1);
        vm.expectRevert(ICollateralRegister.InvalidAttestationId.selector);
        register.attest(ICollateralRegister.Kind.COLLATERAL, bytes32(0), 1, 1);
        vm.stopPrank();
    }

    function test_drawCollateral() public {
        _attest(ICollateralRegister.Kind.COLLATERAL, A, 10 * MN, 1);
        bytes32 role = register.DEFAULT_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        register.drawCollateral(A, 1);

        vm.startPrank(address(dm));
        vm.expectEmit(address(register));
        emit ICollateralRegister.CollateralDrawn(A, 4 * MN);
        register.drawCollateral(A, 4 * MN);
        assertEq(register.collateral(A), 6 * MN);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegister.InsufficientResource.selector, 7 * MN, 6 * MN));
        register.drawCollateral(A, 7 * MN);
        vm.stopPrank();
    }

    function test_drawPool_proRata() public {
        _attest(ICollateralRegister.Kind.POOL, A, 1, 1);
        _attest(ICollateralRegister.Kind.POOL, B, 2, 1);
        _attest(ICollateralRegister.Kind.POOL, C, 4, 1);
        bytes32 role = register.DEFAULT_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        register.drawPool(1);

        vm.startPrank(address(dm));
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegister.InsufficientResource.selector, 8, 7));
        register.drawPool(8);
        register.drawPool(0);
        assertEq(register.poolTotal(), 7);
        // 3 of 7: floors 0, 0, 1; remainder 2 taken from contributors in order.
        vm.expectEmit(address(register));
        emit ICollateralRegister.PoolDrawn(3);
        register.drawPool(3);
        vm.stopPrank();
        assertEq(register.poolTotal(), 4);
        assertEq(register.poolShare(A) + register.poolShare(B) + register.poolShare(C), 4);
        assertEq(register.poolShare(A), 0);
        assertEq(register.poolShare(B), 1);
        assertEq(register.poolShare(C), 3);
    }

    function testFuzz_drawPool_conservesTotal(uint96 a, uint96 b, uint96 c, uint256 draw) public {
        _attest(ICollateralRegister.Kind.POOL, A, a, 1);
        _attest(ICollateralRegister.Kind.POOL, B, b, 1);
        _attest(ICollateralRegister.Kind.POOL, C, c, 1);
        uint256 total = uint256(a) + b + c;
        draw = bound(draw, 0, total);
        vm.prank(address(dm));
        register.drawPool(draw);
        assertEq(register.poolTotal(), total - draw);
        assertEq(register.poolShare(A) + register.poolShare(B) + register.poolShare(C), total - draw);
        assertLe(register.poolShare(A), a);
        assertLe(register.poolShare(B), b);
        assertLe(register.poolShare(C), c);
    }

    function test_publicCommitments() public {
        _attest(ICollateralRegister.Kind.COLLATERAL, A, 20 * MN, 1);
        // Mandatory backing: min(5M, 20M / 2) × 2 = 10M, so 10M is free.
        assertEq(register.collateralCommitted(A), 10 * MN);
        assertEq(register.freeCollateral(A), 10 * MN);

        bytes32 role = register.LEDGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        register.commitPublic(A, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        register.releasePublic(A, 1);

        vm.startPrank(address(ledger));
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralRegister.InsufficientFreeCollateral.selector, A, 10 * MN + 1, 10 * MN)
        );
        register.commitPublic(A, 10 * MN + 1);
        vm.expectEmit(address(register));
        emit ICollateralRegister.PublicCommitted(A, 4 * MN, 4 * MN);
        register.commitPublic(A, 4 * MN);
        vm.stopPrank();

        // Public commitments come out of the mandatory denominator first: (20 − 4) / 2 = 8 > 5.
        assertEq(register.publicCommitted(A), 4 * MN);
        assertEq(register.collateralCommitted(A), 14 * MN);
        assertEq(register.freeCollateral(A), 6 * MN);

        vm.startPrank(address(ledger));
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegister.ReleaseExceedsCommitted.selector, A, 5 * MN, 4 * MN));
        register.releasePublic(A, 5 * MN);
        vm.expectEmit(address(register));
        emit ICollateralRegister.PublicReleased(A, 3 * MN, 1 * MN);
        register.releasePublic(A, 3 * MN);
        vm.stopPrank();

        // Lowering collateral below the commitment does not fail; free collateral floors at 0.
        _attest(ICollateralRegister.Kind.COLLATERAL, A, 0, 2);
        assertEq(register.freeCollateral(A), 0);
    }
}
