// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The cross-chain messenger, v4 (design §4). One message format and one verification
/// path for the hub and every spoke; HubMessenger and SpokeMessenger add what each side does with
/// a message.
interface ICrossChainMessenger {
    /// Encoded with `abi.encode(Envelope)`; the attesters and, for a MINT, the issuing bank sign
    /// `messageDigest(message)` on the destination.
    struct Envelope {
        uint8 version;
        uint8 kind;
        uint32 source;
        uint32 dest;
        uint64 nonce;
        bytes32 member;
        bytes32 counterparty;
        address recipient;
        uint256 amount;
        uint64 epoch;
        uint64 deadline;
        bytes32 ref;
    }

    /// Destination-side state of a (source, nonce): a MINT ends MINTED or CANCELLED, never both;
    /// every other kind ends DONE.
    enum Inbound {
        NONE,
        DONE,
        MINTED,
        CANCELLED
    }

    enum MoveStatus {
        NONE,
        PENDING,
        COMPLETED,
        CANCELLED
    }

    /// A token move as recorded at its source: locked until the destination proves the mint
    /// (MINT_ACK → burned) or its cancellation (MINT_CANCEL → unlocked).
    struct Move {
        bytes32 issuer;
        bytes32 holder;
        address wallet;
        uint256 amount;
        uint32 dest;
        uint64 deadline;
        MoveStatus status;
    }

    /// Inbound mint token bucket per (source domain, issuer): `level` refills at
    /// `capacity / window` up to `capacity`.
    struct RateLimit {
        uint256 capacity;
        uint256 level;
        uint64 window;
        uint64 updatedAt;
    }

    event MessageSent(uint32 indexed dest, uint64 indexed nonce, uint8 indexed kind, bytes message);
    event MessageReceived(uint32 indexed source, uint64 indexed nonce, uint8 indexed kind);
    event MintDelivered(
        uint32 indexed source, uint64 indexed nonce, bytes32 indexed issuer, address recipient, uint256 amount
    );
    event MintRefused(uint32 indexed source, uint64 indexed nonce, uint8 reason);
    event MintExpired(uint32 indexed source, uint64 indexed nonce);
    event MoveLocked(
        uint64 indexed nonce, bytes32 indexed issuer, bytes32 indexed holder, uint32 dest, uint256 amount, uint64 deadline
    );
    event MoveCompleted(uint64 indexed nonce);
    event MoveCancelled(uint64 indexed nonce);
    event AttesterSet(address indexed signer, bool enabled);
    event ThresholdSet(uint8 threshold);
    event IssuerKeySet(bytes32 indexed member, address key);
    event RemoteSet(uint32 indexed domain, address messenger);
    event RateLimitSet(uint32 indexed source, bytes32 indexed issuer, uint256 capacity, uint64 window);

    error ZeroAddress();
    error ZeroAmount();
    error BadVersion(uint8 version);
    error WrongDestination(uint32 dest);
    error UntrustedSource(uint32 source);
    error NonceUsed(uint32 source, uint64 nonce);
    error NotEnoughAttestations(uint256 valid, uint8 threshold);
    error SignersNotSorted();
    error NotAnAttester(address signer);
    error BadThreshold(uint8 threshold, uint256 attesters);
    error IssuerKeyNotSet(bytes32 member);
    error BadIssuerSignature(bytes32 member, address signer);
    error KeyHasOtherRole(address key);
    error KindNotAccepted(uint8 kind);
    error NotAMint(uint8 kind);
    error DeadlineNotPassed(uint64 deadline);
    error DeadlineInPast(uint64 deadline);
    error UnknownDestination(uint32 dest);
    error SpokeToSpoke(uint32 domain);
    error UnknownMove(uint64 nonce);
    error MoveMismatch(uint64 nonce);
    error RateLimited(uint32 source, bytes32 issuer, uint256 amount, uint256 available);
    error NotALowering(uint256 current, uint256 requested);
    error NotHolderWallet(bytes32 holder, address account);
    error UnknownToken(bytes32 issuer);

    function receiveMessage(bytes calldata message, bytes[] calldata attesterSigs, bytes calldata issuerSig)
        external;
    function cancelExpired(bytes calldata message, bytes[] calldata attesterSigs) external;
    function sendMint(bytes32 issuer, bytes32 holder, uint256 amount, uint32 dest, address recipient, uint64 deadline)
        external
        returns (uint64 nonce);

    function setAttester(address signer, bool enabled) external;
    function disableAttester(address signer) external;
    function setThreshold(uint8 t) external;
    function setIssuerKey(bytes32 member, address key) external;
    function setRemote(uint32 domain, address messenger) external;
    function setRateLimit(uint32 source, bytes32 issuer, uint256 capacity, uint64 window) external;
    function lowerRateLimit(uint32 source, bytes32 issuer, uint256 capacity) external;

    function VERSION() external view returns (uint8);
    function LOCAL_DOMAIN() external view returns (uint32);
    function HOME_DOMAIN() external view returns (uint32);
    function messageDigest(bytes calldata message) external view returns (bytes32);
    function threshold() external view returns (uint8);
    function attesterCount() external view returns (uint256);
    function isAttester(address signer) external view returns (bool);
    function issuerKey(bytes32 member) external view returns (address);
    function remote(uint32 domain) external view returns (address);
    function nextNonce() external view returns (uint64);
    function inbound(uint32 source, uint64 nonce) external view returns (Inbound);
    function move(uint64 nonce) external view returns (Move memory);
    function rateLimit(uint32 source, bytes32 issuer) external view returns (RateLimit memory);
    function rateAvailable(uint32 source, bytes32 issuer) external view returns (uint256);
}
