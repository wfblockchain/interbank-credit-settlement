package operator

import (
	"context"
	"fmt"
	"math/big"
	"sync"

	"github.com/ethereum/go-ethereum/core/types"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/rails"
)

// Participant is a party on the rails: a member bank, or the COLLATERAL /
// POOL sub-account of the central-bank joint account.
type Participant struct {
	ID        [32]byte
	BIC       string // on the ISO 20022 messages
	Name      string
	CHIPSAcct string
	RTPAcct   string
}

// Acct is the participant's account on a rail.
func (p Participant) Acct(r rails.Rail) string {
	if r == rails.CHIPS {
		return p.CHIPSAcct
	}
	return p.RTPAcct
}

func (p Participant) bank(r rails.Rail) iso20022.Bank {
	return iso20022.Bank{BIC: p.BIC, Name: p.Name, Account: p.Acct(r)}
}

// Directory maps ids to participants.
type Directory struct {
	byID map[[32]byte]Participant
}

// NewDirectory builds a directory.
func NewDirectory(ps ...Participant) *Directory {
	d := &Directory{byID: map[[32]byte]Participant{}}
	for _, p := range ps {
		d.byID[p.ID] = p
	}
	return d
}

// Get returns a participant.
func (d *Directory) Get(id [32]byte) (Participant, bool) {
	p, ok := d.byID[id]
	return p, ok
}

// All returns every participant.
func (d *Directory) All() []Participant {
	out := make([]Participant, 0, len(d.byID))
	for _, p := range d.byID {
		out = append(out, p)
	}
	return out
}

// Payer is anything the operator can instruct to pay a schedule entry.
type Payer interface {
	Instruct(ctx context.Context, in Instruction) error
}

// Sent is an instruction a payer executed on a rail.
type Sent struct {
	Instruction
	Entry rails.Entry
}

// RailPayer pays schedule entries on the rail simulators with a real
// pacs.009 (CHIPS, FI-to-FI) or pacs.008 (RTP) message. With Auto it pays as
// soon as it is instructed; otherwise instructions wait in its inbox for
// PayNext / PayAll (a slow, or defaulting, bank).
type RailPayer struct {
	Who   Participant
	Dir   *Directory
	CHIPS *rails.CHIPSSim
	RTP   *rails.RTPSim
	Clock rails.Clock
	Log   func(format string, args ...any)

	mu    sync.Mutex
	auto  bool
	inbox []Instruction
	sent  []Sent
	msgN  int
}

// NewRailPayer creates a payer that pays at once (Auto).
func NewRailPayer(who Participant, dir *Directory, chips *rails.CHIPSSim, rtp *rails.RTPSim, clock rails.Clock, log func(string, ...any)) *RailPayer {
	if log == nil {
		log = func(string, ...any) {}
	}
	return &RailPayer{Who: who, Dir: dir, CHIPS: chips, RTP: rtp, Clock: clock, Log: log, auto: true}
}

// SetAuto turns immediate payment on or off.
func (p *RailPayer) SetAuto(on bool) { p.mu.Lock(); p.auto = on; p.mu.Unlock() }

// Instruct implements Payer.
func (p *RailPayer) Instruct(ctx context.Context, in Instruction) error {
	p.mu.Lock()
	p.inbox = append(p.inbox, in)
	auto := p.auto
	p.mu.Unlock()
	if !auto {
		p.Log("%s holds instruction %s %s (not paying yet)", p.Who.Name, in.EndToEndID, money(in.Amount))
		return nil
	}
	_, err := p.PayAll()
	return err
}

// Outstanding returns the instructions not yet paid.
func (p *RailPayer) Outstanding() []Instruction {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]Instruction(nil), p.inbox...)
}

// SentPayments returns what this payer has paid.
func (p *RailPayer) SentPayments() []Sent {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]Sent(nil), p.sent...)
}

// PayAll pays every outstanding instruction in order.
func (p *RailPayer) PayAll() ([]Sent, error) {
	var out []Sent
	for {
		p.mu.Lock()
		n := len(p.inbox)
		p.mu.Unlock()
		if n == 0 {
			return out, nil
		}
		s, err := p.PayNext()
		if err != nil {
			return out, err
		}
		out = append(out, s)
	}
}

