package operator

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/listener"
	"interbank-credit-settlement/internal/rails"
)

// Errors a cut can be refused with (Operator.LastRefusal).
var (
	// ErrHalted: a reconciliation break halted new cuts. The break is wrapped.
	ErrHalted = errors.New("operator halted by a reconciliation break")
	// ErrPoolNotReplenished: the chain refused the cut because the loss pool
	// is below the required cover-2 amount (PoolNotReplenished).
	ErrPoolNotReplenished = errors.New("loss pool not replenished")
)

// Config configures the operator.
type Config struct {
	Deployment   *deploy.Deployment
	Account      chain.Account // holds OPERATOR_ROLE on ledger, limits and batches
	Clock        rails.Clock
	Directory    *Directory
	Payers       map[[32]byte]Payer // members and the COLLATERAL / POOL joint sub-accounts
	PayInWindow  time.Duration      // deadline after the plan (default 1h; CHIPS: capped at the cut-off)
	MinCHIPSLeft time.Duration      // CHIPS only if at least this much session is left (default 15m)
	FinalizePage int                // pairs per finalize call (default 8)
	DrainMax     int                // queue entries per drain call (default 32)
	// Reconcile runs after every finalized batch and on Operator.Reconcile;
	// an error halts new cuts.
	Reconcile func(ctx context.Context) error
	Log       func(format string, args ...any)
}

// BatchRecord is the operator's record of one batch, for narration and the
// demo's summary.
type BatchRecord struct {
	Batch        uint64
	Trigger      uint8
	CutAt        time.Time
	Rail         rails.Rail
	Deadline     time.Time
	Legs         []Leg
	Instructions []Instruction
	Covers       []listener.CoverInstruction
	Defaulted    bool
	Status       uint8
	CompleteAt   time.Time
	FinalizedAt  time.Time
	Burned       *big.Int
	Drained      int

	planned, instructed, declared, coversInstructed bool
}

// Settled is the plan's total.
func (r *BatchRecord) Settled() *big.Int {
	t := new(big.Int)
	for _, l := range r.Legs {
		t.Add(t, l.Amount)
	}
	return t
}

type trigger struct {
	kind  uint8
	who   [32]byte
	block uint64
}

// Operator runs the back office. It is driven by Tick at the clock's time;
// it starts no goroutines.
type Operator struct {
	cfg Config
	d   *deploy.Deployment

	lastBlock   uint64
	triggers    []trigger
	eodDone     map[string]bool
	cur         *BatchRecord
	records     []*BatchRecord
	halted      error
	lastRefusal error
	nextPart    map[[2]uint64]uint32
}

// New creates an operator.
func New(cfg Config) *Operator {
	if cfg.PayInWindow == 0 {
		cfg.PayInWindow = time.Hour
	}
	if cfg.MinCHIPSLeft == 0 {
		cfg.MinCHIPSLeft = 15 * time.Minute
	}
	if cfg.FinalizePage == 0 {
		cfg.FinalizePage = 8
	}
	if cfg.DrainMax == 0 {
		cfg.DrainMax = 32
	}
	if cfg.Log == nil {
		cfg.Log = func(string, ...any) {}
	}
	return &Operator{cfg: cfg, d: cfg.Deployment, eodDone: map[string]bool{}, nextPart: map[[2]uint64]uint32{}}
}

func (o *Operator) log(format string, args ...any) { o.cfg.Log("operator: "+format, args...) }

// Halted is the break that halted new cuts, or nil.
func (o *Operator) Halted() error { return o.halted }

// LastRefusal is the reason the last attempted cut was refused (nil after a
// successful cut).
func (o *Operator) LastRefusal() error { return o.lastRefusal }

// Records returns every batch the operator cut.
func (o *Operator) Records() []*BatchRecord { return append([]*BatchRecord(nil), o.records...) }

// Current is the batch in flight (nil when none).
func (o *Operator) Current() *BatchRecord { return o.cur }

// PendingTriggers is the number of cut triggers waiting.
func (o *Operator) PendingTriggers() int { return len(o.triggers) }

