// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Members of the credit network (design §3.1).
interface IMemberRegistry {
    enum Tier {
        NONE,
        CREDIT,
        PREFUND_ONLY
    }

    enum Status {
        NONE,
        ACTIVE,
        SUSPENDED,
        DEFAULTED,
        EXITED
    }

    struct Member {
        address wallet;
        address issuerOps;
        address token;
        Tier tier;
        Status status;
    }

    event Admitted(bytes32 indexed id, address wallet, address issuerOps, address token, Tier tier);
    event Suspended(bytes32 indexed id, bytes32 reason);
    event Reinstated(bytes32 indexed id);
    event Defaulted(bytes32 indexed id);

    error ZeroId();
    error ReservedId(bytes32 id);
    error ZeroAddress();
    error InvalidTier();
    error AlreadyAdmitted(bytes32 id);
    error AddressInUse(address account);
    error TokenIssuerMismatch(bytes32 id, bytes32 tokenIssuer);
    error NotActive(bytes32 id);
    error NotSuspended(bytes32 id);
    error CannotDefault(bytes32 id, Status status);

    function admit(bytes32 id, address wallet, address issuerOps, address token, Tier tier) external;
    function suspend(bytes32 id, bytes32 reason) external;
    function reinstate(bytes32 id) external;
    function markDefaulted(bytes32 id) external;

    function member(bytes32 id) external view returns (Member memory);
    function memberOfWallet(address wallet) external view returns (bytes32);
    function memberOfIssuerOps(address issuerOps) external view returns (bytes32);
    function memberIds() external view returns (bytes32[] memory);
    function activeCount() external view returns (uint256);
    function activeCreditCount() external view returns (uint256);
    function goodStanding(bytes32 id) external view returns (bool);
}
