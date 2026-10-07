package listener

import (
	"context"
	"fmt"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/rails"
)

// ChainBook is the Book read from the home chain: a leg is open while its
// batch is PLANNED, PARTIAL or DEFAULTING (SettlementBatches.status), its
// payer and payee come from the submitted plan (SettlementBatches.leg), and
// its waterfall payers from DefaultManager's CoverInstruction events.
//
// The rail account directory (which member owns which rail account) is
// off-chain configuration; the payerAcct address of an attested Payment is the
// owner's issuerOps key read from MemberRegistry, or a fixed address for the
// COLLATERAL and POOL sub-accounts of the joint account.
//
// Every lookup reads the chain afresh (no cache of batch state), so the five
// signers always see the same chain the attestor will check. A read error
// makes the leg unknown, which sends the entry to manual review: the safe
// side, never a signature.
type ChainBook struct {
	d       *deploy.Deployment
	timeout time.Duration

	mu       sync.RWMutex
	accounts map[acctKey][32]byte
	addrs    map[[32]byte]common.Address
}

// NewChainBook reads the contracts of d.
func NewChainBook(d *deploy.Deployment) *ChainBook {
	return &ChainBook{d: d, timeout: 10 * time.Second, accounts: map[acctKey][32]byte{}, addrs: map[[32]byte]common.Address{}}
}

// JointAccountAddr is the payerAcct of the joint account's COLLATERAL / POOL
// sub-accounts: the last 20 bytes of keccak256("joint:" + name).
func JointAccountAddr(owner [32]byte) common.Address {
	return common.BytesToAddress(crypto.Keccak256(append([]byte("joint:"), owner[:]...))[12:])
}

// SetAccount registers who owns a rail account.
func (b *ChainBook) SetAccount(r rails.Rail, acct string, owner [32]byte) {
	b.mu.Lock()
	b.accounts[acctKey{r, acct}] = owner
	b.mu.Unlock()
}

// Leg implements Book.
func (b *ChainBook) Leg(batch uint64, leg uint32) (OpenLeg, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), b.timeout)
	defer cancel()
	l, err := b.OpenLeg(ctx, batch, leg)
	return l, err == nil
}

// OpenLeg is Leg with the reason a leg is not open.
func (b *ChainBook) OpenLeg(ctx context.Context, batch uint64, leg uint32) (OpenLeg, error) {
	bt, err := b.d.Batch(ctx, batch)
	if err != nil {
		return OpenLeg{}, err
	}
	switch bt.Status {
	case deploy.StatusPlanned, deploy.StatusPartial, deploy.StatusDefaulting:
	default:
		return OpenLeg{}, fmt.Errorf("batch %d is %s", batch, deploy.StatusName(bt.Status))
	}
	n, err := b.d.Batches.BigInt(ctx, "legCount", batch)
	if err != nil {
		return OpenLeg{}, err
	}
	if uint64(leg) >= n.Uint64() {
		return OpenLeg{}, fmt.Errorf("batch %d has %d legs, no leg %d", batch, n, leg)
	}
	lv, err := b.d.Leg(ctx, batch, leg)
	if err != nil {
		return OpenLeg{}, err
	}
	out := OpenLeg{Batch: batch, Leg: leg, Payer: lv.Payer, Payee: lv.Payee}
	if bt.Status == deploy.StatusDefaulting {
		w, err := b.waterfall(ctx, batch, leg, lv.Payee)
		if err != nil {
			return OpenLeg{}, err
		}
		out.Waterfall = w
	}
	return out, nil
}

// CoverInstruction is one DefaultManager waterfall allocation.
type CoverInstruction struct {
	Batch  uint64
	Leg    uint32
	Source [32]byte
	Amount *big.Int
	Block  uint64
}

// CoverInstructions reads a batch's waterfall allocations.
func CoverInstructions(ctx context.Context, d *deploy.Deployment, batch uint64) ([]CoverInstruction, error) {
	head, err := d.Client.Head(ctx)
	if err != nil {
		return nil, err
	}
	var topic common.Hash
	new(big.Int).SetUint64(batch).FillBytes(topic[:])
	logs, err := d.DefaultManager.EventsWithTopic(ctx, "CoverInstruction", topic, 0, head)
	if err != nil {
		return nil, err
	}
	out := make([]CoverInstruction, 0, len(logs))
	for _, l := range logs {
		var ev struct {
			Batch  uint64
			Leg    uint32
			Source [32]byte
			Amount *big.Int
		}
		if err := d.DefaultManager.Unpack(&ev, "CoverInstruction", l); err != nil {
			return nil, err
		}
		out = append(out, CoverInstruction{Batch: ev.Batch, Leg: ev.Leg, Source: ev.Source, Amount: ev.Amount, Block: l.BlockNumber})
	}
	return out, nil
}

// waterfall lists the cover sources allowed to pay a leg, excluding the payee
// (its own share is absorbed, not paid).
func (b *ChainBook) waterfall(ctx context.Context, batch uint64, leg uint32, payee [32]byte) ([][32]byte, error) {
	cis, err := CoverInstructions(ctx, b.d, batch)
	if err != nil {
		return nil, err
	}
	var out [][32]byte
	seen := map[[32]byte]bool{}
	for _, c := range cis {
		if c.Leg != leg || c.Source == payee || seen[c.Source] {
			continue
		}
		seen[c.Source] = true
		out = append(out, c.Source)
	}
	return out, nil
}

// Account implements Book.
func (b *ChainBook) Account(r rails.Rail, acct string) (Account, bool) {
	b.mu.RLock()
	owner, ok := b.accounts[acctKey{r, acct}]
	addr, cached := b.addrs[owner]
	b.mu.RUnlock()
	if !ok {
		return Account{}, false
	}
	if cached {
		return Account{Owner: owner, Addr: addr}, true
	}
	if owner == CollateralPayer || owner == PoolPayer {
		addr = JointAccountAddr(owner)
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), b.timeout)
		defer cancel()
		m, err := b.d.Member(ctx, owner)
		if err != nil || m.Status == deploy.MemberNone {
			return Account{}, false
		}
		addr = m.IssuerOps
	}
	b.mu.Lock()
	b.addrs[owner] = addr
	b.mu.Unlock()
	return Account{Owner: owner, Addr: addr}, true
}
