// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { IExposureLedger } from "../interfaces/IExposureLedger.sol";
import { IRemoteObligationToken } from "../interfaces/IRemoteObligationToken.sol";
import { ISpokeExposureGuard } from "../interfaces/ISpokeExposureGuard.sol";

/// @notice The spoke side of envelopes (design §4.2–§4.4). The hub reserves headroom first and
/// then raises `env` here; everything that lowers exposure lowers it here first and then at the
/// hub. So at every moment, per pair: `used ≤ env` here and `env` here ≤ the hub's
/// `envelope[domain][issuer][holder]` (design §4.5, invariant 2).
///
/// - pay: the payer's issuerOps on this chain mints its own token to the payee's wallet iff
///   `used + amount ≤ env` and the issuer's supply cap holds; otherwise the payment is queued.
/// - cut (CUT from the hub): every nonzero `used` moves out of `env` and `used` into `locked` for
///   the hub's epoch (the hub moves the same amount out of its envelope into the batch), and the
///   tokens are locked in the holder's wallet. They are settled-pending-burn until BURN_BATCH.
/// - SUSPEND: restrict-only. The member's token here is paused and every envelope it is party to
///   is cut to what is in use (`env = used`, no new headroom); the freed headroom is parked as
///   `releasable`, which the operator returns to the hub by an ordinary release.
///
/// PERMISSIONED and PUBLIC spokes run the same mechanics; on a PUBLIC spoke every envelope was
/// drawn from the issuer's free collateral at the hub (§4.4).
///
/// WINDOW. The operator sets the business window here as at home (`IExposureLedger.Window`,
/// BUSINESS = 0, starting OFF_HOURS). On a PERMISSIONED spoke the envelope is credit, so outside
/// the business window a local pay reverts and the queue does not drain; a PUBLIC spoke is
/// collateral-backed and ignores the window.
contract SpokeExposureGuard is AccessControlDefaultAdminRules, ISpokeExposureGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");

    /// Queue reasons (pay) and mint refusal reasons (mintCheck). 0 = pass.
    uint8 public constant OK = 0;
    uint8 public constant R_ENVELOPE = 1;
    uint8 public constant R_SUPPLY_CAP = 2;
    uint8 public constant R_UNKNOWN = 3;
    uint8 public constant R_SUSPENDED = 4;
    uint8 public constant R_BLOCKED = 5;
    uint8 public constant R_RECIPIENT = 6;

    uint8 public constant CANCEL_BY_PAYER = 0;
    uint8 public constant CANCEL_SUSPENDED = 1;

    uint32 public immutable DOMAIN;
    IExposureLedger.DomainKind public immutable KIND;

    mapping(bytes32 => Member) private _members;
    bytes32[] private _ids;
    mapping(address => bytes32) public memberOfWallet;
    mapping(address => bytes32) public memberOfIssuerOps;

    mapping(bytes32 => mapping(bytes32 => uint256)) public env;
    mapping(bytes32 => mapping(bytes32 => uint256)) public used;
    mapping(bytes32 => mapping(bytes32 => uint256)) public lockedTotal;
    mapping(bytes32 => mapping(bytes32 => uint256)) public releasable;
    mapping(uint64 => mapping(bytes32 => mapping(bytes32 => uint256))) public locked;
    mapping(uint64 => bool) public epochLocked;
    mapping(bytes32 => uint256) public supplyCap;
    IExposureLedger.Window public window = IExposureLedger.Window.OFF_HOURS;

    uint256 public nextSeq = 1;
    mapping(uint256 => QueueEntry) private _entries;
    uint256[] private _queue;
    uint256 public queueHead;

    constructor(
        uint48 adminDelay,
        address admin,
        uint32 domain,
        IExposureLedger.DomainKind kind,
        address messenger,
        address guardian,
        address operator
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (messenger == address(0) || guardian == address(0) || operator == address(0)) {
            revert ZeroAddress();
        }
        DOMAIN = domain;
        KIND = kind;
        _grantRole(MESSENGER_ROLE, messenger);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, operator);
    }

    // ---------------------------------------------------------------- members and caps

    /// A member's wallet and issuerOps on this chain and its token here. Set once.
    function setMember(bytes32 id, address wallet, address issuerOps, address token)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (wallet == address(0) || issuerOps == address(0) || token == address(0)) {
            revert ZeroAddress();
        }
        if (_members[id].wallet != address(0)) {
            revert MemberAlreadySet(id);
        }
        if (memberOfWallet[wallet] != bytes32(0)) {
            revert AddressInUse(wallet);
        }
        if (memberOfIssuerOps[issuerOps] != bytes32(0)) {
            revert AddressInUse(issuerOps);
        }
        bytes32 tokenIssuer = IRemoteObligationToken(token).issuer();
        if (tokenIssuer != id) {
            revert TokenIssuerMismatch(id, tokenIssuer);
        }
        _members[id] = Member({ wallet: wallet, issuerOps: issuerOps, token: token, suspended: false });
        _ids.push(id);
        memberOfWallet[wallet] = id;
        memberOfIssuerOps[issuerOps] = id;
        emit MemberSet(id, wallet, issuerOps, token);
    }

    /// Static, raised only by governance (the timelock in deployment).
    function setSupplyCap(bytes32 issuer, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supplyCap[issuer] = cap;
        emit SupplyCapSet(issuer, cap);
    }

    function lowerSupplyCap(bytes32 issuer, uint256 cap) external onlyRole(GUARDIAN_ROLE) {
        uint256 current = supplyCap[issuer];
        if (cap >= current) {
            revert NotALowering(current, cap);
        }
        supplyCap[issuer] = cap;
        emit SupplyCapSet(issuer, cap);
    }

    /// The business window, set by the operator at each boundary as on the home ledger.
    function setWindow(IExposureLedger.Window w) external onlyRole(OPERATOR_ROLE) {
        window = w;
        emit WindowSet(w);
    }

    /// Lifting a suspension is governance; envelopes come back only by new grants.
    function reinstate(bytes32 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Member storage m = _member(id);
        if (!m.suspended) {
            revert NotSuspended(id);
        }
        m.suspended = false;
        emit Reinstated(id);
    }

    // ---------------------------------------------------------------- local payments

    function pay(bytes32 to, uint256 amount, bytes32 ref) external returns (uint256 seq) {
        bytes32 payer = memberOfIssuerOps[msg.sender];
        if (payer == bytes32(0)) {
            revert NotIssuerOps(msg.sender);
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (payer == to) {
            revert SelfPayment();
        }
        Member storage p = _members[payer];
        Member storage r = _member(to);
        if (p.suspended) {
            revert MemberSuspended(payer);
        }
        if (r.suspended) {
            revert MemberSuspended(to);
        }
        if (_blocked(p.token, r.wallet)) {
            revert TokenBlocked(payer, r.wallet);
        }
        if (_offHoursCredit()) {
            revert OffHoursCredit(payer, amount);
        }
        seq = nextSeq++;
        uint8 reason = _check(payer, to, amount);
        if (reason != OK) {
            _entries[seq] = QueueEntry({
                seq: seq,
                payer: payer,
                to: to,
                amount: amount,
                ref: ref,
                enqueuedAt: uint64(block.timestamp),
                state: QueueState.QUEUED
            });
            _queue.push(seq);
            emit Queued(seq, reason);
            return seq;
        }
        _execute(seq, payer, to, amount, ref);
    }

    /// FIFO from the head; stops at the first entry that still fails; cancels entries whose payer
    /// or payee is suspended. Anyone may call.
    function drain(uint256 max) external returns (uint256 executed) {
        if (_offHoursCredit()) {
            return 0; // no credit minted on a permissioned spoke outside the business window
        }
        uint256 n = _queue.length;
        for (uint256 processed = 0; queueHead < n && processed < max; processed++) {
            QueueEntry storage e = _entries[_queue[queueHead]];
            if (e.state != QueueState.QUEUED) {
                queueHead++;
                continue;
            }
            Member storage p = _members[e.payer];
            Member storage r = _members[e.to];
            if (p.suspended || r.suspended) {
                e.state = QueueState.CANCELLED;
                queueHead++;
                emit QueueCancelled(e.seq, CANCEL_SUSPENDED);
                continue;
            }
            if (_check(e.payer, e.to, e.amount) != OK || _blocked(p.token, r.wallet)) {
                break;
            }
            e.state = QueueState.PAID;
            queueHead++;
            // The mint goes to a member's remote token (governance-set, no hooks); this entry is
            // already PAID and the head advanced, so a re-entrant drain cannot execute it twice.
            // slither-disable-next-line reentrancy-no-eth
            _execute(e.seq, e.payer, e.to, e.amount, e.ref);
            executed++;
        }
    }

    function cancel(uint256 seq) external {
        QueueEntry storage e = _entries[seq];
        if (e.state != QueueState.QUEUED) {
            revert NotQueued(seq);
        }
        if (memberOfIssuerOps[msg.sender] != e.payer) {
            revert NotPayer(seq);
        }
        e.state = QueueState.CANCELLED;
        emit QueueCancelled(seq, CANCEL_BY_PAYER);
    }

    // ---------------------------------------------------------------- messenger hooks

    /// ENVELOPE_GRANT. A grant for a suspended or unknown pair does not raise anything: it is
    /// parked as releasable, for the operator to hand back to the hub.
    function grant(bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
        returns (bool applied)
    {
        Member storage i = _members[issuer];
        Member storage h = _members[holder];
        if (i.wallet == address(0) || h.wallet == address(0) || i.suspended || h.suspended) {
            releasable[issuer][holder] += amount;
            emit GrantRefused(issuer, holder, amount);
            return false;
        }
        uint256 e = env[issuer][holder] + amount;
        env[issuer][holder] = e;
        emit EnvelopeGranted(issuer, holder, amount, e);
        return true;
    }

    /// Lowers the pair's headroom here before the hub releases it: the parked releasable part
    /// first, then the unused envelope.
    function release(bytes32 issuer, bytes32 holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 parked = releasable[issuer][holder];
        uint256 e = env[issuer][holder];
        uint256 free = parked + e - used[issuer][holder];
        if (amount > free) {
            revert ReleaseExceedsFree(amount, free);
        }
        uint256 fromParked = amount < parked ? amount : parked;
        releasable[issuer][holder] = parked - fromParked;
        e -= amount - fromParked;
        env[issuer][holder] = e;
        emit EnvelopeReleased(issuer, holder, amount, e);
    }

    /// Spoke → home, locking: the holder's tokens are locked here and leave this spoke's open
    /// position and envelope (the hub takes them out of its envelope when it mints them).
    function moveOut(bytes32 issuer, bytes32 holder, address wallet, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        if (amount == 0) {
            revert ZeroAmount();
        }
        Member storage i = _member(issuer);
        Member storage h = _member(holder);
        if (h.wallet != wallet) {
            revert NotHolderWallet(holder, wallet);
        }
        if (_blocked(i.token, wallet)) {
            revert TokenBlocked(issuer, wallet);
        }
        uint256 u = used[issuer][holder];
        if (amount > u) {
            revert MoveExceedsOpen(amount, u);
        }
        used[issuer][holder] = u - amount;
        env[issuer][holder] -= amount;
        IRemoteObligationToken(i.token).lock(wallet, amount);
        emit MovedOut(issuer, holder, amount);
    }

    /// MINT_CANCEL for a move from here: unlocked, back in the open position and envelope.
    function moveCancelled(bytes32 issuer, bytes32 holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        Member storage i = _members[issuer];
        IRemoteObligationToken(i.token).unlock(_members[holder].wallet, amount);
        used[issuer][holder] += amount;
        env[issuer][holder] += amount;
        emit MoveReturned(issuer, holder, amount);
    }

    /// MINT_ACK for a move from here: the mint at home is proven, the locked tokens burn.
    function moveDone(bytes32 issuer, bytes32 holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        IRemoteObligationToken(_members[issuer].token).burnLocked(_members[holder].wallet, amount);
        emit MoveBurned(issuer, holder, amount);
    }

    /// Home → spoke MINT: the hub moved the amount from the holder's open position into its
    /// envelope for this spoke, so it raises `env` and `used` together here.
    function mintIn(bytes32 issuer, bytes32 holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        uint8 reason = mintCheck(issuer, holder, _members[holder].wallet, amount);
        if (reason != OK) {
            revert MintRefused(reason);
        }
        used[issuer][holder] += amount;
        env[issuer][holder] += amount;
        IRemoteObligationToken(_members[issuer].token).mint(_members[holder].wallet, amount);
        emit MovedIn(issuer, holder, amount);
    }

    /// CUT: locks every nonzero open pair for the hub's epoch. Returns the pairs for BATCH_LOCKED.
    function cut(uint64 epoch)
        external
        onlyRole(MESSENGER_ROLE)
        returns (bytes32[] memory issuers, bytes32[] memory holders, uint256[] memory amounts)
    {
        if (epochLocked[epoch]) {
            revert EpochAlreadyLocked(epoch);
        }
        epochLocked[epoch] = true;
        uint256 n = _ids.length;
        issuers = new bytes32[](n * n);
        holders = new bytes32[](n * n);
        amounts = new uint256[](n * n);
        uint256 count;
        for (uint256 a = 0; a < n; a++) {
            bytes32 i = _ids[a];
            for (uint256 b = 0; b < n; b++) {
                bytes32 h = _ids[b];
                uint256 u = used[i][h];
                if (u == 0) {
                    continue;
                }
                used[i][h] = 0;
                env[i][h] -= u;
                locked[epoch][i][h] = u;
                lockedTotal[i][h] += u;
                issuers[count] = i;
                holders[count] = h;
                amounts[count] = u;
                count++;
                emit PairLocked(epoch, i, h, u);
            }
        }
        assembly ("memory-safe") {
            mstore(issuers, count)
            mstore(holders, count)
            mstore(amounts, count)
        }
        // Interactions after every effect: lock the tokens in the holders' wallets.
        for (uint256 k = 0; k < count; k++) {
            IRemoteObligationToken(_members[issuers[k]].token).lock(_members[holders[k]].wallet, amounts[k]);
        }
        emit EpochLocked(epoch, count);
    }

    /// BURN_BATCH: the pair's locked amount for the epoch, exactly, once.
    function burnBatch(uint64 epoch, bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(MESSENGER_ROLE)
    {
        uint256 l = locked[epoch][issuer][holder];
        if (amount == 0 || amount != l) {
            revert BurnMismatch(epoch, issuer, holder, amount, l);
        }
        locked[epoch][issuer][holder] = 0;
        lockedTotal[issuer][holder] -= amount;
        IRemoteObligationToken(_members[issuer].token).burnLocked(_members[holder].wallet, amount);
        emit PairBurned(epoch, issuer, holder, amount);
    }

    /// SUSPEND: restrict-only. Pauses the member's token here and cuts every envelope it is party
    /// to down to what is in use. Nothing is raised; nothing is unpaused.
    function suspend(bytes32 id) external onlyRole(MESSENGER_ROLE) {
        Member storage m = _members[id];
        if (m.wallet == address(0)) {
            return; // not a member here: nothing to restrict
        }
        m.suspended = true;
        IRemoteObligationToken t = IRemoteObligationToken(m.token);
        if (!t.paused()) {
            t.pause();
        }
        uint256 n = _ids.length;
        for (uint256 k = 0; k < n; k++) {
            bytes32 x = _ids[k];
            if (x != id) {
                _park(id, x);
                _park(x, id);
            }
        }
        emit Suspended(id);
    }

    // ---------------------------------------------------------------- views

    /// 0 if a home → spoke MINT may land here now: both members known and not suspended, the
    /// recipient the holder's wallet, the token neither paused nor the wallet frozen, and the
    /// issuer's supply cap holds.
    function mintCheck(bytes32 issuer, bytes32 holder, address recipient, uint256 amount)
        public
        view
        returns (uint8)
    {
        Member storage i = _members[issuer];
        Member storage h = _members[holder];
        if (i.wallet == address(0) || h.wallet == address(0) || issuer == holder) {
            return R_UNKNOWN;
        }
        if (i.suspended || h.suspended) {
            return R_SUSPENDED;
        }
        if (recipient != h.wallet) {
            return R_RECIPIENT;
        }
        if (_blocked(i.token, h.wallet)) {
            return R_BLOCKED;
        }
        if (IRemoteObligationToken(i.token).totalSupply() + amount > supplyCap[issuer]) {
            return R_SUPPLY_CAP;
        }
        return OK;
    }

    function member(bytes32 id) external view returns (Member memory) {
        return _members[id];
    }

    function memberIds() external view returns (bytes32[] memory) {
        return _ids;
    }

    /// The spoke's open position for the current epoch (= `used`).
    function open(bytes32 issuer, bytes32 holder) external view returns (uint256) {
        return used[issuer][holder];
    }

    function available(bytes32 issuer, bytes32 holder) external view returns (uint256) {
        return env[issuer][holder] - used[issuer][holder];
    }

    function queueEntry(uint256 seq) external view returns (QueueEntry memory) {
        return _entries[seq];
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    // ---------------------------------------------------------------- internals

    function _execute(uint256 seq, bytes32 payer, bytes32 to, uint256 amount, bytes32 ref) private {
        used[payer][to] += amount;
        IRemoteObligationToken(_members[payer].token).mint(_members[to].wallet, amount);
        emit Paid(seq, payer, to, amount, ref);
    }

    function _check(bytes32 payer, bytes32 to, uint256 amount) private view returns (uint8) {
        if (used[payer][to] + amount > env[payer][to]) {
            return R_ENVELOPE;
        }
        if (IRemoteObligationToken(_members[payer].token).totalSupply() + amount > supplyCap[payer]) {
            return R_SUPPLY_CAP;
        }
        return OK;
    }

    /// Check (2) of the home ledger on this spoke: no unsecured credit outside the business window.
    function _offHoursCredit() private view returns (bool) {
        return KIND == IExposureLedger.DomainKind.PERMISSIONED && window == IExposureLedger.Window.OFF_HOURS;
    }

    function _blocked(address token, address wallet) private view returns (bool) {
        IRemoteObligationToken t = IRemoteObligationToken(token);
        return t.paused() || t.frozen(wallet);
    }

    function _park(bytes32 issuer, bytes32 holder) private {
        uint256 e = env[issuer][holder];
        uint256 u = used[issuer][holder];
        if (e > u) {
            env[issuer][holder] = u;
            releasable[issuer][holder] += e - u;
            emit EnvelopeParked(issuer, holder, e - u);
        }
    }

    function _member(bytes32 id) private view returns (Member storage m) {
        m = _members[id];
        if (m.wallet == address(0)) {
            revert UnknownMember(id);
        }
    }
}
