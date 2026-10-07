package rails

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"interbank-credit-settlement/internal/calendar"
)

// Errors the rails return.
var (
	ErrClosed         = errors.New("rail closed")
	ErrUnknownAccount = errors.New("unknown account")
	ErrSameAccount    = errors.New("payer and payee are the same account")
	ErrZeroAmount     = errors.New("amount is zero")
	ErrOverLimit      = errors.New("amount over the per-payment limit")
	ErrInsufficient   = errors.New("insufficient prefunded position")
	ErrNoSuchPayment  = errors.New("no such payment")
	ErrFedwireClosed  = errors.New("Fedwire funds service closed")
)

// CHIPSFundingWindow is how long after the payment cut-off a participant has
// to fund a closing position (§5.1).
const CHIPSFundingWindow = 30 * time.Minute

// CHIPSSim simulates CHIPS: payments accepted only within a session (21:00
// ET the previous calendar day to 17:00 ET, business days), no size limit,
// each payment final at release with a sequence id
// "CHIPS-yyyymmdd-nnnnnn" (business day of the session, release number).
//
// Liquidity mechanics (opening prefunding, the release algorithm, closing
// positions) are not simulated: every accepted payment is released at once.
// Net positions per session day are tracked for reconciliation.
type CHIPSSim struct {
	clock Clock
	j     *Journal

	mu        sync.Mutex
	accounts  map[string]bool
	releases  map[string]int              // session day → releases so far
	positions map[string]map[string]int64 // session day → account → net position (6 decimals)
}

// NewCHIPS creates the simulator with its participants' accounts.
func NewCHIPS(clock Clock, accounts ...string) *CHIPSSim {
	c := &CHIPSSim{clock: clock, j: newJournal(CHIPS), accounts: map[string]bool{},
		releases: map[string]int{}, positions: map[string]map[string]int64{}}
	for _, a := range accounts {
		c.accounts[a] = true
	}
	return c
}

// Journal is the rail's journal and finality feed.
func (c *CHIPSSim) Journal() *Journal { return c.j }

// Open adds a participant account.
func (c *CHIPSSim) Open(acct string) { c.mu.Lock(); c.accounts[acct] = true; c.mu.Unlock() }

// Pay releases a payment of amount from payerAcct to payeeAcct carrying msg
// (the pacs.009/pacs.008 as sent). It is final at release.
func (c *CHIPSSim) Pay(payerAcct, payeeAcct string, amount uint64, msg []byte) (Entry, error) {
	now := c.clock.Now()
	day, open := calendar.CHIPSOpen(now)
	if !open {
		return Entry{}, fmt.Errorf("CHIPS at %s: %w", now.In(calendar.ET).Format(time.RFC3339), ErrClosed)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.checkLocked(payerAcct, payeeAcct, amount); err != nil {
		return Entry{}, err
	}
	key := day.Format("20060102")
	c.releases[key]++
	if c.positions[key] == nil {
		c.positions[key] = map[string]int64{}
	}
	c.positions[key][payerAcct] -= int64(amount)
	c.positions[key][payeeAcct] += int64(amount)
	e := Entry{
		Kind:      KindPayment,
		TxID:      fmt.Sprintf("CHIPS-%s-%06d", key, c.releases[key]),
		PayerAcct: payerAcct,
		PayeeAcct: payeeAcct,
		Amount:    amount,
		Final:     true,
		FinalAt:   now,
		PostedAt:  now,
		Message:   append([]byte(nil), msg...),
	}
	return c.j.append(e), nil
}

func (c *CHIPSSim) checkLocked(payer, payee string, amount uint64) error {
	if !c.accounts[payer] {
		return fmt.Errorf("payer %s: %w", payer, ErrUnknownAccount)
	}
	if !c.accounts[payee] {
		return fmt.Errorf("payee %s: %w", payee, ErrUnknownAccount)
	}
	if payer == payee {
		return ErrSameAccount
	}
	if amount == 0 {
		return ErrZeroAmount
	}
	return nil
}

// ClosingPositions returns the net positions of a session day (Eastern date of
// `day`), to be funded within CHIPSFundingWindow of the cut-off.
func (c *CHIPSSim) ClosingPositions(day time.Time) map[string]int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := map[string]int64{}
	for a, v := range c.positions[calendar.Date(day).Format("20060102")] {
		out[a] = v
	}
	return out
}

// CopyReference is a fault-injection hook: payerAcct sends a payment that
// carries the message (hence the RF reference and EndToEndId) of an earlier
// payment fromTxID, to the same payee and for the same amount. On the rail it
// is a genuine, final payment; it just does not pay that leg.
func (c *CHIPSSim) CopyReference(fromTxID, payerAcct string) (Entry, error) {
	orig, ok := c.j.Find(fromTxID)
	if !ok {
		return Entry{}, fmt.Errorf("%s: %w", fromTxID, ErrNoSuchPayment)
	}
	return c.Pay(payerAcct, orig.PayeeAcct, orig.Amount, orig.Message)
}