// Reconcile runs the configured reconciliation now; a break halts new cuts.
func (o *Operator) Reconcile(ctx context.Context) error {
	if o.cfg.Reconcile == nil {
		return nil
	}
	if err := o.cfg.Reconcile(ctx); err != nil {
		if o.halted == nil {
			o.log("RECONCILIATION BREAK — halting new cuts: %v", err)
		}
		o.halted = err
		return err
	}
	return nil
}

// Tick does everything due at the clock's current time: the chain clock and
// window, new triggers, the end-of-day cut, and the batch in flight (plan,
// pay-in schedule, deadline and default, finalize, drain, reconcile). It
// returns whether anything changed.
func (o *Operator) Tick(ctx context.Context) (bool, error) {
	now := o.cfg.Clock.Now()
	if err := o.syncChainTime(ctx, now); err != nil {
		return false, err
	}
	progressed, err := o.setWindow(ctx, now)
	if err != nil {
		return progressed, err
	}
	if err := o.scanTriggers(ctx); err != nil {
		return progressed, err
	}
	if day := calendar.Date(now); calendar.IsBusinessDay(day) && !now.Before(calendar.EndOfDayCut(day)) {
		key := day.Format("2006-01-02")
		if !o.eodDone[key] {
			o.eodDone[key] = true
			o.triggers = append(o.triggers, trigger{kind: deploy.TriggerEndOfDay})
			o.log("16:30 ET end-of-day cut due for %s", key)
		}
	}
	for i := 0; i < 16; i++ {
		p, err := o.step(ctx, now)
		if err != nil {
			return progressed, err
		}
		if !p {
			break
		}
		progressed = true
	}
	return progressed, nil
}

// syncChainTime moves the chain clock up to the scenario clock (never back).
func (o *Operator) syncChainTime(ctx context.Context, now time.Time) error {
	h, err := o.d.Client.Eth.HeaderByNumber(ctx, nil)
	if err != nil {
		return err
	}
	if int64(h.Time) < now.Unix() {
		return o.d.Client.SetTime(ctx, now)
	}
	return nil
}

func (o *Operator) setWindow(ctx context.Context, now time.Time) (bool, error) {
	want := deploy.WindowOffHours
	day, business := calendar.BusinessWindowDay(now)
	if business {
		want = deploy.WindowBusiness
	}
	cur, err := o.d.Window(ctx)
	if err != nil {
		return false, err
	}
	if cur == want {
		return false, nil
	}
	if want == deploy.WindowBusiness {
		bd := uint64(day.Year()*10000 + int(day.Month())*100 + day.Day())
		if _, err := o.d.Send(ctx, o.d.Ledger, o.cfg.Account, "setBusinessDay", bd); err != nil {
			return false, err
		}
		if _, err := o.d.Send(ctx, o.d.Ledger, o.cfg.Account, "setWindow", want); err != nil {
			return false, err
		}
		o.log("window → BUSINESS for business day %d (CHIPS open; off-hours usage resets)", bd)
	} else {
		if _, err := o.d.Send(ctx, o.d.Ledger, o.cfg.Account, "setWindow", want); err != nil {
			return false, err
		}
		o.log("window → OFF_HOURS (payments only within attested RTP prefund)")
	}
	return true, nil
}

// scanTriggers reads CapReached and SettlementRequested since the last scan.
func (o *Operator) scanTriggers(ctx context.Context) error {
	head, err := o.d.Client.Head(ctx)
	if err != nil {
		return err
	}
	if head <= o.lastBlock {
		return nil
	}
	from := o.lastBlock + 1
	caps, err := o.d.Ledger.Events(ctx, "CapReached", from, head)
	if err != nil {
		return err
	}
	calls, err := o.d.Batches.Events(ctx, "SettlementRequested", from, head)
	if err != nil {
		return err
	}
	for _, l := range caps {
		var id [32]byte
		copy(id[:], l.Topics[1][:])
		o.triggers = append(o.triggers, trigger{kind: deploy.TriggerCap, who: id, block: l.BlockNumber})
		o.log("CapReached(%s) seen in block %d → cut due (CAP)", deploy.IDString(id), l.BlockNumber)
	}
	for _, l := range calls {
		var id [32]byte
		copy(id[:], l.Topics[1][:])
		o.triggers = append(o.triggers, trigger{kind: deploy.TriggerReceiverCall, who: id, block: l.BlockNumber})
		o.log("SettlementRequested(%s) seen in block %d → cut due (RECEIVER_CALL)", deploy.IDString(id), l.BlockNumber)
	}
	o.lastBlock = head
	return nil
}

