package listener

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/rails"
)

// RunnerConfig configures the listener: n signer processes, a k-of-n
// aggregator and the submitter that calls SettlementAttestor.
type RunnerConfig struct {
	Deployment *deploy.Deployment
	Submitter  chain.Account // pays gas for attestPayment / attestFunding (anyone may call)
	Keys       []*ecdsa.PrivateKey
	Book       Book
	Feeds      map[rails.Rail]Feed
	Funding    FundingSource // each signer's view of the joint account and RTP positions
	Log        func(format string, args ...any)
}

// Submission is one entry of the listener's signed log: a payment k signers
// agreed on and the outcome of submitting it.
type Submission struct {
	RailTxID string // the rail's own id (CHIPS release sequence, RTP transaction id)
	Payment  Payment
	Signers  []common.Address
	TxHash   common.Hash
	Block    uint64
	Err      error // nil: recorded on chain
}

// Runner runs the listener's signer processes. Each signer is a goroutine
// with its own key, its own journal cursors and its own memory of what it
// signed; a signer wakes on a feed delivery, on a timer, or on Sync.
type Runner struct {
	cfg     RunnerConfig
	domain  Domain
	k       int
	signers []*Signer
	agg     *Aggregator

	subMu sync.Mutex // serialises submissions (one submitter key)
	logMu sync.Mutex
	log   []Submission

	kicks   []chan chan struct{}
	stop    context.CancelFunc
	wg      sync.WaitGroup
	started bool

	fundMu    sync.Mutex
	nextNonce uint64
	lastAsOf  map[[33]byte]uint64
}

// NewRunner builds the signers and checks them against the chain: each key
// must be a current signer of the attestor, the threshold is read from it, and
// the Go EIP-712 digest must equal SettlementAttestor.paymentDigest.
func NewRunner(ctx context.Context, cfg RunnerConfig) (*Runner, error) {
	d := cfg.Deployment
	if cfg.Log == nil {
		cfg.Log = func(string, ...any) {}
	}
	th, err := d.Attestor.BigInt(ctx, "threshold")
	if err != nil {
		return nil, err
	}
	dom := Domain{ChainID: d.Client.ChainID, VerifyingContract: d.Attestor.Addr}
	r := &Runner{cfg: cfg, domain: dom, k: int(th.Int64()), lastAsOf: map[[33]byte]uint64{}, nextNonce: 1}
	var addrs []common.Address
	for _, key := range cfg.Keys {
		s := NewSigner(key, dom, cfg.Book, cfg.Feeds)
		ok, err := d.Attestor.Bool(ctx, "isSigner", s.Address())
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, fmt.Errorf("listener key %s is not a signer of the attestor", s.Address())
		}
		r.signers = append(r.signers, s)
		addrs = append(addrs, s.Address())
	}
	if r.k > len(r.signers) {
		return nil, fmt.Errorf("threshold %d above the %d signer processes", r.k, len(r.signers))
	}
	if r.agg, err = NewAggregator(dom, r.k, addrs); err != nil {
		return nil, err
	}
	// The ABI and digest the Go side uses must be the contract's.
	probe := Payment{Batch: 1, Leg: 2, Rail: 2, RailTxID: RailTxHash("probe"), PayerAcct: common.HexToAddress("0x01"),
		Payer: MemberID("PROBE"), Payee: MemberID("PROBE2"), Amount: big.NewInt(3), FinalAt: 4}
	out, err := d.Attestor.Call(ctx, "paymentDigest", toABI(probe))
	if err != nil {
		return nil, err
	}
	want, err := Digest(dom, probe)
	if err != nil {
		return nil, err
	}
	if common.Hash(out[0].([32]byte)) != want {
		return nil, fmt.Errorf("EIP-712 mismatch: contract digest %x, Go digest %s", out[0], want)
	}
	f := Funding{Kind: 1, Member: MemberID("PROBE"), Value: big.NewInt(5), AsOf: 6, Nonce: 7}
	out, err = d.Attestor.Call(ctx, "fundingDigest", abiFunding(f))
	if err != nil {
		return nil, err
	}
	if fw, _ := FundingDigest(dom, f); common.Hash(out[0].([32]byte)) != fw {
		return nil, fmt.Errorf("EIP-712 funding mismatch: contract %x, Go %s", out[0], fw)
	}
	return r, nil
}

func toABI(p Payment) abiPayment {
	return abiPayment{Batch: p.Batch, Leg: p.Leg, Rail: p.Rail, RailTxId: p.RailTxID, PayerAcct: p.PayerAcct,
		Payer: p.Payer, Payee: p.Payee, Amount: p.Amount, FinalAt: p.FinalAt}
}

