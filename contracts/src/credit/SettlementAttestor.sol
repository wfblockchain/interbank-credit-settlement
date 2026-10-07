// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ISettlementAttestor } from "../interfaces/ISettlementAttestor.sol";
import { ISettlementBatches } from "../interfaces/ISettlementBatches.sol";

/// @notice k-of-n EIP-712 attestations by the settlement listener's signers (design §3.6).
/// Signatures must be strictly ascending by signer address, each from an enabled signer.
/// A rail transaction id is usable once, forever.
contract SettlementAttestor is AccessControlDefaultAdminRules, EIP712, ISettlementAttestor {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(uint64 batch,uint32 leg,uint8 rail,bytes32 railTxId,address payerAcct,bytes32 payer,"
        "bytes32 payee,uint256 amount,uint64 finalAt)"
    );
    bytes32 public constant FUNDING_TYPEHASH =
        keccak256("Funding(uint8 kind,bytes32 member,uint256 value,uint64 asOf,uint64 nonce)");

    uint8 public constant RAIL_CHIPS = 1;
    uint8 public constant RAIL_RTP = 2;
    uint256 public constant RTP_MAX = 10_000_000e6;

    ISettlementBatches public immutable batches;
    ICollateralRegister public immutable register;

    address[] private _signers;
    mapping(address => bool) public isSigner;
    mapping(address => bool) private _known;
    uint256 public enabledCount;
    uint256 public threshold;
    mapping(bytes32 => bool) public usedRailTx;
    mapping(uint64 => bool) public usedFundingNonce;

    constructor(
        uint48 adminDelay,
        address admin,
        address batches_,
        address register_,
        address guardian,
        address[] memory signers_,
        uint256 k
    ) AccessControlDefaultAdminRules(adminDelay, admin) EIP712("CreditSettlementAttestor", "1") {
        if (batches_ == address(0) || register_ == address(0) || guardian == address(0)) {
            revert ZeroAddress();
        }
        batches = ISettlementBatches(batches_);
        register = ICollateralRegister(register_);
        _grantRole(GUARDIAN_ROLE, guardian);
        for (uint256 i = 0; i < signers_.length; i++) {
            _enable(signers_[i]);
        }
        _setThreshold(k);
    }

    function attestPayment(ISettlementBatches.Payment calldata p, bytes[] calldata sigs) external {
        if (p.rail != RAIL_CHIPS && p.rail != RAIL_RTP) {
            revert InvalidRail(p.rail);
        }
        if (p.railTxId == bytes32(0)) {
            revert ZeroRailTxId();
        }
        if (usedRailTx[p.railTxId]) {
            revert RailTxUsed(p.railTxId);
        }
        if (p.amount == 0) {
            revert ZeroAmount();
        }
        if (p.rail == RAIL_RTP && p.amount > RTP_MAX) {
            revert RtpLimitExceeded(p.amount);
        }
        if (p.finalAt > block.timestamp) {
            revert FinalAtInFuture(p.finalAt);
        }
        _verify(paymentDigest(p), sigs);
        usedRailTx[p.railTxId] = true;
        emit PaymentAttested(p.batch, p.leg, p.railTxId, p.amount);
        batches.recordPayment(p);
    }

    function attestFunding(Funding calldata f, bytes[] calldata sigs) external {
        if (f.kind > uint8(type(ICollateralRegister.Kind).max)) {
            revert InvalidKind(f.kind);
        }
        if (usedFundingNonce[f.nonce]) {
            revert FundingNonceUsed(f.nonce);
        }
        _verify(fundingDigest(f), sigs);
        usedFundingNonce[f.nonce] = true;
        emit FundingAttested(f.kind, f.member, f.value, f.asOf, f.nonce);
        register.attest(ICollateralRegister.Kind(f.kind), f.member, f.value, f.asOf);
    }

    // Signer set: changes by governance; the guardian may only disable.

    function enableSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _enable(signer);
    }

    function disableSigner(address signer) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        if (!isSigner[signer]) {
            revert SignerNotEnabled(signer);
        }
        if (threshold > enabledCount - 1) {
            revert ThresholdUnreachable(threshold, enabledCount - 1);
        }
        isSigner[signer] = false;
        enabledCount--;
        emit SignerDisabled(signer);
    }

    function setThreshold(uint256 k) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setThreshold(k);
    }

    // Views.

    function paymentDigest(ISettlementBatches.Payment calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_TYPEHASH,
                    p.batch,
                    p.leg,
                    p.rail,
                    p.railTxId,
                    p.payerAcct,
                    p.payer,
                    p.payee,
                    p.amount,
                    p.finalAt
                )
            )
        );
    }

    function fundingDigest(Funding calldata f) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(FUNDING_TYPEHASH, f.kind, f.member, f.value, f.asOf, f.nonce)));
    }

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // Internals.

    function _verify(bytes32 digest, bytes[] calldata sigs) private view {
        if (sigs.length < threshold) {
            revert InsufficientSignatures(sigs.length, threshold);
        }
        address last;
        for (uint256 i = 0; i < sigs.length; i++) {
            address s = ECDSA.recover(digest, sigs[i]);
            if (!isSigner[s]) {
                revert UnknownSigner(s);
            }
            if (s == last) {
                revert DuplicateSigner(s);
            }
            if (s < last) {
                revert SignersNotAscending(last, s);
            }
            last = s;
        }
    }

    function _enable(address signer) private {
        if (signer == address(0)) {
            revert ZeroAddress();
        }
        if (isSigner[signer]) {
            revert SignerAlreadyEnabled(signer);
        }
        isSigner[signer] = true;
        enabledCount++;
        if (!_known[signer]) {
            _known[signer] = true;
            _signers.push(signer);
        }
        emit SignerEnabled(signer);
    }

    function _setThreshold(uint256 k) private {
        if (k == 0 || k > enabledCount) {
            revert ThresholdUnreachable(k, enabledCount);
        }
        threshold = k;
        emit ThresholdSet(k);
    }
}