// step advances the batch in flight by one stage, or cuts a new one.
func (o *Operator) step(ctx context.Context, now time.Time) (bool, error) {
	if o.cur == nil {
		return o.maybeCut(ctx, now)
	}
	r := o.cur
	bt, err := o.d.Batch(ctx, r.Batch)
	if err != nil {
		return false, err
	}
	if bt.Status != r.Status {
		o.log("batch %d is %s", r.Batch, deploy.StatusName(bt.Status))
		r.Status = bt.Status
		if bt.Status == deploy.StatusComplete && r.CompleteAt.IsZero() {
			r.CompleteAt = now
		}
	}
	switch bt.Status {
	case deploy.StatusCut:
		return true, o.plan(ctx, now, r, bt)
	case deploy.StatusPlanned, deploy.StatusPartial:
		if !r.instructed {
			r.instructed = true
			o.instruct(ctx, r.Instructions)
			return true, nil
		}
		if now.Unix() > int64(bt.Deadline) && !r.declared {
			return true, o.declare(ctx, r)
		}
		return false, nil
	case deploy.StatusDefaulting:
		if !r.coversInstructed {
			r.coversInstructed = true
			return true, o.instructCovers(ctx, now, r)
		}
		return false, nil
	case deploy.StatusComplete:
		return true, o.finish(ctx, now, r)
	}
	return false, fmt.Errorf("batch %d in unexpected status %s", r.Batch, deploy.StatusName(bt.Status))
}

func (o *Operator) maybeCut(ctx context.Context, now time.Time) (bool, error) {
	if len(o.triggers) == 0 {
		return false, nil
	}
	t := o.triggers[0]
	if o.halted != nil {
		err := fmt.Errorf("%s cut refused: %w: %v", deploy.TriggerName(t.kind), ErrHalted, o.halted)
		if o.lastRefusal == nil || o.lastRefusal.Error() != err.Error() {
			o.log("%v", err)
		}
		o.lastRefusal = err
		return false, nil
	}
	eh, err := o.d.EpochHash(ctx)
	if err != nil {
		return false, err
	}
	if eh == ([32]byte{}) {
		o.log("%s cut skipped: no payments in the open epoch", deploy.TriggerName(t.kind))
		o.triggers = nil
		return false, nil
	}
	rcpt, err := o.d.Send(ctx, o.d.Batches, o.cfg.Account, "cut", t.kind)
	if err != nil {
		if strings.Contains(err.Error(), "PoolNotReplenished") {
			err = fmt.Errorf("%s cut refused by the chain: %w (%v)", deploy.TriggerName(t.kind), ErrPoolNotReplenished, err)
		} else {
			err = fmt.Errorf("%s cut refused by the chain: %w", deploy.TriggerName(t.kind), err)
		}
		if o.lastRefusal == nil || o.lastRefusal.Error() != err.Error() {
			o.log("%v", err)
		}
		o.lastRefusal = err
		return false, nil
	}
	o.lastRefusal = nil
	o.triggers = nil
	var b, epoch uint64
	for _, l := range rcpt.Logs {
		if l.Address == o.d.Batches.Addr && len(l.Topics) > 2 && l.Topics[0] == o.d.Batches.EventID("BatchCut") {
			b = new(big.Int).SetBytes(l.Topics[1][:]).Uint64()
			epoch = new(big.Int).SetBytes(l.Topics[2][:]).Uint64()
		}
	}
	if b == 0 {
		return false, errors.New("cut: no BatchCut event")
	}
	o.cur = &BatchRecord{Batch: b, Trigger: t.kind, CutAt: now, Status: deploy.StatusCut}
	o.records = append(o.records, o.cur)
	o.log("cut(%s) → BatchCut(batch %d, epoch %d): open positions moved to pending", deploy.TriggerName(t.kind), b, epoch)
	return true, nil
}

