// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ICrossChainHub } from "./ICrossChainHub.sol";
import { ICrossChainMessenger } from "./ICrossChainMessenger.sol";

/// @notice The hub's messenger (design §4.3): envelope grants, the cut broadcast and the spokes'
/// reports, settlement burns, suspensions, and the global accountant.
interface IHubMessenger is ICrossChainMessenger, ICrossChainHub {
    /// One spoke's report for an epoch: the pairs it locked, then a final marker with their count.
    struct Report {
        bool sentCut;
        bool closed;
        uint256 expected;
        uint256 received;
    }

    struct RemotePair {
        uint32 domain;
        bytes32 issuer;
        bytes32 holder;
        uint256 amount;
    }

    event SpokeDisconnected(uint32 indexed domain);
    event CutBroadcast(uint64 indexed epoch, uint64 indexed batch, uint256 spokes);
    event SpokeReported(uint64 indexed epoch, uint32 indexed domain, uint256 pairs);
    event BurnsSent(uint64 indexed epoch, uint256 pairs);
    event SuspendSent(bytes32 indexed member, uint256 spokes);

    error NotBatches(address caller);
    error EpochMismatch(uint64 epoch, uint64 batchEpoch);
    error CutAlreadyBroadcast(uint64 epoch);
    error UnexpectedReport(uint64 epoch, uint32 domain);
    error ReportClosed(uint64 epoch, uint32 domain);
    error BatchNotComplete(uint64 epoch);
    error BurnsAlreadySent(uint64 epoch);
    error MemberInGoodStanding(bytes32 member);
    error NotASpoke(uint32 domain);

    function grantEnvelope(uint32 domain, bytes32 issuer, bytes32 holder, uint256 amount) external returns (uint64);
    function sendBurns(uint64 epoch) external returns (uint256 sent);
    function sendSuspend(bytes32 member) external;
    function disconnectSpoke(uint32 domain) external;

    function spokes() external view returns (uint32[] memory);
    function isSpoke(uint32 domain) external view returns (bool);
    function sent(bytes32 issuer, uint32 domain) external view returns (uint256);
    function returned(bytes32 issuer, uint32 domain) external view returns (uint256);
    function batchOfEpoch(uint64 epoch) external view returns (uint64);
    function report(uint64 epoch, uint32 domain) external view returns (Report memory);
    function remotePairs(uint64 epoch) external view returns (RemotePair[] memory);
    function burnsSent(uint64 epoch) external view returns (bool);
}
