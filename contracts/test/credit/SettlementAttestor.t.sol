// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { SettlementAttestor } from "../../src/credit/SettlementAttestor.sol";
import { ICollateralRegister } from "../../src/interfaces/ICollateralRegister.sol";
import { ISettlementAttestor } from "../../src/interfaces/ISettlementAttestor.sol";
import { ISettlementBatches } from "../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "./utils/CreditFixture.sol";

contract SettlementAttestorTest is CreditFixture {
    uint64 internal b;

    function setUp() public {
        vm.warp(1_760_000_000);
        _deployAll();
        _standardLimits();
        _pay(A, B, 50 * MN);
        b = _cut(1);
        _submitPlan(b);
    }

    function test_constructor_rules() public {
        address[] memory s = signerAddrs;
        vm.expectRevert(ISettlementAttestor.ZeroAddress.selector);
        new SettlementAttestor(0, gov, address(0), address(register), guardian, s, 3);
        vm.expectRevert(ISettlementAttestor.ZeroAddress.selector);
        new SettlementAttestor(0, gov, address(batches), address(0), guardian, s, 3);
        vm.expectRevert(ISettlementAttestor.ZeroAddress.selector);
        new SettlementAttestor(0, gov, address(batches), address(register), address(0), s, 3);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.ThresholdUnreachable.selector, 6, 5));
        new SettlementAttestor(0, gov, address(batches), address(register), guardian, s, 6);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.ThresholdUnreachable.selector, 0, 5));
        new SettlementAttestor(0, gov, address(batches), address(register), guardian, s, 0);
        address[] memory dup = new address[](2);
        dup[0] = s[0];
        dup[1] = s[0];
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.SignerAlreadyEnabled.selector, s[0]));
        new SettlementAttestor(0, gov, address(batches), address(register), guardian, dup, 1);
        assertEq(attestor.threshold(), 3);
        assertEq(attestor.enabledCount(), 5);
        assertEq(attestor.signers().length, 5);
    }

    function test_eip712_domainAndTypes() public view {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CreditSettlementAttestor"),
                keccak256("1"),
                block.chainid,
                address(attestor)
            )
        );
        assertEq(attestor.domainSeparator(), domain);
        assertEq(
            attestor.PAYMENT_TYPEHASH(),
            keccak256(
                "Payment(uint64 batch,uint32 leg,uint8 rail,bytes32 railTxId,address payerAcct,bytes32 payer,bytes32 payee,uint256 amount,uint64 finalAt)"
            )
        );
        assertEq(
            attestor.FUNDING_TYPEHASH(),
            keccak256("Funding(uint8 kind,bytes32 member,uint256 value,uint64 asOf,uint64 nonce)")
        );
        ISettlementAttestor.Funding memory f = ISettlementAttestor.Funding(1, A, 2, 3, 4);
        bytes32 structHash = keccak256(abi.encode(attestor.FUNDING_TYPEHASH(), f.kind, f.member, f.value, f.asOf, f.nonce));
        assertEq(attestor.fundingDigest(f), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function test_attestPayment_emitsAndMarksUsed() public {
        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, A, B, 50 * MN);
        bytes[] memory sigs = _sigs(attestor.paymentDigest(p), 3);
        vm.expectEmit(address(attestor));
        emit ISettlementAttestor.PaymentAttested(b, 0, p.railTxId, 50 * MN);
        vm.prank(stranger); // anyone may submit
        attestor.attestPayment(p, sigs);
        assertTrue(attestor.usedRailTx(p.railTxId));
    }

    function test_attestPayment_fieldChecks() public {
        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, A, B, 50 * MN);
        bytes[] memory sigs = new bytes[](0);
        p.rail = 3;
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.InvalidRail.selector, 3));
        attestor.attestPayment(p, sigs);
        p.rail = 0;
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.InvalidRail.selector, 0));
        attestor.attestPayment(p, sigs);
        p.rail = CHIPS;
        bytes32 id = p.railTxId;
        p.railTxId = 0;
        vm.expectRevert(ISettlementAttestor.ZeroRailTxId.selector);
        attestor.attestPayment(p, sigs);
        p.railTxId = id;
        p.amount = 0;
        vm.expectRevert(ISettlementAttestor.ZeroAmount.selector);
        attestor.attestPayment(p, sigs);
        p.amount = 50 * MN;
        p.finalAt = uint64(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.FinalAtInFuture.selector, block.timestamp + 1));
        attestor.attestPayment(p, sigs);
        p.finalAt = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.InsufficientSignatures.selector, 0, 3));
        attestor.attestPayment(p, sigs);
        // A signature over different fields recovers an unknown address.
        sigs = _sigs(attestor.paymentDigest(p), 3);
        p.amount = 49 * MN;
        vm.expectRevert();
        attestor.attestPayment(p, sigs);
    }

    function test_attestFunding() public {
        ISettlementAttestor.Funding memory f = ISettlementAttestor.Funding(0, C, 12 * MN, 100, 77);
        bytes[] memory sigs = _sigs(attestor.fundingDigest(f), 3);
        vm.expectEmit(address(attestor));
        emit ISettlementAttestor.FundingAttested(0, C, 12 * MN, 100, 77);
        attestor.attestFunding(f, sigs);
        assertEq(register.collateral(C), 12 * MN);
        assertTrue(attestor.usedFundingNonce(77));
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.FundingNonceUsed.selector, 77));
        attestor.attestFunding(f, sigs);

        f.kind = 4;
        f.nonce = 78;
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.InvalidKind.selector, 4));
        attestor.attestFunding(f, sigs);

        f = ISettlementAttestor.Funding(0, C, 1, 101, 79);
        sigs = _sigs(attestor.fundingDigest(f), 2);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.InsufficientSignatures.selector, 2, 3));
        attestor.attestFunding(f, sigs);
    }

    function test_signerManagement() public {
        address extra = makeAddr("signer-6");
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        attestor.enableSigner(extra);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        attestor.setThreshold(2);
        bytes32 role = attestor.GUARDIAN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        attestor.disableSigner(signerAddrs[0]);

        vm.startPrank(gov);
        vm.expectEmit(address(attestor));
        emit ISettlementAttestor.SignerEnabled(extra);
        attestor.enableSigner(extra);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.SignerAlreadyEnabled.selector, extra));
        attestor.enableSigner(extra);
        vm.expectRevert(ISettlementAttestor.ZeroAddress.selector);
        attestor.enableSigner(address(0));
        vm.expectEmit(address(attestor));
        emit ISettlementAttestor.ThresholdSet(4);
        attestor.setThreshold(4);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.ThresholdUnreachable.selector, 7, 6));
        attestor.setThreshold(7);
        vm.stopPrank();

        // The guardian may disable while k stays reachable.
        vm.startPrank(guardian);
        vm.expectEmit(address(attestor));
        emit ISettlementAttestor.SignerDisabled(extra);
        attestor.disableSigner(extra);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.SignerNotEnabled.selector, extra));
        attestor.disableSigner(extra);
        attestor.disableSigner(signerAddrs[4]);
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.ThresholdUnreachable.selector, 4, 3));
        attestor.disableSigner(signerAddrs[3]);
        vm.stopPrank();
        assertEq(attestor.enabledCount(), 4);
        assertFalse(attestor.isSigner(signerAddrs[4]));

        // A disabled signer's signature is refused.
        ISettlementBatches.Payment memory p = _payment(b, 0, CHIPS, A, B, 50 * MN);
        bytes32 digest = attestor.paymentDigest(p);
        bytes[] memory sigs = new bytes[](4);
        for (uint256 i = 0; i < 4; i++) {
            sigs[i] = _sign(digest, signerKeys[i + 1]);
        }
        vm.expectRevert(abi.encodeWithSelector(ISettlementAttestor.UnknownSigner.selector, signerAddrs[4]));
        attestor.attestPayment(p, sigs);

        // Re-enabled by governance; the signer list keeps one entry per address.
        vm.prank(gov);
        attestor.enableSigner(signerAddrs[4]);
        assertEq(attestor.signers().length, 6);
        attestor.attestPayment(p, sigs);
    }
}