// plan builds the multilateral net plan from the batch's pending pairs and
// submits it with the pay-in deadline.
func (o *Operator) plan(ctx context.Context, now time.Time, r *BatchRecord, bt deploy.BatchView) error {
	pv, err := o.d.PendingPairs(ctx, bt.Epoch)
	if err != nil {
		return err
	}
	pairs := make([]Pair, len(pv))
	for k, p := range pv {
		pairs[k] = Pair{Issuer: p.Issuer, Holder: p.Holder, Amount: p.Amount}
		o.log("  batch %d pair: %s holds %s of %s's token", r.Batch, deploy.IDString(p.Holder), Money(p.Amount), deploy.IDString(p.Issuer))
	}
	legs := BuildPlan(pairs)
	if err := CheckPlan(pairs, legs); err != nil {
		return fmt.Errorf("plan builder: %w", err)
	}
	rc := ChooseRail(now, o.cfg.PayInWindow, o.cfg.MinCHIPSLeft)
	type abiLeg struct {
		Payer  [32]byte
		Payee  [32]byte
		Amount *big.Int
		Paid   *big.Int
	}
	var al []abiLeg
	for _, l := range legs {
		al = append(al, abiLeg{Payer: l.Payer, Payee: l.Payee, Amount: l.Amount, Paid: new(big.Int)})
	}
	if _, err := o.d.Send(ctx, o.d.Batches, o.cfg.Account, "submitPlan", r.Batch, al, uint64(rc.Deadline.Unix())); err != nil {
		return err
	}
	ins, err := Schedule(r.Batch, legs, rc)
	if err != nil {
		return err
	}
	// The RF reference the banks will quote must be the contract's.
	out, err := o.d.Batches.Call(ctx, "rfReference", r.Batch)
	if err != nil {
		return err
	}
	if want, _ := iso20022.BatchReference(r.Batch); out[0].(string) != want {
		return fmt.Errorf("batch %d: chain reference %q, iso20022 reference %q", r.Batch, out[0], want)
	}
	r.Legs, r.Rail, r.Deadline, r.Instructions, r.planned = legs, rc.Rail, rc.Deadline, ins, true
	for _, in := range ins {
		k := [2]uint64{in.Batch, uint64(in.Leg)}
		if in.Part > o.nextPart[k] {
			o.nextPart[k] = in.Part
		}
	}
	o.log("submitPlan(batch %d): %d leg(s) on %s, deadline %s, reference %s", r.Batch, len(legs), rc.Rail,
		rc.Deadline.In(calendar.ET).Format("Mon 15:04 MST"), out[0])
	for k, l := range legs {
		o.log("  leg %d: %s pays %s %s", k, deploy.IDString(l.Payer), deploy.IDString(l.Payee), Money(l.Amount))
	}
	if len(ins) > len(legs) {
		o.log("  pay-in schedule: %d payments (RTP, ≤ $10M each)", len(ins))
	}
	return nil
}

func (o *Operator) instruct(ctx context.Context, ins []Instruction) {
	for _, in := range ins {
		p, ok := o.cfg.Payers[in.Payer]
		if !ok {
			o.log("no payer for %s; %s not instructed", deploy.IDString(in.Payer), in.EndToEndID)
			continue
		}
		if err := p.Instruct(ctx, in); err != nil {
			o.log("instruction %s to %s failed: %v", in.EndToEndID, deploy.IDString(in.Payer), err)
		}
	}
}

// declare calls DefaultManager.declare after the deadline.
func (o *Operator) declare(ctx context.Context, r *BatchRecord) error {
	r.declared = true
	legs, err := o.d.Legs(ctx, r.Batch)
	if err != nil {
		return err
	}
	for k, l := range legs {
		if l.Paid.Cmp(l.Amount) < 0 {
			o.log("deadline passed: batch %d leg %d (%s → %s) paid %s of %s", r.Batch, k, deploy.IDString(l.Payer),
				deploy.IDString(l.Payee), Money(l.Paid), Money(l.Amount))
		}
	}
	if _, err := o.d.Send(ctx, o.d.DefaultManager, o.cfg.Account, "declare", r.Batch); err != nil {
		return err
	}
	r.Defaulted = true
	o.log("DefaultManager.declare(batch %d): unpaid payers marked DEFAULTED, waterfall allocated", r.Batch)
	return nil
}

