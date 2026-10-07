// Package operator is the operator's automated back office (§5.4 of
// docs/design.md): it keeps the on-chain business window in step with the
// calendar, cuts settlement batches on their triggers, builds and submits
// the multilateral net plan, issues the pay-in schedule to the paying banks,
// finalizes completed batches and drains the queue, runs the default
// waterfall when a deadline passes, and halts new cuts on a reconciliation
// break.
package operator

import (
	"bytes"
	"fmt"
	"math/big"
	"sort"
	"time"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/rails"
)

// Pair is a pending (issuer, holder) position of a batch: holder holds
// Amount of issuer's token.
type Pair struct {
	Issuer [32]byte
	Holder [32]byte
	Amount *big.Int
}

// Leg is one fiat payment obligation of a plan, Payer to Payee.
type Leg struct {
	Payer  [32]byte
	Payee  [32]byte
	Amount *big.Int
}

// NetPositions computes each member's multilateral net position over the
// pairs, exactly as SettlementBatches.submitPlan does: + held, − issued.
func NetPositions(pairs []Pair) map[[32]byte]*big.Int {
	net := map[[32]byte]*big.Int{}
	add := func(id [32]byte, v *big.Int) {
		if net[id] == nil {
			net[id] = new(big.Int)
		}
		net[id].Add(net[id], v)
	}
	for _, p := range pairs {
		add(p.Holder, p.Amount)
		add(p.Issuer, new(big.Int).Neg(p.Amount))
	}
	return net
}

type position struct {
	id  [32]byte
	amt *big.Int
}

// sortedSide returns the members on one side, largest amount first, ties by
// member id so a plan is deterministic.
func sortedSide(net map[[32]byte]*big.Int, sign int) []position {
	var out []position
	for id, v := range net {
		if v.Sign() == sign {
			out = append(out, position{id, new(big.Int).Abs(v)})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if c := out[i].amt.Cmp(out[j].amt); c != 0 {
			return c > 0
		}
		return bytes.Compare(out[i].id[:], out[j].id[:]) < 0
	})
	return out
}

// BuildPlan nets the pairs multilaterally and pays net debtors to net
// creditors, largest first: the largest remaining debtor pays the largest
// remaining creditor the smaller of the two amounts, until both sides are
// zero. The result has at most (members − 1) legs and satisfies the
// contract's plan check (Σ in − Σ out = net position for every member).
func BuildPlan(pairs []Pair) []Leg {
	net := NetPositions(pairs)
	debtors, creditors := sortedSide(net, -1), sortedSide(net, 1)
	var legs []Leg
	i, j := 0, 0
	for i < len(debtors) && j < len(creditors) {
		d, c := debtors[i], creditors[j]
		amt := new(big.Int).Set(d.amt)
		if c.amt.Cmp(amt) < 0 {
			amt.Set(c.amt)
		}
		legs = append(legs, Leg{Payer: d.id, Payee: c.id, Amount: amt})
		d.amt.Sub(d.amt, amt)
		c.amt.Sub(c.amt, amt)
		if d.amt.Sign() == 0 {
			i++
		}
		if c.amt.Sign() == 0 {
			j++
		}
	}
	return legs
}

// CheckPlan verifies a plan against the pairs the way the contract does.
func CheckPlan(pairs []Pair, legs []Leg) error {
	net := NetPositions(pairs)
	got := map[[32]byte]*big.Int{}
	for k, l := range legs {
		if l.Payer == l.Payee || l.Amount == nil || l.Amount.Sign() <= 0 {
			return fmt.Errorf("leg %d invalid", k)
		}
		for _, x := range []struct {
			id [32]byte
			s  int64
		}{{l.Payee, 1}, {l.Payer, -1}} {
			if got[x.id] == nil {
				got[x.id] = new(big.Int)
			}
			got[x.id].Add(got[x.id], new(big.Int).Mul(l.Amount, big.NewInt(x.s)))
		}
	}
	for id, v := range net {
		g := got[id]
		if g == nil {
			g = new(big.Int)
		}
		if g.Cmp(v) != 0 {
			return fmt.Errorf("member %x: plan nets %s, positions net %s", id[:8], g, v)
		}
	}
	for id, g := range got {
		if g.Sign() != 0 && net[id] == nil {
			return fmt.Errorf("member %x: in the plan but holds no position", id[:8])
		}
	}
	return nil
}

// SplitParts splits a leg into payments of at most limit (limit 0: one
// payment), largest first.
func SplitParts(amount uint64, limit uint64) []uint64 {
	if amount == 0 {
		return nil
	}
	if limit == 0 || amount <= limit {
		return []uint64{amount}
	}
	var out []uint64
	for amount > 0 {
		p := limit
		if amount < p {
			p = amount
		}
		out = append(out, p)
		amount -= p
	}
	return out
}

// RailChoice is the rail and pay-in deadline for payments instructed at a
// given time.
type RailChoice struct {
	Rail     rails.Rail
	Deadline time.Time
	Limit    uint64 // per-payment limit (0: none)
}

// ChooseRail picks CHIPS while the CHIPS session is open with at least minLeft
// before its 17:00 ET cut-off (deadline: the earlier of now + window and the
// cut-off), else RTP (deadline now + window, payments of at most $10M).
func ChooseRail(now time.Time, window, minLeft time.Duration) RailChoice {
	if day, ok := calendar.CHIPSOpen(now); ok {
		_, cutoff, _ := calendar.CHIPSSession(day)
		if cutoff.Sub(now) >= minLeft {
			dl := now.Add(window)
			if dl.After(cutoff) {
				dl = cutoff
			}
			return RailChoice{Rail: rails.CHIPS, Deadline: dl}
		}
	}
	return RailChoice{Rail: rails.RTP, Deadline: now.Add(window), Limit: rails.RTPLimit}
}

// Instruction is one entry of the pay-in schedule: part Part of leg Leg of
// batch Batch, to be paid by Payer to Payee on Rail, carrying the batch's RF
// reference and the EndToEndId CS<batch>-L<leg>-<part>.
type Instruction struct {
	Batch      uint64
	Leg        uint32
	Part       uint32
	Payer      [32]byte // a member, or COLLATERAL / POOL for waterfall payments
	Payee      [32]byte
	Amount     uint64
	Rail       rails.Rail
	Reference  string
	EndToEndID string
	Deadline   time.Time // zero for waterfall payments (no deadline after default)
	Cover      bool      // a waterfall payment
}

// Schedule turns plan legs into instructions on the chosen rail, numbering
// parts from 1 per leg.
func Schedule(batch uint64, legs []Leg, rc RailChoice) ([]Instruction, error) {
	ref, err := iso20022.BatchReference(batch)
	if err != nil {
		return nil, err
	}
	var out []Instruction
	for k, l := range legs {
		if !l.Amount.IsUint64() {
			return nil, fmt.Errorf("leg %d amount %s out of range", k, l.Amount)
		}
		for n, amt := range SplitParts(l.Amount.Uint64(), rc.Limit) {
			e2e, err := iso20022.EndToEndID(batch, uint32(k), uint32(n+1))
			if err != nil {
				return nil, err
			}
			out = append(out, Instruction{Batch: batch, Leg: uint32(k), Part: uint32(n + 1), Payer: l.Payer, Payee: l.Payee,
				Amount: amt, Rail: rc.Rail, Reference: ref, EndToEndID: e2e, Deadline: rc.Deadline})
		}
	}
	return out, nil
}
