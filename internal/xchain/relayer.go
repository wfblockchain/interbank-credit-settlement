package xchain

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
)

// Outcome is what became of a relayed message.
type Outcome int

const (
	// Delivered: receiveMessage succeeded (a MINT may still have been refused
	// by the destination, which then answers MINT_CANCEL).
	Delivered Outcome = iota + 1
	// AlreadyDelivered: the destination had consumed the nonce; nothing sent.
	AlreadyDelivered
	// Expired: a MINT past its deadline was cancelled at the destination.
	Expired
	// RateLimited: the destination's inbound bucket is short; retried later.
	RateLimited
	// IssuerRefused: the issuing bank's signer would not co-sign the MINT.
	IssuerRefused
	// Failed: the destination refused the message for another reason.
	Failed
)

func (o Outcome) String() string {
	switch o {
	case Delivered:
		return "delivered"
	case AlreadyDelivered:
		return "already delivered (skipped)"
	case Expired:
		return "cancelled after its deadline"
	case RateLimited:
		return "rate limited (will retry)"
	case IssuerRefused:
		return "issuer refused to co-sign"
	case Failed:
		return "refused by the destination"
	}
	return fmt.Sprintf("Outcome(%d)", int(o))
}

// Delivery is one relay attempt.
type Delivery struct {
	Envelope Envelope
	Outcome  Outcome
	Err      error
	Signers  []common.Address // attesters whose signatures were submitted
	Issuer   bool             // the issuer's signature was submitted
	Tx       common.Hash
	Block    uint64
}

// CoSigner is a bank's MINT co-signer.
type CoSigner interface {
	Member() [32]byte
	CoSign(ctx context.Context, message []byte) ([]byte, error)
}

// RelayerConfig configures the relayer.
type RelayerConfig struct {
	Domains   []Domain
	Artifacts string           // Foundry artifacts, for the messenger ABIs and revert names
	Account   chain.Account    // pays gas on every chain; holds no role
	Attesters []common.Address // the attester set the messengers enforce
	Threshold int
	Issuers   []CoSigner
	Log       func(format string, args ...any)
}

type item struct {
	env      Envelope
	msg      []byte
	sigs     map[common.Address][]byte
	done     bool
	attempts int
	lastErr  error
}

// Relayer carries attested messages. It is untrusted: it can delay or drop a
// message but cannot forge, alter or replay one.
type Relayer struct {
	cfg        RelayerConfig
	domains    map[uint32]Domain
	clients    map[uint32]*chain.Client
	messengers map[uint32]*chain.Contract
	attesters  map[common.Address]bool
	issuers    map[[32]byte]CoSigner

	mu    sync.Mutex
	items map[MsgID]map[common.Hash]*item
	log   []Delivery
	held  map[uint32]bool
}

// NewRelayer dials the relayer's own connection to every domain.
func NewRelayer(ctx context.Context, cfg RelayerConfig) (*Relayer, error) {
	if cfg.Log == nil {
		cfg.Log = func(string, ...any) {}
	}
	if cfg.Threshold <= 0 || cfg.Threshold*2 <= len(cfg.Attesters) {
		return nil, fmt.Errorf("relayer: threshold %d is not a strict majority of %d attesters", cfg.Threshold, len(cfg.Attesters))
	}
	r := &Relayer{cfg: cfg, domains: map[uint32]Domain{}, clients: map[uint32]*chain.Client{}, messengers: map[uint32]*chain.Contract{},
		attesters: map[common.Address]bool{}, issuers: map[[32]byte]CoSigner{}, items: map[MsgID]map[common.Hash]*item{},
		held: map[uint32]bool{}}
	for _, a := range cfg.Attesters {
		r.attesters[a] = true
	}
	for _, s := range cfg.Issuers {
		r.issuers[s.Member()] = s
	}
	for _, d := range cfg.Domains {
		c, err := chain.Dial(ctx, d.URL, cfg.Artifacts)
		if err != nil {
			return nil, fmt.Errorf("relayer: domain %d: %w", d.ID, err)
		}
		if d.ChainID != nil && c.ChainID.Cmp(d.ChainID) != 0 {
			return nil, fmt.Errorf("relayer: domain %d node reports chain id %s, want %s", d.ID, c.ChainID, d.ChainID)
		}
		// Load every ABI whose custom errors can surface, for readable reverts.
		for _, n := range []string{"HubMessenger", "SpokeExposureGuard", "ExposureLedger", "RemoteObligationToken", "ObligationToken"} {
			if _, err := c.At(n, common.Address{}); err != nil {
				return nil, err
			}
		}
		name := "SpokeMessenger"
		if d.Home {
			name = "HubMessenger"
		}
		m, err := c.At(name, d.Messenger)
		if err != nil {
			return nil, err
		}
		r.domains[d.ID], r.clients[d.ID], r.messengers[d.ID] = d, c, m
	}
	return r, nil
}

