package listener

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/rails"
)

// Reasons an entry is not signed. ErrNotPayment and ErrAlreadySigned are
// benign (a camt.056 return request, a funding, a duplicate delivery); every
// other reason sends the entry to manual review.
var (
	ErrNotPayment       = errors.New("not a payment")
	ErrNotFinal         = errors.New("not final")
	ErrNoLegReference   = errors.New("message does not name a settlement leg")
	ErrNoOpenLeg        = errors.New("no open leg")
	ErrUnknownAccount   = errors.New("rail account not in the directory")
	ErrPayerMismatch    = errors.New("payer is neither the leg payer nor an allowed waterfall payer")
	ErrPayeeMismatch    = errors.New("payee is not the leg payee")
	ErrMessageMismatch  = errors.New("message disagrees with the rail entry")
	ErrAlreadySigned    = errors.New("rail transaction already signed by this signer")
	ErrForeignMatch     = errors.New("match produced by another signer")
	ErrRailNotSupported = errors.New("rail not supported")
)

// Feed is a rail's finality feed read by cursor (rails.Journal implements it).
type Feed interface {
	Read(cursor uint64) ([]rails.Entry, uint64)
}

// Match is an entry this signer has checked and may sign. Only Signer.Match
// makes one.
type Match struct {
	Payment Payment
	Entry   rails.Entry
	Leg     iso20022.LegRef
	by      *Signer
}

// Attestation is one signer's signature over a Payment.
type Attestation struct {
	Payment Payment
	Digest  common.Hash
	Signer  common.Address
	Sig     []byte // 65 bytes, v 27/28
	TxID    string // the rail's id, for logs
}

// Review is an entry that was not signed and needs a person.
type Review struct {
	Rail   rails.Rail
	Entry  rails.Entry
	Reason error
}

// Skipped is an entry that was not signed for a benign reason.
type Skipped struct {
	Rail   rails.Rail
	Entry  rails.Entry
	Reason error
}

// Signer is one listener signer: its own key, its own cursors, its own memory
// of what it signed.
type Signer struct {
	key    *ecdsa.PrivateKey
	addr   common.Address
	domain Domain
	book   Book

	mu      sync.Mutex
	feeds   map[rails.Rail]Feed
	cursors map[rails.Rail]uint64
	signed  map[[32]byte]bool
	review  []Review
	skipped []Skipped
}

// NewSigner creates a signer reading the given feeds from the start.
func NewSigner(key *ecdsa.PrivateKey, domain Domain, book Book, feeds map[rails.Rail]Feed) *Signer {
	s := &Signer{
		key: key, addr: crypto.PubkeyToAddress(key.PublicKey), domain: domain, book: book,
		feeds: map[rails.Rail]Feed{}, cursors: map[rails.Rail]uint64{}, signed: map[[32]byte]bool{},
	}
	for r, f := range feeds {
		s.feeds[r] = f
	}
	return s
}

// Address is the signer's address.
func (s *Signer) Address() common.Address { return s.addr }

// Cursor is the signer's position in a rail's feed.
func (s *Signer) Cursor(r rails.Rail) uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cursors[r]
}

// ManualReview returns the entries that were not signed and need a person.
func (s *Signer) ManualReview() []Review {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Review(nil), s.review...)
}

// Skipped returns entries ignored for benign reasons (return requests,
// fundings, duplicate deliveries).
func (s *Signer) Skipped() []Skipped {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Skipped(nil), s.skipped...)
}

