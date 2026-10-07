package listener

import (
	"sync"

	"github.com/ethereum/go-ethereum/common"

	"interbank-credit-settlement/internal/rails"
)

// Member ids as bytes32: ASCII, left-aligned.
func MemberID(s string) [32]byte {
	var b [32]byte
	copy(b[:], s)
	return b
}

// Waterfall payers (§3.6, §3.8).
var (
	CollateralPayer = MemberID("COLLATERAL")
	PoolPayer       = MemberID("POOL")
)

// Account is who owns a rail account: a member (or the COLLATERAL / POOL
// sub-accounts of the joint account) and the account's on-chain identifier,
// the payerAcct of the attested Payment.
type Account struct {
	Owner [32]byte
	Addr  common.Address
}

// OpenLeg is a leg of a batch that is planned and not yet complete.
type OpenLeg struct {
	Batch uint64
	Leg   uint32
	Payer [32]byte
	Payee [32]byte
	// Waterfall lists the payers DefaultManager allowed for this leg besides
	// the leg payer (COLLATERAL, POOL or a surviving member).
	Waterfall [][32]byte
}

func (l OpenLeg) allows(payer [32]byte) bool {
	if payer == l.Payer {
		return true
	}
	for _, w := range l.Waterfall {
		if w == payer {
			return true
		}
	}
	return false
}

// Book is what a signer knows of the chain: the open legs and the rail
// account directory. A chain-backed implementation reads BatchCut,
// submitPlan and CoverInstruction events; MemBook is the in-memory one.
type Book interface {
	Leg(batch uint64, leg uint32) (OpenLeg, bool)
	Account(rail rails.Rail, acct string) (Account, bool)
}

type legKey struct {
	batch uint64
	leg   uint32
}

type acctKey struct {
	rail rails.Rail
	acct string
}

// MemBook is an in-memory Book, safe for concurrent use.
type MemBook struct {
	mu       sync.RWMutex
	legs     map[legKey]OpenLeg
	accounts map[acctKey]Account
}

// NewMemBook returns an empty book.
func NewMemBook() *MemBook {
	return &MemBook{legs: map[legKey]OpenLeg{}, accounts: map[acctKey]Account{}}
}

// SetAccount registers who owns a rail account.
func (b *MemBook) SetAccount(rail rails.Rail, acct string, a Account) {
	b.mu.Lock()
	b.accounts[acctKey{rail, acct}] = a
	b.mu.Unlock()
}

// OpenLeg records a planned leg.
func (b *MemBook) OpenLeg(l OpenLeg) {
	b.mu.Lock()
	b.legs[legKey{l.Batch, l.Leg}] = l
	b.mu.Unlock()
}

// AllowWaterfall adds a waterfall payer to a leg (a CoverInstruction).
func (b *MemBook) AllowWaterfall(batch uint64, leg uint32, payer [32]byte) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	l, ok := b.legs[legKey{batch, leg}]
	if !ok {
		return false
	}
	l.Waterfall = append(append([][32]byte(nil), l.Waterfall...), payer)
	b.legs[legKey{batch, leg}] = l
	return true
}

// CloseBatch removes every leg of a batch (it completed).
func (b *MemBook) CloseBatch(batch uint64) {
	b.mu.Lock()
	for k := range b.legs {
		if k.batch == batch {
			delete(b.legs, k)
		}
	}
	b.mu.Unlock()
}

// Leg implements Book.
func (b *MemBook) Leg(batch uint64, leg uint32) (OpenLeg, bool) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	l, ok := b.legs[legKey{batch, leg}]
	return l, ok
}

// Account implements Book.
func (b *MemBook) Account(rail rails.Rail, acct string) (Account, bool) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	a, ok := b.accounts[acctKey{rail, acct}]
	return a, ok
}
