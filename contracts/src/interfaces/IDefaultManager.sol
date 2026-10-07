// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Default declaration and the cover waterfall (design §3.8).
interface IDefaultManager {
    event Declared(uint64 indexed batch);
    event CoverInstruction(uint64 indexed batch, uint32 indexed leg, bytes32 indexed source, uint256 amount);

    error NotDeclarable(uint64 batch);
    error DeadlineNotPassed(uint64 deadline);
    error NoSurvivors(uint64 batch, uint32 leg);
    error ZeroAddress();

    function declare(uint64 batch) external;
    function allowedPayer(uint64 batch, uint32 leg, bytes32 payer) external view returns (bool);
    function coverAmount(uint64 batch, uint32 leg, bytes32 source) external view returns (uint256);
    function survivorCall(uint64 batch, bytes32 member) external view returns (uint256);
    function absorbed(uint64 batch, bytes32 member) external view returns (uint256);
}
