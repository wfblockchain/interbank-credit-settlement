package xchain

import (
	"bytes"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func sample() Envelope {
	var m, c, r [32]byte
	copy(m[:], "BNKAUS30")
	copy(c[:], "BNKBUS30")
	r[31] = 7
	return Envelope{Version: Version, Kind: KindMint, Source: 1, Dest: 2, Nonce: 42, Member: m, Counterparty: c,
		Recipient: common.HexToAddress("0x00000000000000000000000000000000000000aa"), Amount: big.NewInt(4_000_000_000_000),
		Epoch: 3, Deadline: 1_760_000_000, Ref: r}
}

func TestEnvelopeRoundTrip(t *testing.T) {
	e := sample()
	b := e.Encode()
	if len(b) != 384 {
		t.Fatalf("%d bytes", len(b))
	}
	got, err := DecodeEnvelope(b)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Encode(), b) || got.Amount.Cmp(e.Amount) != 0 || got.ID() != e.ID() || got.Recipient != e.Recipient {
		t.Fatalf("round trip: %+v", got)
	}
}

func TestEnvelopeStrictDecode(t *testing.T) {
	b := sample().Encode()
	for name, mut := range map[string]func([]byte){
		"kind beyond uint8":     func(b []byte) { b[32+30] = 1 },
		"dest beyond uint32":    func(b []byte) { b[96+27] = 1 },
		"dirty address padding": func(b []byte) { b[7*32] = 1 },
	} {
		c := append([]byte(nil), b...)
		mut(c)
		if _, err := DecodeEnvelope(c); !errors.Is(err, ErrMalformed) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if _, err := DecodeEnvelope(b[:383]); !errors.Is(err, ErrMalformed) {
		t.Fatal("short message accepted")
	}
}

func TestMessageSentLogDecodes(t *testing.T) {
	e := sample()
	l := MessageSentLog(common.HexToAddress("0x01"), 9, e)
	msg, got, err := decodeMessageSent(l)
	if err != nil || !bytes.Equal(msg, e.Encode()) || got.ID() != e.ID() {
		t.Fatalf("%v %+v", err, got)
	}
	l.Topics[2] = TopicUint(43) // the indexed nonce disagrees with the envelope
	if _, _, err := decodeMessageSent(l); !errors.Is(err, ErrMalformed) {
		t.Fatalf("topic mismatch accepted: %v", err)
	}
}

func TestSignRecoverAndDigestBinding(t *testing.T) {
	k, _ := crypto.GenerateKey()
	msg := sample().Encode()
	src, dst := common.HexToAddress("0x0a"), common.HexToAddress("0x0b")
	d := Digest(src, dst, msg)
	sig, err := Sign(k, d)
	if err != nil || (sig[64] != 27 && sig[64] != 28) {
		t.Fatalf("%v v=%d", err, sig[64])
	}
	a, err := Recover(d, sig)
	if err != nil || a != crypto.PubkeyToAddress(k.PublicKey) {
		t.Fatalf("recover %s %v", a, err)
	}
	if Digest(dst, src, msg) == d || Digest(src, common.HexToAddress("0x0c"), msg) == d {
		t.Fatal("digest not bound to both messengers")
	}
}
