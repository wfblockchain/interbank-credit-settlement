// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IExposureLedger } from "./IExposureLedger.sol";

/// @notice The spoke side of envelopes (design §4.2): local envelopes, local payments within them,
/// the per-epoch lock for the hub's cut, and the settlement burns.
///
/// Pair (issuer i, holder h): h holds i's token on this spoke. `env` is what the hub has granted
/// for the pair here, `used` the unsettled tokens of the current spoke epoch (the spoke's `open`).
/// At a cut the used part moves out of both into `locked` (it joins the hub's batch, which takes it
/// out of the hub's envelope at the same time); a settlement burn removes it from `locked`.
interface ISpokeExposureGuard {
    struct Member {
        address wallet;
        address issuerOps;
        address token;
        bool suspended;
    }

    enum QueueState {
        NONE,
        QUEUED,
        PAID,
        CANCELLED
    }

    struct QueueEntry {
        uint256 seq;
        bytes32 payer;
        bytes32 to;
        uint256 amount;
        bytes32 ref;
        uint64 enqueuedAt;
        QueueState state;
    }

    event MemberSet(bytes32 indexed id, address wallet, address issuerOps, address token);
    event SupplyCapSet(bytes32 indexed issuer, uint256 cap);
    event Paid(uint256 indexed seq, bytes32 indexed payer, bytes32 indexed to, uint256 amount, bytes32 ref);
    event Queued(uint256 indexed seq, uint8 reason);
    event QueueCancelled(uint256 indexed seq, uint8 reason);
    event EnvelopeGranted(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount, uint256 env);
    event GrantRefused(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event EnvelopeParked(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event EnvelopeReleased(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount, uint256 env);
    event MovedOut(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event MoveReturned(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event MoveBurned(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event MovedIn(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event EpochLocked(uint64 indexed epoch, uint256 pairs);
    event PairLocked(uint64 indexed epoch, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event PairBurned(uint64 indexed epoch, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    event Suspended(bytes32 indexed id);
    event Reinstated(bytes32 indexed id);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownMember(bytes32 id);
    error MemberAlreadySet(bytes32 id);
    error AddressInUse(address account);
    error TokenIssuerMismatch(bytes32 id, bytes32 tokenIssuer);
    error NotIssuerOps(address account);
    error NotHolderWallet(bytes32 holder, address account);
    error SelfPayment();
    error MemberSuspended(bytes32 id);
    error NotSuspended(bytes32 id);
    error TokenBlocked(bytes32 issuer, address holder);
    error NotQueued(uint256 seq);
    error NotPayer(uint256 seq);
    error ReleaseExceedsFree(uint256 requested, uint256 free);
    error MoveExceedsOpen(uint256 requested, uint256 open);
    error EpochAlreadyLocked(uint64 epoch);
    error BurnMismatch(uint64 epoch, bytes32 issuer, bytes32 holder, uint256 amount, uint256 locked);
    error MintRefused(uint8 reason);
    error NotALowering(uint256 current, uint256 requested);

    // Members and caps.
    function setMember(bytes32 id, address wallet, address issuerOps, address token) external;
    function setSupplyCap(bytes32 issuer, uint256 cap) external;
    function lowerSupplyCap(bytes32 issuer, uint256 cap) external;
    function reinstate(bytes32 id) external;

    // Local payments.
    function pay(bytes32 to, uint256 amount, bytes32 ref) external returns (uint256 seq);
    function drain(uint256 max) external returns (uint256 executed);
    function cancel(uint256 seq) external;

    // Messenger hooks.
    function grant(bytes32 issuer, bytes32 holder, uint256 amount) external returns (bool applied);
    function release(bytes32 issuer, bytes32 holder, uint256 amount) external;
    function moveOut(bytes32 issuer, bytes32 holder, address wallet, uint256 amount) external;
    function moveCancelled(bytes32 issuer, bytes32 holder, uint256 amount) external;
    function moveDone(bytes32 issuer, bytes32 holder, uint256 amount) external;
    function mintIn(bytes32 issuer, bytes32 holder, uint256 amount) external;
    function cut(uint64 epoch)
        external
        returns (bytes32[] memory issuers, bytes32[] memory holders, uint256[] memory amounts);
    function burnBatch(uint64 epoch, bytes32 issuer, bytes32 holder, uint256 amount) external;
    function suspend(bytes32 id) external;

    // Views.
    function DOMAIN() external view returns (uint32);
    function KIND() external view returns (IExposureLedger.DomainKind);
    function mintCheck(bytes32 issuer, bytes32 holder, address recipient, uint256 amount)
        external
        view
        returns (uint8 reason);
    function member(bytes32 id) external view returns (Member memory);
    function memberIds() external view returns (bytes32[] memory);
    function memberOfWallet(address wallet) external view returns (bytes32);
    function memberOfIssuerOps(address issuerOps) external view returns (bytes32);
    function env(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function used(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function open(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function available(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function locked(uint64 epoch, bytes32 issuer, bytes32 holder) external view returns (uint256);
    function lockedTotal(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function releasable(bytes32 issuer, bytes32 holder) external view returns (uint256);
    function supplyCap(bytes32 issuer) external view returns (uint256);
    function epochLocked(uint64 epoch) external view returns (bool);
    function queueEntry(uint256 seq) external view returns (QueueEntry memory);
    function queueLength() external view returns (uint256);
    function queueHead() external view returns (uint256);
    function nextSeq() external view returns (uint256);
}
