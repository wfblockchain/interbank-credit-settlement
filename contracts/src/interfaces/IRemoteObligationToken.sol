// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IObligationToken } from "./IObligationToken.sol";

/// @notice A member bank's deposit token on a spoke (design §4.2): the ObligationToken interface
/// plus locks. A locked balance stays in the holder's wallet but cannot move; it is either
/// unlocked (a cancelled move) or burned (settlement, or a move proven minted at home).
interface IRemoteObligationToken is IObligationToken {
    event Locked(address indexed holder, uint256 amount, uint256 lockedTotal);
    event Unlocked(address indexed holder, uint256 amount, uint256 lockedTotal);

    error ExceedsUnlocked(address holder, uint256 amount, uint256 unlocked);
    error ExceedsLocked(address holder, uint256 amount, uint256 locked);

    function lock(address holder, uint256 amount) external;
    function unlock(address holder, uint256 amount) external;
    function burnLocked(address holder, uint256 amount) external;
    function lockedOf(address holder) external view returns (uint256);
    function unlockedBalanceOf(address holder) external view returns (uint256);
}