// Signers returns the signer processes (for inspection).
func (r *Runner) Signers() []*Signer { return r.signers }

// Domain is the attestor's EIP-712 domain.
func (r *Runner) Domain() Domain { return r.domain }

// K is the threshold.
func (r *Runner) K() int { return r.k }

// Start launches one goroutine per signer.
func (r *Runner) Start(ctx context.Context) {
	if r.started {
		return
	}
	r.started = true
	ctx, r.stop = context.WithCancel(ctx)
	for i, s := range r.signers {
		kick := make(chan chan struct{})
		r.kicks = append(r.kicks, kick)
		r.wg.Add(1)
		go r.loop(ctx, i, s, kick)
	}
}

// Stop ends the signer processes.
func (r *Runner) Stop() {
	if r.stop != nil {
		r.stop()
	}
	r.wg.Wait()
}

type changer interface{ Changed() <-chan struct{} }

func (r *Runner) loop(ctx context.Context, i int, s *Signer, kick chan chan struct{}) {
	defer r.wg.Done()
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		var chipsC, rtpC <-chan struct{}
		if c, ok := r.cfg.Feeds[rails.CHIPS].(changer); ok {
			chipsC = c.Changed()
		}
		if c, ok := r.cfg.Feeds[rails.RTP].(changer); ok {
			rtpC = c.Changed()
		}
		var ack chan struct{}
		select {
		case <-ctx.Done():
			return
		case ack = <-kick:
		case <-chipsC:
		case <-rtpC:
		case <-tick.C:
		}
		for _, a := range s.Poll() {
			r.collect(ctx, a)
		}
		if ack != nil {
			close(ack)
		}
	}
}

