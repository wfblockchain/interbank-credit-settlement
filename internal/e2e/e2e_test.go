package e2e

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/listener"
	"interbank-credit-settlement/internal/operator"
	"interbank-credit-settlement/internal/rails"
	"interbank-credit-settlement/internal/reconcile"
)

// newWorld starts a fresh anvil and home chain at start, or skips the test
// when anvil is not available.
func newWorld(t *testing.T, start time.Time) *World {
	t.Helper()
	bin, err := AnvilBin()
	if err != nil {
		t.Skipf("SKIP end-to-end test: %v (e.g. ANVIL_BIN=/path/to/anvil)", err)
	}
	if dir, err := deploy.ArtifactsDir(); err == nil {
		if _, err := deploy.ModuleRoot(); err != nil {
			t.Fatal(err)
		}
		t.Logf("artifacts: %s", dir)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	t.Cleanup(cancel)
	w, err := NewWorld(ctx, bin, Options{Start: start, Log: t.Logf})
	if err != nil {
		t.Fatalf("world: %v", err)
	}
	t.Cleanup(w.Close)
	return w
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func u(v uint64) *big.Int { return new(big.Int).SetUint64(v) }

func status(t *testing.T, w *World, b uint64) uint8 {
	t.Helper()
	bt, err := w.D.Batch(w.Ctx, b)
	must(t, err)
	return bt.Status
}

func requireStatus(t *testing.T, w *World, b uint64, want uint8) {
	t.Helper()
	if got := status(t, w, b); got != want {
		t.Fatalf("batch %d is %s, want %s", b, deploy.StatusName(got), deploy.StatusName(want))
	}
}

func requireFinalized(t *testing.T, w *World, b uint64) deploy.BatchView {
	t.Helper()
	bt, err := w.D.Batch(w.Ctx, b)
	must(t, err)
	if bt.Status != deploy.StatusComplete || !bt.Finalized {
		t.Fatalf("batch %d: %s finalized=%v", b, deploy.StatusName(bt.Status), bt.Finalized)
	}
	return bt
}

func requireNoExposure(t *testing.T, w *World) {
	t.Helper()
	x, err := w.Exposure()
	must(t, err)
	s, err := w.Supply()
	must(t, err)
	if x.Sign() != 0 || s.Sign() != 0 {
		t.Fatalf("exposure %s, token supply %s; want zero", operator.Money(x), operator.Money(s))
	}
	w.Log("exposure between banks: $0; deposit-token supply: $0")
}

func requireClean(t *testing.T, w *World) {
	t.Helper()
	if err := w.Op.Reconcile(w.Ctx); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if w.Op.Halted() != nil {
		t.Fatalf("operator halted: %v", w.Op.Halted())
	}
	w.Log("three-way reconciliation clean: %d rail payments, %d listener submissions, chain agrees",
		len(railPayments(w)), len(w.Listener.Log()))
}

func railPayments(w *World) []rails.Entry {
	var out []rails.Entry
	for _, j := range []*rails.Journal{w.CHIPS.Journal(), w.RTP.Journal()} {
		for _, e := range j.Entries() {
			if e.Kind == rails.KindPayment {
				out = append(out, e)
			}
		}
	}
	return out
}

func chainPayments(t *testing.T, w *World) []reconcile.ChainPayment {
	t.Helper()
	c, err := reconcile.ReadChain(w.Ctx, w.D)
	must(t, err)
	return c
}

// 1. Bank A pays Bank B up to B's receiver cap → CapReached → cut → plan →
// one CHIPS payment carrying a pacs.009 → 3-of-5 attestation → COMPLETE →
// finalize → exposure zero, reconciliation clean.
func TestE2E_CapReachedSettlesOverCHIPS(t *testing.T) {
	day := Date("2026-10-06") // a Tuesday
	w := newWorld(t, At(day, 9, 0))
	A := w.Banks["A"]
	must(t, w.AdvanceTo(At(day, 10, 0)))

	w.Log("— Bank A's customers pay Bank B's customers $100M (Bank B's receiver cap) —")
	var last operator.PayResult
	for i := 0; i < 4; i++ {
		var err error
		last, err = A.Pay(w.Ctx, ID("B"), 25*M)
		must(t, err)
		if last.Queued {
			t.Fatalf("payment %d queued (reason %d)", i, last.Reason)
		}
	}
	if !last.CapHit {
		t.Fatal("the payment reaching the cap did not emit CapReached")
	}
	net, err := w.D.NetPosition(w.Ctx, ID("B"))
	must(t, err)
	if net.Cmp(u(100*M)) != 0 {
		t.Fatalf("B's net position %s", net)
	}

	w.Log("— the operator reacts to CapReached —")
	must(t, w.Step())

	recs := w.Op.Records()
	if len(recs) != 1 || recs[0].Trigger != deploy.TriggerCap || recs[0].Rail != rails.CHIPS {
		t.Fatalf("records %+v", recs)
	}
	if len(recs[0].Legs) != 1 || recs[0].Legs[0].Payer != ID("A") || recs[0].Legs[0].Payee != ID("B") ||
		recs[0].Legs[0].Amount.Cmp(u(100*M)) != 0 {
		t.Fatalf("plan %+v", recs[0].Legs)
	}
	sent := A.SentPayments()
	if len(sent) != 1 || sent[0].Rail != rails.CHIPS {
		t.Fatalf("A sent %+v", sent)
	}
	msg, leg, err := iso20022.ParseLeg(sent[0].Entry.Message)
	must(t, err)
	ref, _ := iso20022.BatchReference(1)
	if msg.Type != iso20022.Pacs009Type || msg.EndToEndID != "CS1-L0-1" || msg.Reference != ref || leg.Batch != 1 || leg.Leg != 0 ||
		msg.Amount != 100*M || msg.DebtorBIC != "BNKAUS30" || msg.CreditorBIC != "BNKBUS30" {
		t.Fatalf("message %+v leg %+v", msg, leg)
	}
	w.Log("CHIPS release %s carried a %s, EndToEndId %s, reference %s", sent[0].Entry.TxID, msg.Type, msg.EndToEndID, msg.Reference)

	subs := w.Listener.Log()
	if len(subs) != 1 || subs[0].Err != nil || len(subs[0].Signers) != 3 || subs[0].RailTxID != sent[0].Entry.TxID {
		t.Fatalf("listener log %+v", subs)
	}
	for i := 1; i < len(subs[0].Signers); i++ {
		if bytes.Compare(subs[0].Signers[i-1][:], subs[0].Signers[i][:]) >= 0 {
			t.Fatal("signatures not strictly ascending")
		}
	}
	for i, s := range w.Listener.Signers() {
		if s.Cursor(rails.CHIPS) == 0 {
			t.Fatalf("signer %d never read the CHIPS feed", i)
		}
	}
	used, err := w.D.Attestor.Bool(w.Ctx, "usedRailTx", listener.RailTxHash(sent[0].Entry.TxID))
	must(t, err)
	if !used {
		t.Fatal("rail transaction not marked used")
	}
	bt := requireFinalized(t, w, 1)
	if bt.Trigger != deploy.TriggerCap || bt.Burned.Cmp(u(100*M)) != 0 {
		t.Fatalf("batch %+v", bt)
	}
	requireNoExposure(t, w)
	requireClean(t, w)
}

// 2. End of day: positions among A, B and C → multilateral plan → CHIPS legs
// → all settled the same business day.
func TestE2E_EndOfDayMultilateral(t *testing.T) {
	day := Date("2026-10-06")
	w := newWorld(t, At(day, 9, 0))
	A, B, C := w.Banks["A"], w.Banks["B"], w.Banks["C"]
	must(t, w.AdvanceTo(At(day, 11, 0)))
	w.Log("— a business day of interbank payments —")
	for _, p := range []struct {
		from *operator.Bank
		to   string
		amt  uint64
	}{{A, "B", 30 * M}, {B, "C", 20 * M}, {C, "A", 5 * M}, {A, "C", 10 * M}} {
		res, err := p.from.Pay(w.Ctx, ID(p.to), p.amt)
		must(t, err)
		if res.Queued || res.CapHit {
			t.Fatalf("unexpected %+v", res)
		}
	}
	must(t, w.AdvanceTo(At(day, 15, 0)))
	if len(w.Op.Records()) != 0 {
		t.Fatal("cut before end of day")
	}
	w.Log("— 16:30 ET: the end-of-day cut —")
	must(t, w.AdvanceTo(At(day, 17, 30)))

	recs := w.Op.Records()
	if len(recs) != 1 || recs[0].Trigger != deploy.TriggerEndOfDay || recs[0].Rail != rails.CHIPS {
		t.Fatalf("records %+v", recs)
	}
	if !recs[0].CutAt.Equal(calendar.EndOfDayCut(day)) {
		t.Fatalf("cut at %s", recs[0].CutAt)
	}
	// Net: A −35, B +10, C +25 → A pays C 25 (largest first), then A pays B 10.
	want := []operator.Leg{{Payer: ID("A"), Payee: ID("C"), Amount: u(25 * M)}, {Payer: ID("A"), Payee: ID("B"), Amount: u(10 * M)}}
	legs, err := w.D.Legs(w.Ctx, 1)
	must(t, err)
	if len(legs) != len(want) {
		t.Fatalf("legs %+v", legs)
	}
	for k := range want {
		if legs[k].Payer != want[k].Payer || legs[k].Payee != want[k].Payee || legs[k].Amount.Cmp(want[k].Amount) != 0 ||
			legs[k].Paid.Cmp(legs[k].Amount) != 0 {
			t.Fatalf("leg %d: %+v", k, legs[k])
		}
	}
	cutoff := calendar.At(day, calendar.CHIPSCutoffHour, 0)
	for _, e := range w.CHIPS.Journal().Entries() {
		if !calendar.Date(e.FinalAt).Equal(day) || e.FinalAt.After(cutoff) {
			t.Fatalf("%s final at %s, not inside the business day", e.TxID, e.FinalAt)
		}
		m, err := iso20022.ParsePayment(e.Message)
		must(t, err)
		if m.Type != iso20022.Pacs009Type {
			t.Fatalf("%s carried %s", e.TxID, m.Type)
		}
	}
	if n := len(w.CHIPS.Journal().Entries()); n != 2 {
		t.Fatalf("%d CHIPS payments, want 2", n)
	}
	requireFinalized(t, w, 1)
	if !calendar.Date(recs[0].CompleteAt).Equal(day) || recs[0].CompleteAt.After(cutoff) {
		t.Fatalf("complete at %s", recs[0].CompleteAt)
	}
	win, err := w.D.Window(w.Ctx)
	must(t, err)
	if win != deploy.WindowOffHours {
		t.Fatal("window not OFF_HOURS after the end-of-day cut")
	}
	w.Log("all positions settled on business day %s by %s ET", day.Format("2006-01-02"), recs[0].CompleteAt.In(calendar.ET).Format("15:04"))
	requireNoExposure(t, w)
	requireClean(t, w)
}

// 3. Saturday: payments only within the attested RTP prefund; a cap hit is
// settled by ten $10M RTP payments; the batch is PARTIAL until the tenth.
func TestE2E_SaturdayRTPWithinPrefund(t *testing.T) {
	fri := Date("2026-10-09")
	sat := Date("2026-10-10")
	w := newWorld(t, At(fri, 10, 0)) // Fedwire open: RTP positions funded and attested ($150M each)
	A, C := w.Banks["A"], w.Banks["C"]
	must(t, w.AdvanceTo(At(sat, 10, 0)))
	win, err := w.D.Window(w.Ctx)
	must(t, err)
	if win != deploy.WindowOffHours {
		t.Fatal("Saturday is not OFF_HOURS")
	}
	pre, err := w.D.Register.BigInt(w.Ctx, "rtpPrefund", ID("A"))
	must(t, err)
	w.Log("— Saturday: no unsecured credit; Bank A's attested RTP prefund is %s —", operator.Money(pre))

	for _, amt := range []uint64{60 * M, 40 * M} {
		res, err := A.Pay(w.Ctx, ID("B"), amt)
		must(t, err)
		if res.Queued {
			t.Fatalf("queued: %+v", res)
		}
		if amt == 40*M && !res.CapHit {
			t.Fatal("no CapReached at B's cap")
		}
	}
	_, err = A.Pay(w.Ctx, ID("C"), 60*M)
	if err == nil || !strings.Contains(err.Error(), "OffHoursPrefundExceeded") {
		t.Fatalf("payment beyond the prefund: %v", err)
	}
	w.Log("Bank A → Bank C $60M refused on chain: %v", err)
	q, err := C.Pay(w.Ctx, ID("B"), 5*M)
	must(t, err)
	if !q.Queued || q.Reason != 4 {
		t.Fatalf("C's payment over B's cap: %+v", q)
	}

	w.Log("— the operator cuts on CapReached; Bank A pays its leg in ten RTP payments —")
	A.SetAuto(false)
	must(t, w.Step())
	recs := w.Op.Records()
	if len(recs) != 1 || recs[0].Rail != rails.RTP || len(recs[0].Instructions) != 10 {
		t.Fatalf("records %+v", recs)
	}
	requireStatus(t, w, 1, deploy.StatusPlanned)
	for i := 1; i <= 10; i++ {
		s, err := A.PayNext()
		must(t, err)
		m, err := iso20022.ParsePayment(s.Entry.Message)
		must(t, err)
		if m.Type != iso20022.Pacs008Type || m.Amount != 10*M || m.EndToEndID != fmt.Sprintf("CS1-L0-%d", i) {
			t.Fatalf("part %d: %+v", i, m)
		}
		must(t, w.Listener.Sync(w.Ctx))
		st := status(t, w, 1)
		w.Log("after RTP part %d/10 (%s): batch 1 is %s", i, s.Entry.TxID, deploy.StatusName(st))
		if i < 10 && st != deploy.StatusPartial {
			t.Fatalf("after part %d: %s, want PARTIAL", i, deploy.StatusName(st))
		}
		if i == 10 && st != deploy.StatusComplete {
			t.Fatalf("after part 10: %s, want COMPLETE", deploy.StatusName(st))
		}
	}
	must(t, w.Step())
	requireFinalized(t, w, 1)
	if n := len(w.Listener.Log()); n != 10 {
		t.Fatalf("%d attestations, want 10", n)
	}
	if recs[0].Drained != 1 {
		t.Fatalf("drained %d", recs[0].Drained)
	}
	qe, err := w.D.QueueEntry(w.Ctx, q.Seq)
	must(t, err)
	if qe.State != deploy.QueuePaid {
		t.Fatalf("queued payment state %d", qe.State)
	}
	nb, err := w.D.NetPosition(w.Ctx, ID("B"))
	must(t, err)
	if nb.Cmp(u(5*M)) != 0 {
		t.Fatalf("B's position after the drain %s", nb)
	}
	pending, err := w.D.Ledger.BigInt(w.Ctx, "pending", ID("A"), ID("B"))
	must(t, err)
	sa, err := w.D.TokenSupply(w.Ctx, ID("A"))
	must(t, err)
	if pending.Sign() != 0 || sa.Sign() != 0 {
		t.Fatalf("A→B pending %s, A-dT supply %s", pending, sa)
	}
	w.Log("batch exposure released ($0 pending, A-dT supply $0); the queued $5M from Bank C was drained after settlement")
	requireClean(t, w)
}

func camt056(orig rails.Entry, now time.Time) []byte {
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.056.001.08"><FIToFIPmtCxlReq>
<Assgnmt><Id>RR-%s</Id><Assgnr><Agt><FinInstnId><BICFI>BNKAUS30</BICFI></FinInstnId></Agt></Assgnr>
<Assgne><Agt><FinInstnId><BICFI>BNKBUS30</BICFI></FinInstnId></Agt></Assgne><CreDtTm>%s</CreDtTm></Assgnmt>
<Undrlyg><TxInf><OrgnlUETR>%s</OrgnlUETR><OrgnlIntrBkSttlmAmt Ccy="USD">%d.00</OrgnlIntrBkSttlmAmt>
<CxlRsnInf><Rsn><Cd>DUPL</Cd></Rsn></CxlRsnInf></TxInf></Undrlyg></FIToFIPmtCxlReq></Document>`,
		orig.TxID, now.UTC().Format(time.RFC3339), orig.TxID, orig.Amount/USD))
}

// 4. Faults: a duplicate rail delivery is attested once; a copied reference
// from the wrong payer goes to manual review; a camt.056 return request
// changes nothing; a reconciliation break halts cuts.
func TestE2E_Faults(t *testing.T) {
	day := Date("2026-10-06")
	w := newWorld(t, At(day, 9, 0))
	A, B, C := w.Banks["A"], w.Banks["B"], w.Banks["C"]
	must(t, w.AdvanceTo(At(day, 18, 0))) // off hours: settlement over RTP
	_, err := A.Pay(w.Ctx, ID("B"), 8*M)
	must(t, err)
	_, err = C.Pay(w.Ctx, ID("B"), 3*M)
	must(t, err)
	C.SetAuto(false) // Bank C is slow to pay its leg
	must(t, B.RequestSettlement(w.Ctx))
	must(t, w.Step())
	recs := w.Op.Records()
	if len(recs) != 1 || recs[0].Trigger != deploy.TriggerReceiverCall || recs[0].Rail != rails.RTP || len(recs[0].Legs) != 2 {
		t.Fatalf("records %+v", recs)
	}
	sent := A.SentPayments()
	if len(sent) != 1 {
		t.Fatalf("A sent %d", len(sent))
	}
	txA := sent[0].Entry
	requireStatus(t, w, 1, deploy.StatusPartial)
	leg0 := func() (paid, over *big.Int) {
		l, err := w.D.Leg(w.Ctx, 1, 0)
		must(t, err)
		o, err := w.D.Batches.BigInt(w.Ctx, "overpaid", uint64(1), uint32(0))
		must(t, err)
		return l.Paid, o
	}
	recorded := func(id string) int {
		n := 0
		for _, c := range chainPayments(t, w) {
			if c.RailTxID == listener.RailTxHash(id) {
				n++
			}
		}
		return n
	}

	w.Log("— fault 1: the RTP feed delivers %s twice —", txA.TxID)
	must(t, w.RTP.Journal().Redeliver(txA.TxID))
	must(t, w.Step())
	if n := recorded(txA.TxID); n != 1 {
		t.Fatalf("%s recorded %d times", txA.TxID, n)
	}
	for i, s := range w.Listener.Signers() {
		found := false
		for _, sk := range s.Skipped() {
			if sk.Entry.TxID == txA.TxID && errors.Is(sk.Reason, listener.ErrAlreadySigned) {
				found = true
			}
		}
		if !found {
			t.Fatalf("signer %d did not skip the duplicate", i)
		}
	}
	if paid, over := leg0(); paid.Cmp(u(8*M)) != 0 || over.Sign() != 0 {
		t.Fatalf("leg 0 paid %s overpaid %s", paid, over)
	}
	w.Log("duplicate delivery skipped by all five signers; attested once")

	w.Log("— fault 2: Bank C copies Bank A's reference and EndToEndId onto its own payment to Bank B —")
	cAcct, _ := w.Dir.Get(ID("C"))
	cp, err := w.RTP.CopyReference(txA.TxID, cAcct.RTPAcct)
	must(t, err)
	must(t, w.Step())
	for i, rv := range w.Listener.ManualReview() {
		found := false
		for _, r := range rv {
			if r.Entry.TxID == cp.TxID && errors.Is(r.Reason, listener.ErrMessageMismatch) {
				found = true
			}
		}
		if !found {
			t.Fatalf("signer %d did not send %s to manual review: %+v", i, cp.TxID, rv)
		}
	}
	if n := recorded(cp.TxID); n != 0 {
		t.Fatal("copied-reference payment attested")
	}
	if paid, over := leg0(); paid.Cmp(u(8*M)) != 0 || over.Sign() != 0 {
		t.Fatalf("leg 0 paid %s overpaid %s", paid, over)
	}
	w.Log("%s (Bank C's payment quoting Bank A's leg) is in manual review at all five signers; nothing signed", cp.TxID)

	w.Log("— fault 3: a camt.056 return request for %s —", txA.TxID)
	bAcct, _ := w.Dir.Get(ID("B"))
	before := w.RTP.Position(bAcct.RTPAcct)
	rr, err := w.RTP.RequestReturn(txA.TxID, "DUPL", camt056(txA, w.Clock.Now()))
	must(t, err)
	must(t, w.Step())
	if w.RTP.Position(bAcct.RTPAcct) != before {
		t.Fatal("return request moved money")
	}
	if paid, _ := leg0(); paid.Cmp(u(8*M)) != 0 {
		t.Fatalf("leg 0 paid %s after the return request", paid)
	}
	for i, s := range w.Listener.Signers() {
		found := false
		for _, sk := range s.Skipped() {
			if sk.Entry.TxID == rr.TxID && errors.Is(sk.Reason, listener.ErrNotPayment) {
				found = true
			}
		}
		if !found {
			t.Fatalf("signer %d did not skip the return request", i)
		}
	}
	requireStatus(t, w, 1, deploy.StatusPartial)
	w.Log("return request %s skipped (not a payment): the posted payment stays final and attested", rr.TxID)
	requireClean(t, w)

	w.Log("— fault 4: three signer keys attest an RTP payment that never happened (Bank C's leg) —")
	cOps := C.Ops.Addr
	forged := listener.Payment{Batch: 1, Leg: 1, Rail: uint8(rails.RTP), RailTxID: listener.RailTxHash("RTP-20261006-99999999"),
		PayerAcct: cOps, Payer: ID("C"), Payee: ID("B"), Amount: u(3 * M), FinalAt: uint64(w.Clock.Now().Unix())}
	dg, err := listener.Digest(w.Listener.Domain(), forged)
	must(t, err)
	keys := append(w.SignerKeys[:0:0], w.SignerKeys[:3]...)
	sort.Slice(keys, func(i, j int) bool {
		a, b := crypto.PubkeyToAddress(keys[i].PublicKey), crypto.PubkeyToAddress(keys[j].PublicKey)
		return bytes.Compare(a[:], b[:]) < 0
	})
	var sigs [][]byte
	for _, k := range keys {
		s, err := listener.SignDigest(k, dg)
		must(t, err)
		sigs = append(sigs, s)
	}
	type abiPayment struct {
		Batch     uint64
		Leg       uint32
		Rail      uint8
		RailTxId  [32]byte
		PayerAcct common.Address
		Payer     [32]byte
		Payee     [32]byte
		Amount    *big.Int
		FinalAt   uint64
	}
	ap := abiPayment{Batch: forged.Batch, Leg: forged.Leg, Rail: forged.Rail, RailTxId: forged.RailTxID, PayerAcct: forged.PayerAcct,
		Payer: forged.Payer, Payee: forged.Payee, Amount: forged.Amount, FinalAt: forged.FinalAt}
	_, err = w.D.Send(w.Ctx, w.D.Attestor, C.Ops, "attestPayment", ap, sigs)
	must(t, err)
	requireStatus(t, w, 1, deploy.StatusComplete)
	err = w.Op.Reconcile(w.Ctx)
	var be *reconcile.BreakError
	if !errors.As(err, &be) || !errors.Is(err, reconcile.ErrBreak) || !be.Has(reconcile.ChainWithoutRail) || !be.Has(reconcile.ChainWithoutListener) {
		t.Fatalf("reconcile: %v", err)
	}
	if w.Op.Halted() == nil {
		t.Fatal("operator not halted")
	}
	w.Log("break detected: %v", err)

	w.Log("— a new receiver call: the operator must refuse to cut —")
	_, err = A.Pay(w.Ctx, ID("B"), 1*M)
	must(t, err)
	must(t, B.RequestSettlement(w.Ctx))
	must(t, w.Step())
	if !errors.Is(w.Op.LastRefusal(), operator.ErrHalted) {
		t.Fatalf("last refusal %v", w.Op.LastRefusal())
	}
	n, err := w.D.BatchCount(w.Ctx)
	must(t, err)
	if n != 1 {
		t.Fatalf("%d batches cut while halted", n)
	}
	w.Log("cut refused: %v", w.Op.LastRefusal())
}

// 5. Default: the debtor misses the deadline → declare → waterfall payments
// (COLLATERAL, POOL, survivor) → COMPLETE; the next cut is refused until the
// pool is re-attested; after re-attestation it proceeds.
func TestE2E_DefaultWaterfall(t *testing.T) {
	day := Date("2026-10-06")
	w := newWorld(t, At(day, 9, 0))
	A, B, C := w.Banks["A"], w.Banks["B"], w.Banks["C"]
	must(t, w.AdvanceTo(At(day, 10, 0)))
	_, err := A.Pay(w.Ctx, ID("B"), 40*M)
	must(t, err)
	A.SetAuto(false) // Bank A will not pay
	must(t, B.RequestSettlement(w.Ctx))
	must(t, w.Step())
	recs := w.Op.Records()
	if len(recs) != 1 || recs[0].Rail != rails.CHIPS {
		t.Fatalf("records %+v", recs)
	}
	requireStatus(t, w, 1, deploy.StatusPlanned)
	w.Log("— Bank A misses its %s deadline —", recs[0].Deadline.In(calendar.ET).Format("15:04"))
	must(t, w.AdvanceTo(At(day, 11, 30)))

	m, err := w.D.Member(w.Ctx, ID("A"))
	must(t, err)
	if m.Status != deploy.MemberDefaulted {
		t.Fatalf("A status %d", m.Status)
	}
	if !recs[0].Defaulted {
		t.Fatal("no default recorded")
	}
	covers := map[[32]byte]*big.Int{}
	for _, c := range recs[0].Covers {
		covers[c.Source] = c.Amount
	}
	wantCovers := map[[32]byte]uint64{listener.CollateralPayer: 20 * M, listener.PoolPayer: 15 * M, ID("B"): 2_500_000 * USD, ID("C"): 2_500_000 * USD}
	for src, amt := range wantCovers {
		if covers[src] == nil || covers[src].Cmp(u(amt)) != 0 {
			t.Fatalf("cover from %s: %v, want %d", deploy.IDString(src), covers[src], amt)
		}
	}
	payers := map[[32]byte]uint64{}
	for _, c := range chainPayments(t, w) {
		payers[c.Payer] += c.Amount.Uint64()
	}
	if payers[listener.CollateralPayer] != 20*M || payers[listener.PoolPayer] != 15*M || payers[ID("C")] != 2_500_000*USD || len(payers) != 3 {
		t.Fatalf("attested waterfall payers %v", payers)
	}
	bt := requireFinalized(t, w, 1)
	if bt.Burned.Cmp(u(40*M)) != 0 {
		t.Fatalf("burned %s", bt.Burned)
	}
	w.Log("waterfall paid: collateral $20M, pool $15M, Bank C $2.5M; Bank B absorbed $2.5M; batch 1 COMPLETE and finalized")
	requireNoExposure(t, w)
	requireClean(t, w)

	pt, err := w.D.Register.BigInt(w.Ctx, "poolTotal")
	must(t, err)
	pr, err := w.D.Register.BigInt(w.Ctx, "poolRequired")
	must(t, err)
	if pt.Cmp(pr) >= 0 {
		t.Fatalf("pool %s not below required %s", pt, pr)
	}
	w.Log("— the pool is down to %s of the required %s: the next cut must be refused —", operator.Money(pt), operator.Money(pr))
	_, err = C.Pay(w.Ctx, ID("B"), 1*M)
	must(t, err)
	must(t, B.RequestSettlement(w.Ctx))
	must(t, w.Step())
	if !errors.Is(w.Op.LastRefusal(), operator.ErrPoolNotReplenished) {
		t.Fatalf("last refusal %v", w.Op.LastRefusal())
	}
	if n, _ := w.D.BatchCount(w.Ctx); n != 1 {
		t.Fatalf("batch count %d", n)
	}

	w.Log("— Banks B and C top up the pool; the listener attests the joint account statement —")
	must(t, w.Attest(deploy.KindPool, ID("B"), 7_500_000*USD))
	must(t, w.Attest(deploy.KindPool, ID("C"), 7_500_000*USD))
	must(t, w.Step())
	if w.Op.LastRefusal() != nil {
		t.Fatalf("still refused: %v", w.Op.LastRefusal())
	}
	recs = w.Op.Records()
	if len(recs) != 2 || recs[1].Trigger != deploy.TriggerReceiverCall {
		t.Fatalf("records %+v", recs)
	}
	requireFinalized(t, w, 2)
	requireNoExposure(t, w)
	requireClean(t, w)
}
