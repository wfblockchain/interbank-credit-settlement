package listener

import (
	"bytes"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"sync"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// attestorABI is the submitter's view of SettlementAttestor.attestPayment.
const attestorABI = `[{"type":"function","name":"attestPayment","stateMutability":"nonpayable","inputs":[
 {"name":"p","type":"tuple","components":[
  {"name":"batch","type":"uint64"},{"name":"leg","type":"uint32"},{"name":"rail","type":"uint8"},
  {"name":"railTxId","type":"bytes32"},{"name":"payerAcct","type":"address"},{"name":"payer","type":"bytes32"},
  {"name":"payee","type":"bytes32"},{"name":"amount","type":"uint256"},{"name":"finalAt","type":"uint64"}]},
 {"name":"sigs","type":"bytes[]"}],"outputs":[]}]`

var parsedAttestorABI = func() abi.ABI {
	a, err := abi.JSON(strings.NewReader(attestorABI))
	if err != nil {
		panic(err)
	}
	return a
}()

// abiPayment mirrors the tuple for packing (abi matches fields by name).
type abiPayment struct {
	Batch     uint64
	Leg       uint32
	Rail      uint8
	RailTxId  [32]byte // named as the ABI component
	PayerAcct common.Address
	Payer     [32]byte
	Payee     [32]byte
	Amount    *big.Int
	FinalAt   uint64
}

// Errors the aggregator returns.
var (
	ErrBadSignature   = errors.New("signature does not recover to the claimed signer")
	ErrNotSigner      = errors.New("not a current signer")
	ErrDigestMismatch = errors.New("attestation digest does not match its payment")
	ErrNotEnough      = errors.New("fewer than k signatures")
)

// Call is a ready SettlementAttestor.attestPayment call.
type Call struct {
	Payment Payment
	Signers []common.Address // strictly ascending
	Sigs    [][]byte         // in the same order
	Data    []byte           // ABI-encoded call data
}

type pending struct {
	payment Payment
	sigs    map[common.Address][]byte
}

// Aggregator collects signatures per payment digest until k distinct current
// signers agree on the same Payment.
type Aggregator struct {
	domain  Domain
	k       int
	signers map[common.Address]bool

	mu      sync.Mutex
	pending map[common.Hash]*pending
	emitted map[[32]byte]bool // railTxIds already turned into a call
}

// NewAggregator creates an aggregator for the attestor at domain with
// threshold k over the given signer set.
func NewAggregator(domain Domain, k int, signers []common.Address) (*Aggregator, error) {
	if k <= 0 || k > len(signers) {
		return nil, fmt.Errorf("k=%d with %d signers", k, len(signers))
	}
	a := &Aggregator{domain: domain, k: k, signers: map[common.Address]bool{},
		pending: map[common.Hash]*pending{}, emitted: map[[32]byte]bool{}}
	for _, s := range signers {
		a.signers[s] = true
	}
	return a, nil
}

// Add verifies and stores one attestation. It returns the call once k
// signatures over the same digest are present (exactly once per rail
// transaction); otherwise nil.
func (a *Aggregator) Add(at Attestation) (*Call, error) {
	d, err := Digest(a.domain, at.Payment)
	if err != nil {
		return nil, err
	}
	if d != at.Digest {
		return nil, ErrDigestMismatch
	}
	who, err := Recover(d, at.Sig)
	if err != nil || who != at.Signer {
		return nil, ErrBadSignature
	}
	if !a.signers[who] {
		return nil, fmt.Errorf("%s: %w", who, ErrNotSigner)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.emitted[at.Payment.RailTxID] {
		return nil, nil
	}
	p, ok := a.pending[d]
	if !ok {
		p = &pending{payment: at.Payment, sigs: map[common.Address][]byte{}}
		a.pending[d] = p
	}
	p.sigs[who] = append([]byte(nil), at.Sig...)
	if len(p.sigs) < a.k {
		return nil, nil
	}
	c, err := buildCall(p.payment, p.sigs, a.k)
	if err != nil {
		return nil, err
	}
	a.emitted[at.Payment.RailTxID] = true
	delete(a.pending, d)
	return c, nil
}

// buildCall orders the signatures strictly ascending by signer address, keeps
// the first k and encodes the call.
func buildCall(p Payment, sigs map[common.Address][]byte, k int) (*Call, error) {
	if len(sigs) < k {
		return nil, ErrNotEnough
	}
	addrs := make([]common.Address, 0, len(sigs))
	for s := range sigs {
		addrs = append(addrs, s)
	}
	sort.Slice(addrs, func(i, j int) bool { return bytes.Compare(addrs[i][:], addrs[j][:]) < 0 })
	addrs = addrs[:k]
	c := &Call{Payment: p, Signers: addrs}
	for _, s := range addrs {
		c.Sigs = append(c.Sigs, sigs[s])
	}
	data, err := parsedAttestorABI.Pack("attestPayment", abiPayment{
		Batch: p.Batch, Leg: p.Leg, Rail: p.Rail, RailTxId: p.RailTxID, PayerAcct: p.PayerAcct,
		Payer: p.Payer, Payee: p.Payee, Amount: p.Amount, FinalAt: p.FinalAt,
	}, c.Sigs)
	if err != nil {
		return nil, err
	}
	c.Data = data
	return c, nil
}
