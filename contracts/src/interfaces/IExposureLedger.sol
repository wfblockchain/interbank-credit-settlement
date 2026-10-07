// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Positions, the pre-transfer check, the queue, and the hub side of spoke envelopes
/// (design §3.5). Pair (issuer i, holder h): h holds i's token, i.e. h is exposed to i.
interface IExposureLedger {
    enum Window {
        BUSINESS,
        OFF_HOURS
    }

    enum DomainKind {
        NONE,
        PERMISSIONED,
        PUBLIC
    }

    enum QueueState {
        NONE,
        QUEUED,
        PAID,
        CANCELLED,
        EXPIRED
    }

    struct QueueEntry {
        uint256 seq;
        bytes32 payer;
        bytes32 to;
        uint256 amount;
        bytes32 ref;
        uint64 enqueuedAt;
        uint64 businessDay;
        QueueState state;
    }

    struct PendingPair {
        bytes32 issuer;
        bytes32 holder;
        uint256 amount;
        bool remote;
    }

    event Paid(uint256 indexed seq, bytes32 indexed payer, bytes32 indexed to, uint256 amount, bytes32 ref);
    event Queued(uint256 indexed seq, uint8 reason);
    event QueueCancelled(uint256 indexed seq, uint8 reason);
    event QueueExpired(uint256 indexed seq);
    event CapReached(bytes32 indexed to);
    event WindowSet(Window window, uint64 offHoursSession);
    event BusinessDaySet(uint64 businessDay);
    event DomainKindSet(uint32 indexed domain, DomainKind kind);
    event Snapshot(uint64 indexed epoch, bytes32 epochHash, uint256 pairs);
    event BatchSealed(uint64 indexed epoch);
    event PendingCleared(uint64 indexed epoch, uint256 start, uint256 count);
    event EpochSettled(uint64 indexed epoch);
    event EnvelopeReserved(uint32 indexed domain, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event EnvelopeReleased(uint32 indexed domain, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event EnvelopeToPending(
        uint32 indexed domain, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount, uint64 epoch
    );
    event RemoteAddedToBatch(uint64 indexed epoch, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event MovedOut(uint32 indexed domain, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event MoveReturned(uint32 indexed domain, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event MovedIn(uint32 indexed domain, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);

    error NotIssuerOps(address account);
    error ZeroAmount();
    error SelfPayment();
    error PayerNotInGoodStanding(bytes32 payer);
    error PayeeNotInGoodStanding(bytes32 payee);
    error OffHoursPrefundExceeded(bytes32 payer, uint256 used, uint256 amount, uint256 prefund);
    error BilateralLimitExceeded(bytes32 grantor, bytes32 debtor);
    error ReceiverCapExceeded(bytes32 receiver);
    error DebitCapExceeded(bytes32 debtor);
    error NotQueued(uint256 seq);
    error NotPayer(uint256 seq);
    error BatchInFlight(uint64 epoch);
    error EpochMismatch(uint64 expected, uint64 given);
    error EpochSealed(uint64 epoch);
    error EpochNotSealed(uint64 epoch);
    error RemoteUnrecorded(uint64 epoch, uint256 amount);
    error RemoteExceedsLocked(uint256 requested, uint256 available);
    error PageOutOfOrder(uint256 expectedStart, uint256 start);
    error PageOutOfRange(uint256 end, uint256 length);
    error BusinessDayRegress(uint64 current, uint64 requested);
    error UnknownDomain(uint32 domain);
    error InvalidDomain(uint32 domain);
    error DomainAlreadySet(uint32 domain);
    error EnvelopeUnderflow(uint256 requested, uint256 available);
    error ZeroAddress();
    error MoveExceedsOpen(uint256 requested, uint256 open);
    error MoveRefused(uint8 reason);

    // Payments and queue.
    function pay(bytes32 to, uint256 amount, bytes32 ref) external returns (uint256 seq);
    function drain(uint256 max) external returns (uint256 executed);
    function cancel(uint256 seq) external;

    // Operator.
    function setWindow(Window window) external;
    function setBusinessDay(uint64 day) external;
    function setDomainKind(uint32 domain, DomainKind kind) external;

    // Settlement hooks (BATCHES_ROLE).
    function snapshotForCut() external returns (bytes32 epochHash, uint64 epoch);
    function sealBatch(uint64 epoch) external;
    function clearPending(uint64 epoch, uint256 start, uint256 count) external;

    // Cross-chain hooks (MESSENGER_ROLE).
    function reserveEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) external;
    function releaseEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) external;
    function envelopeToPending(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount, uint64 epoch)
        external;
    function addRemoteToBatch(uint64 epoch, bytes32 issuer, bytes32 holder, uint256 amount) external;

    // Token moves between home and a spoke (MESSENGER_ROLE).
    function moveOut(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) external;
    function moveCancelled(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) external;
    function moveIn(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) external;
    function moveInCheck(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        view
        returns (uint8 reason);

    // Views.
    function open(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function pending(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function envelope(uint32 domain, bytes32 issuer, bytes32 holder) external view returns (uint256);
    function envelopeTotal(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function gross(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function bilateralNet(bytes32 holder, bytes32 issuer) external view returns (uint256);
    function netPosition(bytes32 member) external view returns (int256);
    function check(bytes32 payer, bytes32 to, uint256 amount) external view returns (uint8 reason);
    function epoch() external view returns (uint64);
    function epochHash() external view returns (bytes32);
    function pendingEpoch() external view returns (uint64);
    function isSealed(uint64 epoch) external view returns (bool);
    function businessDay() external view returns (uint64);
    function window() external view returns (Window);
    function domainKind(uint32 domain) external view returns (DomainKind);
    function offHoursUsed(bytes32 member) external view returns (uint256);
    function grossIn(bytes32 member) external view returns (uint256);
    function grossOut(bytes32 member) external view returns (uint256);
    function queuedFor(bytes32 member) external view returns (uint256 count);
    function remotePublicCommitted(uint64 epoch, bytes32 issuer, bytes32 holder) external view returns (uint256);
    function pendingPairs(uint64 epoch)
        external
        view
        returns (bytes32[] memory issuers, bytes32[] memory holders, uint256[] memory amounts);
    function pendingPairCount(uint64 epoch) external view returns (uint256);
    function pendingPair(uint64 epoch, uint256 index) external view returns (PendingPair memory);
    function clearedPairs(uint64 epoch) external view returns (uint256);
    function queueEntry(uint256 seq) external view returns (QueueEntry memory);
    function queueLength() external view returns (uint256);
    function queueHead() external view returns (uint256);
    function queueSeqAt(uint256 index) external view returns (uint256);
    function nextSeq() external view returns (uint256);
}
