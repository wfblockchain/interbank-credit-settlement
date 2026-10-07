// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControlDefaultAdminRules } from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IObligationToken } from "../interfaces/IObligationToken.sol";

/// @notice One issuing bank's deposit token (design §3.2). Six decimals. Holders cannot transfer
/// or approve; only MOVER_ROLE (the messenger's lock-then-burn escrow) moves tokens. Pause and
/// freeze block mints and mover transfers, never burns.
contract ObligationToken is ERC20, Pausable, AccessControlDefaultAdminRules, IObligationToken {
    bytes32 public constant LEDGER_ROLE = keccak256("LEDGER_ROLE");
    bytes32 public constant BATCHES_ROLE = keccak256("BATCHES_ROLE");
    bytes32 public constant MESSENGER_ROLE = keccak256("MESSENGER_ROLE");
    bytes32 public constant MOVER_ROLE = keccak256("MOVER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ISSUER_ADMIN_ROLE = keccak256("ISSUER_ADMIN_ROLE");

    bytes32 public immutable issuer;
    mapping(address => bool) public frozen;

    constructor(
        uint48 adminDelay,
        address admin,
        string memory name_,
        string memory symbol_,
        bytes32 issuer_,
        address ledger,
        address batches,
        address issuerAdmin,
        address guardian
    ) ERC20(name_, symbol_) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (ledger == address(0) || batches == address(0) || issuerAdmin == address(0) || guardian == address(0))
        {
            revert ZeroAddress();
        }
        issuer = issuer_;
        _grantRole(LEDGER_ROLE, ledger);
        _grantRole(BATCHES_ROLE, batches);
        _grantRole(ISSUER_ADMIN_ROLE, issuerAdmin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyRole(LEDGER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (!hasRole(BATCHES_ROLE, msg.sender) && !hasRole(MESSENGER_ROLE, msg.sender)) {
            revert NotBurner(msg.sender);
        }
        _burn(from, amount);
    }

    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        if (!hasRole(MOVER_ROLE, msg.sender)) {
            revert TransfersDisabled();
        }
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20, IERC20)
        returns (bool)
    {
        if (!hasRole(MOVER_ROLE, msg.sender)) {
            revert TransfersDisabled();
        }
        return super.transferFrom(from, to, value);
    }

    /// Only an allowance to a mover (the messenger's escrow) can be set.
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

    function pause() external {
        if (!hasRole(ISSUER_ADMIN_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) {
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

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            _requireNotPaused();
            if (frozen[to]) {
                revert HolderFrozen(to);
            }
            if (from != address(0) && frozen[from]) {
                revert HolderFrozen(from);
            }
        }
        super._update(from, to, value);
    }
}
