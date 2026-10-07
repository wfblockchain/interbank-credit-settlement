// Package reconcile is the operator's three-way reconciliation (§5.4 of
// docs/design.md): the rails' journals (what moved), the listener's signed log
// (what the listener attested) and the chain's PaymentRecorded events (what
// the contracts accepted) must tell the same story.
//
// Every attested payment on chain must be a final payment on a rail journal,
// for the same amount, and must be in the listener's log; every successful
// submission in the listener's log must be on chain; every final rail payment
// that names a settlement leg must be on chain or in manual review; and no
// rail transaction may be recorded twice. Anything else is a Break, returned
// as a *BreakError (errors.Is(err, ErrBreak)); the operator halts new cuts on
// one.
package reconcile

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"

	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/listener"
	"interbank-credit-settlement/internal/rails"
)

// ErrBreak matches every *BreakError.
var ErrBreak = errors.New("reconciliation break")

// Kind is the kind of a break.
type Kind string

const (
	ChainWithoutRail     Kind = "attested on chain, no final payment on the rail"
	ChainWithoutListener Kind = "attested on chain, not in the listener's signed log"
	ListenerWithoutChain Kind = "in the listener's signed log, not on chain"
	AmountMismatch       Kind = "amount differs between rail and chain"
	RailMismatch         Kind = "rail differs between journal and chain"
	RailUnaccounted      Kind = "settlement payment on the rail neither attested nor in manual review"
	DuplicateRecord      Kind = "rail transaction recorded on chain more than once"
)

// Break is one inconsistency.
type Break struct {
	Kind     Kind
	RailTxID string // the rail's id when known, else the bytes32 hash
	Batch    uint64
	Leg      uint32
	Detail   string
}

func (b Break) String() string {
	s := fmt.Sprintf("%s: %s", b.Kind, b.RailTxID)
	if b.Batch != 0 {
		s += fmt.Sprintf(" (batch %d leg %d)", b.Batch, b.Leg)
	}
	if b.Detail != "" {
		s += ": " + b.Detail
	}
	return s
}

// BreakError is the typed error of a failed reconciliation.
type BreakError struct {
	Breaks []Break
}

func (e *BreakError) Error() string {
	parts := make([]string, len(e.Breaks))
	for i, b := range e.Breaks {
		parts[i] = b.String()
	}
	return fmt.Sprintf("%d reconciliation break(s): %s", len(e.Breaks), strings.Join(parts, "; "))
}

// Is makes errors.Is(err, ErrBreak) true.
func (e *BreakError) Is(target error) bool { return target == ErrBreak }

// Has reports whether a break of kind k is present.
func (e *BreakError) Has(k Kind) bool {
	for _, b := range e.Breaks {
		if b.Kind == k {
			return true
		}
	}
	return false
}

// ChainPayment is a SettlementBatches.PaymentRecorded event.
type ChainPayment struct {
	Batch    uint64
	Leg      uint32
	Rail     uint8
	RailTxID [32]byte
	Payer    [32]byte
	Amount   *big.Int
	Block    uint64
}

// ReadChain reads every PaymentRecorded event.
func ReadChain(ctx context.Context, d *deploy.Deployment) ([]ChainPayment, error) {
	head, err := d.Client.Head(ctx)
	if err != nil {
		return nil, err
	}
	logs, err := d.Batches.Events(ctx, "PaymentRecorded", 0, head)
	if err != nil {
		return nil, err
	}
	out := make([]ChainPayment, 0, len(logs))
	for _, l := range logs {
		var ev struct {
			Batch    uint64
			Leg      uint32
			Rail     uint8
			RailTxId [32]byte
			Payer    [32]byte
			Amount   *big.Int
		}
		if err := d.Batches.Unpack(&ev, "PaymentRecorded", l); err != nil {
			return nil, err
		}
		out = append(out, ChainPayment{Batch: ev.Batch, Leg: ev.Leg, Rail: ev.Rail, RailTxID: ev.RailTxId, Payer: ev.Payer,
			Amount: ev.Amount, Block: l.BlockNumber})
	}
	return out, nil
}

// Inputs are the three sides.
type Inputs struct {
	Journals []*rails.Journal      // the rails' records
	Listener []listener.Submission // the listener's signed log
	Reviewed map[string]bool       // rail tx ids the listener put in manual review (or failed to submit)
	Chain    []ChainPayment        // PaymentRecorded events
}

