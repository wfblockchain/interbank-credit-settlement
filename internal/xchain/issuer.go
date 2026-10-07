package xchain

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"sync"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Issuer signer refusals.
var (
	ErrNotMint     = errors.New("not a MINT")
	ErrNotOwnToken = errors.New("not this bank's token")
	// ErrNotFinal: the source lock is not final on the signer's node yet
	// (retryable).
	ErrNotFinal = errors.New("source lock not final yet")
	// ErrNoSourceLock: the source chain, read from the signer's node, holds no
	// pending move matching the envelope.
	ErrNoSourceLock = errors.New("no matching locked move at the source")
)

// IssuerConfig configures one bank's MINT co-signer.
type IssuerConfig struct {
	Name    string
	Member  [32]byte
	Key     *ecdsa.PrivateKey
	Domains []Domain
	Dial    DialFunc // nil: DialOwn
}

// Issuer is a bank's own signer for MINT messages of its token.
type Issuer struct {
	name   string
	member [32]byte
	key    *ecdsa.PrivateKey
	addr   common.Address
	views  map[uint32]*view

	mu       sync.Mutex
	signed   map[MsgID]bool
	refusals []Fault
}

// NewIssuer dials the bank's own node for every domain.
func NewIssuer(ctx context.Context, cfg IssuerConfig) (*Issuer, error) {
	dial := cfg.Dial
	if dial == nil {
		dial = DialOwn
	}
	s := &Issuer{name: cfg.Name, member: cfg.Member, key: cfg.Key, addr: crypto.PubkeyToAddress(cfg.Key.PublicKey),
		views: map[uint32]*view{}, signed: map[MsgID]bool{}}
	for _, d := range cfg.Domains {
		src, err := dial(ctx, d)
		if err != nil {
			s.Close()
			return nil, err
		}
		s.views[d.ID] = &view{Domain: d, src: src}
	}
	return s, nil
}

// Member is the bank whose token this signer co-signs.
func (s *Issuer) Member() [32]byte { return s.member }

// Address is the bank's issuer key.
func (s *Issuer) Address() common.Address { return s.addr }

// Close closes the signer's connections.
func (s *Issuer) Close() {
	for _, v := range s.views {
		v.src.Close()
	}
}

// Refusals lists what the signer refused to co-sign.
func (s *Issuer) Refusals() []Fault {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Fault(nil), s.refusals...)
}

// CoSign signs a MINT of the bank's own token after checking, on its own
// node, that the source messenger emitted exactly this message in a final
// block and still holds the move PENDING with the same issuer, holder,
// amount, destination and deadline.
func (s *Issuer) CoSign(ctx context.Context, message []byte) ([]byte, error) {
	sig, e, err := s.coSign(ctx, message)
	if err != nil && !errors.Is(err, ErrNotFinal) {
		s.mu.Lock()
		s.refusals = append(s.refusals, Fault{Domain: e.Source, Err: fmt.Errorf("%s: %w", e, err)})
		s.mu.Unlock()
	}
	return sig, err
}

func (s *Issuer) coSign(ctx context.Context, message []byte) ([]byte, Envelope, error) {
	e, err := DecodeEnvelope(message)
	if err != nil {
		return nil, e, err
	}
	if e.Kind != KindMint {
		return nil, e, fmt.Errorf("%w: %s", ErrNotMint, KindName(e.Kind))
	}
	if e.Member != s.member {
		return nil, e, fmt.Errorf("%w: a MINT of %s", ErrNotOwnToken, idString(e.Member))
	}
	src, ok := s.views[e.Source]
	if !ok {
		return nil, e, fmt.Errorf("%w: source %d", ErrUnknownDomain, e.Source)
	}
	dst, ok := s.views[e.Dest]
	if !ok || e.Dest == e.Source {
		return nil, e, fmt.Errorf("%w: destination %d", ErrUnknownDomain, e.Dest)
	}
	if err := checkChain(ctx, src.src, src.Domain); err != nil {
		return nil, e, err
	}
	final, ok, err := finalHead(ctx, src.src, src.Domain)
	if err != nil {
		return nil, e, err
	}
	head := final + src.Finality
	logs, err := src.src.FilterLogs(ctx, ethereum.FilterQuery{
		FromBlock: big.NewInt(0), ToBlock: new(big.Int).SetUint64(head), Addresses: []common.Address{src.Messenger},
		Topics: [][]common.Hash{{MessageSentID}, {TopicUint(uint64(e.Dest))}, {TopicUint(e.Nonce)}},
	})
	if err != nil {
		return nil, e, err
	}
	var found, finalFound bool
	for _, l := range logs {
		if l.Removed || l.Address != src.Messenger {
			continue
		}
		msg, _, derr := decodeMessageSent(l)
		if derr != nil || !bytes.Equal(msg, message) {
			continue
		}
		found = true
		if ok && l.BlockNumber <= final {
			finalFound = true
		}
	}
	if !found {
		return nil, e, fmt.Errorf("%w: no MessageSent for %s on domain %d", ErrNoSourceLock, e, e.Source)
	}
	if !finalFound {
		return nil, e, fmt.Errorf("%w: %s on domain %d", ErrNotFinal, e, e.Source)
	}
	m, err := readMove(ctx, src.src, src.Messenger, e.Nonce)
	if err != nil {
		return nil, e, err
	}
	if m.Status != MovePending || m.Issuer != e.Member || m.Holder != e.Counterparty || m.Amount.Cmp(e.Amount) != 0 ||
		m.Dest != e.Dest || m.Deadline != e.Deadline {
		return nil, e, fmt.Errorf("%w: %s, source move is %+v", ErrNoSourceLock, e, m)
	}
	s.mu.Lock()
	s.signed[e.ID()] = true
	s.mu.Unlock()
	sig, err := Sign(s.key, Digest(src.Messenger, dst.Messenger, message))
	return sig, e, err
}

// Move mirrors ICrossChainMessenger.Move.
type Move struct {
	Issuer   [32]byte
	Holder   [32]byte
	Wallet   common.Address
	Amount   *big.Int
	Dest     uint32
	Deadline uint64
	Status   uint8
}

var moveSelector = crypto.Keccak256([]byte("move(uint64)"))[:4]

// readMove calls messenger.move(nonce) on the signer's own node.
func readMove(ctx context.Context, src Source, messenger common.Address, nonce uint64) (Move, error) {
	data := append(append([]byte(nil), moveSelector...), TopicUint(nonce).Bytes()...)
	out, err := src.CallContract(ctx, ethereum.CallMsg{To: &messenger, Data: data}, nil)
	if err != nil {
		return Move{}, err
	}
	if len(out) != 7*32 {
		return Move{}, fmt.Errorf("move(%d): %d bytes returned", nonce, len(out))
	}
	w := func(i int) []byte { return out[32*i : 32*i+32] }
	var m Move
	copy(m.Issuer[:], w(0))
	copy(m.Holder[:], w(1))
	copy(m.Wallet[:], w(2)[12:])
	m.Amount = new(big.Int).SetBytes(w(3))
	m.Dest = uint32(new(big.Int).SetBytes(w(4)).Uint64())
	m.Deadline = new(big.Int).SetBytes(w(5)).Uint64()
	m.Status = uint8(new(big.Int).SetBytes(w(6)).Uint64())
	return m, nil
}

func idString(id [32]byte) string {
	n := bytes.IndexByte(id[:], 0)
	if n < 0 {
		n = 32
	}
	if n == 0 {
		return "0x0"
	}
	return string(id[:n])
}
