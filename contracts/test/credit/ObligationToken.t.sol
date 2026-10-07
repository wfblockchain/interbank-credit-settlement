// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ObligationToken } from "../../src/credit/ObligationToken.sol";
import { IObligationToken } from "../../src/interfaces/IObligationToken.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract ObligationTokenTest is CreditFixture {
    ObligationToken internal t;
    address internal holder = makeAddr("holder");
    address internal mover = makeAddr("mover");
    address internal tokMessenger = makeAddr("tok-messenger");

    function setUp() public {
        _deployAll();
        t = tok[A];
        bytes32 moverRole = t.MOVER_ROLE();
        bytes32 messengerRole = t.MESSENGER_ROLE();
        vm.startPrank(gov);
        t.grantRole(moverRole, mover);
        t.grantRole(messengerRole, tokMessenger);
        vm.stopPrank();
        vm.prank(address(ledger));
        t.mint(holder, 100);
    }

    function test_metadata() public view {
        assertEq(t.name(), "Bank A deposit token");
        assertEq(t.symbol(), "A-dT");
        assertEq(t.decimals(), 6);
        assertEq(t.issuer(), A);
        assertTrue(t.hasRole(t.LEDGER_ROLE(), address(ledger)));
        assertTrue(t.hasRole(t.BATCHES_ROLE(), address(batches)));
        assertTrue(t.hasRole(t.ISSUER_ADMIN_ROLE(), issuerAdmin[A]));
        assertTrue(t.hasRole(t.GUARDIAN_ROLE(), guardian));
        assertEq(t.defaultAdmin(), gov);
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(IObligationToken.ZeroAddress.selector);
        new ObligationToken(0, gov, "n", "s", A, address(0), address(batches), gov, guardian);
        vm.expectRevert(IObligationToken.ZeroAddress.selector);
        new ObligationToken(0, gov, "n", "s", A, address(ledger), address(0), gov, guardian);
        vm.expectRevert(IObligationToken.ZeroAddress.selector);
        new ObligationToken(0, gov, "n", "s", A, address(ledger), address(batches), address(0), guardian);
        vm.expectRevert(IObligationToken.ZeroAddress.selector);
        new ObligationToken(0, gov, "n", "s", A, address(ledger), address(batches), gov, address(0));
    }

    function test_mint_onlyLedger() public {
        bytes32 role = t.LEDGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        t.mint(holder, 1);
    }

    function test_burn_batchesOrMessenger() public {
        vm.prank(address(batches));
        t.burn(holder, 10);
        vm.prank(tokMessenger);
        t.burn(holder, 10);
        assertEq(t.balanceOf(holder), 80);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.NotBurner.selector, stranger));
        t.burn(holder, 1);
        vm.prank(address(ledger));
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.NotBurner.selector, address(ledger)));
        t.burn(holder, 1);
    }

    function test_noUserTransfers() public {
        vm.startPrank(holder);
        vm.expectRevert(IObligationToken.TransfersDisabled.selector);
        t.transfer(stranger, 1);
        vm.expectRevert(IObligationToken.TransfersDisabled.selector);
        t.approve(stranger, 1);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(IObligationToken.TransfersDisabled.selector);
        t.transferFrom(holder, stranger, 1);
    }

    function test_mover_escrow() public {
        vm.prank(holder);
        t.approve(mover, 40);
        vm.prank(mover);
        t.transferFrom(holder, mover, 40);
        assertEq(t.balanceOf(mover), 40);
        vm.prank(mover);
        t.transfer(holder, 15);
        assertEq(t.balanceOf(holder), 75);
        vm.prank(mover);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, mover, 0, 1));
        t.transferFrom(holder, mover, 1);
    }

    function test_freeze() public {
        bytes32 role = t.GUARDIAN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        t.setFrozen(holder, true);

        vm.expectEmit(address(t));
        emit IObligationToken.FrozenSet(holder, true);
        vm.prank(guardian);
        t.setFrozen(holder, true);
        assertTrue(t.frozen(holder));

        vm.prank(address(ledger));
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.HolderFrozen.selector, holder));
        t.mint(holder, 1);

        vm.prank(holder);
        t.approve(mover, 10);
        vm.prank(mover);
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.HolderFrozen.selector, holder));
        t.transferFrom(holder, mover, 1);

        vm.prank(address(ledger));
        t.mint(mover, 5);
        vm.prank(mover);
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.HolderFrozen.selector, holder));
        t.transfer(holder, 1);

        // Settlement still extinguishes.
        vm.prank(address(batches));
        t.burn(holder, 100);
        assertEq(t.balanceOf(holder), 0);
    }

    function test_pause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IObligationToken.NotPauser.selector, stranger));
        t.pause();

        vm.expectEmit(address(t));
        emit Pausable.Paused(guardian);
        vm.prank(guardian);
        t.pause();
        assertTrue(t.paused());

        vm.prank(address(ledger));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        t.mint(holder, 1);
        vm.prank(address(batches));
        t.burn(holder, 1);

        bytes32 role = t.ISSUER_ADMIN_ROLE();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, role));
        t.unpause();

        vm.expectEmit(address(t));
        emit Pausable.Unpaused(issuerAdmin[A]);
        vm.prank(issuerAdmin[A]);
        t.unpause();

        vm.prank(issuerAdmin[A]);
        t.pause();
        vm.prank(holder);
        t.approve(mover, 1);
        vm.prank(mover);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        t.transferFrom(holder, mover, 1);
    }
}
