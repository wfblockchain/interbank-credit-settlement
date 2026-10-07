package xchain

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"sync"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// Attester errors and faults.
var (
	// ErrWrongChain: a signer's node serves another chain than the domain's.
	ErrWrongChain = errors.New("node serves the wrong chain")
	// ErrEquivocation: a second, different message for a (source, nonce) the
	// attester already signed. It never signs both.
	ErrEquivocation = errors.New("conflicting message for a signed nonce")
	// ErrUnknownDomain: the envelope names a domain the signer does not know.
	ErrUnknownDomain = errors.New("unknown domain")
)

// Attestation is one attester's signature over one message.
type Attestation struct {
	Attester common.Address
	Envelope Envelope
	Message  []byte
	Digest   common.Hash
	Sig      []byte
	Block    uint64 // source block of the MessageSent log
}

// Fault is something an attester refused to sign, and why.
type Fault struct {
	Domain uint32
	Block  uint64
	Err    error
}

func (f Fault) String() string {
	if f.Block == 0 {
		return fmt.Sprintf("domain %d: %v", f.Domain, f.Err)
	}
	return fmt.Sprintf("domain %d block %d: %v", f.Domain, f.Block, f.Err)
}

// AttesterConfig configures one attester process.
type AttesterConfig struct {
	Name    string
	Key     *ecdsa.PrivateKey
	Domains []Domain
	Dial    DialFunc // nil: DialOwn (a fresh connection per domain)
}

type view struct {
	Domain
	src  Source
	next uint64 // next block to scan
}

// Attester watches every chain's messenger from its own nodes and signs final
// messages.
type Attester struct {
	name string
	key  *ecdsa.PrivateKey
	addr common.Address

	mu     sync.Mutex
	views  map[uint32]*view
	signed map[MsgID]Attestation
	faults []Fault
	seen   map[string]bool
}

// NewAttester dials the attester's own node for every domain.
func NewAttester(ctx context.Context, cfg AttesterConfig) (*Attester, error) {
	dial := cfg.Dial
	if dial == nil {
		dial = DialOwn
	}
	a := &Attester{name: cfg.Name, key: cfg.Key, addr: crypto.PubkeyToAddress(cfg.Key.PublicKey), views: map[uint32]*view{},
		signed: map[MsgID]Attestation{}, seen: map[string]bool{}}
	for _, d := range cfg.Domains {
		src, err := dial(ctx, d)
		if err != nil {
			a.Close()
			return nil, err
		}
		a.views[d.ID] = &view{Domain: d, src: src}
	}
	return a, nil
}

// Name is the attester's label.
func (a *Attester) Name() string { return a.name }

// Address is the attester's signing address.
func (a *Attester) Address() common.Address { return a.addr }

// Close closes the attester's connections.
func (a *Attester) Close() {
	for _, v := range a.views {
		v.src.Close()
	}
}

// Faults lists what the attester refused to sign.
func (a *Attester) Faults() []Fault {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]Fault(nil), a.faults...)
}

// Attestations is everything the attester has signed, by (source, nonce).
func (a *Attester) Attestations() []Attestation {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]Attestation, 0, len(a.signed))
	for _, s := range a.signed {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return lessID(out[i].Envelope.ID(), out[j].Envelope.ID()) })
	return out
}

func lessID(x, y MsgID) bool {
	if x.Source != y.Source {
		return x.Source < y.Source
	}
	return x.Nonce < y.Nonce
}

func (a *Attester) fault(f Fault) {
	k := f.String()
	if !a.seen[k] {
		a.seen[k] = true
		a.faults = append(a.faults, f)
	}
}

// Scan reads every domain up to its final head and signs the new messages.
// A node that reports the wrong chain is skipped and recorded as a fault.
func (a *Attester) Scan(ctx context.Context) ([]Attestation, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	ids := make([]uint32, 0, len(a.views))
	for id := range a.views {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	var out []Attestation
	for _, id := range ids {
		v := a.views[id]
		if err := checkChain(ctx, v.src, v.Domain); err != nil {
			if errors.Is(err, ErrWrongChain) {
				a.fault(Fault{Domain: id, Err: err})
				continue
			}
			return out, err
		}
		final, ok, err := finalHead(ctx, v.src, v.Domain)
		if err != nil {
			return out, err
		}
		if !ok || final < v.next {
			continue
		}
		logs, err := v.src.FilterLogs(ctx, ethereum.FilterQuery{
			FromBlock: new(big.Int).SetUint64(v.next), ToBlock: new(big.Int).SetUint64(final),
			Addresses: []common.Address{v.Messenger}, Topics: [][]common.Hash{{MessageSentID}},
		})
		if err != nil {
			return out, err
		}
		for _, l := range logs {
			if l.Removed || l.Address != v.Messenger || l.BlockNumber > final {
				continue
			}
			at, err := a.sign(v, l)
			if err != nil {
				a.fault(Fault{Domain: id, Block: l.BlockNumber, Err: err})
				continue
			}
			if at != nil {
				out = append(out, *at)
			}
		}
		v.next = final + 1
	}
	return out, nil
}

func (a *Attester) sign(v *view, l types.Log) (*Attestation, error) {
	msg, e, err := decodeMessageSent(l)
	if err != nil {
		return nil, err
	}
	if e.Version != Version {
		return nil, fmt.Errorf("%w: version %d", ErrMalformed, e.Version)
	}
	if e.Source != v.ID {
		return nil, fmt.Errorf("%w: envelope says source %d, read from domain %d", ErrMalformed, e.Source, v.ID)
	}
	dst, ok := a.views[e.Dest]
	if !ok || e.Dest == e.Source {
		return nil, fmt.Errorf("%w: destination %d", ErrUnknownDomain, e.Dest)
	}
	digest := Digest(v.Messenger, dst.Messenger, msg)
	if prev, done := a.signed[e.ID()]; done {
		if prev.Digest != digest {
			return nil, fmt.Errorf("%w: %s", ErrEquivocation, e)
		}
		return nil, nil
	}
	sig, err := Sign(a.key, digest)
	if err != nil {
		return nil, err
	}
	at := Attestation{Attester: a.addr, Envelope: e, Message: msg, Digest: digest, Sig: sig, Block: l.BlockNumber}
	a.signed[e.ID()] = at
	return &at, nil
}
