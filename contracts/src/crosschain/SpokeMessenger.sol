// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISpokeExposureGuard } from "../interfaces/ISpokeExposureGuard.sol";
import { CrossChainMessenger } from "./CrossChainMessenger.sol";

/// @notice A spoke's messenger (design §4.3). It talks only to home and routes everything it
/// receives through the spoke's SpokeExposureGuard, which keeps the envelope accounting and holds
/// the token roles here.
///
/// Accepts from home: MINT, MINT_ACK, MINT_CANCEL, ENVELOPE_GRANT, CUT, BURN_BATCH, SUSPEND.
/// Sends to home: MINT, MINT_ACK, MINT_CANCEL, ENVELOPE_RELEASE, BATCH_LOCKED.
contract SpokeMessenger is CrossChainMessenger {
    ISpokeExposureGuard public immutable guard;

    event ReleaseSent(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);
    /// An ENVELOPE_GRANT the guard parked as releasable (unknown or suspended pair).
    event GrantParked(bytes32 indexed issuer, bytes32 indexed holder, uint256 amount);

    constructor(
        uint48 adminDelay,
        address admin,
        uint32 localDomain,
        uint32 homeDomain,
        address guard_,
        address guardian,
        address operator,
        address[] memory attesters,
        uint8 threshold_
    ) CrossChainMessenger(adminDelay, admin, localDomain, homeDomain, guardian, operator, attesters, threshold_) {
        if (guard_ == address(0)) {
            revert ZeroAddress();
        }
        if (localDomain == homeDomain) {
            revert SpokeToSpoke(localDomain);
        }
        guard = ISpokeExposureGuard(guard_);
    }

    /// The operator hands unused (or parked) headroom back: lowered here first, then at the hub.
    function releaseEnvelope(bytes32 issuer, bytes32 holder, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint64)
    {
        guard.release(issuer, holder, amount);
        emit ReleaseSent(issuer, holder, amount);
        return _send(ENVELOPE_RELEASE, HOME_DOMAIN, issuer, holder, address(0), amount, 0, 0, bytes32(0));
    }

    // ---------------------------------------------------------------- side hooks

    function _checkRemote(uint32 domain) internal view override {
        if (domain != HOME_DOMAIN) {
            revert SpokeToSpoke(domain);
        }
    }

    function _checkDest(uint32 dest) internal view override {
        if (dest != HOME_DOMAIN) {
            revert SpokeToSpoke(dest);
        }
        if (remote[dest] == address(0)) {
            revert UnknownDestination(dest);
        }
    }

    function _lockMove(bytes32 issuer, bytes32 holder, address wallet, uint256 amount, uint32) internal override {
        guard.moveOut(issuer, holder, wallet, amount);
    }

    function _completeMove(Move storage m) internal override {
        guard.moveDone(m.issuer, m.holder, m.amount);
    }

    function _cancelMove(Move storage m) internal override {
        guard.moveCancelled(m.issuer, m.holder, m.amount);
    }

    function _mintCheck(Envelope memory e) internal view override returns (uint8) {
        return guard.mintCheck(e.member, e.counterparty, e.recipient, e.amount);
    }

    function _mintIn(Envelope memory e) internal override {
        guard.mintIn(e.member, e.counterparty, e.amount);
    }

    function _handle(Envelope memory e) internal override {
        uint8 k = e.kind;
        if (k == ENVELOPE_GRANT) {
            if (!guard.grant(e.member, e.counterparty, e.amount)) {
                emit GrantParked(e.member, e.counterparty, e.amount);
            }
        } else if (k == CUT) {
            (bytes32[] memory is_, bytes32[] memory hs, uint256[] memory amts) = guard.cut(e.epoch);
            for (uint256 n = 0; n < is_.length; n++) {
                _send(BATCH_LOCKED, HOME_DOMAIN, is_[n], hs[n], address(0), amts[n], e.epoch, 0, bytes32(0));
            }
            _send(BATCH_LOCKED, HOME_DOMAIN, bytes32(0), bytes32(0), address(0), is_.length, e.epoch, 0, bytes32(0));
        } else if (k == BURN_BATCH) {
            guard.burnBatch(e.epoch, e.member, e.counterparty, e.amount);
        } else if (k == SUSPEND) {
            guard.suspend(e.member);
        } else {
            revert KindNotAccepted(k);
        }
    }
}
