// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ICreditLimits } from "../interfaces/ICreditLimits.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";

/// @notice Credit grants (design §3.4). Every setter only gates new transfers; exposure already
/// taken is never affected. A member acts through its issuerOps key.
contract CreditLimits is AccessControlDefaultAdminRules, ICreditLimits {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant DEFAULT_RECEIVER_CAP = 100_000_000e6;

    IMemberRegistry public immutable registry;
    ICollateralRegister public immutable register;

    uint256 public mandatoryPerPair = 5_000_000e6;
    uint256 public systemMax = 1_000_000_000e6;
    uint256 public electiveMax = 100_000_000e6;
    bool public mandatoryRemoved;
    uint16 public triggerBps = 10_000;

    mapping(bytes32 => mapping(bytes32 => uint256)) private _elective;
    mapping(bytes32 => mapping(bytes32 => bool)) private _regCapSet;
    mapping(bytes32 => mapping(bytes32 => uint256)) private _regCap;
    mapping(bytes32 => bool) private _receiverCapSet;
    mapping(bytes32 => uint256) private _receiverCap;
    mapping(bytes32 => bool) public restricted;

    constructor(
        uint48 adminDelay,
        address admin,
        address registry_,
        address register_,
        address guardian,
        address operator
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (registry_ == address(0) || register_ == address(0) || guardian == address(0) || operator == address(0))
        {
            revert ZeroAddress();
        }
        registry = IMemberRegistry(registry_);
        register = ICollateralRegister(register_);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, operator);
    }

    // Governance.

    function setMandatoryPerPair(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mandatoryPerPair = value;
        emit MandatoryPerPairSet(value);
    }

    function setSystemMax(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        systemMax = value;
        emit SystemMaxSet(value);
    }

    function setElectiveMax(uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        electiveMax = value;
        emit ElectiveMaxSet(value);
    }

    function setMandatoryRemoved(bool removed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mandatoryRemoved = removed;
        emit MandatoryRemovedSet(removed);
    }

    /// triggerLevel = receiverCap * bps / 10_000.
    function setTriggerBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps == 0 || bps > 10_000) {
            revert InvalidBps(bps);
        }
        triggerBps = bps;
        emit TriggerBpsSet(bps);
    }

    function setReceiverCap(bytes32 id, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReceiverCap(id, cap);
    }

    function unrestrict(bytes32 debtor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        restricted[debtor] = false;
        emit RestrictedSet(debtor, false);
    }

    // Restrict-only (PCA or supervisory trigger).

    function restrict(bytes32 debtor) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        restricted[debtor] = true;
        emit RestrictedSet(debtor, true);
    }

    // Member (grantor) settings.

    function setElective(bytes32 debtor, uint256 amount) external {
        bytes32 grantor = _callerMember(debtor);
        if (amount > electiveMax) {
            revert ElectiveAboveMax(amount, electiveMax);
        }
        _elective[grantor][debtor] = amount;
        emit ElectiveSet(grantor, debtor, amount);
    }

    function setRegCap(bytes32 debtor, uint256 cap, bytes32 reason) external {
        bytes32 grantor = _callerMember(debtor);
        _regCapSet[grantor][debtor] = true;
        _regCap[grantor][debtor] = cap;
        emit RegCapSet(grantor, debtor, cap, reason);
    }

    function clearRegCap(bytes32 debtor, bytes32 reason) external {
        bytes32 grantor = _callerMember(debtor);
        _regCapSet[grantor][debtor] = false;
        _regCap[grantor][debtor] = 0;
        emit RegCapCleared(grantor, debtor, reason);
    }

    function lowerReceiverCap(uint256 cap) external {
        bytes32 id = registry.memberOfIssuerOps(msg.sender);
        if (id == bytes32(0)) {
            revert NotIssuerOps(msg.sender);
        }
        uint256 current = receiverCap(id);
        if (cap > current) {
            revert CanOnlyLower(current, cap);
        }
        _setReceiverCap(id, cap);
    }

    // Views.

    function elective(bytes32 grantor, bytes32 debtor) external view returns (uint256) {
        return _elective[grantor][debtor];
    }

    function regCap(bytes32 grantor, bytes32 debtor) external view returns (bool set, uint256 cap) {
        return (_regCapSet[grantor][debtor], _regCap[grantor][debtor]);
    }

    function receiverCap(bytes32 id) public view returns (uint256) {
        return _receiverCapSet[id] ? _receiverCap[id] : DEFAULT_RECEIVER_CAP;
    }

    function triggerLevel(bytes32 id) external view returns (uint256) {
        return receiverCap(id) * triggerBps / 10_000;
    }

    /// Collateral not committed to public-spoke envelopes.
    function collateralFreeForMandatory(bytes32 debtor) public view returns (uint256) {
        uint256 c = register.collateral(debtor);
        uint256 p = register.publicCommitted(debtor);
        return c > p ? c - p : 0;
    }

    /// EURO1: min(mandatoryPerPair, free collateral / (active credit members - 1)).
    function mandatory(bytes32 debtor) public view returns (uint256) {
        IMemberRegistry.Member memory m = registry.member(debtor);
        if (
            mandatoryRemoved || restricted[debtor] || m.status != IMemberRegistry.Status.ACTIVE
                || m.tier != IMemberRegistry.Tier.CREDIT
        ) {
            return 0;
        }
        uint256 n = registry.activeCreditCount();
        if (n < 2) {
            return 0;
        }
        uint256 share = collateralFreeForMandatory(debtor) / (n - 1);
        return share < mandatoryPerPair ? share : mandatoryPerPair;
    }

    /// The collateral backing the mandatory limits the debtor receives from all other credit members.
    function mandatoryBacking(bytes32 debtor) external view returns (uint256) {
        uint256 m = mandatory(debtor);
        if (m == 0) {
            return 0;
        }
        return m * (registry.activeCreditCount() - 1);
    }

    function bilateralLimit(bytes32 grantor, bytes32 debtor) public view returns (uint256) {
        if (grantor == debtor) {
            return 0;
        }
        IMemberRegistry.Member memory g = registry.member(grantor);
        IMemberRegistry.Member memory d = registry.member(debtor);
        if (g.status != IMemberRegistry.Status.ACTIVE || d.status != IMemberRegistry.Status.ACTIVE) {
            return 0;
        }
        uint256 el = _elective[grantor][debtor];
        if (el > electiveMax) {
            el = electiveMax;
        }
        uint256 base = (g.tier == IMemberRegistry.Tier.CREDIT ? mandatory(debtor) : 0) + el;
        if (_regCapSet[grantor][debtor] && _regCap[grantor][debtor] < base) {
            return _regCap[grantor][debtor];
        }
        return base;
    }

    function debitCap(bytes32 debtor) external view returns (uint256) {
        IMemberRegistry.Member memory d = registry.member(debtor);
        if (d.status != IMemberRegistry.Status.ACTIVE) {
            return 0;
        }
        uint256 cap;
        if (d.tier == IMemberRegistry.Tier.PREFUND_ONLY) {
            uint256 c = register.collateral(debtor);
            uint256 committed = register.collateralCommitted(debtor);
            cap = c > committed ? c - committed : 0;
        } else {
            bytes32[] memory ids = registry.memberIds();
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] != debtor) {
                    cap += bilateralLimit(ids[i], debtor);
                }
            }
        }
        return cap < systemMax ? cap : systemMax;
    }

    function _setReceiverCap(bytes32 id, uint256 cap) private {
        if (registry.member(id).status == IMemberRegistry.Status.NONE) {
            revert UnknownMember(id);
        }
        _receiverCapSet[id] = true;
        _receiverCap[id] = cap;
        emit ReceiverCapSet(id, cap);
    }

    function _callerMember(bytes32 debtor) private view returns (bytes32 grantor) {
        grantor = registry.memberOfIssuerOps(msg.sender);
        if (grantor == bytes32(0)) {
            revert NotIssuerOps(msg.sender);
        }
        if (registry.member(debtor).status == IMemberRegistry.Status.NONE) {
            revert UnknownMember(debtor);
        }
        if (grantor == debtor) {
            revert SelfGrant();
        }
    }
}
