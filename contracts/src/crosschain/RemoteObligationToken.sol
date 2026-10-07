// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IObligationToken } from "../interfaces/IObligationToken.sol";
import { IRemoteObligationToken } from "../interfaces/IRemoteObligationToken.sol";

/// @notice One issuing bank's deposit token on a spoke (design §4.2). Same rules as the home
/// ObligationToken: six decimals, no user transfers or approvals except to a mover, freeze and
/// pause block mints and mover transfers, never burns. Added: locks.
///
/// MINT: LEDGER_ROLE, held by the spoke guard (local payments within envelopes, and inbound MINT
/// messages, which the messenger routes through the guard so one contract keeps the envelope
/// accounting). BURN, LOCK, UNLOCK and a restrict-only PAUSE: MESSENGER_ROLE (the guard).
///
/// A locked balance stays in the holder's wallet and cannot move; it leaves only by `unlock`
/// (a cancelled move) or `burnLocked` (a settled batch, or a move proven minted at home).
contract RemoteObligationToken is ERC20, Pausable, AccessControlDefaultAdminRules, IRemoteObligationToken {
    bytes32 public constant LEDGER_ROLE = keccak256("LEDGER_ROLE");
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    bytes32 public constant MOVER_ROLE = keccak256("MOVER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ISSUER_ADMIN_ROLE = keccak256("ISSUER_ADMIN_ROLE");

    bytes32 public immutable issuer;
    mapping(address => bool) public frozen;
    mapping(address => uint256) public lockedOf;

    constructor(
        uint48 adminDelay,
        address admin,
        string memory name_,
        string memory symbol_,
        bytes32 issuer_,
        address guard,
        address issuerAdmin,
        address guardian
    ) ERC20(name_, symbol_) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (guard == address(0) || issuerAdmin == address(0) || guardian == address(0)) {
            revert ZeroAddress();
        }
        issuer = issuer_;
        _grantRole(LEDGER_ROLE, guard);
        _grantRole(MESSENGER_ROLE, guard);
        _grantRole(ISSUER_ADMIN_ROLE, issuerAdmin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyRole(LEDGER_ROLE) {
        _mint(to, amount);
    }

    /// Burns an unlocked balance.
    function burn(address from, uint256 amount) external {
        if (!hasRole(MESSENGER_ROLE, msg.sender)) {
            revert NotBurner(msg.sender);
        }
        _requireUnlocked(from, amount);
        _burn(from, amount);
    }

    function lock(address holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        _requireUnlocked(holder, amount);
        uint256 l = lockedOf[holder] + amount;
        lockedOf[holder] = l;
        emit Locked(holder, amount, l);
    }

    function unlock(address holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        uint256 l = _takeLocked(holder, amount);
        emit Unlocked(holder, amount, l);
    }

    /// Settlement must always extinguish: not blocked by pause or freeze.
    function burnLocked(address holder, uint256 amount) external onlyRole(MESSENGER_ROLE) {
        uint256 l = _takeLocked(holder, amount);
        emit Unlocked(holder, amount, l);
        _burn(holder, amount);
    }

    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (!hasRole(MOVER_ROLE, msg.sender)) {
            revert TransfersDisabled();
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (!hasRole(MOVER_ROLE, msg.sender)) {
            revert TransfersDisabled();
        }
        return super.transferFrom(from, to, value);
    }

    function approve(address spender, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (!hasRole(MOVER_ROLE, spender)) {
            revert TransfersDisabled();
        }
        return super.approve(spender, value);
    }

    function setFrozen(address holder, bool frozen_) external onlyRole(GUARDIAN_ROLE) {
        frozen[holder] = frozen_;
        emit FrozenSet(holder, frozen_);
    }

    /// Restrict-only: the issuer, the guardian, or the guard on a SUSPEND.
    function pause() external {
        if (
            !hasRole(ISSUER_ADMIN_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)
                && !hasRole(MESSENGER_ROLE, msg.sender)
        ) {
            revert NotPauser(msg.sender);
        }
        _pause();
    }

    function unpause() external onlyRole(ISSUER_ADMIN_ROLE) {
        _unpause();
    }

    function paused() public view override(Pausable, IObligationToken) returns (bool) {
        return super.paused();
    }

    function unlockedBalanceOf(address holder) public view returns (uint256) {
        return balanceOf(holder) - lockedOf[holder];
    }

    function _requireUnlocked(address holder, uint256 amount) private view {
        uint256 u = unlockedBalanceOf(holder);
        if (amount > u) {
            revert ExceedsUnlocked(holder, amount, u);
        }
    }

    function _takeLocked(address holder, uint256 amount) private returns (uint256 l) {
        l = lockedOf[holder];
        if (amount > l) {
            revert ExceedsLocked(holder, amount, l);
        }
        l -= amount;
        lockedOf[holder] = l;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            _requireNotPaused();
            if (frozen[to]) {
                revert HolderFrozen(to);
            }
            if (from != address(0)) {
                if (frozen[from]) {
                    revert HolderFrozen(from);
                }
                _requireUnlocked(from, value);
            }
        }
        super._update(from, to, value);
    }
}