// Sync makes every signer poll its feeds now and returns when each has
// processed everything delivered before the call, including any submission
// its signatures completed.
func (r *Runner) Sync(ctx context.Context) error {
	if !r.started {
		return errors.New("listener not started")
	}
	acks := make([]chan struct{}, len(r.kicks))
	for i, k := range r.kicks {
		acks[i] = make(chan struct{})
		select {
		case k <- acks[i]:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	for _, a := range acks {
		select {
		case <-a:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// collect hands one attestation to the aggregator and submits the call once
// k signers agree.
func (r *Runner) collect(ctx context.Context, a Attestation) {
	call, err := r.agg.Add(a)
	if err != nil {
		r.cfg.Log("listener: attestation by %s refused: %v", short(a.Signer), err)
		return
	}
	if call == nil {
		return
	}
	r.submit(ctx, a.TxID, call)
}

func (r *Runner) submit(ctx context.Context, txID string, call *Call) {
	r.subMu.Lock()
	defer r.subMu.Unlock()
	sub := Submission{RailTxID: txID, Payment: call.Payment, Signers: call.Signers}
	rcpt, err := r.cfg.Deployment.Send(ctx, r.cfg.Deployment.Attestor, r.cfg.Submitter, "attestPayment", toABI(call.Payment), call.Sigs)
	if rcpt != nil {
		sub.TxHash, sub.Block = rcpt.TxHash, rcpt.BlockNumber.Uint64()
	}
	sub.Err = err
	p := call.Payment
	if err != nil {
		r.cfg.Log("listener: attestPayment %s (batch %d leg %d) FAILED: %v", txID, p.Batch, p.Leg, err)
	} else {
		r.cfg.Log("listener: %d-of-%d attested %s: batch %d leg %d, %s pays %s %s (rail %s)", len(call.Sigs), len(r.signers),
			txID, p.Batch, p.Leg, deploy.IDString(p.Payer), deploy.IDString(p.Payee), usd(p.Amount), rails.Rail(p.Rail))
	}
	r.logMu.Lock()
	r.log = append(r.log, sub)
	r.logMu.Unlock()
}

// Log returns the listener's signed log.
func (r *Runner) Log() []Submission {
	r.logMu.Lock()
	defer r.logMu.Unlock()
	return append([]Submission(nil), r.log...)
}

// ManualReview returns, per signer, the entries it refused to sign.
func (r *Runner) ManualReview() [][]Review {
	out := make([][]Review, len(r.signers))
	for i, s := range r.signers {
		out[i] = s.ManualReview()
	}
	return out
}

// Reviewed returns the rail transaction ids that are in manual review at
// some signer or whose submission failed: payments the listener has
// accounted for without attesting.
func (r *Runner) Reviewed() map[string]bool {
	out := map[string]bool{}
	for _, s := range r.signers {
		for _, rv := range s.ManualReview() {
			out[rv.Entry.TxID] = true
		}
	}
	for _, sub := range r.Log() {
		if sub.Err != nil {
			out[sub.RailTxID] = true
		}
	}
	return out
}

// AttestFunding has the signers check f against their funding source and,
// with k agreeing signatures, submits SettlementAttestor.attestFunding. Zero
// AsOf and Nonce are filled in: AsOf strictly increasing per (kind, member)
// from `now`, Nonce the next unused.
func (r *Runner) AttestFunding(ctx context.Context, f Funding, now time.Time) error {
	r.fundMu.Lock()
	defer r.fundMu.Unlock()
	var key [33]byte
	key[0] = f.Kind
	copy(key[1:], f.Member[:])
	if f.AsOf == 0 {
		f.AsOf = uint64(now.Unix())
		if last := r.lastAsOf[key]; f.AsOf <= last {
			f.AsOf = last + 1
		}
		out, err := r.cfg.Deployment.Register.Call(ctx, "lastAsOf", f.Kind, f.Member)
		if err != nil {
			return err
		}
		onChain, err := deploy.Decode[uint64](out[0])
		if err != nil {
			return err
		}
		if f.AsOf <= onChain {
			f.AsOf = onChain + 1
		}
	}
	if f.Nonce == 0 {
		for {
			used, err := r.cfg.Deployment.Attestor.Bool(ctx, "usedFundingNonce", r.nextNonce)
			if err != nil {
				return err
			}
			if !used {
				break
			}
			r.nextNonce++
		}
		f.Nonce = r.nextNonce
		r.nextNonce++
	}
	type sig struct {
		who common.Address
		s   []byte
	}
	var sigs []sig
	for _, s := range r.signers {
		_, sg, err := s.SignFunding(r.domain, f, r.cfg.Funding)
		if err != nil {
			r.cfg.Log("listener: %s refuses funding: %v", short(s.Address()), err)
			continue
		}
		sigs = append(sigs, sig{s.Address(), sg})
	}
	if len(sigs) < r.k {
		return fmt.Errorf("funding kind %d %s: %d of %d signers agree: %w", f.Kind, deploy.IDString(f.Member), len(sigs), r.k, ErrNotEnough)
	}
	sort.Slice(sigs, func(i, j int) bool { return bytes.Compare(sigs[i].who[:], sigs[j].who[:]) < 0 })
	var raw [][]byte
	for _, s := range sigs[:r.k] {
		raw = append(raw, s.s)
	}
	r.subMu.Lock()
	_, err := r.cfg.Deployment.Send(ctx, r.cfg.Deployment.Attestor, r.cfg.Submitter, "attestFunding", abiFunding(f), raw)
	r.subMu.Unlock()
	if err != nil {
		return err
	}
	r.lastAsOf[key] = f.AsOf
	r.cfg.Log("listener: %d-of-%d attested funding %s %s = %s", r.k, len(r.signers), fundingKindName(f.Kind), memberOrNetwork(f.Member), usd(f.Value))
	return nil
}

func fundingKindName(k uint8) string {
	switch k {
	case deploy.KindCollateral:
		return "COLLATERAL"
	case deploy.KindPool:
		return "POOL"
	case deploy.KindRTPPrefund:
		return "RTP_PREFUND"
	case deploy.KindPoolRequired:
		return "POOL_REQUIRED"
	}
	return fmt.Sprintf("Kind(%d)", k)
}

func memberOrNetwork(id [32]byte) string {
	if id == ([32]byte{}) {
		return "(network)"
	}
	return deploy.IDString(id)
}

func short(a common.Address) string { return a.Hex()[:10] }

// usd renders a 6-decimal amount as dollars.
func usd(v *big.Int) string {
	if v == nil {
		return "$?"
	}
	q, m := new(big.Int).QuoRem(v, big.NewInt(1_000_000), new(big.Int))
	s := commas(q.String())
	if m.Sign() != 0 {
		return fmt.Sprintf("$%s.%06d", s, m.Int64())
	}
	return "$" + s
}

func commas(s string) string {
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg, s = true, s[1:]
	}
	var b []byte
	for i := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b = append(b, ',')
		}
		b = append(b, s[i])
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}

// KeyFromSeed derives a deterministic test key (keccak256 of the seed).
func KeyFromSeed(seed string) *ecdsa.PrivateKey {
	k, err := crypto.ToECDSA(crypto.Keccak256([]byte(seed)))
	if err != nil {
		panic(err)
	}
	return k
}
