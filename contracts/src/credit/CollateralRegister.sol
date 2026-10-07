// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ICollateralRegister } from "../interfaces/ICollateralRegister.sol";
import { ICreditLimits } from "../interfaces/ICreditLimits.sol";

/// @notice Attested off-chain resources (design §3.3). Values change only by k-of-n attestation,
/// by a waterfall draw on default, or by public-envelope commitments from the ledger.
contract CollateralRegister is AccessControlDefaultAdminRules, ICollateralRegister {
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    bytes32 public constant LEDGER_ROLE = keccak256("LEDGER_ROLE");
    bytes32 public constant DEFAULT_MANAGER_ROLE = keccak256("DEFAULT_MANAGER_ROLE");

    ICreditLimits public immutable limits;

    mapping(bytes32 => uint256) public collateral;
    mapping(bytes32 => uint256) public poolShare;
    mapping(bytes32 => uint256) public rtpPrefund;
    uint256 public poolRequired;
    uint256 public poolTotal;
    mapping(bytes32 => uint256) public publicCommitted;
    mapping(Kind => mapping(bytes32 => uint64)) public lastAsOf;

    bytes32[] private _poolContributors;
    mapping(bytes32 => bool) private _isContributor;

    constructor(
        uint48 adminDelay,
        address admin,
        address attestor,
        address ledger,
        address defaultManager,
        address limits_
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (attestor == address(0) || ledger == address(0) || defaultManager == address(0) || limits_ == address(0))
        {
            revert ZeroAddress();
        }
        limits = ICreditLimits(limits_);
        _grantRole(ATTESTOR_ROLE, attestor);
        _grantRole(LEDGER_ROLE, ledger);
        _grantRole(DEFAULT_MANAGER_ROLE, defaultManager);
    }

    /// POOL_REQUIRED is network-wide and uses id 0; the other kinds need a member id.
    function attest(Kind kind, bytes32 id, uint256 value, uint64 asOf) external onlyRole(ATTESTOR_ROLE) {
        if ((kind == Kind.POOL_REQUIRED) != (id == bytes32(0))) {
            revert InvalidAttestationId();
        }
        uint64 last = lastAsOf[kind][id];
        if (asOf <= last) {
            revert StaleAttestation(kind, id, asOf, last);
        }
        lastAsOf[kind][id] = asOf;
        if (kind == Kind.COLLATERAL) {
            collateral[id] = value;
        } else if (kind == Kind.POOL) {
            if (!_isContributor[id]) {
                _isContributor[id] = true;
                _poolContributors.push(id);
            }
            poolTotal = poolTotal - poolShare[id] + value;
            poolShare[id] = value;
        } else if (kind == Kind.RTP_PREFUND) {
            rtpPrefund[id] = value;
        } else {
            poolRequired = value;
        }
        emit Attested(kind, id, value, asOf);
    }

    /// Waterfall step 1: the defaulter's own collateral.
    function drawCollateral(bytes32 id, uint256 amount) external onlyRole(DEFAULT_MANAGER_ROLE) {
        uint256 c = collateral[id];
        if (amount > c) {
            revert InsufficientResource(amount, c);
        }
        collateral[id] = c - amount;
        emit CollateralDrawn(id, amount);
    }

    /// Waterfall step 2: the loss pool, drawn pro rata to the contributions.
    function drawPool(uint256 amount) external onlyRole(DEFAULT_MANAGER_ROLE) {
        uint256 total = poolTotal;
        if (amount > total) {
            revert InsufficientResource(amount, total);
        }
        if (amount == 0) {
            return;
        }
        uint256 n = _poolContributors.length;
        uint256 drawn;
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = _poolContributors[i];
            uint256 cut = poolShare[id] * amount / total;
            poolShare[id] -= cut;
            drawn += cut;
        }
        for (uint256 i = 0; i < n && drawn < amount; i++) {
            bytes32 id = _poolContributors[i];
            uint256 cut = amount - drawn;
            if (cut > poolShare[id]) {
                cut = poolShare[id];
            }
            poolShare[id] -= cut;
            drawn += cut;
        }
        poolTotal = total - amount;
        emit PoolDrawn(amount);
    }

    /// A public-spoke envelope draws from free collateral one-for-one (design §4.4).
    function commitPublic(bytes32 id, uint256 amount) external onlyRole(LEDGER_ROLE) {
        uint256 free = freeCollateral(id);
        if (amount > free) {
            revert InsufficientFreeCollateral(id, amount, free);
        }
        publicCommitted[id] += amount;
        emit PublicCommitted(id, amount, publicCommitted[id]);
    }

    function releasePublic(bytes32 id, uint256 amount) external onlyRole(LEDGER_ROLE) {
        uint256 c = publicCommitted[id];
        if (amount > c) {
            revert ReleaseExceedsCommitted(id, amount, c);
        }
        publicCommitted[id] = c - amount;
        emit PublicReleased(id, amount, c - amount);
    }

    /// Mandatory backing (the mandatory limits the member receives) plus public envelopes.
    function collateralCommitted(bytes32 id) public view returns (uint256) {
        return publicCommitted[id] + limits.mandatoryBacking(id);
    }

    function freeCollateral(bytes32 id) public view returns (uint256) {
        uint256 c = collateral[id];
        uint256 committed = collateralCommitted(id);
        return c > committed ? c - committed : 0;
    }

    function poolContributors() external view returns (bytes32[] memory) {
        return _poolContributors;
    }
}