// PayNext pays the oldest outstanding instruction.
func (p *RailPayer) PayNext() (Sent, error) {
	p.mu.Lock()
	if len(p.inbox) == 0 {
		p.mu.Unlock()
		return Sent{}, fmt.Errorf("%s: nothing to pay", p.Who.Name)
	}
	in := p.inbox[0]
	p.inbox = p.inbox[1:]
	p.msgN++
	n := p.msgN
	p.mu.Unlock()

	payee, ok := p.Dir.Get(in.Payee)
	if !ok {
		return Sent{}, fmt.Errorf("payee %s not in the directory", deploy.IDString(in.Payee))
	}
	now := p.Clock.Now()
	tr := iso20022.Transfer{
		MsgID:      fmt.Sprintf("%s-%s-%04d", p.Who.BIC, now.In(calendar.ET).Format("060102150405"), n),
		CreatedAt:  now,
		SettleDate: calendar.Date(now),
		Batch:      in.Batch, Leg: in.Leg, Part: in.Part, Amount: in.Amount,
		Debtor:   p.Who.bank(in.Rail),
		Creditor: payee.bank(in.Rail),
	}
	var msg []byte
	var err error
	var e rails.Entry
	if in.Rail == rails.CHIPS {
		tr.Clearing = iso20022.ClearingCHIPS
		if msg, err = iso20022.Pacs009(tr); err == nil {
			e, err = p.CHIPS.Pay(p.Who.CHIPSAcct, payee.CHIPSAcct, in.Amount, msg)
		}
	} else {
		tr.Clearing = iso20022.ClearingRTP
		if msg, err = iso20022.Pacs008(tr); err == nil {
			e, err = p.RTP.Pay(p.Who.RTPAcct, payee.RTPAcct, in.Amount, msg)
		}
	}
	if err != nil {
		p.Log("%s FAILED to pay %s on %s: %v", p.Who.Name, in.EndToEndID, in.Rail, err)
		return Sent{}, err
	}
	kind := "pacs.008"
	if in.Rail == rails.CHIPS {
		kind = "pacs.009"
	}
	p.Log("%s pays %s %s on %s (%s, %s, ref %s) → %s", p.Who.Name, payee.Name, money(in.Amount), in.Rail, kind,
		in.EndToEndID, in.Reference, e.TxID)
	s := Sent{Instruction: in, Entry: e}
	p.mu.Lock()
	p.sent = append(p.sent, s)
	p.mu.Unlock()
	return s, nil
}

// Bank is a simulated member bank: a rail payer plus its on-chain issuerOps
// key, with which it pays customers' transfers and asks for settlement.
type Bank struct {
	*RailPayer
	Ops  chain.Account
	D    *deploy.Deployment
	refN int
}

// PayResult is the outcome of a token payment.
type PayResult struct {
	Seq      *big.Int
	Queued   bool
	Reason   uint8 // queue reason: 3 bilateral, 4 receiver cap, 5 debit cap
	CapHit   bool  // the payment emitted CapReached
	Receipt  *types.Receipt
	Ref      [32]byte
	RefLabel string
}

// Pay sends ExposureLedger.pay(to, amount, ref) from the bank's issuerOps key.
func (b *Bank) Pay(ctx context.Context, to [32]byte, amount uint64) (PayResult, error) {
	b.refN++
	label := fmt.Sprintf("%s-CUST-%04d", b.Who.BIC, b.refN)
	ref := chain.RefOf(label)
	rcpt, err := b.D.Send(ctx, b.D.Ledger, b.Ops, "pay", to, new(big.Int).SetUint64(amount), ref)
	if err != nil {
		return PayResult{}, err
	}
	res := PayResult{Receipt: rcpt, Ref: ref, RefLabel: label}
	for _, l := range rcpt.Logs {
		if l.Address != b.D.Ledger.Addr || len(l.Topics) == 0 {
			continue
		}
		switch l.Topics[0] {
		case b.D.Ledger.EventID("Paid"):
			res.Seq = new(big.Int).SetBytes(l.Topics[1][:])
		case b.D.Ledger.EventID("Queued"):
			var ev struct {
				Seq    *big.Int
				Reason uint8
			}
			if err := b.D.Ledger.Unpack(&ev, "Queued", *l); err != nil {
				return res, err
			}
			res.Seq, res.Queued, res.Reason = ev.Seq, true, ev.Reason
		case b.D.Ledger.EventID("CapReached"):
			res.CapHit = true
		}
	}
	to2, _ := b.Dir.Get(to)
	switch {
	case res.Queued:
		b.Log("%s → %s %s: QUEUED (seq %s, check %d failed)", b.Who.Name, to2.Name, money(amount), res.Seq, res.Reason)
	case res.CapHit:
		b.Log("%s → %s %s: paid (seq %s), %s mints to %s; CapReached(%s)", b.Who.Name, to2.Name, money(amount), res.Seq,
			b.Who.Name, to2.Name, to2.Name)
	default:
		b.Log("%s → %s %s: paid (seq %s), token minted to %s", b.Who.Name, to2.Name, money(amount), res.Seq, to2.Name)
	}
	return res, nil
}

// RequestSettlement is the receiver call (SettlementBatches.requestSettlement).
func (b *Bank) RequestSettlement(ctx context.Context) error {
	if _, err := b.D.Send(ctx, b.D.Batches, b.Ops, "requestSettlement"); err != nil {
		return err
	}
	b.Log("%s calls for settlement (requestSettlement)", b.Who.Name)
	return nil
}

// SetElective grants debtor an elective limit.
func (b *Bank) SetElective(ctx context.Context, debtor [32]byte, amount uint64) error {
	_, err := b.D.Send(ctx, b.D.Limits, b.Ops, "setElective", debtor, new(big.Int).SetUint64(amount))
	return err
}

// money renders a 6-decimal amount.
func money(v uint64) string { return Money(new(big.Int).SetUint64(v)) }

// Money renders a 6-decimal amount as dollars ("$12,500,000").
func Money(v *big.Int) string {
	if v == nil {
		return "$0"
	}
	neg := v.Sign() < 0
	a := new(big.Int).Abs(v)
	q, m := new(big.Int).QuoRem(a, big.NewInt(1_000_000), new(big.Int))
	s := q.String()
	var b []byte
	for i := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b = append(b, ',')
		}
		b = append(b, s[i])
	}
	out := "$" + string(b)
	if m.Sign() != 0 {
		out += fmt.Sprintf(".%02d", m.Int64()/10_000)
	}
	if neg {
		out = "-" + out
	}
	return out
}
