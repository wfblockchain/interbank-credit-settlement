// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A member bank's deposit token (design §3.2). Holders cannot transfer; only the
/// ledger mints and only settlement or the messenger burns.
interface IObligationToken is IERC20 {
    event FrozenSet(address indexed holder, bool frozen);

    error TransfersDisabled();
    error HolderFrozen(address holder);
    error NotBurner(address account);
    error NotPauser(address account);
    error ZeroAddress();

    function issuer() external view returns (bytes32);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function setFrozen(address holder, bool frozen) external;
    function frozen(address holder) external view returns (bool);
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}
