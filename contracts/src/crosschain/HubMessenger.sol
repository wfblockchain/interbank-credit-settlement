// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IExposureLedger } from "../interfaces/IExposureLedger.sol";
import { IHubMessenger } from "../interfaces/IHubMessenger.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";
import { IObligationToken } from "../interfaces/IObligationToken.sol";
import { ISettlementBatches } from "../interfaces/ISettlementBatches.sol";
import { CrossChainMessenger } from "./CrossChainMessenger.sol";

/// @notice The hub's messenger (design §4.3). Spokes talk only to the hub.
///
/// - Envelopes: `grantEnvelope` reserves headroom in the ledger (checks run first) and only then
///   sends ENVELOPE_GRANT; an ENVELOPE_RELEASE from a spoke lowers the ledger's envelope after
///   the spoke has lowered its own.
/// - Moves: home → spoke locks the holder's home tokens here and moves that part of its open
///   position into the domain's envelope (gross unchanged); spoke → home takes the amount out of
///   the domain's envelope back into open and the ledger mints it.
/// - Global accountant: per (issuer, domain) `sent` (locked here for that spoke, net of
///   cancellations) and `returned` (minted here from it). A spoke can never mint at home more than
///   home sent it; spoke-to-spoke always goes through home.
/// - Cut: SettlementBatches.cut calls `broadcastCut`; each spoke answers with one BATCH_LOCKED per
///   locked pair and a final one (zero ids) carrying the pair count. `spokesReported` gates the
///   plan. Burn: once the batch is COMPLETE anyone may call `sendBurns(epoch)`, which sends one
///   BURN_BATCH per remote pair, once.
/// - Suspend: restrict-only SUSPEND to every spoke for a member not in good standing (anyone) or
///   on the guardian's call.
contract HubMessenger is CrossChainMessenger, IHubMessenger {
    /// MINT refusal reasons on the hub beyond the ledger's (3–5 limits, 7 envelope).
    uint8 public constant R_UNKNOWN = 10;
    uint8 public constant R_RECIPIENT = 11;
    uint8 public constant R_BLOCKED = 12;
    uint8 public constant R_ACCOUNTANT = 13;

    IExposureLedger public immutable ledger;
    ISettlementBatches public immutable batches;
    IMemberRegistry public immutable registry;

    uint32[] private _spokes;
    mapping(uint32 => bool) public isSpoke;
    mapping(bytes32 => mapping(uint32 => uint256)) public sent;
    mapping(bytes32 => mapping(uint32 => uint256)) public returned;
    mapping(uint64 => uint64) public batchOfEpoch;
    mapping(uint64 => mapping(uint32 => Report)) private _reports;
    mapping(uint64 => RemotePair[]) private _remotePairs;
    mapping(uint64 => bool) public burnsSent;

    constructor(
        uint48 adminDelay,
        address admin,
        uint32 homeDomain,
        address ledger_,
        address batches_,
        address registry_,
        address guardian,
        address operator,
        address[] memory attesters,
        uint8 threshold_
    ) CrossChainMessenger(adminDelay, admin, homeDomain, homeDomain, guardian, operator, attesters, threshold_) {
        if (ledger_ == address(0) || batches_ == address(0) || registry_ == address(0)) {
            revert ZeroAddress();
        }
        ledger = IExposureLedger(ledger_);
        batches = ISettlementBatches(batches_);
        registry = IMemberRegistry(registry_);
    }

    // ---------------------------------------------------------------- envelopes

    function grantEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint64)
    {
        if (!isSpoke[domain]) {
            revert NotASpoke(domain);
        }
        ledger.reserveEnvelope(domain, issuer, holder, amount);
        return _send(ENVELOPE_GRANT, domain, issuer, holder, address(0), amount, 0, 0, bytes32(0));
    }

    // ---------------------------------------------------------------- cut and burn

    function broadcastCut(uint64 epoch) external {
        if (msg.sender != address(batches)) {
            revert NotBatches(msg.sender);
        }
        if (batchOfEpoch[epoch] != 0) {
            revert CutAlreadyBroadcast(epoch);
        }
        uint64 b = batches.batchCount();
        uint64 be = batches.batch(b).epoch;
        if (be != epoch) {
            revert EpochMismatch(epoch, be);
        }
        batchOfEpoch[epoch] = b;
        uint256 n = _spokes.length;
        for (uint256 k = 0; k < n; k++) {
            uint32 d = _spokes[k];
            _reports[epoch][d].sentCut = true;
            _send(CUT, d, bytes32(0), bytes32(0), address(0), 0, epoch, 0, bytes32(0));
        }
        emit CutBroadcast(epoch, b, n);
    }

    /// True once every connected spoke that was sent the epoch's cut has reported all its pairs.
    function spokesReported(uint64 epoch) public view returns (bool) {
        for (uint256 k = 0; k < _spokes.length; k++) {
            Report storage r = _reports[epoch][_spokes[k]];
            if (r.sentCut && !(r.closed && r.received == r.expected)) {
                return false;
            }
        }
        return true;
    }

    function sendBurns(uint64 epoch) external returns (uint256 n) {
        uint64 b = batchOfEpoch[epoch];
        if (b == 0 || batches.status(b) != ISettlementBatches.Status.COMPLETE) {
            revert BatchNotComplete(epoch);
        }
        if (burnsSent[epoch]) {
            revert BurnsAlreadySent(epoch);
        }
        burnsSent[epoch] = true;
        RemotePair[] storage pairs = _remotePairs[epoch];
        n = pairs.length;
        for (uint256 k = 0; k < n; k++) {
            RemotePair storage p = pairs[k];
            _send(BURN_BATCH, p.domain, p.issuer, p.holder, address(0), p.amount, epoch, 0, bytes32(0));
        }
        emit BurnsSent(epoch, n);
    }

    // ---------------------------------------------------------------- restrictions

    function sendSuspend(bytes32 member) external {
        if (registry.goodStanding(member) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert MemberInGoodStanding(member);
        }
        uint256 n = _spokes.length;
        for (uint256 k = 0; k < n; k++) {
            _send(SUSPEND, _spokes[k], member, bytes32(0), address(0), 0, 0, 0, bytes32(0));
        }
        emit SuspendSent(member, n);
    }

    /// Restrict-only: a lost spoke stops counting for plans and nothing from it is accepted. Its
    /// envelopes stay reserved at the hub: the loss is bounded by them. Reconnecting is
    /// governance (setRemote).
    function disconnectSpoke(uint32 domain) external onlyRole(GUARDIAN_ROLE) {
        if (!isSpoke[domain]) {
            revert NotASpoke(domain);
        }
        isSpoke[domain] = false;
        remote[domain] = address(0);
        uint256 n = _spokes.length;
        for (uint256 k = 0; k < n; k++) {
            if (_spokes[k] == domain) {
                _spokes[k] = _spokes[n - 1];
                _spokes.pop();
                break;
            }
        }
        emit SpokeDisconnected(domain);
    }

    // ---------------------------------------------------------------- views

    function spokes() external view returns (uint32[] memory) {
        return _spokes;
    }

    function report(uint64 epoch, uint32 domain) external view returns (Report memory) {
        return _reports[epoch][domain];
    }

    function remotePairs(uint64 epoch) external view returns (RemotePair[] memory) {
        return _remotePairs[epoch];
    }

    // ---------------------------------------------------------------- side hooks

    function _checkRemote(uint32 domain) internal override {
        if (!isSpoke[domain]) {
            isSpoke[domain] = true;
            _spokes.push(domain);
        }
    }

    function _checkDest(uint32 dest) internal view override {
        if (!isSpoke[dest]) {
            revert UnknownDestination(dest);
        }
    }

    function _lockMove(bytes32 issuer, bytes32 holder, address wallet, uint256 amount, uint32 dest)
        internal
        override
    {
        if (registry.memberOfWallet(wallet) != holder) {
            revert NotHolderWallet(holder, wallet);
        }
        IObligationToken t = _token(issuer);
        t.transferFrom(wallet, address(this), amount);
        ledger.moveOut(dest, issuer, holder, amount);
        sent[issuer][dest] += amount;
    }

    function _completeMove(Move storage m) internal override {
        _token(m.issuer).burn(address(this), m.amount);
    }

    function _cancelMove(Move storage m) internal override {
        sent[m.issuer][m.dest] -= m.amount;
        ledger.moveCancelled(m.dest, m.issuer, m.holder, m.amount);
        _token(m.issuer).transfer(m.wallet, m.amount);
    }

    function _mintCheck(Envelope memory e) internal view override returns (uint8) {
        if (e.member == e.counterparty) {
            return R_UNKNOWN;
        }
        address token = registry.member(e.member).token;
        address wallet = registry.member(e.counterparty).wallet;
        if (token == address(0) || wallet == address(0)) {
            return R_UNKNOWN;
        }
        if (e.recipient != wallet) {
            return R_RECIPIENT;
        }
        if (IObligationToken(token).paused() || IObligationToken(token).frozen(wallet)) {
            return R_BLOCKED;
        }
        if (returned[e.member][e.source] + e.amount > sent[e.member][e.source]) {
            return R_ACCOUNTANT;
        }
        return ledger.moveInCheck(e.source, e.member, e.counterparty, e.amount);
    }

    function _mintIn(Envelope memory e) internal override {
        returned[e.member][e.source] += e.amount;
        ledger.moveIn(e.source, e.member, e.counterparty, e.amount);
    }

    function _handle(Envelope memory e) internal override {
        if (e.kind == ENVELOPE_RELEASE) {
            ledger.releaseEnvelope(e.source, e.member, e.counterparty, e.amount);
        } else if (e.kind == BATCH_LOCKED) {
            _batchLocked(e);
        } else {
            revert KindNotAccepted(e.kind);
        }
    }

    // ---------------------------------------------------------------- internals

    function _batchLocked(Envelope memory e) private {
        Report storage r = _reports[e.epoch][e.source];
        if (!r.sentCut) {
            revert UnexpectedReport(e.epoch, e.source);
        }
        if (e.member == bytes32(0) && e.counterparty == bytes32(0)) {
            if (r.closed) {
                revert ReportClosed(e.epoch, e.source);
            }
            r.closed = true;
            r.expected = e.amount;
        } else {
            if (r.closed && r.received >= r.expected) {
                revert ReportClosed(e.epoch, e.source);
            }
            ledger.envelopeToPending(e.source, e.member, e.counterparty, e.amount, e.epoch);
            ledger.addRemoteToBatch(e.epoch, e.member, e.counterparty, e.amount);
            _remotePairs[e.epoch].push(
                RemotePair({ domain: e.source, issuer: e.member, holder: e.counterparty, amount: e.amount })
            );
            r.received++;
        }
        if (r.closed && r.received == r.expected) {
            emit SpokeReported(e.epoch, e.source, r.received);
        }
    }

    function _token(bytes32 issuer) private view returns (IObligationToken t) {
        t = IObligationToken(registry.member(issuer).token);
        if (address(t) == address(0)) {
            revert UnknownToken(issuer);
        }
    }
}
