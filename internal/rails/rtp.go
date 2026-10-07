package rails

import (
	"fmt"
	"sync"
	"time"

	"interbank-credit-settlement/internal/calendar"
)

// RTPLimit is the per-payment limit: $10,000,000 in 6-decimal units.
const RTPLimit uint64 = 10_000_000_000_000

// RTPSim simulates RTP: open 24x7; every participant has a prefunded position
// in the joint account, raised or lowered only by Fedwire transfers during
// Fedwire hours; a payment of at most RTPLimit posts against the payer's
// position, is final at posting and gets a transaction id
// "RTP-yyyymmdd-nnnnnnnn" (Eastern posting date, rail-wide counter).
//
// A camt.056 return request is recorded in the journal and changes nothing:
// a posted payment is never reversed. A return, if the payee agrees, is a new
// payment the other way.
type RTPSim struct {
	clock Clock
	j     *Journal

	mu       sync.Mutex
	position map[string]uint64 // account → prefunded position
	n        uint64
}

// NewRTP creates the simulator with its participants' accounts at zero.
func NewRTP(clock Clock, accounts ...string) *RTPSim {
	r := &RTPSim{clock: clock, j: newJournal(RTP), position: map[string]uint64{}}
	for _, a := range accounts {
		r.position[a] = 0
	}
	return r
}

// Journal is the rail's journal and finality feed.
func (r *RTPSim) Journal() *Journal { return r.j }

// Open adds a participant account with a zero position.
func (r *RTPSim) Open(acct string) {
	r.mu.Lock()
	if _, ok := r.position[acct]; !ok {
		r.position[acct] = 0
	}
	r.mu.Unlock()
}

// Position is acct's prefunded position.
func (r *RTPSim) Position(acct string) uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.position[acct]
}

func (r *RTPSim) nextIDLocked(now time.Time) string {
	r.n++
	return fmt.Sprintf("RTP-%s-%08d", now.In(calendar.ET).Format("20060102"), r.n)
}

// Fund moves amount into acct's position by a Fedwire transfer; only during
// Fedwire hours. The funding is journaled (KindFunding) for reconciliation.
func (r *RTPSim) Fund(acct string, amount uint64) (Entry, error) {
	return r.fedwire(acct, amount, true)
}

// Defund moves amount out of acct's position by a Fedwire transfer; only
// during Fedwire hours and only up to the position.
func (r *RTPSim) Defund(acct string, amount uint64) (Entry, error) {
	return r.fedwire(acct, amount, false)
}

func (r *RTPSim) fedwire(acct string, amount uint64, in bool) (Entry, error) {
	now := r.clock.Now()
	if _, ok := calendar.FedwireOpen(now); !ok {
		return Entry{}, fmt.Errorf("funding at %s: %w", now.In(calendar.ET).Format(time.RFC3339), ErrFedwireClosed)
	}
	if amount == 0 {
		return Entry{}, ErrZeroAmount
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	pos, ok := r.position[acct]
	if !ok {
		return Entry{}, fmt.Errorf("%s: %w", acct, ErrUnknownAccount)
	}
	e := Entry{Kind: KindFunding, Amount: amount, Final: true, FinalAt: now, PostedAt: now, TxID: r.nextIDLocked(now)}
	if in {
		r.position[acct] = pos + amount
		e.PayeeAcct = acct
	} else {
		if amount > pos {
			return Entry{}, ErrInsufficient
		}
		r.position[acct] = pos - amount
		e.PayerAcct = acct
	}
	return r.j.append(e), nil
}

// Pay posts a payment, final at posting.
func (r *RTPSim) Pay(payerAcct, payeeAcct string, amount uint64, msg []byte) (Entry, error) {
	now := r.clock.Now()
	r.mu.Lock()
	defer r.mu.Unlock()
	payerPos, ok := r.position[payerAcct]
	if !ok {
		return Entry{}, fmt.Errorf("payer %s: %w", payerAcct, ErrUnknownAccount)
	}
	if _, ok := r.position[payeeAcct]; !ok {
		return Entry{}, fmt.Errorf("payee %s: %w", payeeAcct, ErrUnknownAccount)
	}
	switch {
	case payerAcct == payeeAcct:
		return Entry{}, ErrSameAccount
	case amount == 0:
		return Entry{}, ErrZeroAmount
	case amount > RTPLimit:
		return Entry{}, fmt.Errorf("%d > %d: %w", amount, RTPLimit, ErrOverLimit)
	case amount > payerPos:
		return Entry{}, fmt.Errorf("%s has %d, needs %d: %w", payerAcct, payerPos, amount, ErrInsufficient)
	}
	r.position[payerAcct] -= amount
	r.position[payeeAcct] += amount
	e := Entry{
		Kind:      KindPayment,
		TxID:      r.nextIDLocked(now),
		PayerAcct: payerAcct,
		PayeeAcct: payeeAcct,
		Amount:    amount,
		Final:     true,
		FinalAt:   now,
		PostedAt:  now,
		Message:   append([]byte(nil), msg...),
	}
	return r.j.append(e), nil
}

// RequestReturn records a camt.056 request to return origTxID. It never
// reverses the posted payment and moves nothing; the entry is not a payment.
func (r *RTPSim) RequestReturn(origTxID, reason string, msg []byte) (Entry, error) {
	orig, ok := r.j.Find(origTxID)
	if !ok || orig.Kind != KindPayment {
		return Entry{}, fmt.Errorf("%s: %w", origTxID, ErrNoSuchPayment)
	}
	now := r.clock.Now()
	r.mu.Lock()
	id := r.nextIDLocked(now)
	r.mu.Unlock()
	e := Entry{
		Kind:      KindReturnRequest,
		TxID:      id,
		PayerAcct: orig.PayeeAcct, // the party asked to pay back
		PayeeAcct: orig.PayerAcct,
		Amount:    orig.Amount,
		PostedAt:  now,
		OrigTxID:  origTxID,
		Reason:    reason,
		Message:   append([]byte(nil), msg...),
	}
	return r.j.append(e), nil
}

// CopyReference is a fault-injection hook: payerAcct posts a payment that
// carries the message of an earlier payment fromTxID, to the same payee and
// for the same amount (see CHIPSSim.CopyReference).
func (r *RTPSim) CopyReference(fromTxID, payerAcct string) (Entry, error) {
	orig, ok := r.j.Find(fromTxID)
	if !ok {
		return Entry{}, fmt.Errorf("%s: %w", fromTxID, ErrNoSuchPayment)
	}
	return r.Pay(payerAcct, orig.PayeeAcct, orig.Amount, orig.Message)
}