// Match checks an entry against every rule of §5.3 without changing state.
func (s *Signer) Match(e rails.Entry) (Match, error) {
	if e.Kind != rails.KindPayment {
		return Match{}, fmt.Errorf("%s %s: %w", e.Kind, e.TxID, ErrNotPayment)
	}
	if e.Rail != rails.CHIPS && e.Rail != rails.RTP {
		return Match{}, fmt.Errorf("%s: %w", e.Rail, ErrRailNotSupported)
	}
	if !e.Final || e.FinalAt.IsZero() {
		return Match{}, fmt.Errorf("%s: %w", e.TxID, ErrNotFinal)
	}
	if e.TxID == "" {
		return Match{}, fmt.Errorf("entry without a rail id: %w", ErrNotFinal)
	}
	railTx := RailTxHash(e.TxID)
	s.mu.Lock()
	done := s.signed[railTx]
	s.mu.Unlock()
	if done {
		return Match{}, fmt.Errorf("%s: %w", e.TxID, ErrAlreadySigned)
	}
	msg, leg, err := iso20022.ParseLeg(e.Message)
	if err != nil {
		return Match{}, fmt.Errorf("%s: %w: %v", e.TxID, ErrNoLegReference, err)
	}
	if msg.Amount != e.Amount || msg.DebtorAccount != e.PayerAcct || msg.CreditorAccount != e.PayeeAcct {
		return Match{}, fmt.Errorf("%s: %w (message %d %s→%s, rail %d %s→%s)", e.TxID, ErrMessageMismatch,
			msg.Amount, msg.DebtorAccount, msg.CreditorAccount, e.Amount, e.PayerAcct, e.PayeeAcct)
	}
	open, ok := s.book.Leg(leg.Batch, leg.Leg)
	if !ok {
		return Match{}, fmt.Errorf("%s: batch %d leg %d: %w", e.TxID, leg.Batch, leg.Leg, ErrNoOpenLeg)
	}
	payer, ok := s.book.Account(e.Rail, e.PayerAcct)
	if !ok {
		return Match{}, fmt.Errorf("%s: payer account %s: %w", e.TxID, e.PayerAcct, ErrUnknownAccount)
	}
	payee, ok := s.book.Account(e.Rail, e.PayeeAcct)
	if !ok {
		return Match{}, fmt.Errorf("%s: payee account %s: %w", e.TxID, e.PayeeAcct, ErrUnknownAccount)
	}
	if !open.allows(payer.Owner) {
		return Match{}, fmt.Errorf("%s: account %s: %w", e.TxID, e.PayerAcct, ErrPayerMismatch)
	}
	if payee.Owner != open.Payee {
		return Match{}, fmt.Errorf("%s: account %s: %w", e.TxID, e.PayeeAcct, ErrPayeeMismatch)
	}
	p := Payment{
		Batch:     leg.Batch,
		Leg:       leg.Leg,
		Rail:      uint8(e.Rail),
		RailTxID:  railTx,
		PayerAcct: payer.Addr,
		Payer:     payer.Owner,
		Payee:     open.Payee,
		Amount:    new(big.Int).SetUint64(e.Amount),
		FinalAt:   uint64(e.FinalAt.Unix()),
	}
	return Match{Payment: p, Entry: e, Leg: leg, by: s}, nil
}

// Sign signs a match this signer produced, once per rail transaction.
func (s *Signer) Sign(m Match) (Attestation, error) {
	if m.by != s {
		return Attestation{}, ErrForeignMatch
	}
	d, err := Digest(s.domain, m.Payment)
	if err != nil {
		return Attestation{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.signed[m.Payment.RailTxID] {
		return Attestation{}, fmt.Errorf("%s: %w", m.Entry.TxID, ErrAlreadySigned)
	}
	sig, err := SignDigest(s.key, d)
	if err != nil {
		return Attestation{}, err
	}
	s.signed[m.Payment.RailTxID] = true
	return Attestation{Payment: m.Payment, Digest: d, Signer: s.addr, Sig: sig, TxID: m.Entry.TxID}, nil
}

// Process matches and, if it matches, signs one entry; unmatched entries are
// recorded for review or as skipped.
func (s *Signer) Process(e rails.Entry) (Attestation, bool) {
	m, err := s.Match(e)
	if err == nil {
		a, serr := s.Sign(m)
		if serr == nil {
			return a, true
		}
		err = serr
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if errors.Is(err, ErrNotPayment) || errors.Is(err, ErrAlreadySigned) {
		s.skipped = append(s.skipped, Skipped{Rail: e.Rail, Entry: e, Reason: err})
	} else {
		s.review = append(s.review, Review{Rail: e.Rail, Entry: e, Reason: err})
	}
	return Attestation{}, false
}

// Poll reads every feed from this signer's cursors and processes what is new,
// rails in ascending order.
func (s *Signer) Poll() []Attestation {
	var out []Attestation
	for _, r := range []rails.Rail{rails.CHIPS, rails.RTP} {
		s.mu.Lock()
		f, ok := s.feeds[r]
		cur := s.cursors[r]
		s.mu.Unlock()
		if !ok {
			continue
		}
		entries, next := f.Read(cur)
		for _, e := range entries {
			if a, ok := s.Process(e); ok {
				out = append(out, a)
			}
		}
		s.mu.Lock()
		s.cursors[r] = next
		s.mu.Unlock()
	}
	return out
}