// instructCovers turns CoverInstruction events into waterfall payments:
// COLLATERAL and POOL pay from the joint account, survivors pay their share;
// the leg payee's own share is absorbed on chain and not paid.
func (o *Operator) instructCovers(ctx context.Context, now time.Time, r *BatchRecord) error {
	cis, err := listener.CoverInstructions(ctx, o.d, r.Batch)
	if err != nil {
		return err
	}
	r.Covers = cis
	legs, err := o.d.Legs(ctx, r.Batch)
	if err != nil {
		return err
	}
	ref, err := iso20022.BatchReference(r.Batch)
	if err != nil {
		return err
	}
	rc := ChooseRail(now, o.cfg.PayInWindow, o.cfg.MinCHIPSLeft)
	var ins []Instruction
	for _, c := range cis {
		l := legs[c.Leg]
		if c.Source == l.Payee {
			o.log("  cover leg %d: %s absorbs its own share %s", c.Leg, deploy.IDString(c.Source), Money(c.Amount))
			continue
		}
		o.log("  cover leg %d: %s pays %s %s", c.Leg, deploy.IDString(c.Source), deploy.IDString(l.Payee), Money(c.Amount))
		k := [2]uint64{r.Batch, uint64(c.Leg)}
		for _, amt := range SplitParts(c.Amount.Uint64(), rc.Limit) {
			o.nextPart[k]++
			e2e, err := iso20022.EndToEndID(r.Batch, c.Leg, o.nextPart[k])
			if err != nil {
				return err
			}
			ins = append(ins, Instruction{Batch: r.Batch, Leg: c.Leg, Part: o.nextPart[k], Payer: c.Source, Payee: l.Payee,
				Amount: amt, Rail: rc.Rail, Reference: ref, EndToEndID: e2e, Cover: true})
		}
	}
	r.Instructions = append(r.Instructions, ins...)
	o.instruct(ctx, ins)
	return nil
}

// finish finalizes a COMPLETE batch page by page, drains the queue and
// reconciles.
func (o *Operator) finish(ctx context.Context, now time.Time, r *BatchRecord) error {
	for {
		bt, err := o.d.Batch(ctx, r.Batch)
		if err != nil {
			return err
		}
		if bt.Finalized {
			r.Burned = bt.Burned
			break
		}
		if _, err := o.d.Send(ctx, o.d.Batches, o.cfg.Account, "finalize", r.Batch, big.NewInt(int64(o.cfg.FinalizePage))); err != nil {
			return err
		}
	}
	r.FinalizedAt = now
	o.log("finalize(batch %d): %s of deposit tokens burned, exposure released", r.Batch, Money(r.Burned))
	o.cur = nil
	if err := o.drain(ctx, r); err != nil {
		return err
	}
	if err := o.Reconcile(ctx); err != nil {
		return nil // halted; recorded
	}
	if o.cfg.Reconcile != nil {
		o.log("reconciliation clean (rail journals ↔ listener log ↔ chain)")
	}
	return nil
}

func (o *Operator) drain(ctx context.Context, r *BatchRecord) error {
	head, err := o.d.Ledger.BigInt(ctx, "queueHead")
	if err != nil {
		return err
	}
	n, err := o.d.Ledger.BigInt(ctx, "queueLength")
	if err != nil {
		return err
	}
	if head.Cmp(n) >= 0 {
		return nil
	}
	rcpt, err := o.d.Send(ctx, o.d.Ledger, o.cfg.Account, "drain", big.NewInt(int64(o.cfg.DrainMax)))
	if err != nil {
		return err
	}
	for _, l := range rcpt.Logs {
		if l.Address == o.d.Ledger.Addr && len(l.Topics) > 0 && l.Topics[0] == o.d.Ledger.EventID("Paid") {
			r.Drained++
		}
	}
	o.log("drain: %d queued payment(s) executed", r.Drained)
	return nil
}
