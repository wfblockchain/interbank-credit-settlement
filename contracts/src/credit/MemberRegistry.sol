// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { IMemberRegistry } from "../interfaces/IMemberRegistry.sol";
import { IObligationToken } from "../interfaces/IObligationToken.sol";

/// @notice Members of the credit network (design §3.1). A member is in good standing iff ACTIVE.
contract MemberRegistry is AccessControlDefaultAdminRules, IMemberRegistry {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DEFAULT_MANAGER_ROLE = keccak256("DEFAULT_MANAGER_ROLE");

    /// Waterfall sources used as payer ids (design §3.6); never member ids.
    bytes32 public constant COLLATERAL = bytes32("COLLATERAL");
    bytes32 public constant POOL = bytes32("POOL");

    mapping(bytes32 => Member) private _members;
    mapping(address => bytes32) public memberOfWallet;
    mapping(address => bytes32) public memberOfIssuerOps;
    mapping(address => bytes32) public memberOfToken;
    bytes32[] private _ids;
    uint256 public activeCount;
    uint256 public activeCreditCount;

    constructor(uint48 adminDelay, address admin, address guardian, address defaultManager)
        AccessControlDefaultAdminRules(adminDelay, admin)
    {
        if (guardian == address(0) || defaultManager == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(DEFAULT_MANAGER_ROLE, defaultManager);
    }

    function admit(bytes32 id, address wallet, address issuerOps, address token, Tier tier)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (id == bytes32(0)) {
            revert ZeroId();
        }
        if (id == COLLATERAL || id == POOL) {
            revert ReservedId(id);
        }
        if (wallet == address(0) || issuerOps == address(0) || token == address(0)) {
            revert ZeroAddress();
        }
        if (tier != Tier.CREDIT && tier != Tier.PREFUND_ONLY) {
            revert InvalidTier();
        }
        if (_members[id].status != Status.NONE) {
            revert AlreadyAdmitted(id);
        }
        _requireUnused(wallet);
        _requireUnused(issuerOps);
        _requireUnused(token);
        if (wallet == issuerOps) {
            revert AddressInUse(wallet);
        }
        bytes32 tokenIssuer = IObligationToken(token).issuer();
        if (tokenIssuer != id) {
            revert TokenIssuerMismatch(id, tokenIssuer);
        }
        _members[id] = Member({ wallet: wallet, issuerOps: issuerOps, token: token, tier: tier, status: Status.ACTIVE });
        memberOfWallet[wallet] = id;
        memberOfIssuerOps[issuerOps] = id;
        memberOfToken[token] = id;
        _ids.push(id);
        _countActive(id, true);
        emit Admitted(id, wallet, issuerOps, token, tier);
    }

    function suspend(bytes32 id, bytes32 reason) external onlyRole(GUARDIAN_ROLE) {
        if (_members[id].status != Status.ACTIVE) {
            revert NotActive(id);
        }
        _countActive(id, false);
        _members[id].status = Status.SUSPENDED;
        emit Suspended(id, reason);
    }

    function reinstate(bytes32 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_members[id].status != Status.SUSPENDED) {
            revert NotSuspended(id);
        }
        _members[id].status = Status.ACTIVE;
        _countActive(id, true);
        emit Reinstated(id);
    }

    function markDefaulted(bytes32 id) external onlyRole(DEFAULT_MANAGER_ROLE) {
        Status s = _members[id].status;
        if (s != Status.ACTIVE && s != Status.SUSPENDED) {
            revert CannotDefault(id, s);
        }
        if (s == Status.ACTIVE) {
            _countActive(id, false);
        }
        _members[id].status = Status.DEFAULTED;
        emit Defaulted(id);
    }

    function member(bytes32 id) external view returns (Member memory) {
        return _members[id];
    }

    function memberIds() external view returns (bytes32[] memory) {
        return _ids;
    }

    function goodStanding(bytes32 id) external view returns (bool) {
        return _members[id].status == Status.ACTIVE;
    }

    function _countActive(bytes32 id, bool up) private {
        bool credit = _members[id].tier == Tier.CREDIT;
        if (up) {
            activeCount++;
            if (credit) {
                activeCreditCount++;
            }
        } else {
            activeCount--;
            if (credit) {
                activeCreditCount--;
            }
        }
    }

    function _requireUnused(address a) private view {
        if (memberOfWallet[a] != 0 || memberOfIssuerOps[a] != 0 || memberOfToken[a] != 0) {
            revert AddressInUse(a);
        }
    }
}