func (r *Relayer) name(d uint32) string {
	if n := r.domains[d].Name; n != "" {
		return n
	}
	return fmt.Sprintf("domain %d", d)
}

// Hold stops (or resumes) deliveries to a domain: a transport outage.
func (r *Relayer) Hold(dest uint32, on bool) {
	r.mu.Lock()
	r.held[dest] = on
	r.mu.Unlock()
}

// Log is every delivery attempt so far.
func (r *Relayer) Log() []Delivery {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Delivery(nil), r.log...)
}

// Pending is a message not yet delivered, with its signature count.
type Pending struct {
	Envelope Envelope
	Message  []byte
	Signers  int
	Attempts int
	LastErr  error
}

// Pending lists every message not delivered (yet), in (source, nonce) order.
func (r *Relayer) Pending() []Pending {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []Pending
	for _, it := range r.sorted() {
		if !it.done {
			out = append(out, Pending{Envelope: it.env, Message: it.msg, Signers: len(it.sigs), Attempts: it.attempts, LastErr: it.lastErr})
		}
	}
	return out
}

// Collect accepts one attester's signature after checking it is a member of
// the set and signed exactly this message for its source and destination.
func (r *Relayer) Collect(a Attestation) error {
	if !r.attesters[a.Attester] {
		return fmt.Errorf("relayer: %s is not an attester", a.Attester)
	}
	e, err := DecodeEnvelope(a.Message)
	if err != nil {
		return err
	}
	src, ok1 := r.domains[e.Source]
	dst, ok2 := r.domains[e.Dest]
	if !ok1 || !ok2 {
		return fmt.Errorf("relayer: %w: %s", ErrUnknownDomain, e)
	}
	digest := Digest(src.Messenger, dst.Messenger, a.Message)
	if signer, err := Recover(digest, a.Sig); err != nil || signer != a.Attester {
		return fmt.Errorf("relayer: bad signature from %s on %s", a.Attester, e)
	}
	h := common.BytesToHash(digest[:])
	r.mu.Lock()
	defer r.mu.Unlock()
	byHash := r.items[e.ID()]
	if byHash == nil {
		byHash = map[common.Hash]*item{}
		r.items[e.ID()] = byHash
	}
	it := byHash[h]
	if it == nil {
		it = &item{env: e, msg: append([]byte(nil), a.Message...), sigs: map[common.Address][]byte{}}
		byHash[h] = it
	}
	it.sigs[a.Attester] = a.Sig
	return nil
}

func (r *Relayer) sorted() []*item {
	var out []*item
	for _, byHash := range r.items {
		for _, it := range byHash {
			out = append(out, it)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].env.ID() != out[j].env.ID() {
			return lessID(out[i].env.ID(), out[j].env.ID())
		}
		return bytes.Compare(out[i].msg, out[j].msg) < 0
	})
	return out
}

// sortedSigs returns the signatures ascending by signer, as the messenger
// requires.
func sortedSigs(sigs map[common.Address][]byte) ([]common.Address, [][]byte) {
	addrs := make([]common.Address, 0, len(sigs))
	for a := range sigs {
		addrs = append(addrs, a)
	}
	sort.Slice(addrs, func(i, j int) bool { return bytes.Compare(addrs[i][:], addrs[j][:]) < 0 })
	out := make([][]byte, len(addrs))
	for i, a := range addrs {
		out[i] = sigs[a]
	}
	return addrs, out
}

// Deliver submits every message that has a majority, in (source, nonce)
// order, and returns how many reached a final outcome this round.
func (r *Relayer) Deliver(ctx context.Context) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, it := range r.sorted() {
		if it.done || r.held[it.env.Dest] || len(it.sigs) < r.cfg.Threshold {
			continue
		}
		d, final, err := r.deliver(ctx, it)
		if err != nil {
			return n, err
		}
		if d == nil {
			continue
		}
		r.log = append(r.log, *d)
		if final {
			n++
			for _, other := range r.items[it.env.ID()] {
				other.done = true // one message per (source, nonce) ever lands
			}
		}
	}
	return n, nil
}

