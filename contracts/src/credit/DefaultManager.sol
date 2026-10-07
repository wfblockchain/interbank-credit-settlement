// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ICreditLimits } from "../interfaces/ICreditLimits.sol";
import { IDefaultManager } from "../interfaces/IDefaultManager.sol";
import { IExposureLedger } from "../interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";
import { ISettlementBatches } from "../interfaces/ISettlementBatches.sol";

/// @notice Default declaration and the cover waterfall (design §3.8). After the plan deadline
/// anyone may declare: every member payer of an unpaid leg is marked DEFAULTED, and each unpaid
/// remainder is covered by COLLATERAL, then POOL, then the survivors pro rata to the elective
/// limits they granted the defaulter. Nothing is unwound. PREFUND_ONLY members never share a loss;
/// with no eligible survivor the payee bears the rest as a recorded loss.
///
/// Governance also runs the orderly exit: `exit` sets EXITED for a member with no position left.
contract DefaultManager is AccessControlDefaultAdminRules, IDefaultManager {
    bytes32 public constant COLLATERAL = bytes32("COLLATERAL");
    bytes32 public constant POOL = bytes32("POOL");

    IMemberRegistry public immutable registry;
    ICollateralRegister public immutable register;
    ICreditLimits public immutable limits;
    ISettlementBatches public immutable batches;

    mapping(uint64 => mapping(uint32 => mapping(bytes32 => uint256))) public coverAmount;
    mapping(uint64 => mapping(bytes32 => uint256)) public survivorCall;
    mapping(uint64 => mapping(bytes32 => uint256)) public absorbed;

    constructor(
        uint48 adminDelay,
        address admin,
        address registry_,
        address register_,
        address limits_,
        address batches_
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (registry_ == address(0) || register_ == address(0) || limits_ == address(0) || batches_ == address(0))
        {
            revert ZeroAddress();
        }
        registry = IMemberRegistry(registry_);
        register = ICollateralRegister(register_);
        limits = ICreditLimits(limits_);
        batches = ISettlementBatches(batches_);
    }

    function declare(uint64 b) external {
        ISettlementBatches.Batch memory bt = batches.batch(b);
        if (bt.status != ISettlementBatches.Status.PLANNED && bt.status != ISettlementBatches.Status.PARTIAL) {
            revert NotDeclarable(b);
        }
        if (block.timestamp <= bt.deadline) {
            revert DeadlineNotPassed(bt.deadline);
        }
        batches.markDefaulting(b);
        emit Declared(b);

        ISettlementBatches.Leg[] memory legs = batches.legs(b);
        for (uint256 k = 0; k < legs.length; k++) {
            if (legs[k].paid < legs[k].amount) {
                IMemberRegistry.Status s = registry.member(legs[k].payer).status;
                if (s != IMemberRegistry.Status.DEFAULTED) {
                    registry.markDefaulted(legs[k].payer);
                }
            }
        }
        for (uint256 k = 0; k < legs.length; k++) {
            if (legs[k].paid < legs[k].amount) {
                _cover(b, uint32(k), legs[k]);
            }
        }
    }

    /// Orderly exit (governance): only for an ACTIVE or SUSPENDED member with no open, pending or
    /// envelope position as issuer or holder (its gross in and out are both zero) and no queued
    /// payment as payer or payee. EXITED is terminal and not good standing.
    function exit(bytes32 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IExposureLedger ledger = batches.ledger();
        uint256 grossIn = ledger.grossIn(id);
        uint256 grossOut = ledger.grossOut(id);
        uint256 queued = ledger.queuedFor(id);
        if (grossIn != 0 || grossOut != 0 || queued != 0) {
            revert MemberHasPositions(id, grossIn, grossOut, queued);
        }
        registry.markExited(id);
    }

    function allowedPayer(uint64 b, uint32 leg, bytes32 payer) external view returns (bool) {
        return coverAmount[b][leg][payer] != 0;
    }

    function _cover(uint64 b, uint32 leg, ISettlementBatches.Leg memory l) private {
        bytes32 d = l.payer;
        uint256 rem = l.amount - l.paid;

        // Only collateral not committed to public-spoke envelopes: the committed part stays to
        // cover the public positions.
        uint256 c = register.collateral(d);
        uint256 committed = register.publicCommitted(d);
        uint256 fromCollateral = c > committed ? c - committed : 0;
        if (fromCollateral > rem) {
            fromCollateral = rem;
        }
        if (fromCollateral != 0) {
            _instruct(b, leg, COLLATERAL, fromCollateral);
            rem -= fromCollateral;
        }

        uint256 fromPool = register.poolTotal();
        if (fromPool > rem) {
            fromPool = rem;
        }
        if (fromPool != 0) {
            _instruct(b, leg, POOL, fromPool);
            rem -= fromPool;
        }

        uint256 payeeShare;
        if (rem != 0) {
            payeeShare = _survivors(b, leg, l, rem);
        }

        // Interactions last (the register and the batches are the system's own contracts).
        if (fromCollateral != 0) {
            register.drawCollateral(d, fromCollateral);
        }
        if (fromPool != 0) {
            register.drawPool(fromPool);
        }
        if (payeeShare != 0) {
            batches.absorbLoss(b, leg, l.payee, payeeShare);
        }
    }

    /// Survivors: every admitted CREDIT member that is ACTIVE or SUSPENDED, other than the
    /// defaulter; PREFUND_ONLY members never share a loss. Weights are the elective limits granted
    /// to the defaulter; equal weights if all are zero. Rounding remainder goes to the first
    /// survivor with the largest weight. With no eligible survivor the payee bears the whole
    /// remainder as a recorded loss (absorbLoss), never a silent zero. Effects only: returns the
    /// payee's own share, which the caller books with absorbLoss.
    function _survivors(uint64 b, uint32 leg, ISettlementBatches.Leg memory l, uint256 rem)
        private
        returns (uint256 payeeShare)
    {
        bytes32[] memory ids = registry.memberIds();
        uint256[] memory w = new uint256[](ids.length);
        bool[] memory eligible = new bool[](ids.length);
        uint256 total;
        uint256 count;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == l.payer) {
                continue;
            }
            IMemberRegistry.Member memory m = registry.member(ids[i]);
            if (
                m.tier != IMemberRegistry.Tier.CREDIT
                    || (m.status != IMemberRegistry.Status.ACTIVE && m.status != IMemberRegistry.Status.SUSPENDED)
            ) {
                continue;
            }
            eligible[i] = true;
            w[i] = limits.elective(ids[i], l.payer);
            total += w[i];
            count++;
        }
        if (count == 0) {
            _instruct(b, leg, l.payee, rem);
            absorbed[b][l.payee] += rem;
            emit ShortfallAbsorbed(b, leg, l.payee, rem);
            return rem;
        }
        if (total == 0) {
            for (uint256 i = 0; i < ids.length; i++) {
                if (eligible[i]) {
                    w[i] = 1;
                }
            }
            total = count;
        }
        uint256[] memory share = new uint256[](ids.length);
        uint256 allocated;
        uint256 top;
        for (uint256 i = 0; i < ids.length; i++) {
            share[i] = rem * w[i] / total;
            allocated += share[i];
            if (w[i] > w[top]) {
                top = i;
            }
        }
        share[top] += rem - allocated;
        for (uint256 i = 0; i < ids.length; i++) {
            if (share[i] == 0) {
                continue;
            }
            _instruct(b, leg, ids[i], share[i]);
            if (ids[i] == l.payee) {
                absorbed[b][ids[i]] += share[i];
                payeeShare = share[i];
            } else {
                survivorCall[b][ids[i]] += share[i];
            }
        }
    }

    function _instruct(uint64 b, uint32 leg, bytes32 source, uint256 amount) private {
        coverAmount[b][leg][source] += amount;
        emit CoverInstruction(b, leg, source, amount);
    }
}
