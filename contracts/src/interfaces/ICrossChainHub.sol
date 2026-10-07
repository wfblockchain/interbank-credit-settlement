// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice What SettlementBatches asks of the hub messenger (design §4.3, Cut): every cut is
/// broadcast to the connected spokes, and a plan is accepted only once every spoke that was sent
/// the cut has reported its locked amounts.
interface ICrossChainHub {
    function broadcastCut(uint64 epoch) external;
    function spokesReported(uint64 epoch) external view returns (bool);
}
