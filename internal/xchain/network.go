package xchain

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"sync"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/chain"
)

// NetworkConfig assembles the attesters, the issuer signers and a relayer.
type NetworkConfig struct {
	Domains      []Domain
	Artifacts    string
	Relayer      chain.Account
	AttesterKeys []*ecdsa.PrivateKey
	Threshold    int
	IssuerKeys   map[[32]byte]*ecdsa.PrivateKey
	// AttesterDial, if set, may return a DialFunc for attester i (nil: its own
	// fresh connections). Tests use it to give one attester a lying node.
	AttesterDial func(i int) DialFunc
	Log          func(format string, args ...any)
}

// Network is the cross-chain transport.
type Network struct {
	Domains   map[uint32]Domain
	Attesters []*Attester
	Issuers   map[[32]byte]*Issuer
	Relayer   *Relayer

	probes map[uint32]Source
	log    func(format string, args ...any)
}

// NewNetwork starts every signer with its own connections.
func NewNetwork(ctx context.Context, cfg NetworkConfig) (_ *Network, err error) {
	if cfg.Log == nil {
		cfg.Log = func(string, ...any) {}
	}
	n := &Network{Domains: map[uint32]Domain{}, Issuers: map[[32]byte]*Issuer{}, probes: map[uint32]Source{}, log: cfg.Log}
	defer func() {
		if err != nil {
			n.Close()
		}
	}()
	for _, d := range cfg.Domains {
		n.Domains[d.ID] = d
		if n.probes[d.ID], err = DialOwn(ctx, d); err != nil {
			return nil, err
		}
	}
	var addrs []common.Address
	for i, k := range cfg.AttesterKeys {
		var dial DialFunc
		if cfg.AttesterDial != nil {
			dial = cfg.AttesterDial(i)
		}
		a, err := NewAttester(ctx, AttesterConfig{Name: fmt.Sprintf("attester-%d", i), Key: k, Domains: cfg.Domains, Dial: dial})
		if err != nil {
			return nil, err
		}
		n.Attesters = append(n.Attesters, a)
		addrs = append(addrs, a.Address())
	}
	var cos []CoSigner
	for id, k := range cfg.IssuerKeys {
		s, err := NewIssuer(ctx, IssuerConfig{Name: "issuer-" + idString(id), Member: id, Key: k, Domains: cfg.Domains})
		if err != nil {
			return nil, err
		}
		n.Issuers[id] = s
		cos = append(cos, s)
	}
	n.Relayer, err = NewRelayer(ctx, RelayerConfig{Domains: cfg.Domains, Artifacts: cfg.Artifacts, Account: cfg.Relayer,
		Attesters: addrs, Threshold: cfg.Threshold, Issuers: cos, Log: cfg.Log})
	if err != nil {
		return nil, err
	}
	return n, nil
}

// Close closes every connection.
func (n *Network) Close() {
	for _, a := range n.Attesters {
		a.Close()
	}
	for _, s := range n.Issuers {
		s.Close()
	}
	for _, p := range n.probes {
		p.Close()
	}
}

// Round is what one Pump did.
type Round struct {
	Attested  int // new signatures collected
	Delivered int // messages that reached a final outcome
}

// Progress reports whether the round changed anything.
func (r Round) Progress() bool { return r.Attested > 0 || r.Delivered > 0 }

// Pump runs every attester concurrently (each on its own nodes), hands their
// signatures to the relayer, and lets the relayer deliver.
func (n *Network) Pump(ctx context.Context) (Round, error) {
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		all  []Attestation
		errs []error
	)
	for _, a := range n.Attesters {
		wg.Add(1)
		go func(a *Attester) {
			defer wg.Done()
			got, err := a.Scan(ctx)
			mu.Lock()
			defer mu.Unlock()
			all = append(all, got...)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s: %w", a.Name(), err))
			}
		}(a)
	}
	wg.Wait()
	if len(errs) > 0 {
		return Round{}, errs[0]
	}
	var r Round
	for _, at := range all {
		if err := n.Relayer.Collect(at); err != nil {
			return r, err
		}
		r.Attested++
	}
	d, err := n.Relayer.Deliver(ctx)
	r.Delivered = d
	return r, err
}

// Unfinalized returns, per spoke, how many more blocks must be produced for
// every MessageSent log on it to be final.
func (n *Network) Unfinalized(ctx context.Context) (map[uint32]uint64, error) {
	out := map[uint32]uint64{}
	for id, d := range n.Domains {
		if d.Finality == 0 {
			continue
		}
		p := n.probes[id]
		head, err := p.BlockNumber(ctx)
		if err != nil {
			return nil, err
		}
		from := uint64(0)
		if head+1 > d.Finality {
			from = head + 1 - d.Finality
		}
		logs, err := p.FilterLogs(ctx, ethereum.FilterQuery{FromBlock: new(big.Int).SetUint64(from), ToBlock: new(big.Int).SetUint64(head),
			Addresses: []common.Address{d.Messenger}, Topics: [][]common.Hash{{MessageSentID}}})
		if err != nil {
			return nil, err
		}
		var last uint64
		for _, l := range logs {
			if l.BlockNumber > last {
				last = l.BlockNumber
			}
		}
		if len(logs) > 0 && last+d.Finality > head {
			out[id] = last + d.Finality - head
		}
	}
	return out, nil
}

// Settle pumps until nothing moves. When a spoke's messages are waiting for
// finality it asks produce to make that many blocks there (on a development
// chain: anvil_mine), so every wait is explicit.
func (n *Network) Settle(ctx context.Context, produce func(ctx context.Context, domain uint32, blocks uint64) error) error {
	for i := 0; i < 256; i++ {
		r, err := n.Pump(ctx)
		if err != nil {
			return err
		}
		need, err := n.Unfinalized(ctx)
		if err != nil {
			return err
		}
		if len(need) > 0 && produce != nil {
			for d, b := range need {
				n.log("%s: waiting for finality: %d more block(s) for its latest messages", n.Domains[d].Name, b)
				if err := produce(ctx, d, b); err != nil {
					return err
				}
			}
			continue
		}
		if !r.Progress() {
			return nil
		}
	}
	return fmt.Errorf("xchain: the network did not settle")
}

// AttesterAddress is the address of a key.
func AttesterAddress(k *ecdsa.PrivateKey) common.Address { return crypto.PubkeyToAddress(k.PublicKey) }