func (r *Relayer) deliver(ctx context.Context, it *item) (*Delivery, bool, error) {
	e := it.env
	m := r.messengers[e.Dest]
	c := r.clients[e.Dest]
	in, err := m.Call(ctx, "inbound", e.Source, e.Nonce)
	if err != nil {
		return nil, false, err
	}
	if st := in[0].(uint8); st != InboundNone {
		r.cfg.Log("relayer: %s already consumed at %s (state %d): skipped", e, r.name(e.Dest), st)
		return &Delivery{Envelope: e, Outcome: AlreadyDelivered}, true, nil
	}
	signers, sigs := sortedSigs(it.sigs)
	if e.Kind == KindMint {
		h, err := c.Eth.HeaderByNumber(ctx, nil)
		if err != nil {
			return nil, false, err
		}
		if h.Time >= e.Deadline { // the next block is past the deadline
			rcpt, err := deploy.Send(ctx, c, m, r.cfg.Account, "cancelExpired", it.msg, sigs)
			if err != nil {
				it.attempts++
				it.lastErr = err
				return &Delivery{Envelope: e, Outcome: Failed, Err: err, Signers: signers}, false, nil
			}
			r.cfg.Log("relayer: %s past its deadline: cancelled at %s with %d attester signatures (block %d); MINT_CANCEL goes back",
				e, r.name(e.Dest), len(sigs), rcpt.BlockNumber.Uint64())
			return &Delivery{Envelope: e, Outcome: Expired, Signers: signers, Tx: rcpt.TxHash, Block: rcpt.BlockNumber.Uint64()}, true, nil
		}
		s := r.issuers[e.Member]
		if s == nil {
			it.lastErr = fmt.Errorf("no issuer signer for %s", idString(e.Member))
			return nil, false, nil
		}
		issuerSig, err := s.CoSign(ctx, it.msg)
		if errors.Is(err, ErrNotFinal) {
			it.lastErr = err
			return nil, false, nil
		}
		if err != nil {
			it.lastErr = err
			r.cfg.Log("relayer: %s not delivered: issuer %s refused: %v", e, idString(e.Member), err)
			return &Delivery{Envelope: e, Outcome: IssuerRefused, Err: err, Signers: signers}, true, nil
		}
		return r.submit(ctx, it, signers, sigs, issuerSig)
	}
	return r.submit(ctx, it, signers, sigs, nil)
}

func (r *Relayer) submit(ctx context.Context, it *item, signers []common.Address, sigs [][]byte, issuerSig []byte) (*Delivery, bool, error) {
	e := it.env
	it.attempts++
	rcpt, err := r.Submit(ctx, e.Dest, it.msg, sigs, issuerSig)
	d := &Delivery{Envelope: e, Signers: signers, Issuer: issuerSig != nil, Err: err}
	if err == nil {
		d.Outcome, d.Tx, d.Block = Delivered, rcpt.TxHash, rcpt.BlockNumber.Uint64()
		extra := ""
		if issuerSig != nil {
			extra = " + issuer " + idString(e.Member)
		}
		r.cfg.Log("relayer: %s delivered to %s: %d of %d attesters%s (block %d)", e, r.name(e.Dest), len(sigs), len(r.attesters),
			extra, d.Block)
		return d, true, nil
	}
	it.lastErr = err
	switch {
	case strings.Contains(err.Error(), "RateLimited"):
		d.Outcome = RateLimited
		r.cfg.Log("relayer: %s to %s: inbound rate limit exhausted (%v); retrying later (attempt %d)", e, r.name(e.Dest), err, it.attempts)
		return d, false, nil
	case strings.Contains(err.Error(), "NonceUsed"):
		d.Outcome = AlreadyDelivered
		return d, true, nil
	default:
		d.Outcome = Failed
		r.cfg.Log("relayer: %s refused by %s: %v", e, r.name(e.Dest), err)
		return d, true, nil
	}
}

// Submit sends receiveMessage to a destination as given: no checks, no
// bookkeeping. The messenger is the only judge (tests use it to try forged
// and replayed messages).
func (r *Relayer) Submit(ctx context.Context, dest uint32, message []byte, sigs [][]byte, issuerSig []byte) (*types.Receipt, error) {
	m, ok := r.messengers[dest]
	if !ok {
		return nil, fmt.Errorf("relayer: %w: %d", ErrUnknownDomain, dest)
	}
	if issuerSig == nil {
		issuerSig = []byte{}
	}
	return deploy.Send(ctx, r.clients[dest], m, r.cfg.Account, "receiveMessage", message, sigs, issuerSig)
}

// Signatures returns the message with the most signatures collected for a
// (source, nonce), and those signatures in submission order.
func (r *Relayer) Signatures(id MsgID) ([]byte, [][]byte, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var best *item
	for _, it := range r.items[id] {
		if best == nil || len(it.sigs) > len(best.sigs) {
			best = it
		}
	}
	if best == nil {
		return nil, nil, false
	}
	_, sigs := sortedSigs(best.sigs)
	return best.msg, sigs, true
}

// Messenger is the relayer's binding of a domain's messenger.
func (r *Relayer) Messenger(d uint32) *chain.Contract { return r.messengers[d] }

// Client is the relayer's connection to a domain.
func (r *Relayer) Client(d uint32) *chain.Client { return r.clients[d] }
