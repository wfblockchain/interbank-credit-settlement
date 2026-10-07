// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Credit grants between members (design §3.4). `grantor` accepts holding `debtor`'s token.
interface ICreditLimits {
    event MandatoryPerPairSet(uint256 value);
    event SystemMaxSet(uint256 value);
    event ElectiveMaxSet(uint256 value);
    event MandatoryRemovedSet(bool removed);
    event TriggerBpsSet(uint16 bps);
    event ElectiveSet(bytes32 indexed grantor, bytes32 indexed debtor, uint256 amount);
    event RegCapSet(bytes32 indexed grantor, bytes32 indexed debtor, uint256 cap, bytes32 reason);
    event RegCapCleared(bytes32 indexed grantor, bytes32 indexed debtor, bytes32 reason);
    event ReceiverCapSet(bytes32 indexed id, uint256 cap);
    event RestrictedSet(bytes32 indexed debtor, bool restricted);

    error NotIssuerOps(address account);
    error UnknownMember(bytes32 id);
    error SelfGrant();
    error ElectiveAboveMax(uint256 amount, uint256 max);
    error CanOnlyLower(uint256 current, uint256 requested);
    error InvalidBps(uint16 bps);
    error ZeroAddress();

    function setMandatoryPerPair(uint256 value) external;
    function setSystemMax(uint256 value) external;
    function setElectiveMax(uint256 value) external;
    function setMandatoryRemoved(bool removed) external;
    function setTriggerBps(uint16 bps) external;
    function setElective(bytes32 debtor, uint256 amount) external;
    function setRegCap(bytes32 debtor, uint256 cap, bytes32 reason) external;
    function clearRegCap(bytes32 debtor, bytes32 reason) external;
    function lowerReceiverCap(uint256 cap) external;
    function setReceiverCap(bytes32 id, uint256 cap) external;
    function restrict(bytes32 debtor) external;
    function unrestrict(bytes32 debtor) external;

    function mandatoryPerPair() external view returns (uint256);
    function systemMax() external view returns (uint256);
    function electiveMax() external view returns (uint256);
    function mandatoryRemoved() external view returns (bool);
    function restricted(bytes32 debtor) external view returns (bool);
    function elective(bytes32 grantor, bytes32 debtor) external view returns (uint256);
    function regCap(bytes32 grantor, bytes32 debtor) external view returns (bool set, uint256 cap);
    function receiverCap(bytes32 id) external view returns (uint256);
    function triggerLevel(bytes32 id) external view returns (uint256);
    function collateralFreeForMandatory(bytes32 debtor) external view returns (uint256);
    function mandatory(bytes32 debtor) external view returns (uint256);
    function mandatoryBacking(bytes32 debtor) external view returns (uint256);
    function bilateralLimit(bytes32 grantor, bytes32 debtor) external view returns (uint256);
    function debitCap(bytes32 debtor) external view returns (uint256);
}
