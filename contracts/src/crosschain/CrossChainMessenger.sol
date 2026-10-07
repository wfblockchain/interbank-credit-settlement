// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ICrossChainMessenger } from "../interfaces/ICrossChainMessenger.sol";

/// @notice Cross-chain messenger v4 (design §4): what the hub and every spoke share. HubMessenger
/// and SpokeMessenger add what each side does with a message.
///
/// AUTHORITY. A message is accepted only from the messenger registered for its source domain,
/// once per (source, nonce), with signatures from a strict majority of the operator's attesters
/// (strictly ascending by signer, each enabled). A MINT additionally needs the issuing bank's own
/// key. Keys cannot hold both roles. Transports only carry; none holds mint power. Attesters sign
/// after source-chain finality, each reading the source from a node it runs (operational rule).
///
/// LOCK-THEN-BURN. `sendMint` locks the holder's tokens at the source and records the move
/// PENDING. The destination either mints (MINTED → MINT_ACK → the source burns the locked tokens)
/// or refuses / times out (CANCELLED → MINT_CANCEL → the source unlocks). A destination never
/// both mints and cancels a nonce, so a token is never burned before its mint is proven and never
/// minted twice. After the deadline anyone may cancel an un-minted nonce at the destination with
/// the message's attestations (`cancelExpired`): the timeout is a proof from the destination, not
/// a clock at the source.
///
/// BOUNDS. Every MINT spends the receiving chain's token bucket for (source domain, issuer); it
/// refills at capacity / window. Mints only, never burns. An exhausted bucket reverts the delivery
/// (the message stays deliverable), it does not cancel it.
abstract contract CrossChainMessenger is AccessControlDefaultAdminRules, ICrossChainMessenger {
    uint8 public constant VERSION = 4;

    uint8 public constant MINT = 0;
    uint8 public constant MINT_ACK = 1;
    uint8 public constant MINT_CANCEL = 2;
    uint8 public constant ENVELOPE_GRANT = 3;
    uint8 public constant ENVELOPE_RELEASE = 4;
    uint8 public constant CUT = 5;
    uint8 public constant BATCH_LOCKED = 6;
    uint8 public constant BURN_BATCH = 7;
    uint8 public constant SUSPEND = 8;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint64 public constant DEFAULT_WINDOW = 1 hours;
    bytes32 private constant DIGEST_TAG = keccak256("CreditCrossChainMessage.v4");

    uint32 public immutable LOCAL_DOMAIN;
    uint32 public immutable HOME_DOMAIN;

    uint8 public threshold;
    uint256 public attesterCount;
    mapping(address => bool) public isAttester;
    mapping(bytes32 => address) public issuerKey;
    mapping(address => bytes32) public issuerOfKey;
    mapping(uint32 => address) public remote;
    uint64 public nextNonce = 1;
    mapping(uint32 => mapping(uint64 => Inbound)) public inbound;

    mapping(uint64 => Move) private _moves;
    mapping(uint32 => mapping(bytes32 => RateLimit)) private _rates;

    constructor(
        uint48 adminDelay,
        address admin,
        uint32 localDomain,
        uint32 homeDomain,
        address guardian,
        address operator,
        address[] memory attesters,
        uint8 threshold_
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (guardian == address(0) || operator == address(0)) {
            revert ZeroAddress();
        }
        LOCAL_DOMAIN = localDomain;
        HOME_DOMAIN = homeDomain;
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, operator);
        for (uint256 i = 0; i < attesters.length; i++) {
            address a = attesters[i];
            if (a == address(0)) {
                revert ZeroAddress();
            }
            if (isAttester[a]) {
                revert KeyHasOtherRole(a);
            }
            isAttester[a] = true;
            emit AttesterSet(a, true);
        }
        attesterCount = attesters.length;
        _checkThreshold(threshold_, attesters.length);
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    // ---------------------------------------------------------------- messages

    /// Delivers an attested message. A MINT also needs `issuerSig`, the issuing bank's signature
    /// over the same digest; other kinds ignore it.
    function receiveMessage(bytes calldata message, bytes[] calldata attesterSigs, bytes calldata issuerSig)
        external
    {
        (Envelope memory e, bytes32 digest) = _open(message, attesterSigs);
        if (e.kind == MINT) {
            _checkIssuer(e.member, digest, issuerSig);
            uint8 reason = _mintCheck(e);
            if (reason == 0) {
                _consumeRate(e.source, e.member, e.amount);
                inbound[e.source][e.nonce] = Inbound.MINTED;
                _mintIn(e);
                emit MintDelivered(e.source, e.nonce, e.member, e.recipient, e.amount);
                _reply(e, MINT_ACK);
            } else {
                inbound[e.source][e.nonce] = Inbound.CANCELLED;
                emit MintRefused(e.source, e.nonce, reason);
                _reply(e, MINT_CANCEL);
            }
        } else {
            inbound[e.source][e.nonce] = Inbound.DONE;
            if (e.kind == MINT_ACK || e.kind == MINT_CANCEL) {
                _settleMove(e);
            } else {
                _handle(e);
            }
        }
        emit MessageReceived(e.source, e.nonce, e.kind);
    }

    /// After its deadline, an un-minted MINT is cancelled here for good and MINT_CANCEL goes back
    /// to the source. Anyone may call with the message's attestations.
    function cancelExpired(bytes calldata message, bytes[] calldata attesterSigs) external {
        (Envelope memory e,) = _open(message, attesterSigs);
        if (e.kind != MINT) {
            revert NotAMint(e.kind);
        }
        if (block.timestamp <= e.deadline) {
            revert DeadlineNotPassed(e.deadline);
        }
        inbound[e.source][e.nonce] = Inbound.CANCELLED;
        emit MintExpired(e.source, e.nonce);
        _reply(e, MINT_CANCEL);
        emit MessageReceived(e.source, e.nonce, e.kind);
    }

    /// Locks `amount` of `issuer`'s token held by the caller (the holder's wallet) and sends a
    /// MINT to `dest`. Spokes move only to and from home.
    function sendMint(bytes32 issuer, bytes32 holder, uint256 amount, uint32 dest, address recipient, uint64 deadline)
        external
        returns (uint64 nonce)
    {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        if (deadline <= block.timestamp) {
            revert DeadlineInPast(deadline);
        }
        _checkDest(dest);
        _lockMove(issuer, holder, msg.sender, amount, dest);
        nonce = _send(MINT, dest, issuer, holder, recipient, amount, 0, deadline, bytes32(0));
        _moves[nonce] = Move({
            issuer: issuer,
            holder: holder,
            wallet: msg.sender,
            amount: amount,
            dest: dest,
            deadline: deadline,
            status: MoveStatus.PENDING
        });
        emit MoveLocked(nonce, issuer, holder, dest, amount, deadline);
    }

    // ---------------------------------------------------------------- configuration

    /// Enabling or disabling keeps the threshold a strict majority of, and at most, the enabled
    /// attesters: raise the threshold before adding, lower it before removing.
    function setAttester(address signer, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (signer == address(0)) {
            revert ZeroAddress();
        }
        if (enabled == isAttester[signer]) {
            return;
        }
        if (enabled && issuerOfKey[signer] != bytes32(0)) {
            revert KeyHasOtherRole(signer);
        }
        uint256 count = enabled ? attesterCount + 1 : attesterCount - 1;
        _checkThreshold(threshold, count);
        isAttester[signer] = enabled;
        attesterCount = count;
        emit AttesterSet(signer, enabled);
    }

    /// Restrict-only, fast.
    function disableAttester(address signer) external onlyRole(GUARDIAN_ROLE) {
        if (!isAttester[signer]) {
            revert NotAnAttester(signer);
        }
        uint256 count = attesterCount - 1;
        _checkThreshold(threshold, count);
        isAttester[signer] = false;
        attesterCount = count;
        emit AttesterSet(signer, false);
    }

    function setThreshold(uint8 t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _checkThreshold(t, attesterCount);
        threshold = t;
        emit ThresholdSet(t);
    }

    /// Sets or rotates a member bank's own key for MINT messages on this chain.
    function setIssuerKey(bytes32 member, address key) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (key == address(0)) {
            revert ZeroAddress();
        }
        if (isAttester[key]) {
            revert KeyHasOtherRole(key);
        }
        bytes32 holderOfKey = issuerOfKey[key];
        if (holderOfKey != bytes32(0) && holderOfKey != member) {
            revert KeyHasOtherRole(key);
        }
        address old = issuerKey[member];
        if (old != address(0)) {
            delete issuerOfKey[old];
        }
        issuerKey[member] = key;
        issuerOfKey[key] = member;
        emit IssuerKeySet(member, key);
    }

    function setRemote(uint32 domain, address messenger) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (messenger == address(0)) {
            revert ZeroAddress();
        }
        if (domain == LOCAL_DOMAIN) {
            revert UntrustedSource(domain);
        }
        _checkRemote(domain);
        remote[domain] = messenger;
        emit RemoteSet(domain, messenger);
    }

    /// Governance sets (and raises) the bucket; it starts full. `window` 0 means one hour.
    function setRateLimit(uint32 source, bytes32 issuer, uint256 capacity, uint64 window)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (window == 0) {
            window = DEFAULT_WINDOW;
        }
        _rates[source][issuer] =
            RateLimit({ capacity: capacity, level: capacity, window: window, updatedAt: uint64(block.timestamp) });
        emit RateLimitSet(source, issuer, capacity, window);
    }

    /// Restrict-only, fast: the capacity and the current level only go down.
    function lowerRateLimit(uint32 source, bytes32 issuer, uint256 capacity) external onlyRole(GUARDIAN_ROLE) {
        RateLimit storage r = _rates[source][issuer];
        if (capacity >= r.capacity) {
            revert NotALowering(r.capacity, capacity);
        }
        uint256 lvl = _level(r);
        r.level = lvl < capacity ? lvl : capacity;
        r.capacity = capacity;
        r.updatedAt = uint64(block.timestamp);
        emit RateLimitSet(source, issuer, capacity, r.window);
    }

    // ---------------------------------------------------------------- views

    /// What the attesters (and for a MINT the issuer) sign: bound to the source messenger and to
    /// this messenger.
    function messageDigest(bytes calldata message) external view returns (bytes32) {
        Envelope memory e = abi.decode(message, (Envelope));
        address src = remote[e.source];
        if (src == address(0)) {
            revert UntrustedSource(e.source);
        }
        return _digest(src, message);
    }

    function move(uint64 nonce) external view returns (Move memory) {
        return _moves[nonce];
    }

    function rateLimit(uint32 source, bytes32 issuer) external view returns (RateLimit memory) {
        return _rates[source][issuer];
    }

    function rateAvailable(uint32 source, bytes32 issuer) external view returns (uint256) {
        return _level(_rates[source][issuer]);
    }

    // ---------------------------------------------------------------- side hooks

    function _checkRemote(uint32 domain) internal virtual;
    function _checkDest(uint32 dest) internal view virtual;
    function _lockMove(bytes32 issuer, bytes32 holder, address wallet, uint256 amount, uint32 dest) internal virtual;
    function _completeMove(Move storage m) internal virtual;
    function _cancelMove(Move storage m) internal virtual;
    function _mintCheck(Envelope memory e) internal view virtual returns (uint8 reason);
    function _mintIn(Envelope memory e) internal virtual;
    function _handle(Envelope memory e) internal virtual;

    // ---------------------------------------------------------------- internals

    function _send(
        uint8 kind,
        uint32 dest,
        bytes32 member,
        bytes32 counterparty,
        address recipient,
        uint256 amount,
        uint64 epoch,
        uint64 deadline,
        bytes32 ref
    ) internal returns (uint64 nonce) {
        nonce = nextNonce++;
        bytes memory message = abi.encode(
            Envelope({
                version: VERSION,
                kind: kind,
                source: LOCAL_DOMAIN,
                dest: dest,
                nonce: nonce,
                member: member,
                counterparty: counterparty,
                recipient: recipient,
                amount: amount,
                epoch: epoch,
                deadline: deadline,
                ref: ref
            })
        );
        emit MessageSent(dest, nonce, kind, message);
    }

    /// MINT_ACK / MINT_CANCEL for an inbound MINT: same fields, `ref` = the move's nonce.
    function _reply(Envelope memory e, uint8 kind) internal {
        _send(kind, e.source, e.member, e.counterparty, e.recipient, e.amount, 0, e.deadline, bytes32(uint256(e.nonce)));
    }

    function _settleMove(Envelope memory e) private {
        uint256 id = uint256(e.ref);
        if (id > type(uint64).max || _moves[uint64(id)].status == MoveStatus.NONE) {
            revert UnknownMove(uint64(id));
        }
        Move storage m = _moves[uint64(id)];
        if (
            m.status != MoveStatus.PENDING || m.dest != e.source || m.issuer != e.member || m.holder != e.counterparty
                || m.amount != e.amount
        ) {
            revert MoveMismatch(uint64(id));
        }
        if (e.kind == MINT_ACK) {
            m.status = MoveStatus.COMPLETED;
            _completeMove(m);
            emit MoveCompleted(uint64(id));
        } else {
            m.status = MoveStatus.CANCELLED;
            _cancelMove(m);
            emit MoveCancelled(uint64(id));
        }
    }

    function _open(bytes calldata message, bytes[] calldata sigs)
        private
        view
        returns (Envelope memory e, bytes32 digest)
    {
        e = abi.decode(message, (Envelope));
        if (e.version != VERSION) {
            revert BadVersion(e.version);
        }
        if (e.dest != LOCAL_DOMAIN) {
            revert WrongDestination(e.dest);
        }
        address src = remote[e.source];
        if (src == address(0)) {
            revert UntrustedSource(e.source);
        }
        if (inbound[e.source][e.nonce] != Inbound.NONE) {
            revert NonceUsed(e.source, e.nonce);
        }
        digest = _digest(src, message);
        _verifyAttesters(digest, sigs);
    }

    function _digest(address src, bytes calldata message) private view returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(DIGEST_TAG, src, address(this), keccak256(message)))
        );
    }

    function _verifyAttesters(bytes32 digest, bytes[] calldata sigs) private view {
        address last;
        for (uint256 i = 0; i < sigs.length; i++) {
            address signer = ECDSA.recover(digest, sigs[i]);
            if (signer <= last) {
                revert SignersNotSorted();
            }
            if (!isAttester[signer]) {
                revert NotAnAttester(signer);
            }
            last = signer;
        }
        if (threshold == 0 || sigs.length < threshold) {
            revert NotEnoughAttestations(sigs.length, threshold);
        }
    }

    function _checkIssuer(bytes32 member, bytes32 digest, bytes calldata sig) private view {
        address key = issuerKey[member];
        if (key == address(0)) {
            revert IssuerKeyNotSet(member);
        }
        (address signer,,) = ECDSA.tryRecover(digest, sig);
        if (signer != key) {
            revert BadIssuerSignature(member, signer);
        }
    }

    function _consumeRate(uint32 source, bytes32 issuer, uint256 amount) private {
        RateLimit storage r = _rates[source][issuer];
        uint256 lvl = _level(r);
        if (amount > lvl) {
            revert RateLimited(source, issuer, amount, lvl);
        }
        r.level = lvl - amount;
        r.updatedAt = uint64(block.timestamp);
    }

    function _level(RateLimit storage r) private view returns (uint256) {
        uint256 cap = r.capacity;
        if (cap == 0) {
            return 0;
        }
        uint256 lvl = r.level + (block.timestamp - r.updatedAt) * cap / r.window;
        return lvl < cap ? lvl : cap;
    }

    /// Strict majority of the enabled attesters, and no more than them.
    function _checkThreshold(uint8 t, uint256 count) private pure {
        if (t == 0 || t > count || uint256(t) * 2 <= count) {
            revert BadThreshold(t, count);
        }
    }
}