// Check compares the three sides and returns nil or a *BreakError.
func Check(in Inputs) error {
	var breaks []Break
	rail := map[[32]byte]rails.Entry{}
	for _, j := range in.Journals {
		for _, e := range j.Entries() {
			if e.Kind == rails.KindPayment && e.Final {
				rail[listener.RailTxHash(e.TxID)] = e
			}
		}
	}
	logged := map[[32]byte]listener.Submission{}
	for _, s := range in.Listener {
		if s.Err == nil {
			logged[s.Payment.RailTxID] = s
		}
	}
	onChain := map[[32]byte]ChainPayment{}
	name := func(h [32]byte) string {
		if e, ok := rail[h]; ok {
			return e.TxID
		}
		if s, ok := logged[h]; ok {
			return s.RailTxID
		}
		return fmt.Sprintf("0x%x", h[:])
	}
	for _, c := range in.Chain {
		if _, dup := onChain[c.RailTxID]; dup {
			breaks = append(breaks, Break{Kind: DuplicateRecord, RailTxID: name(c.RailTxID), Batch: c.Batch, Leg: c.Leg})
		}
		onChain[c.RailTxID] = c
		e, ok := rail[c.RailTxID]
		if !ok {
			breaks = append(breaks, Break{Kind: ChainWithoutRail, RailTxID: name(c.RailTxID), Batch: c.Batch, Leg: c.Leg,
				Detail: fmt.Sprintf("payer %s amount %s", deploy.IDString(c.Payer), c.Amount)})
		} else {
			if c.Amount.Cmp(new(big.Int).SetUint64(e.Amount)) != 0 {
				breaks = append(breaks, Break{Kind: AmountMismatch, RailTxID: e.TxID, Batch: c.Batch, Leg: c.Leg,
					Detail: fmt.Sprintf("rail %d, chain %s", e.Amount, c.Amount)})
			}
			if rails.Rail(c.Rail) != e.Rail {
				breaks = append(breaks, Break{Kind: RailMismatch, RailTxID: e.TxID, Batch: c.Batch, Leg: c.Leg,
					Detail: fmt.Sprintf("journal %s, chain rail %d", e.Rail, c.Rail)})
			}
		}
		if _, ok := logged[c.RailTxID]; !ok {
			breaks = append(breaks, Break{Kind: ChainWithoutListener, RailTxID: name(c.RailTxID), Batch: c.Batch, Leg: c.Leg})
		}
	}
	for h, s := range logged {
		if _, ok := onChain[h]; !ok {
			breaks = append(breaks, Break{Kind: ListenerWithoutChain, RailTxID: s.RailTxID, Batch: s.Payment.Batch, Leg: s.Payment.Leg})
		}
	}
	for h, e := range rail {
		if _, ok := onChain[h]; ok || in.Reviewed[e.TxID] {
			continue
		}
		if _, leg, err := iso20022.ParseLeg(e.Message); err == nil {
			breaks = append(breaks, Break{Kind: RailUnaccounted, RailTxID: e.TxID, Batch: leg.Batch, Leg: leg.Leg,
				Detail: fmt.Sprintf("%s → %s %d", e.PayerAcct, e.PayeeAcct, e.Amount)})
		}
	}
	if len(breaks) == 0 {
		return nil
	}
	sort.Slice(breaks, func(i, j int) bool {
		if breaks[i].Kind != breaks[j].Kind {
			return breaks[i].Kind < breaks[j].Kind
		}
		return breaks[i].RailTxID < breaks[j].RailTxID
	})
	return &BreakError{Breaks: breaks}
}

// Reconciler reads the three sides live.
type Reconciler struct {
	D        *deploy.Deployment
	Journals []*rails.Journal
	Listener *listener.Runner
}

// Run reads the chain and the listener and checks them against the journals.
func (r *Reconciler) Run(ctx context.Context) error {
	c, err := ReadChain(ctx, r.D)
	if err != nil {
		return err
	}
	return Check(Inputs{Journals: r.Journals, Listener: r.Listener.Log(), Reviewed: r.Listener.Reviewed(), Chain: c})
}
