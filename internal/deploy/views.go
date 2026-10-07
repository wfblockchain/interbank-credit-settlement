package deploy

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"interbank-credit-settlement/internal/chain"
)

// Batch statuses (ISettlementBatches.Status).
const (
	StatusNone uint8 = iota
	StatusCut
	StatusPlanned
	StatusPartial
	StatusDefaulting
	StatusComplete
)

// StatusName names a batch status.
func StatusName(s uint8) string {
	switch s {
	case StatusNone:
		return "NONE"
	case StatusCut:
		return "CUT"
	case StatusPlanned:
		return "PLANNED"
	case StatusPartial:
		return "PARTIAL"
	case StatusDefaulting:
		return "DEFAULTING"
	case StatusComplete:
		return "COMPLETE"
	}
	return fmt.Sprintf("Status(%d)", s)
}

// Cut triggers (SettlementBatches.TRIGGER_*).
const (
	TriggerCap          uint8 = 1
	TriggerReceiverCall uint8 = 2
	TriggerEndOfDay     uint8 = 3
)

// TriggerName names a cut trigger.
func TriggerName(t uint8) string {
	switch t {
	case TriggerCap:
		return "CAP"
	case TriggerReceiverCall:
		return "RECEIVER_CALL"
	case TriggerEndOfDay:
		return "END_OF_DAY"
	}
	return fmt.Sprintf("Trigger(%d)", t)
}

// Ledger windows (IExposureLedger.Window). Note the Solidity enum starts at
// BUSINESS = 0, unlike calendar.Window.
const (
	WindowBusiness uint8 = 0
	WindowOffHours uint8 = 1
)

// Funding kinds (ICollateralRegister.Kind).
const (
	KindCollateral   uint8 = 0
	KindPool         uint8 = 1
	KindRTPPrefund   uint8 = 2
	KindPoolRequired uint8 = 3
)

// Member statuses (IMemberRegistry.Status).
const (
	MemberNone uint8 = iota
	MemberActive
	MemberSuspended
	MemberDefaulted
	MemberExited
)

// Ledger queue states (IExposureLedger.QueueState).
const (
	QueueNone uint8 = iota
	QueueQueued
	QueuePaid
	QueueCancelled
	QueueExpired
)

// BatchView mirrors ISettlementBatches.Batch (field order matters: the ABI
// decoder assigns tuple fields by position).
type BatchView struct {
	Epoch       uint64
	EpochHash   [32]byte
	Trigger     uint8
	Status      uint8
	CutAt       uint64
	BusinessDay uint64
	Deadline    uint64
	UnpaidLegs  uint32
	Finalized   bool
	Cursor      *big.Int
	Burned      *big.Int
}

// LegView mirrors ISettlementBatches.Leg.
type LegView struct {
	Payer  [32]byte
	Payee  [32]byte
	Amount *big.Int
	Paid   *big.Int
}

// MemberView mirrors IMemberRegistry.Member.
type MemberView struct {
	Wallet    common.Address
	IssuerOps common.Address
	Token     common.Address
	Tier      uint8
	Status    uint8
}

// QueueEntryView mirrors IExposureLedger.QueueEntry.
type QueueEntryView struct {
	Seq         *big.Int
	Payer       [32]byte
	To          [32]byte
	Amount      *big.Int
	Ref         [32]byte
	EnqueuedAt  uint64
	BusinessDay uint64
	State       uint8
}

// PairView is one pending (issuer, holder) pair of a batch.
type PairView struct {
	Issuer [32]byte
	Holder [32]byte
	Amount *big.Int
}

// Decode converts an ABI-decoded value into T (struct fields by position).
func Decode[T any](v any) (out T, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("decode %T: %v", out, r)
		}
	}()
	return *abi.ConvertType(v, new(T)).(*T), nil
}

func one[T any](ctx context.Context, c *chain.Contract, method string, args ...any) (T, error) {
	out, err := c.Call(ctx, method, args...)
	if err != nil {
		var zero T
		return zero, err
	}
	return Decode[T](out[0])
}

// Batch reads a batch.
func (d *Deployment) Batch(ctx context.Context, b uint64) (BatchView, error) {
	return one[BatchView](ctx, d.Batches, "batch", b)
}

// BatchCount is the number of batches cut so far.
func (d *Deployment) BatchCount(ctx context.Context) (uint64, error) {
	return one[uint64](ctx, d.Batches, "batchCount")
}

// Legs reads a batch's plan.
func (d *Deployment) Legs(ctx context.Context, b uint64) ([]LegView, error) {
	return one[[]LegView](ctx, d.Batches, "legs", b)
}

// Leg reads one leg.
func (d *Deployment) Leg(ctx context.Context, b uint64, leg uint32) (LegView, error) {
	return one[LegView](ctx, d.Batches, "leg", b, leg)
}

// Member reads a registry entry.
func (d *Deployment) Member(ctx context.Context, id [32]byte) (MemberView, error) {
	return one[MemberView](ctx, d.Registry, "member", id)
}

// MemberIDs lists every admitted member.
func (d *Deployment) MemberIDs(ctx context.Context) ([][32]byte, error) {
	return one[[][32]byte](ctx, d.Registry, "memberIds")
}

// PendingPairs reads the pairs of a batch's epoch.
func (d *Deployment) PendingPairs(ctx context.Context, epoch uint64) ([]PairView, error) {
	out, err := d.Ledger.Call(ctx, "pendingPairs", epoch)
	if err != nil {
		return nil, err
	}
	is, err := Decode[[][32]byte](out[0])
	if err != nil {
		return nil, err
	}
	hs, err := Decode[[][32]byte](out[1])
	if err != nil {
		return nil, err
	}
	as, err := Decode[[]*big.Int](out[2])
	if err != nil {
		return nil, err
	}
	ps := make([]PairView, len(is))
	for k := range is {
		ps[k] = PairView{Issuer: is[k], Holder: hs[k], Amount: as[k]}
	}
	return ps, nil
}

// NetPosition is the member's multilateral net position (> 0: net creditor).
func (d *Deployment) NetPosition(ctx context.Context, id [32]byte) (*big.Int, error) {
	return d.Ledger.BigInt(ctx, "netPosition", id)
}

// QueueEntry reads a ledger queue entry.
func (d *Deployment) QueueEntry(ctx context.Context, seq *big.Int) (QueueEntryView, error) {
	return one[QueueEntryView](ctx, d.Ledger, "queueEntry", seq)
}

// Window is the ledger's current window (WindowBusiness / WindowOffHours).
func (d *Deployment) Window(ctx context.Context) (uint8, error) {
	return one[uint8](ctx, d.Ledger, "window")
}

// EpochHash is the open epoch's commitment (zero while nothing was paid in it).
func (d *Deployment) EpochHash(ctx context.Context) ([32]byte, error) {
	return one[[32]byte](ctx, d.Ledger, "epochHash")
}

// TokenSupply is the total supply of a member's deposit token.
func (d *Deployment) TokenSupply(ctx context.Context, id [32]byte) (*big.Int, error) {
	t := d.Tokens[id]
	if t == nil {
		return nil, fmt.Errorf("no token for %s", IDString(id))
	}
	return t.BigInt(ctx, "totalSupply")
}

// IDString renders a bytes32 member id.
func IDString(id [32]byte) string {
	n := 0
	for n < 32 && id[n] != 0 {
		n++
	}
	return string(id[:n])
}
