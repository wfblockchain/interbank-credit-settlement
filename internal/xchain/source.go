package xchain

import (
	"context"
	"fmt"
	"math/big"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Domain is one chain as the transport knows it.
type Domain struct {
	ID        uint32
	Name      string
	URL       string         // the default node; each signer dials its own connection
	ChainID   *big.Int       // what that chain's nodes must report
	Messenger common.Address // the messenger contract on it
	// Finality is the number of confirmations a signer waits for before it
	// treats a block as final: 0 on a BFT chain (the home chain), N on a spoke
	// with probabilistic finality.
	Finality uint64
	Home     bool // the hub's domain
}

// Source is a signer's own read access to one chain. *ethclient.Client is
// one; a test may substitute a lying node.
type Source interface {
	ChainID(ctx context.Context) (*big.Int, error)
	BlockNumber(ctx context.Context) (uint64, error)
	FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error)
	CallContract(ctx context.Context, call ethereum.CallMsg, block *big.Int) ([]byte, error)
	Close()
}

// DialFunc opens a signer's own connection to a domain.
type DialFunc func(ctx context.Context, d Domain) (Source, error)

// DialOwn opens a fresh JSON-RPC connection to the domain's node.
func DialOwn(ctx context.Context, d Domain) (Source, error) {
	c, err := ethclient.DialContext(ctx, d.URL)
	if err != nil {
		return nil, fmt.Errorf("dial domain %d (%s): %w", d.ID, d.URL, err)
	}
	return c, nil
}

// MessageSentID is topic 0 of MessageSent(uint32 dest, uint64 nonce, uint8 kind, bytes message).
var MessageSentID = crypto.Keccak256Hash([]byte("MessageSent(uint32,uint64,uint8,bytes)"))

// TopicUint is a uint as an indexed-topic word.
func TopicUint(v uint64) common.Hash {
	return common.BigToHash(new(big.Int).SetUint64(v))
}

// MessageSentLog builds the log a messenger emits for an envelope (used by
// tests to fabricate one).
func MessageSentLog(messenger common.Address, block uint64, e Envelope) types.Log {
	msg := e.Encode()
	data := make([]byte, 64, 64+len(msg))
	big.NewInt(32).FillBytes(data[:32])
	big.NewInt(int64(len(msg))).FillBytes(data[32:64])
	data = append(data, msg...)
	return types.Log{Address: messenger, BlockNumber: block,
		Topics: []common.Hash{MessageSentID, TopicUint(uint64(e.Dest)), TopicUint(e.Nonce), TopicUint(uint64(e.Kind))},
		Data:   data}
}

// decodeMessageSent checks a MessageSent log's shape and that its indexed
// topics agree with the envelope it carries, and returns the message bytes.
func decodeMessageSent(l types.Log) ([]byte, Envelope, error) {
	if len(l.Topics) != 4 || l.Topics[0] != MessageSentID {
		return nil, Envelope{}, fmt.Errorf("%w: not a MessageSent log", ErrMalformed)
	}
	if len(l.Data) < 64 || new(big.Int).SetBytes(l.Data[:32]).Cmp(big.NewInt(32)) != 0 {
		return nil, Envelope{}, fmt.Errorf("%w: bytes offset", ErrMalformed)
	}
	n := new(big.Int).SetBytes(l.Data[32:64])
	if !n.IsUint64() || n.Uint64() != 32*envelopeWords || uint64(len(l.Data)) < 64+n.Uint64() {
		return nil, Envelope{}, fmt.Errorf("%w: bytes length", ErrMalformed)
	}
	msg := append([]byte(nil), l.Data[64:64+n.Uint64()]...)
	e, err := DecodeEnvelope(msg)
	if err != nil {
		return nil, Envelope{}, err
	}
	if TopicUint(uint64(e.Dest)) != l.Topics[1] || TopicUint(e.Nonce) != l.Topics[2] || TopicUint(uint64(e.Kind)) != l.Topics[3] {
		return nil, Envelope{}, fmt.Errorf("%w: topics disagree with the envelope", ErrMalformed)
	}
	return msg, e, nil
}

// finalHead is the last block the signer treats as final on d, and whether
// any block is final yet.
func finalHead(ctx context.Context, src Source, d Domain) (uint64, bool, error) {
	head, err := src.BlockNumber(ctx)
	if err != nil {
		return 0, false, err
	}
	if head < d.Finality {
		return 0, false, nil
	}
	return head - d.Finality, true, nil
}

// checkChain verifies the node serves the domain's chain.
func checkChain(ctx context.Context, src Source, d Domain) error {
	id, err := src.ChainID(ctx)
	if err != nil {
		return err
	}
	if d.ChainID != nil && id.Cmp(d.ChainID) != 0 {
		return fmt.Errorf("%w: node for domain %d (%s) reports chain id %s, want %s", ErrWrongChain, d.ID, d.Name, id, d.ChainID)
	}
	return nil
}
