package listener

import (
	"bytes"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/rails"
)

func key(seed string) *ecdsa.PrivateKey {
	k, err := crypto.ToECDSA(crypto.Keccak256([]byte(seed)))
	if err != nil {
		panic(err)
	}
	return k
}

var testDomain = Domain{ChainID: big.NewInt(31337), VerifyingContract: common.HexToAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")}

// word left-pads to 32 bytes, as abi.encode does for static types.
func word(b []byte) []byte { return common.LeftPadBytes(b, 32) }

func u(v uint64) []byte { return word(new(big.Int).SetUint64(v).Bytes()) }

// The digest computed through go-ethereum's apitypes equals one assembled by
// hand from the EIP-712 definition.
func TestDigestMatchesHandComputed(t *testing.T) {
	p := Payment{
		Batch: 42, Leg: 3, Rail: 2, RailTxID: RailTxHash("RTP-20261006-00000017"),
		PayerAcct: common.HexToAddress("0x00000000000000000000000000000000000000a1"),
		Payer:     MemberID("BNKAUS30"), Payee: MemberID("BNKBUS30"),
		Amount: big.NewInt(10_000_000_000_000), FinalAt: 1_791_300_000,
	}
	k := crypto.Keccak256
	domainType := k([]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"))
	domainSep := k(domainType, k([]byte("CreditSettlementAttestor")), k([]byte("1")),
		word(testDomain.ChainID.Bytes()), word(testDomain.VerifyingContract.Bytes()))
	typeHash := k([]byte("Payment(uint64 batch,uint32 leg,uint8 rail,bytes32 railTxId,address payerAcct,bytes32 payer,bytes32 payee,uint256 amount,uint64 finalAt)"))
	structHash := k(typeHash, u(p.Batch), u(uint64(p.Leg)), u(uint64(p.Rail)), p.RailTxID[:], word(p.PayerAcct.Bytes()),
		p.Payer[:], p.Payee[:], word(p.Amount.Bytes()), u(p.FinalAt))
	want := common.BytesToHash(k([]byte{0x19, 0x01}, domainSep, structHash))

	got, err := Digest(testDomain, p)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("digest %s, hand-computed %s", got, want)
	}
	if !bytes.Equal(typeHash, crypto.Keccak256([]byte(PaymentTypeString))) {
		t.Fatal("PaymentTypeString differs from the spec")
	}
	// Any field change changes the digest; another domain changes it too.
	p2 := p
	p2.Leg = 4
	if d2, _ := Digest(testDomain, p2); d2 == got {
		t.Fatal("leg not bound")
	}
	if d3, _ := Digest(Domain{ChainID: big.NewInt(1), VerifyingContract: testDomain.VerifyingContract}, p); d3 == got {
		t.Fatal("chain id not bound")
	}
	sk := key("signer-0")
	sig, err := SignDigest(sk, got)
	if err != nil {
		t.Fatal(err)
	}
	if who, err := Recover(got, sig); err != nil || who != crypto.PubkeyToAddress(sk.PublicKey) || (sig[64] != 27 && sig[64] != 28) {
		t.Fatalf("recover %s %v", who, err)
	}
}

// --- scenario harness ---

var (
	bankA = iso20022.Bank{BIC: "BNKAUS30", Name: "Bank A"}
	bankB = iso20022.Bank{BIC: "BNKBUS30", Name: "Bank B"}
	bankC = iso20022.Bank{BIC: "BNKCUS30", Name: "Bank C"}
	pool  = iso20022.Bank{BIC: "OPERUS30", Name: "Loss pool"}
)

func acctOf(b iso20022.Bank, r rails.Rail) string { return fmt.Sprintf("%s-%s", b.BIC, r) }

type env struct {
	clk     *rails.ManualClock
	chips   *rails.CHIPSSim
	rtp     *rails.RTPSim
	book    *MemBook
	signers []*Signer
}

const batch = uint64(7)

func newEnv(t *testing.T, nSigners int) *env {
	t.Helper()
	at, _ := time.ParseInLocation("2006-01-02 15:04", "2026-10-06 10:00", calendar.ET)
	e := &env{clk: rails.NewManualClock(at), book: NewMemBook()}
	e.chips = rails.NewCHIPS(e.clk)
	e.rtp = rails.NewRTP(e.clk)
	owners := map[iso20022.Bank][32]byte{bankA: MemberID("BNKAUS30"), bankB: MemberID("BNKBUS30"), bankC: MemberID("BNKCUS30"), pool: PoolPayer}
	for b, owner := range owners {
		for _, r := range []rails.Rail{rails.CHIPS, rails.RTP} {
			acct := acctOf(b, r)
			if r == rails.CHIPS {
				e.chips.Open(acct)
			} else {
				e.rtp.Open(acct)
				if _, err := e.rtp.Fund(acct, 50_000_000_000_000); err != nil {
					t.Fatal(err)
				}
			}
			e.book.SetAccount(r, acct, Account{Owner: owner, Addr: common.BytesToAddress(crypto.Keccak256([]byte(acct))[12:])})
		}
	}
	// Batch 7: leg 0 A→B, leg 1 C→B, leg 2 A→C.
	e.book.OpenLeg(OpenLeg{Batch: batch, Leg: 0, Payer: owners[bankA], Payee: owners[bankB]})
	e.book.OpenLeg(OpenLeg{Batch: batch, Leg: 1, Payer: owners[bankC], Payee: owners[bankB]})
	e.book.OpenLeg(OpenLeg{Batch: batch, Leg: 2, Payer: owners[bankA], Payee: owners[bankC]})
	feeds := map[rails.Rail]Feed{rails.CHIPS: e.chips.Journal(), rails.RTP: e.rtp.Journal()}
	for i := 0; i < nSigners; i++ {
		e.signers = append(e.signers, NewSigner(key(fmt.Sprintf("signer-%d", i)), testDomain, e.book, feeds))
	}
	return e
}

func (e *env) msg(t *testing.T, r rails.Rail, b uint64, leg, n uint32, from, to iso20022.Bank, amount uint64) []byte {
	t.Helper()
	from.Account, to.Account = acctOf(from, r), acctOf(to, r)
	tr := iso20022.Transfer{MsgID: fmt.Sprintf("M-%d-%d-%d-%s", b, leg, n, from.BIC), CreatedAt: e.clk.Now(), SettleDate: calendar.Date(e.clk.Now()),
		Batch: b, Leg: leg, Part: n, Amount: amount, Debtor: from, Creditor: to}
	var m []byte
	var err error
	if r == rails.CHIPS {
		tr.Clearing = iso20022.ClearingCHIPS
		m, err = iso20022.Pacs009(tr)
	} else {
		tr.Clearing = iso20022.ClearingRTP
		m, err = iso20022.Pacs008(tr)
	}
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// pay sends a payment whose message names (b, leg, n) from `from` to `to`.
func (e *env) pay(t *testing.T, r rails.Rail, b uint64, leg, n uint32, from, to iso20022.Bank, amount uint64) rails.Entry {
	t.Helper()
	m := e.msg(t, r, b, leg, n, from, to, amount)
	var ent rails.Entry
	var err error
	if r == rails.CHIPS {
		ent, err = e.chips.Pay(acctOf(from, r), acctOf(to, r), amount, m)
	} else {
		ent, err = e.rtp.Pay(acctOf(from, r), acctOf(to, r), amount, m)
	}
	if err != nil {
		t.Fatal(err)
	}
	return ent
}

// pollAll polls every signer and returns the rail tx ids each signed.
func (e *env) pollAll() [][]string {
	out := make([][]string, len(e.signers))
	for i, s := range e.signers {
		for _, a := range s.Poll() {
			out[i] = append(out[i], a.TxID)
		}
	}
	return out
}

func TestListenerScenarios(t *testing.T) {
	const amt = 4_000_000_000_000 // $4M
	type result struct {
		signed  []string // tx ids every signer must have signed (in order)
		review  []error  // reasons every signer must have put in review (in order)
		skipped []error
	}
	cases := []struct {
		name string
		run  func(t *testing.T, e *env) result
	}{
		{"final CHIPS payment signed", func(t *testing.T, e *env) result {
			p := e.pay(t, rails.CHIPS, batch, 0, 1, bankA, bankB, amt)
			return result{signed: []string{p.TxID}}
		}},
		{"duplicate delivery signed once", func(t *testing.T, e *env) result {
			p := e.pay(t, rails.CHIPS, batch, 0, 1, bankA, bankB, amt)
			if err := e.chips.Journal().Redeliver(p.TxID); err != nil {
				t.Fatal(err)
			}
			return result{signed: []string{p.TxID}, skipped: []error{ErrAlreadySigned}}
		}},
		{"duplicate delivered in a later poll signed once", func(t *testing.T, e *env) result {
			p := e.pay(t, rails.RTP, batch, 0, 1, bankA, bankB, amt)
			got := e.pollAll()
			for _, g := range got {
				if len(g) != 1 || g[0] != p.TxID {
					t.Fatalf("first poll %v", got)
				}
			}
			_ = e.rtp.Journal().Redeliver(p.TxID)
			return result{skipped: []error{ErrAlreadySigned}}
		}},
		{"wrong payer not signed", func(t *testing.T, e *env) result {
			// Bank C pays leg 0 (Bank A's leg) with its own, honest message.
			e.pay(t, rails.CHIPS, batch, 0, 1, bankC, bankB, amt)
			return result{review: []error{ErrPayerMismatch}}
		}},
		{"copied reference from the wrong payer not signed", func(t *testing.T, e *env) result {
			p := e.pay(t, rails.RTP, batch, 0, 1, bankA, bankB, amt)
			if _, err := e.rtp.CopyReference(p.TxID, acctOf(bankC, rails.RTP)); err != nil {
				t.Fatal(err)
			}
			return result{signed: []string{p.TxID}, review: []error{ErrMessageMismatch}}
		}},
		{"copied reference with a rewritten debtor not signed", func(t *testing.T, e *env) result {
			// Bank C copies the RF reference and EndToEndId but names itself as debtor.
			m := e.msg(t, rails.RTP, batch, 0, 1, bankC, bankB, amt)
			if _, err := e.rtp.Pay(acctOf(bankC, rails.RTP), acctOf(bankB, rails.RTP), amt, m); err != nil {
				t.Fatal(err)
			}
			return result{review: []error{ErrPayerMismatch}}
		}},
		{"wrong payee not signed", func(t *testing.T, e *env) result {
			e.pay(t, rails.CHIPS, batch, 0, 1, bankA, bankC, amt)
			return result{review: []error{ErrPayeeMismatch}}
		}},
		{"return request ignored, payment stays signed", func(t *testing.T, e *env) result {
			p := e.pay(t, rails.RTP, batch, 0, 1, bankA, bankB, amt)
			if _, err := e.rtp.RequestReturn(p.TxID, "DUPL", []byte("<camt.056/>")); err != nil {
				t.Fatal(err)
			}
			return result{signed: []string{p.TxID}, skipped: []error{ErrNotPayment}}
		}},
		{"non-final entry not signed", func(t *testing.T, e *env) result {
			m := e.msg(t, rails.CHIPS, batch, 0, 1, bankA, bankB, amt)
			e.chips.Journal().DeliverNonFinal(rails.Entry{TxID: "CHIPS-20261006-999999", PayerAcct: acctOf(bankA, rails.CHIPS),
				PayeeAcct: acctOf(bankB, rails.CHIPS), Amount: amt, Message: m})
			return result{review: []error{ErrNotFinal}}
		}},
		{"delayed entry signed when it arrives", func(t *testing.T, e *env) result {
			e.chips.Journal().DelayNext(1)
			p := e.pay(t, rails.CHIPS, batch, 2, 1, bankA, bankC, amt)
			for _, g := range e.pollAll() {
				if len(g) != 0 {
					t.Fatalf("signed before delivery: %v", g)
				}
			}
			if err := e.chips.Journal().Release(p.TxID); err != nil {
				t.Fatal(err)
			}
			return result{signed: []string{p.TxID}}
		}},
		{"waterfall payer only after the cover instruction", func(t *testing.T, e *env) result {
			e.pay(t, rails.RTP, batch, 1, 1, pool, bankB, amt)
			for _, g := range e.pollAll() {
				if len(g) != 0 {
					t.Fatalf("pool signed without an instruction: %v", g)
				}
			}
			e.book.AllowWaterfall(batch, 1, PoolPayer)
			p := e.pay(t, rails.RTP, batch, 1, 2, pool, bankB, amt)
			return result{signed: []string{p.TxID}, review: []error{ErrPayerMismatch}}
		}},
		{"RTP parts of one leg each signed", func(t *testing.T, e *env) result {
			p1 := e.pay(t, rails.RTP, batch, 2, 1, bankA, bankC, rails.RTPLimit)
			p2 := e.pay(t, rails.RTP, batch, 2, 2, bankA, bankC, 2_500_000_000_000)
			return result{signed: []string{p1.TxID, p2.TxID}}
		}},
		{"closed or unknown batch not signed", func(t *testing.T, e *env) result {
			e.pay(t, rails.CHIPS, batch+1, 0, 1, bankA, bankB, amt)
			e.book.CloseBatch(batch)
			e.pay(t, rails.CHIPS, batch, 0, 1, bankA, bankB, amt)
			return result{review: []error{ErrNoOpenLeg, ErrNoOpenLeg}}
		}},
		{"payment without a settlement reference not signed", func(t *testing.T, e *env) result {
			if _, err := e.chips.Pay(acctOf(bankA, rails.CHIPS), acctOf(bankB, rails.CHIPS), amt, []byte("<Document/>")); err != nil {
				t.Fatal(err)
			}
			return result{review: []error{ErrNoLegReference}}
		}},
		{"amount differs from the message not signed", func(t *testing.T, e *env) result {
			m := e.msg(t, rails.CHIPS, batch, 0, 1, bankA, bankB, amt)
			if _, err := e.chips.Pay(acctOf(bankA, rails.CHIPS), acctOf(bankB, rails.CHIPS), amt-10_000, m); err != nil {
				t.Fatal(err)
			}
			return result{review: []error{ErrMessageMismatch}}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t, 3)
			want := c.run(t, e)
			got := e.pollAll()
			for i, s := range e.signers {
				if fmt.Sprint(got[i]) != fmt.Sprint(want.signed) && !(len(got[i]) == 0 && len(want.signed) == 0) {
					t.Fatalf("signer %d signed %v, want %v", i, got[i], want.signed)
				}
				rv := s.ManualReview()
				if len(rv) != len(want.review) {
					t.Fatalf("signer %d review %v, want %v", i, rv, want.review)
				}
				for j := range rv {
					if !errors.Is(rv[j].Reason, want.review[j]) {
						t.Fatalf("signer %d review %d: %v, want %v", i, j, rv[j].Reason, want.review[j])
					}
				}
				// The harness's own fundings are skipped (not payments); compare
				// the rest.
				var tail []Skipped
				for _, x := range s.Skipped() {
					if x.Entry.Kind != rails.KindFunding {
						tail = append(tail, x)
					}
				}
				wantSkipped := want.skipped
				if len(tail) != len(wantSkipped) {
					t.Fatalf("signer %d skipped %v, want %v", i, tail, wantSkipped)
				}
				for j := range tail {
					if !errors.Is(tail[j].Reason, wantSkipped[j]) {
						t.Fatalf("signer %d skipped %d: %v", i, j, tail[j].Reason)
					}
				}
				if s.Cursor(rails.CHIPS) != uint64(len(mustRead(e.chips.Journal()))) {
					t.Fatalf("signer %d cursor not advanced", i)
				}
			}
		})
	}
}

func mustRead(j *rails.Journal) []rails.Entry { es, _ := j.Read(0); return es }

func TestSignOnlyOwnMatches(t *testing.T) {
	e := newEnv(t, 2)
	p := e.pay(t, rails.CHIPS, batch, 0, 1, bankA, bankB, 1_000_000)
	m, err := e.signers[0].Match(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.signers[1].Sign(m); !errors.Is(err, ErrForeignMatch) {
		t.Fatalf("signer 1 signed signer 0's match: %v", err)
	}
	if _, err := e.signers[0].Sign(m); err != nil {
		t.Fatal(err)
	}
	if _, err := e.signers[0].Sign(m); !errors.Is(err, ErrAlreadySigned) {
		t.Fatalf("signed twice: %v", err)
	}
	if _, err := e.signers[0].Match(p); !errors.Is(err, ErrAlreadySigned) {
		t.Fatalf("matched after signing: %v", err)
	}
	if m.Payment.Payer != MemberID("BNKAUS30") || m.Payment.Payee != MemberID("BNKBUS30") || m.Payment.Rail != 1 ||
		m.Payment.RailTxID != RailTxHash(p.TxID) || m.Payment.FinalAt != uint64(p.FinalAt.Unix()) || m.Payment.Amount.Uint64() != 1_000_000 {
		t.Fatalf("payment %+v", m.Payment)
	}
}

func TestAggregator(t *testing.T) {
	e := newEnv(t, 5)
	var addrs []common.Address
	for _, s := range e.signers {
		addrs = append(addrs, s.Address())
	}
	agg, err := NewAggregator(testDomain, 3, addrs)
	if err != nil {
		t.Fatal(err)
	}
	p := e.pay(t, rails.CHIPS, batch, 0, 1, bankA, bankB, 7_000_000)
	var atts []Attestation
	for _, s := range e.signers {
		atts = append(atts, s.Poll()...)
	}
	if len(atts) != 5 {
		t.Fatalf("%d attestations", len(atts))
	}

	// Tampered and foreign attestations are refused.
	bad := atts[0]
	bad.Sig = append([]byte(nil), bad.Sig...)
	bad.Sig[10] ^= 1
	if _, err := agg.Add(bad); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("tampered: %v", err)
	}
	outsider := NewSigner(key("outsider"), testDomain, e.book, map[rails.Rail]Feed{rails.CHIPS: e.chips.Journal()})
	oa := outsider.Poll()
	if _, err := agg.Add(oa[0]); !errors.Is(err, ErrNotSigner) {
		t.Fatalf("outsider: %v", err)
	}
	moved := atts[1]
	moved.Payment.Amount = big.NewInt(8_000_000)
	if _, err := agg.Add(moved); !errors.Is(err, ErrDigestMismatch) {
		t.Fatalf("altered payment: %v", err)
	}

	var call *Call
	for i, a := range atts {
		c, err := agg.Add(a)
		if err != nil {
			t.Fatal(err)
		}
		if i < 2 && c != nil {
			t.Fatal("call before k signatures")
		}
		if i == 2 {
			call = c
		}
		if i > 2 && c != nil {
			t.Fatal("second call for the same rail transaction")
		}
	}
	if call == nil || len(call.Sigs) != 3 || len(call.Signers) != 3 {
		t.Fatalf("call %+v", call)
	}
	for i := 1; i < len(call.Signers); i++ {
		if bytes.Compare(call.Signers[i-1][:], call.Signers[i][:]) >= 0 {
			t.Fatalf("signers not strictly ascending: %v", call.Signers)
		}
	}
	d, _ := Digest(testDomain, call.Payment)
	for i, sig := range call.Sigs {
		if who, _ := Recover(d, sig); who != call.Signers[i] {
			t.Fatalf("sig %d recovers %s, want %s", i, who, call.Signers[i])
		}
	}
	// The call data decodes back to the payment and the ordered signatures.
	method := parsedAttestorABI.Methods["attestPayment"]
	if !bytes.Equal(call.Data[:4], method.ID) {
		t.Fatal("selector")
	}
	vals, err := method.Inputs.Unpack(call.Data[4:])
	if err != nil {
		t.Fatal(err)
	}
	sigs := vals[1].([][]byte)
	if len(sigs) != 3 || !bytes.Equal(sigs[0], call.Sigs[0]) {
		t.Fatal("sigs not encoded in order")
	}
	if call.Payment.RailTxID != RailTxHash(p.TxID) {
		t.Fatal("rail tx id")
	}
	if _, err := NewAggregator(testDomain, 6, addrs); err == nil {
		t.Fatal("k above n accepted")
	}
}
