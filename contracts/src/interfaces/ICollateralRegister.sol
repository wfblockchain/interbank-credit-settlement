// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Attested off-chain resources per member (design §3.3).
interface ICollateralRegister {
    /// Funding kinds; the numeric value is the `kind` field of an attested `Funding`.
    enum Kind {
        COLLATERAL,
        POOL,
        RTP_PREFUND,
        POOL_REQUIRED
    }

    event Attested(Kind indexed kind, bytes32 indexed id, uint256 value, uint64 asOf);
    event CollateralDrawn(bytes32 indexed id, uint256 amount);
    event PoolDrawn(uint256 amount);
    event PublicCommitted(bytes32 indexed id, uint256 amount, uint256 total);
    event PublicReleased(bytes32 indexed id, uint256 amount, uint256 total);

    error StaleAttestation(Kind kind, bytes32 id, uint64 asOf, uint64 lastAsOf);
    error InvalidAttestationId();
    error InsufficientResource(uint256 requested, uint256 available);
    error InsufficientFreeCollateral(bytes32 id, uint256 requested, uint256 free);
    error ReleaseExceedsCommitted(bytes32 id, uint256 requested, uint256 committed);
    error ZeroAddress();

    function attest(Kind kind, bytes32 id, uint256 value, uint64 asOf) external;
    function drawCollateral(bytes32 id, uint256 amount) external;
    function drawPool(uint256 amount) external;
    function commitPublic(bytes32 id, uint256 amount) external;
    function releasePublic(bytes32 id, uint256 amount) external;

    function collateral(bytes32 id) external view returns (uint256);
    function poolShare(bytes32 id) external view returns (uint256);
    function rtpPrefund(bytes32 id) external view returns (uint256);
    function poolRequired() external view returns (uint256);
    function poolTotal() external view returns (uint256);
    function publicCommitted(bytes32 id) external view returns (uint256);
    function collateralCommitted(bytes32 id) external view returns (uint256);
    function freeCollateral(bytes32 id) external view returns (uint256);
    function lastAsOf(Kind kind, bytes32 id) external view returns (uint64);
}
