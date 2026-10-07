// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ICreditLimits } from "../interfaces/ICreditLimits.sol";
import { IExposureLedger } from "../interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";
import { IObligationToken } from "../interfaces/IObligationToken.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Positions, the pre-transfer check, the queue and the hub side of spoke envelopes
/// (design §3.5). Pair (i, h): h holds i's token, so h is exposed to i.
///
/// gross(i, h) = open + pending + Σ_d envelope[d]; grossIn[m] = Σ_x gross(x, m) and
/// grossOut[m] = Σ_x gross(m, x) are kept in step so netPosition(m) = grossIn − grossOut.
contract ExposureLedger is AccessControlDefaultAdminRules, IExposureLedger {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant BATCHES_ROLE = keccak256("BATCHES_ROLE");
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");

    /// Check numbers of design §3.5 (0 = pass). 6 is the public-spoke free-collateral check (§4.4).
    uint8 public constant OK = 0;
    uint8 public constant R_STANDING = 1;
    uint8 public constant R_WINDOW = 2;
    uint8 public constant R_BILATERAL = 3;
    uint8 public constant R_RECEIVER_CAP = 4;
    uint8 public constant R_DEBIT_CAP = 5;
    /// moveInCheck only: the spoke's envelope at the hub does not cover the move.
    uint8 public constant R_ENVELOPE = 7;

    /// QueueCancelled reasons.
    uint8 public constant CANCEL_BY_PAYER = 0;
    uint8 public constant CANCEL_STANDING = 1;

    IMemberRegistry public immutable registry;
    ICreditLimits public immutable limits;
    ICollateralRegister public immutable register;

    mapping(bytes32 => mapping(bytes32 => uint256)) public open;
    mapping(bytes32 => mapping(bytes32 => uint256)) public pending;
    mapping(bytes32 => mapping(bytes32 => uint256)) public envelopeTotal;
    mapping(uint32 => mapping(bytes32 => mapping(bytes32 => uint256))) public envelope;
    mapping(bytes32 => uint256) public grossIn;
    mapping(bytes32 => uint256) public grossOut;
    mapping(uint32 => DomainKind) public domainKind;

    uint64 public epoch = 1;
    bytes32 public epochHash;
    uint64 public pendingEpoch;
    mapping(uint64 => bool) public isSealed;
    mapping(uint64 => uint256) public clearedPairs;
    mapping(uint64 => PendingPair[]) private _pendingPairs;
    mapping(uint64 => bytes32[2][]) private _openPairs;
    mapping(uint64 => mapping(bytes32 => mapping(bytes32 => bool))) private _openSeen;
    mapping(uint64 => mapping(bytes32 => mapping(bytes32 => uint256))) public remoteLocked;
    mapping(uint64 => mapping(bytes32 => mapping(bytes32 => uint256))) public remoteRecorded;
    mapping(uint64 => uint256) public remoteUnrecorded;

    Window public window = Window.OFF_HOURS;
    uint64 public businessDay;
    uint64 public offHoursSession;
    mapping(uint64 => mapping(bytes32 => uint256)) private _offHoursUsed;

    uint256 public nextSeq = 1;
    mapping(uint256 => QueueEntry) private _entries;
    uint256[] private _queue;
    uint256 public queueHead;

    constructor(
        uint48 adminDelay,
        address admin,
        address registry_,
        address limits_,
        address register_,
        address batches,
        address operator
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (
            registry_ == address(0) || limits_ == address(0) || register_ == address(0) || batches == address(0)
                || operator == address(0)
        ) {
            revert ZeroAddress();
        }
        registry = IMemberRegistry(registry_);
        limits = ICreditLimits(limits_);
        register = ICollateralRegister(register_);
        _grantRole(BATCHES_ROLE, batches);
        _grantRole(OPERATOR_ROLE, operator);
    }

    // ---------------------------------------------------------------- payments

    /// Checks (1)–(2) revert; (3)–(5) queue the payment. Returns the payment's sequence number.
    function pay(bytes32 to, uint256 amount, bytes32 ref) external returns (uint256 seq) {
        bytes32 payer = registry.memberOfIssuerOps(msg.sender);
        if (payer == bytes32(0)) {
            revert NotIssuerOps(msg.sender);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (payer == to) {
            revert SelfPayment();
        }
        if (!registry.goodStanding(payer)) {
            revert PayerNotInGoodStanding(payer);
        }
        if (!registry.goodStanding(to)) {
            revert PayeeNotInGoodStanding(to);
        }
        if (!_windowOk(payer, amount)) {
            revert OffHoursPrefundExceeded(
                payer, offHoursUsed(payer), amount, register.rtpPrefund(payer)
            );
        }
        seq = nextSeq++;
        uint8 reason = _limitCheck(payer, to, amount);
        if (reason != OK) {
            _entries[seq] = QueueEntry({
                seq: seq,
                payer: payer,
                to: to,
                amount: amount,
                ref: ref,
                enqueuedAt: uint64(block.timestamp),
                businessDay: businessDay,
                state: QueueState.QUEUED
            });
            _queue.push(seq);
            emit Queued(seq, reason);
            return seq;
        }
        _execute(seq, payer, to, amount, ref);
    }

    /// Retries the queue from the head (FIFO). Stops at the first entry that still fails; cancels
    /// entries whose payer or payee is no longer in good standing. Anyone may call.
    function drain(uint256 max) external returns (uint256 executed) {
        uint256 n = _queue.length;
        for (uint256 processed = 0; queueHead < n && processed < max; processed++) {
            QueueEntry storage e = _entries[_queue[queueHead]];
            if (e.state != QueueState.QUEUED) {
                queueHead++;
                continue;
            }
            if (!registry.goodStanding(e.payer) || !registry.goodStanding(e.to)) {
                e.state = QueueState.CANCELLED;
                queueHead++;
                emit QueueCancelled(e.seq, CANCEL_STANDING);
                continue;
            }
            if (!_windowOk(e.payer, e.amount) || _limitCheck(e.payer, e.to, e.amount) != OK || _mintBlocked(e)) {
                break;
            }
            e.state = QueueState.PAID;
            queueHead++;
            _execute(e.seq, e.payer, e.to, e.amount, e.ref);
            executed++;
        }
    }

    function cancel(uint256 seq) external {
        QueueEntry storage e = _entries[seq];
        if (e.state != QueueState.QUEUED) {
            revert NotQueued(seq);
        }
        if (registry.memberOfIssuerOps(msg.sender) != e.payer) {
            revert NotPayer(seq);
        }
        e.state = QueueState.CANCELLED;
        emit QueueCancelled(seq, CANCEL_BY_PAYER);
    }

    // ---------------------------------------------------------------- operator

    /// Returning to BUSINESS starts a new off-hours session, so offHoursUsed resets.
    function setWindow(Window w) external onlyRole(OPERATOR_ROLE) {
        if (w == Window.BUSINESS && window == Window.OFF_HOURS) {
            offHoursSession++;
        }
        window = w;
        emit WindowSet(w, offHoursSession);
    }

    function setBusinessDay(uint64 day) external onlyRole(OPERATOR_ROLE) {
        if (day < businessDay) {
            revert BusinessDayRegress(businessDay, day);
        }
        businessDay = day;
        emit BusinessDaySet(day);
    }

    /// Set once per domain: the kind decides how envelopes are released.
    function setDomainKind(uint32 domain, DomainKind kind) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (domain == 0 || kind == DomainKind.NONE) {
            revert InvalidDomain(domain);
        }
        if (domainKind[domain] != DomainKind.NONE) {
            revert DomainAlreadySet(domain);
        }
        domainKind[domain] = kind;
        emit DomainKindSet(domain, kind);
    }

    // ---------------------------------------------------------------- settlement hooks

    /// Moves every open position into pending for the batch, starts a new epoch and expires
    /// queue entries from earlier business days.
    function snapshotForCut() external onlyRole(BATCHES_ROLE) returns (bytes32 hash, uint64 snapped) {
        if (pendingEpoch != 0) {
            revert BatchInFlight(pendingEpoch);
        }
        snapped = epoch;
        hash = epochHash;
        bytes32[2][] storage pairs = _openPairs[snapped];
        for (uint256 k = 0; k < pairs.length; k++) {
            bytes32 i = pairs[k][0];
            bytes32 h = pairs[k][1];
            uint256 amount = open[i][h];
            if (amount == 0) {
                continue; // every open token of the pair moved to a spoke
            }
            open[i][h] = 0;
            pending[i][h] += amount;
            _pendingPairs[snapped].push(PendingPair({ issuer: i, holder: h, amount: amount, remote: false }));
        }
        pendingEpoch = snapped;
        epoch = snapped + 1;
        epochHash = bytes32(0);
        _expireQueue();
        emit Snapshot(snapped, hash, pairs.length);
    }

    /// Fixes the batch's pair list (called when the plan is accepted).
    function sealBatch(uint64 e) external onlyRole(BATCHES_ROLE) {
        _requireInFlight(e);
        if (remoteUnrecorded[e] != 0) {
            revert RemoteUnrecorded(e, remoteUnrecorded[e]);
        }
        isSealed[e] = true;
        emit BatchSealed(e);
    }

    /// Releases a page of settled pairs, in order; the caller burns the home tokens in the same call.
    function clearPending(uint64 e, uint256 start, uint256 count) external onlyRole(BATCHES_ROLE) {
        _requireInFlight(e);
        if (!isSealed[e]) {
            revert EpochNotSealed(e);
        }
        if (start != clearedPairs[e]) {
            revert PageOutOfOrder(clearedPairs[e], start);
        }
        PendingPair[] storage pairs = _pendingPairs[e];
        uint256 end = start + count;
        if (end > pairs.length) {
            revert PageOutOfRange(end, pairs.length);
        }
        for (uint256 k = start; k < end; k++) {
            PendingPair storage p = pairs[k];
            pending[p.issuer][p.holder] -= p.amount;
            grossIn[p.holder] -= p.amount;
            grossOut[p.issuer] -= p.amount;
        }
        clearedPairs[e] = end;
        emit PendingCleared(e, start, count);
        if (end == pairs.length) {
            pendingEpoch = 0;
            emit EpochSettled(e);
        }
    }

    // ---------------------------------------------------------------- cross-chain hooks

    /// Reserves headroom for a spoke envelope. PERMISSIONED: checks (1), (3)–(5) as if paying
    /// `amount`. PUBLIC: check (1) and (6), the envelope ≤ the issuer's free collateral.
    function reserveEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        DomainKind kind = domainKind[domain];
        if (kind == DomainKind.NONE) {
            revert UnknownDomain(domain);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (issuer == holder) {
            revert SelfPayment();
        }
        if (!registry.goodStanding(issuer)) {
            revert PayerNotInGoodStanding(issuer);
        }
        if (!registry.goodStanding(holder)) {
            revert PayeeNotInGoodStanding(holder);
        }
        if (kind == DomainKind.PERMISSIONED) {
            uint8 reason = _limitCheck(issuer, holder, amount);
            if (reason == R_BILATERAL) {
                revert BilateralLimitExceeded(holder, issuer);
            } else if (reason == R_RECEIVER_CAP) {
                revert ReceiverCapExceeded(holder);
            } else if (reason == R_DEBIT_CAP) {
                revert DebitCapExceeded(issuer);
            }
        } else {
            register.commitPublic(issuer, amount);
        }
        envelope[domain][issuer][holder] += amount;
        envelopeTotal[issuer][holder] += amount;
        grossIn[holder] += amount;
        grossOut[issuer] += amount;
        emit EnvelopeReserved(domain, issuer, holder, amount);
    }

    function releaseEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        _takeEnvelope(domain, issuer, holder, amount);
        grossIn[holder] -= amount;
        grossOut[issuer] -= amount;
        emit EnvelopeReleased(domain, issuer, holder, amount);
    }

    /// On a spoke's BATCH_LOCKED: the locked part of the envelope joins the in-flight batch.
    function envelopeToPending(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount, uint64 e)
        external
        onlyRole(MESSENGER_ROLE)
    {
        _requireInFlight(e);
        if (isSealed[e]) {
            revert EpochSealed(e);
        }
        _takeEnvelope(domain, issuer, holder, amount);
        pending[issuer][holder] += amount;
        remoteLocked[e][issuer][holder] += amount;
        remoteUnrecorded[e] += amount;
        emit EnvelopeToPending(domain, issuer, holder, amount, e);
    }

    /// Adds spoke-locked amounts (already moved by envelopeToPending) to the batch's pair list.
    function addRemoteToBatch(uint64 e, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        _requireInFlight(e);
        if (isSealed[e]) {
            revert EpochSealed(e);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 available = remoteLocked[e][issuer][holder] - remoteRecorded[e][issuer][holder];
        if (amount > available) {
            revert RemoteExceedsLocked(amount, available);
        }
        remoteRecorded[e][issuer][holder] += amount;
        remoteUnrecorded[e] -= amount;
        _pendingPairs[e].push(PendingPair({ issuer: issuer, holder: holder, amount: amount, remote: true }));
        emit RemoteAddedToBatch(e, issuer, holder, amount);
    }

    // ---------------------------------------------------------------- token moves (design §4.3)

    /// Home → spoke, when the holder's tokens are locked at home: that part of the holder's open
    /// position becomes envelope on `domain`, so gross is unchanged. On a PUBLIC domain the moved
    /// amount draws the issuer's free collateral like a grant (§4.4).
    function moveOut(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        DomainKind kind = domainKind[domain];
        if (kind == DomainKind.NONE) {
            revert UnknownDomain(domain);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 o = open[issuer][holder];
        if (amount > o) {
            revert MoveExceedsOpen(amount, o);
        }
        open[issuer][holder] = o - amount;
        if (kind == DomainKind.PUBLIC) {
            register.commitPublic(issuer, amount);
        }
        envelope[domain][issuer][holder] += amount;
        envelopeTotal[issuer][holder] += amount;
        emit MovedOut(domain, issuer, holder, amount);
    }

    /// The destination cancelled a home → spoke move: the envelope part returns to open (gross
    /// unchanged) and the messenger hands the locked tokens back.
    function moveCancelled(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        _takeEnvelope(domain, issuer, holder, amount);
        _addOpen(issuer, holder, amount);
        emit MoveReturned(domain, issuer, holder, amount);
    }

    /// Spoke → home: the spoke's envelope part becomes open at home (gross unchanged) and the
    /// tokens are minted to the holder's wallet. Refused unless moveInCheck passes.
    function moveIn(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint8 reason = moveInCheck(domain, issuer, holder, amount);
        if (reason != OK) {
            revert MoveRefused(reason);
        }
        _takeEnvelope(domain, issuer, holder, amount);
        _addOpen(issuer, holder, amount);
        IObligationToken(registry.member(issuer).token).mint(registry.member(holder).wallet, amount);
        emit MovedIn(domain, issuer, holder, amount);
    }

    /// 0 if a spoke → home move of `amount` may land: the domain's envelope covers it, and when it
    /// comes from a PUBLIC domain (collateral-covered there, credit at home) the credit checks
    /// (3)–(5) hold for the position, which the conversion leaves unchanged in gross terms.
    function moveInCheck(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        public
        view
        returns (uint8)
    {
        DomainKind kind = domainKind[domain];
        if (kind == DomainKind.NONE || amount > envelope[domain][issuer][holder]) {
            return R_ENVELOPE;
        }
        if (kind == DomainKind.PUBLIC) {
            return _limitCheck(issuer, holder, 0);
        }
        return OK;
    }

    // ---------------------------------------------------------------- views

    function gross(bytes32 i, bytes32 h) public view returns (uint256) {
        return open[i][h] + pending[i][h] + envelopeTotal[i][h];
    }

    /// Exposure of `holder` to `issuer` after bilateral netting.
    function bilateralNet(bytes32 holder, bytes32 issuer) public view returns (uint256) {
        uint256 a = gross(issuer, holder);
        uint256 b = gross(holder, issuer);
        return a > b ? a - b : 0;
    }

    /// > 0: net creditor.
    function netPosition(bytes32 m) public view returns (int256) {
        return SafeCast.toInt256(grossIn[m]) - SafeCast.toInt256(grossOut[m]);
    }

    /// The reason `pay` would revert (1, 2) or queue (3–5), or 0.
    function check(bytes32 payer, bytes32 to, uint256 amount) external view returns (uint8) {
        if (payer == to || !registry.goodStanding(payer) || !registry.goodStanding(to)) {
            return R_STANDING;
        }
        if (!_windowOk(payer, amount)) {
            return R_WINDOW;
        }
        return _limitCheck(payer, to, amount);
    }

    function offHoursUsed(bytes32 m) public view returns (uint256) {
        return _offHoursUsed[offHoursSession][m];
    }

    function pendingPairs(uint64 e)
        external
        view
        returns (bytes32[] memory issuers, bytes32[] memory holders, uint256[] memory amounts)
    {
        PendingPair[] storage pairs = _pendingPairs[e];
        uint256 n = pairs.length;
        issuers = new bytes32[](n);
        holders = new bytes32[](n);
        amounts = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            issuers[k] = pairs[k].issuer;
            holders[k] = pairs[k].holder;
            amounts[k] = pairs[k].amount;
        }
    }

    function pendingPairCount(uint64 e) external view returns (uint256) {
        return _pendingPairs[e].length;
    }

    function pendingPair(uint64 e, uint256 index) external view returns (PendingPair memory) {
        return _pendingPairs[e][index];
    }

    function queueEntry(uint256 seq) external view returns (QueueEntry memory) {
        return _entries[seq];
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function queueSeqAt(uint256 index) external view returns (uint256) {
        return _queue[index];
    }

    // ---------------------------------------------------------------- internals

    function _execute(uint256 seq, bytes32 payer, bytes32 to, uint256 amount, bytes32 ref) private {
        if (window == Window.OFF_HOURS) {
            _offHoursUsed[offHoursSession][payer] += amount;
        }
        uint64 e = epoch;
        if (!_openSeen[e][payer][to]) {
            _openSeen[e][payer][to] = true;
            _openPairs[e].push([payer, to]);
        }
        open[payer][to] += amount;
        grossIn[to] += amount;
        grossOut[payer] += amount;
        epochHash = keccak256(abi.encode(epochHash, seq, payer, to, amount, ref));
        IObligationToken(registry.member(payer).token).mint(registry.member(to).wallet, amount);
        emit Paid(seq, payer, to, amount, ref);
        if (netPosition(to) >= _limit(limits.triggerLevel(to))) {
            emit CapReached(to);
        }
    }

    /// Adds to the current epoch's open position (moves; payments go through _execute).
    function _addOpen(bytes32 issuer, bytes32 holder, uint256 amount) private {
        uint64 e = epoch;
        if (!_openSeen[e][issuer][holder]) {
            _openSeen[e][issuer][holder] = true;
            _openPairs[e].push([issuer, holder]);
        }
        open[issuer][holder] += amount;
    }

    /// Checks (3)–(5) with `amount` added to gross(payer, to). A prefund-only payer is covered by
    /// its own collateral, so check (3) does not apply to it.
    function _limitCheck(bytes32 payer, bytes32 to, uint256 amount) private view returns (uint8) {
        if (registry.member(payer).tier != IMemberRegistry.Tier.PREFUND_ONLY) {
            uint256 a = gross(payer, to) + amount;
            uint256 b = gross(to, payer);
            uint256 net = a > b ? a - b : 0;
            if (net > limits.bilateralLimit(to, payer)) {
                return R_BILATERAL;
            }
        }
        int256 amt = SafeCast.toInt256(amount);
        if (netPosition(to) + amt > _limit(limits.receiverCap(to))) {
            return R_RECEIVER_CAP;
        }
        if (amt - netPosition(payer) > _limit(limits.debitCap(payer))) {
            return R_DEBIT_CAP;
        }
        return OK;
    }

    /// A limit as a signed value; a limit above int256's range is unbounded in practice.
    function _limit(uint256 x) private pure returns (int256) {
        return x > uint256(type(int256).max) ? type(int256).max : int256(x);
    }

    /// Check (2): no unsecured credit outside business windows.
    function _windowOk(bytes32 payer, uint256 amount) private view returns (bool) {
        if (window != Window.OFF_HOURS) {
            return true;
        }
        return offHoursUsed(payer) + amount <= register.rtpPrefund(payer);
    }

    function _mintBlocked(QueueEntry storage e) private view returns (bool) {
        IObligationToken t = IObligationToken(registry.member(e.payer).token);
        return t.paused() || t.frozen(registry.member(e.to).wallet);
    }

    function _expireQueue() private {
        uint256 n = _queue.length;
        while (queueHead < n) {
            QueueEntry storage e = _entries[_queue[queueHead]];
            if (e.state == QueueState.QUEUED) {
                if (e.businessDay >= businessDay) {
                    break;
                }
                e.state = QueueState.EXPIRED;
                emit QueueExpired(e.seq);
            }
            queueHead++;
        }
    }

    function _takeEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) private {
        DomainKind kind = domainKind[domain];
        if (kind == DomainKind.NONE) {
            revert UnknownDomain(domain);
        }
        uint256 env = envelope[domain][issuer][holder];
        if (amount > env) {
            revert EnvelopeUnderflow(amount, env);
        }
        envelope[domain][issuer][holder] = env - amount;
        envelopeTotal[issuer][holder] -= amount;
        if (kind == DomainKind.PUBLIC) {
            register.releasePublic(issuer, amount);
        }
    }

    function _requireInFlight(uint64 e) private view {
        if (pendingEpoch == 0 || e != pendingEpoch) {
            revert EpochMismatch(pendingEpoch, e);
        }
    }
}
