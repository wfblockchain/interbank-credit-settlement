// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISettlementBatches } from "./ISettlementBatches.sol";

/// @notice k-of-n EIP-712 attestations by the settlement listener's signers (design §3.6).
interface ISettlementAttestor {
    struct Funding {
        uint8 kind;
        bytes32 member;
        uint256 value;
        uint64 asOf;
        uint64 nonce;
    }

    event SignerEnabled(address indexed signer);
    event SignerDisabled(address indexed signer);
    event ThresholdSet(uint256 k);
    event PaymentAttested(uint64 indexed batch, uint32 indexed leg, bytes32 indexed railTxId, uint256 amount);
    event FundingAttested(uint8 indexed kind, bytes32 indexed member, uint256 value, uint64 asOf, uint64 nonce);

    error ZeroAddress();
    error SignerAlreadyEnabled(address signer);
    error SignerNotEnabled(address signer);
    error ThresholdUnreachable(uint256 k, uint256 enabled);
    error InsufficientSignatures(uint256 given, uint256 k);
    error UnknownSigner(address signer);
    error DuplicateSigner(address signer);
    error SignersNotAscending(address previous, address next);
    error InvalidRail(uint8 rail);
    error ZeroRailTxId();
    error RailTxUsed(bytes32 railTxId);
    error RtpLimitExceeded(uint256 amount);
    error ZeroAmount();
    error FinalAtInFuture(uint64 finalAt);
    error InvalidKind(uint8 kind);
    error FundingNonceUsed(uint64 nonce);

    function attestPayment(ISettlementBatches.Payment calldata p, bytes[] calldata sigs) external;
    function attestFunding(Funding calldata f, bytes[] calldata sigs) external;
    function enableSigner(address signer) external;
    function disableSigner(address signer) external;
    function setThreshold(uint256 k) external;

    function paymentDigest(ISettlementBatches.Payment calldata p) external view returns (bytes32);
    function fundingDigest(Funding calldata f) external view returns (bytes32);
    function isSigner(address signer) external view returns (bool);
    function signers() external view returns (address[] memory);
    function enabledCount() external view returns (uint256);
    function threshold() external view returns (uint256);
    function usedRailTx(bytes32 railTxId) external view returns (bool);
    function usedFundingNonce(uint64 nonce) external view returns (bool);
}
