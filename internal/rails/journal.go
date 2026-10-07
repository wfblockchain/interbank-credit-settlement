// Package rails holds deterministic simulators of the two fiat rails the model
// settles over (§5.1 of docs/design.md): CHIPS (weekday sessions, final at
// release, no size limit) and RTP (24x7, prefunded, $10M per payment, final at
// posting). Each rail writes an append-only journal and exposes a finality
// feed, which is the settlement listener's only input.
//
// The simulators take their time from a Clock, so a scenario controls the
// calendar exactly; nothing here reads the wall clock.
package rails

import (
	"fmt"
	"sync"
	"time"
)

// Rail identifies a rail; the values are the `rail` field of the attested
// Payment (§3.6).
type Rail uint8

const (
	CHIPS Rail = 1
	RTP   Rail = 2
)

func (r Rail) String() string {
	switch r {
	case CHIPS:
		return "CHIPS"
	case RTP:
		return "RTP"
	}
	return fmt.Sprintf("Rail(%d)", uint8(r))
}

// Kind is the kind of a journal entry.
type Kind uint8

const (
	// KindPayment is a payment released (CHIPS) or posted (RTP).
	KindPayment Kind = iota + 1
	// KindReturnRequest is a camt.056 request to return a posted payment. It
	// is a request only: it never reverses anything.
	KindReturnRequest
	// KindFunding is a Fedwire funding (or defunding) of an RTP prefunded
	// position.
	KindFunding
)

func (k Kind) String() string {
	switch k {
	case KindPayment:
		return "PAYMENT"
	case KindReturnRequest:
		return "RETURN_REQUEST"
	case KindFunding:
		return "FUNDING"
	}
	return fmt.Sprintf("Kind(%d)", uint8(k))
}

// Entry is one journal record. Entries are values: the journal never changes
// one after appending it.
type Entry struct {
	Seq       uint64 // 1-based position in the rail's journal
	Rail      Rail
	Kind      Kind
	TxID      string // the rail's own identifier (CHIPS release sequence, RTP transaction id)
	PayerAcct string
	PayeeAcct string
	Amount    uint64 // 6 decimals
	Final     bool
	FinalAt   time.Time // zero unless Final
	PostedAt  time.Time
	OrigTxID  string // KindReturnRequest: the payment whose return is requested
	Reason    string // KindReturnRequest: the requester's reason code
	Message   []byte // the ISO 20022 message the payment carried, as received
}

// Clock is the simulators' only source of time.
type Clock interface{ Now() time.Time }

// ManualClock is a Clock a test or scenario moves by hand.
type ManualClock struct {
	mu sync.Mutex
	t  time.Time
}

// NewManualClock starts a clock at t.
func NewManualClock(t time.Time) *ManualClock { return &ManualClock{t: t} }

// Now returns the clock's time.
func (c *ManualClock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }

// Set moves the clock to t.
func (c *ManualClock) Set(t time.Time) { c.mu.Lock(); c.t = t; c.mu.Unlock() }

// Advance moves the clock forward by d.
func (c *ManualClock) Advance(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

// Journal is a rail's append-only record and its finality feed.
//
// The record (Entries) is the rail's book of what happened, in order. The
// feed is the delivery stream readers consume by cursor; it normally carries
// each entry once, in order, but the fault-injection hooks can delay an
// entry's delivery, deliver it twice, or deliver an entry that is not final,
// so the listener can be tested against an imperfect transport.
type Journal struct {
	rail Rail

	mu        sync.Mutex
	entries   []Entry
	feed      []Entry
	delayNext int
	held      map[string]Entry
	changed   chan struct{}
}

func newJournal(r Rail) *Journal {
	return &Journal{rail: r, held: map[string]Entry{}, changed: make(chan struct{})}
}

// append records e (assigning Seq) and delivers it unless a delay is armed.
func (j *Journal) append(e Entry) Entry {
	j.mu.Lock()
	defer j.mu.Unlock()
	e.Rail = j.rail
	e.Seq = uint64(len(j.entries)) + 1
	j.entries = append(j.entries, e)
	if j.delayNext > 0 {
		j.delayNext--
		j.held[e.TxID] = e
		return e
	}
	j.deliverLocked(e)
	return e
}

func (j *Journal) deliverLocked(e Entry) {
	j.feed = append(j.feed, e)
	close(j.changed)
	j.changed = make(chan struct{})
}

// Entries returns a copy of the record.
func (j *Journal) Entries() []Entry {
	j.mu.Lock()
	defer j.mu.Unlock()
	return append([]Entry(nil), j.entries...)
}

// Find returns the recorded entry with TxID id.
func (j *Journal) Find(id string) (Entry, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	for _, e := range j.entries {
		if e.TxID == id {
			return e, true
		}
	}
	return Entry{}, false
}

// Read is the finality feed, polled by cursor: it returns the deliveries
// from position `cursor` (0-based) on and the cursor to pass next time. Each
// reader keeps its own cursor.
func (j *Journal) Read(cursor uint64) ([]Entry, uint64) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if cursor >= uint64(len(j.feed)) {
		return nil, uint64(len(j.feed))
	}
	return append([]Entry(nil), j.feed[cursor:]...), uint64(len(j.feed))
}

// Changed returns a channel closed at the next delivery, for readers that
// would rather wait than poll.
func (j *Journal) Changed() <-chan struct{} {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.changed
}

// --- Fault injection (tests and scenarios only) ---

// DelayNext holds the delivery of the next n appended entries until Release.
// They are in the record at once; only the feed is late.
func (j *Journal) DelayNext(n int) {
	j.mu.Lock()
	j.delayNext += n
	j.mu.Unlock()
}

// Release delivers a held entry now (out of order relative to the record).
func (j *Journal) Release(txID string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	e, ok := j.held[txID]
	if !ok {
		return fmt.Errorf("%s: %s is not held", j.rail, txID)
	}
	delete(j.held, txID)
	j.deliverLocked(e)
	return nil
}

// Redeliver delivers a recorded entry again: a duplicate delivery.
func (j *Journal) Redeliver(txID string) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	for _, e := range j.entries {
		if e.TxID == txID {
			j.deliverLocked(e)
			return nil
		}
	}
	return fmt.Errorf("%s: no entry %s", j.rail, txID)
}

// DeliverNonFinal delivers a payment that the rail has accepted but not yet
// released or posted (e.g. a CHIPS payment still queued). It is not in the
// record, because the rail has not settled it.
func (j *Journal) DeliverNonFinal(e Entry) {
	j.mu.Lock()
	defer j.mu.Unlock()
	e.Rail, e.Kind, e.Final, e.FinalAt = j.rail, KindPayment, false, time.Time{}
	j.deliverLocked(e)
}
