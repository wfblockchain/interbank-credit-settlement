// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Net settlement batches (design §3.7).
interface ISettlementBatches {
    enum Status {
        NONE,
        CUT,
        PLANNED,
        PARTIAL,
        DEFAULTING,
        COMPLETE
    }

    struct Leg {
        bytes32 payer;
        bytes32 payee;
        uint256 amount;
        uint256 paid;
    }

    /// An attested final rail payment (EIP-712 type `Payment`, design §3.6).
    struct Payment {
        uint64 batch;
        uint32 leg;
        uint8 rail;
        bytes32 railTxId;
        address payerAcct;
        bytes32 payer;
        bytes32 payee;
        uint256 amount;
        uint64 finalAt;
    }

    struct Batch {
        uint64 epoch;
        bytes32 epochHash;
        uint8 trigger;
        Status status;
        uint64 cutAt;
        uint64 businessDay;
        uint64 deadline;
        uint32 unpaidLegs;
        bool finalized;
        uint256 cursor;
        uint256 burned;
    }

    event BatchCut(uint64 indexed batch, uint64 indexed epoch, bytes32 epochHash);
    event SettlementRequested(bytes32 indexed member);
    event PlanSubmitted(uint64 indexed batch, uint256 legs, uint64 deadline);
    event PaymentRecorded(
        uint64 indexed batch, uint32 indexed leg, uint8 rail, bytes32 railTxId, bytes32 payer, uint256 amount
    );
    event LegPaid(uint64 indexed batch, uint32 indexed leg);
    event Overpaid(uint64 indexed batch, uint32 indexed leg, uint256 overpaid);
    event BatchPartial(uint64 indexed batch);
    event BatchDefaulting(uint64 indexed batch);
    event LossAbsorbed(uint64 indexed batch, uint32 indexed leg, bytes32 indexed member, uint256 amount);
    event BatchComplete(uint64 indexed batch);
    event PairSettled(
        uint64 indexed batch, bytes32 indexed issuer, bytes32 indexed holder, uint256 amount, bool remote
    );
    event BatchFinalized(uint64 indexed batch, uint256 burned);

    error InvalidTrigger(uint8 trigger);
    error BatchOutstanding(uint64 batch);
    error PoolNotReplenished(uint256 poolTotal, uint256 poolRequired);
    error NotIssuerOps(address account);
    error NotInGoodStanding(bytes32 member);
    error UnknownBatch(uint64 batch);
    error WrongStatus(uint64 batch, Status status);
    error DeadlineInPast(uint64 deadline);
    error InvalidLeg(uint256 index);
    error NotAMember(bytes32 id);
    error PlanMismatch(bytes32 member);
    error UnknownLeg(uint64 batch, uint32 leg);
    error WrongPayer(bytes32 expected, bytes32 given);
    error WrongPayee(bytes32 expected, bytes32 given);
    error DeadlineNotPassed(uint64 deadline);
    error AbsorbExceedsRemainder(uint256 amount, uint256 remainder);
    error NotPayee(bytes32 member);
    error AlreadyFinalized(uint64 batch);
    error ZeroAddress();

    function cut(uint8 trigger) external returns (uint64 batch);
    function requestSettlement() external;
    function submitPlan(uint64 batch, Leg[] calldata legs, uint64 deadline) external;
    function recordPayment(Payment calldata p) external;
    function finalize(uint64 batch, uint256 maxPairs) external returns (uint256 settled);
    function markDefaulting(uint64 batch) external;
    function absorbLoss(uint64 batch, uint32 leg, bytes32 member, uint256 amount) external;

    function rfReference(uint64 batch) external view returns (string memory);
    function batchCount() external view returns (uint64);
    function batch(uint64 batch) external view returns (Batch memory);
    function status(uint64 batch) external view returns (Status);
    function legCount(uint64 batch) external view returns (uint256);
    function leg(uint64 batch, uint32 index) external view returns (Leg memory);
    function legs(uint64 batch) external view returns (Leg[] memory);
    function overpaid(uint64 batch, uint32 leg) external view returns (uint256);
    function paidBy(uint64 batch, uint32 leg, bytes32 payer) external view returns (uint256);
}
