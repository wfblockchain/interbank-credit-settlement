// Package xchain is the cross-chain transport of design §4: the operator's
// attesters, the banks' issuer signers and an untrusted relayer that carry the
// messengers' envelopes between the home chain and the spokes.
//
//   - Attesters (n, a strict majority signs) each read every chain from their
//     own node (a separate RPC connection per attester and chain), wait for
//     that chain's finality depth (0 on the BFT home chain, N blocks on a
//     spoke), check the MessageSent log against the messenger they know for
//     that domain and sign the envelope's digest. An attester signs at most one
//     message per (source, nonce) and signs nothing from a node that reports
//     the wrong chain id.
//   - Issuer signers (one per bank) co-sign a MINT only for their own token,
//     and only after reading, from their own node, that the source messenger
//     holds the move PENDING with exactly the envelope's fields and that the
//     MessageSent log is final.
//   - The relayer holds no authority: it gathers signatures, submits
//     receiveMessage with a strict majority (and the issuer's signature for a
//     MINT), skips a nonce the destination has already consumed, retries a
//     delivery refused by the inbound rate limit, and after a MINT's deadline
//     cancels it at the destination (cancelExpired, attesters only).
package xchain

import (
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Version is the envelope version the messengers accept.
const Version uint8 = 4

// Envelope kinds (CrossChainMessenger constants).
const (
	KindMint uint8 = iota
	KindMintAck
	KindMintCancel
	KindEnvelopeGrant
	KindEnvelopeRelease
	KindCut
	KindBatchLocked
	KindBurnBatch
	KindSuspend
)

// KindName names an envelope kind.
func KindName(k uint8) string {
	names := []string{"MINT", "MINT_ACK", "MINT_CANCEL", "ENVELOPE_GRANT", "ENVELOPE_RELEASE", "CUT", "BATCH_LOCKED", "BURN_BATCH", "SUSPEND"}
	if int(k) < len(names) {
		return names[k]
	}
	return fmt.Sprintf("Kind(%d)", k)
}

// Inbound states (ICrossChainMessenger.Inbound).
const (
	InboundNone uint8 = iota
	InboundDone
	InboundMinted
	InboundCancelled
)

// Move statuses (ICrossChainMessenger.MoveStatus).
const (
	MoveNone uint8 = iota
	MovePending
	MoveCompleted
	MoveCancelled
)

// Envelope mirrors ICrossChainMessenger.Envelope.
type Envelope struct {
	Version      uint8
	Kind         uint8
	Source       uint32
	Dest         uint32
	Nonce        uint64
	Member       [32]byte
	Counterparty [32]byte
	Recipient    common.Address
	Amount       *big.Int
	Epoch        uint64
	Deadline     uint64
	Ref          [32]byte
}

// envelopeWords: every field is static, so abi.encode(Envelope) is twelve
// 32-byte words.
const envelopeWords = 12

// Encode is abi.encode(envelope).
func (e Envelope) Encode() []byte {
	out := make([]byte, 32*envelopeWords)
	word := func(i int, v *big.Int) { v.FillBytes(out[32*i : 32*i+32]) }
	u := func(v uint64) *big.Int { return new(big.Int).SetUint64(v) }
	word(0, u(uint64(e.Version)))
	word(1, u(uint64(e.Kind)))
	word(2, u(uint64(e.Source)))
	word(3, u(uint64(e.Dest)))
	word(4, u(e.Nonce))
	copy(out[32*5:], e.Member[:])
	copy(out[32*6:], e.Counterparty[:])
	copy(out[32*7+12:], e.Recipient[:])
	amt := e.Amount
	if amt == nil {
		amt = new(big.Int)
	}
	word(8, amt)
	word(9, u(e.Epoch))
	word(10, u(e.Deadline))
	copy(out[32*11:], e.Ref[:])
	return out
}

// ErrMalformed: the bytes are not a canonical abi.encode(Envelope).
var ErrMalformed = errors.New("malformed envelope")

// DecodeEnvelope is abi.decode(message, (Envelope)), strict: every small
// integer must fit its type, so one envelope has exactly one encoding.
func DecodeEnvelope(b []byte) (Envelope, error) {
	if len(b) != 32*envelopeWords {
		return Envelope{}, fmt.Errorf("%w: %d bytes", ErrMalformed, len(b))
	}
	w := func(i int) []byte { return b[32*i : 32*i+32] }
	small := func(i int, bits int) (uint64, error) {
		v := new(big.Int).SetBytes(w(i))
		if v.BitLen() > bits {
			return 0, fmt.Errorf("%w: word %d exceeds uint%d", ErrMalformed, i, bits)
		}
		return v.Uint64(), nil
	}
	var e Envelope
	var err error
	var v uint64
	if v, err = small(0, 8); err != nil {
		return e, err
	}
	e.Version = uint8(v)
	if v, err = small(1, 8); err != nil {
		return e, err
	}
	e.Kind = uint8(v)
	if v, err = small(2, 32); err != nil {
		return e, err
	}
	e.Source = uint32(v)
	if v, err = small(3, 32); err != nil {
		return e, err
	}
	e.Dest = uint32(v)
	if e.Nonce, err = small(4, 64); err != nil {
		return e, err
	}
	copy(e.Member[:], w(5))
	copy(e.Counterparty[:], w(6))
	if new(big.Int).SetBytes(w(7)[:12]).Sign() != 0 {
		return e, fmt.Errorf("%w: recipient is not an address", ErrMalformed)
	}
	copy(e.Recipient[:], w(7)[12:])
	e.Amount = new(big.Int).SetBytes(w(8))
	if e.Epoch, err = small(9, 64); err != nil {
		return e, err
	}
	if e.Deadline, err = small(10, 64); err != nil {
		return e, err
	}
	copy(e.Ref[:], w(11))
	return e, nil
}

// MsgID identifies a message: the source domain's nonce is unique per source.
type MsgID struct {
	Source uint32
	Nonce  uint64
}

func (m MsgID) String() string { return fmt.Sprintf("%d/%d", m.Source, m.Nonce) }

// ID is the envelope's (source, nonce).
func (e Envelope) ID() MsgID { return MsgID{Source: e.Source, Nonce: e.Nonce} }

func (e Envelope) String() string {
	return fmt.Sprintf("%s %d→%d #%d", KindName(e.Kind), e.Source, e.Dest, e.Nonce)
}

var digestTag = crypto.Keccak256Hash([]byte("CreditCrossChainMessage.v4"))

// Digest is what the attesters (and for a MINT the issuer) sign, as
// CrossChainMessenger._digest computes it on the destination: bound to the
// source messenger and the destination messenger.
func Digest(srcMessenger, dstMessenger common.Address, message []byte) common.Hash {
	buf := make([]byte, 0, 128)
	buf = append(buf, digestTag[:]...)
	buf = append(buf, common.LeftPadBytes(srcMessenger[:], 32)...)
	buf = append(buf, common.LeftPadBytes(dstMessenger[:], 32)...)
	mh := crypto.Keccak256(message)
	buf = append(buf, mh...)
	inner := crypto.Keccak256(buf)
	return crypto.Keccak256Hash([]byte("\x19Ethereum Signed Message:\n32"), inner)
}

// Sign signs a digest as r ‖ s ‖ v with v ∈ {27, 28} (what ECDSA.recover takes).
func Sign(key *ecdsa.PrivateKey, digest common.Hash) ([]byte, error) {
	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		return nil, err
	}
	sig[64] += 27
	return sig, nil
}

// Recover returns the signer of a digest.
func Recover(digest common.Hash, sig []byte) (common.Address, error) {
	if len(sig) != 65 {
		return common.Address{}, fmt.Errorf("signature length %d", len(sig))
	}
	s := append([]byte(nil), sig...)
	if s[64] >= 27 {
		s[64] -= 27
	}
	pub, err := crypto.SigToPub(digest[:], s)
	if err != nil {
		return common.Address{}, err
	}
	return crypto.PubkeyToAddress(*pub), nil
}
