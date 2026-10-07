// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ICreditLimits } from "../interfaces/ICreditLimits.sol";
import { IDefaultManager } from "../interfaces/IDefaultManager.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";
import { ISettlementBatches } from "../interfaces/ISettlementBatches.sol";

/// @notice Default declaration and the cover waterfall (design §3.8). After the plan deadline
/// anyone may declare: every member payer of an unpaid leg is marked DEFAULTED, and each unpaid
/// remainder is covered by COLLATERAL, then POOL, then the survivors pro rata to the elective
/// limits they granted the defaulter. Nothing is unwound.
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

    function allowedPayer(uint64 b, uint32 leg, bytes32 payer) external view returns (bool) {
        return coverAmount[b][leg][payer] != 0;
    }

    function _cover(uint64 b, uint32 leg, ISettlementBatches.Leg memory l) private {
        bytes32 d = l.payer;
        uint256 rem = l.amount - l.paid;

        uint256 x = register.collateral(d);
        if (x > rem) {
            x = rem;
        }
        if (x != 0) {
            register.drawCollateral(d, x);
            _instruct(b, leg, COLLATERAL, x);
            rem -= x;
        }

        x = register.poolTotal();
        if (x > rem) {
            x = rem;
        }
        if (x != 0) {
            register.drawPool(x);
            _instruct(b, leg, POOL, x);
            rem -= x;
        }

        if (rem != 0) {
            _survivors(b, leg, l, rem);
        }
    }

    /// Survivors: every admitted member not DEFAULTED (and not EXITED), other than the defaulter.
    /// Weights are the elective limits granted to the defaulter; equal weights if all are zero.
    /// Rounding remainder goes to the first survivor with the largest weight.
    function _survivors(uint64 b, uint32 leg, ISettlementBatches.Leg memory l, uint256 rem) private {
        bytes32[] memory ids = registry.memberIds();
        uint256[] memory w = new uint256[](ids.length);
        uint256 total;
        uint256 count;
        for (uint256 i = 0; i < ids.length; i++) {
            IMemberRegistry.Status s = registry.member(ids[i]).status;
            if (ids[i] == l.payer || (s != IMemberRegistry.Status.ACTIVE && s != IMemberRegistry.Status.SUSPENDED)) {
                continue;
            }
            w[i] = limits.elective(ids[i], l.payer);
            total += w[i];
            count++;
        }
        if (count == 0) {
            revert NoSurvivors(b, leg);
        }
        if (total == 0) {
            for (uint256 i = 0; i < ids.length; i++) {
                IMemberRegistry.Status s = registry.member(ids[i]).status;
                if (ids[i] != l.payer && (s == IMemberRegistry.Status.ACTIVE || s == IMemberRegistry.Status.SUSPENDED))
                {
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
                batches.absorbLoss(b, leg, ids[i], share[i]);
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
