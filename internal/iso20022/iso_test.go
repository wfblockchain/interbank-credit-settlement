package iso20022

import (
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/moov-io/iso20022/pkg/camt_v08"
	"github.com/moov-io/iso20022/pkg/document"
	"github.com/moov-io/iso20022/pkg/pacs_v08"
)

// independentMod97 computes the rearranged reference as a big integer, as the
// standard describes it, as an oracle for the streaming mod97.
func independentMod97(ref string) int64 {
	s := normalizeRF(ref)
	s = s[4:] + s[:4]
	var digits strings.Builder
	for _, c := range s {
		if c >= 'A' && c <= 'Z' {
			digits.WriteString(big.NewInt(int64(c - 'A' + 10)).String())
		} else {
			digits.WriteRune(c)
		}
	}
	n, _ := new(big.Int).SetString(digits.String(), 10)
	return new(big.Int).Mod(n, big.NewInt(97)).Int64()
}

func TestCreditorReferenceVectors(t *testing.T) {
	cases := []struct {
		ref   string
		valid bool
	}{
		{"RF18539007547034", true},           // ISO 11649 published example
		{"RF18 5390 0754 7034", true},        // print format
		{"rf18539007547034", true},           // case-insensitive
		{"RF18000000000539007547034", true},  // leading zeros do not change the check
		{"RF19539007547034", false},          // wrong check digits
		{"RF18539007547035", false},          // altered body
		{"RF18", false},                      // no body
		{"XX18539007547034", false},          // not RF
		{"RF1A539007547034", false},          // non-numeric check digits
		{"RF18539007547034000000000", false}, // 25+ chars body beyond 21
		{"RF18-539007547034", false},         // non-alphanumeric
	}
	for _, c := range cases {
		err := ValidateCreditorReference(c.ref)
		if (err == nil) != c.valid {
			t.Errorf("%q: valid=%v, err=%v", c.ref, c.valid, err)
		}
	}
	got, err := CreditorReference("539007547034")
	if err != nil || got != "RF18539007547034" {
		t.Fatalf("generator: %q %v", got, err)
	}
}

func TestBatchReference(t *testing.T) {
	cases := []uint64{0, 1, 7, 42, 1000, 123456789, 9_999_999_999_999_999_999}
	for _, b := range cases {
		ref, err := BatchReference(b)
		if err != nil {
			t.Fatalf("batch %d: %v", b, err)
		}
		if !strings.HasPrefix(ref[4:], "CS") || len(ref) > 25 {
			t.Fatalf("batch %d: %q", b, ref)
		}
		if independentMod97(ref) != 1 {
			t.Fatalf("batch %d: %q fails the big-integer check", b, ref)
		}
		back, err := ParseBatchReference(ref)
		if err != nil || back != b {
			t.Fatalf("batch %d: parsed %d %v", b, back, err)
		}
	}
	if _, err := BatchReference(10_000_000_000_000_000_000); err == nil {
		t.Fatal("a 20-digit batch fits the 21-character RF body after CS")
	}
	// Valid RF references that are not canonical batch references.
	notBatch, _ := CreditorReference("INV2026")
	lead, _ := CreditorReference("CS007")
	for _, ref := range []string{"RF18539007547034", notBatch, lead, "RF18 5390 0754 7034"} {
		if _, err := ParseBatchReference(ref); err == nil {
			t.Errorf("%q accepted as a batch reference", ref)
		}
	}
}

func TestEndToEndID(t *testing.T) {
	cases := []struct {
		batch   uint64
		leg, n  uint32
		want    string
		tooLong bool
	}{
		{7, 0, 1, "CS7-L0-1", false},
		{123456, 12, 3, "CS123456-L12-3", false},
		{1<<64 - 1, 1<<32 - 1, 1, "", true}, // 2+20+2+10+2 = 36
		{1 << 40, 1 << 20, 99, "CS1099511627776-L1048576-99", false},
	}
	for _, c := range cases {
		got, err := EndToEndID(c.batch, c.leg, c.n)
		if c.tooLong {
			if err == nil {
				t.Errorf("%d/%d/%d: %q accepted", c.batch, c.leg, c.n, got)
			}
			continue
		}
		if err != nil || got != c.want {
			t.Errorf("%d/%d/%d: %q %v", c.batch, c.leg, c.n, got, err)
		}
		b, l, n, err := ParseEndToEndID(got)
		if err != nil || b != c.batch || l != c.leg || n != c.n {
			t.Errorf("parse %q: %d %d %d %v", got, b, l, n, err)
		}
	}
	for _, bad := range []string{"", "CS7-L0", "CS7-0-1", "CS07-L0-1", "CS7-L00-1", "XX7-L0-1", "CS7-L0-1-2", "CS-L0-1", "CS7-L0-+1"} {
		if _, _, _, err := ParseEndToEndID(bad); err == nil {
			t.Errorf("%q parsed", bad)
		}
	}
}

func sampleTransfer(clearing string) Transfer {
	return Transfer{
		MsgID:      "MSG-CS42-L3-2",
		CreatedAt:  time.Date(2026, 10, 6, 14, 5, 0, 0, time.UTC),
		SettleDate: time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC),
		Clearing:   clearing,
		Batch:      42,
		Leg:        3,
		Part:       2,
		Amount:     25_000_000_120_000, // $25,000,000.12
		Debtor:     Bank{BIC: "BNKAUS30", Name: "Bank A", Account: "A-SETTLE-001"},
		Creditor:   Bank{BIC: "BNKBUS30", Name: "Bank B", Account: "B-SETTLE-001"},
	}
}

func assertClean(t *testing.T, b []byte) {
	t.Helper()
	s := string(b)
	for _, bad := range []string{"<Prtry></Prtry>", "<Cd></Cd>", "<IBAN></IBAN>", "<Dt></Dt>", "0001-01-01", "e+0", "<Id></Id>"} {
		if strings.Contains(s, bad) {
			t.Fatalf("document carries %s:\n%s", bad, s)
		}
	}
}

func TestPacs008(t *testing.T) {
	for _, clearing := range []string{ClearingRTP, ClearingCHIPS} {
		b, err := Pacs008(sampleTransfer(clearing))
		if err != nil {
			t.Fatal(err)
		}
		assertClean(t, b)
		s := string(b)
		for _, want := range []string{"<Ref>RF", "<Cd>SCOR</Cd>", "<EndToEndId>CS42-L3-2</EndToEndId>", ">25000000.12<"} {
			if !strings.Contains(s, want) {
				t.Fatalf("%s missing %s:\n%s", clearing, want, s)
			}
		}
		// moov reads it back, and the read-back message validates.
		doc, err := document.ParseIso20022Document(b)
		if err != nil {
			t.Fatalf("moov cannot read what we wrote: %v\n%s", err, s)
		}
		m := doc.InspectMessage().(*pacs_v08.FIToFICustomerCreditTransferV08)
		if err := validate008(m); err != nil {
			t.Fatalf("read-back message fails validation: %v", err)
		}
		p, leg, err := ParseLeg(b)
		if err != nil {
			t.Fatal(err)
		}
		if leg != (LegRef{Batch: 42, Leg: 3, N: 2}) || p.Amount != 25_000_000_120_000 || p.Type != Pacs008Type ||
			p.DebtorAccount != "A-SETTLE-001" || p.CreditorAccount != "B-SETTLE-001" || p.DebtorBIC != "BNKAUS30" ||
			p.CreditorBIC != "BNKBUS30" || p.SettleDate.Format("2006-01-02") != "2026-10-06" {
			t.Fatalf("parsed %+v %+v", p, leg)
		}
	}
}

// The trap this package works around: moov's Validate checks both branches of
// a choice, so a message with a correctly typed creditor reference fails it.
func TestMoovChoiceTrap(t *testing.T) {
	b, err := Pacs008(sampleTransfer(ClearingCHIPS))
	if err != nil {
		t.Fatal(err)
	}
	doc, _ := document.ParseIso20022Document(b)
	m := doc.InspectMessage().(*pacs_v08.FIToFICustomerCreditTransferV08)
	if err := m.Validate(); err == nil {
		t.Fatal("moov's own Validate passed a message with a typed creditor reference; the workaround may be obsolete")
	}
	if err := validate008(m); err != nil {
		t.Fatal(err)
	}
	// Both branches set is refused.
	m.CdtTrfTxInf[0].RmtInf.Strd[0].CdtrRefInf.Tp.CdOrPrtry.Prtry = "X"
	if err := validate008(m); err == nil {
		t.Fatal("a choice with both branches passed")
	}
}

func TestPacs009(t *testing.T) {
	b, err := Pacs009(sampleTransfer(ClearingCHIPS))
	if err != nil {
		t.Fatal(err)
	}
	assertClean(t, b)
	s := string(b)
	for _, want := range []string{`xmlns="urn:iso:std:iso:20022:tech:xsd:pacs.009.001.08"`, "<FICdtTrf>", "<Cd>CHI</Cd>", "<Ustrd>RF"} {
		if !strings.Contains(s, want) {
			t.Fatalf("missing %s:\n%s", want, s)
		}
	}
	p, leg, err := ParseLeg(b)
	if err != nil {
		t.Fatal(err)
	}
	if leg != (LegRef{Batch: 42, Leg: 3, N: 2}) || p.Amount != 25_000_000_120_000 || p.Type != Pacs009Type ||
		p.DebtorBIC != "BNKAUS30" || p.CreditorAccount != "B-SETTLE-001" {
		t.Fatalf("parsed %+v %+v", p, leg)
	}
}

func TestTransferChecks(t *testing.T) {
	mut := []struct {
		name string
		f    func(*Transfer)
	}{
		{"sub-cent amount", func(x *Transfer) { x.Amount = 1_000_001 }},
		{"zero amount", func(x *Transfer) { x.Amount = 0 }},
		{"same bank", func(x *Transfer) { x.Creditor = x.Debtor }},
		{"bad BIC", func(x *Transfer) { x.Debtor.BIC = "bank a" }},
		{"unknown rail", func(x *Transfer) { x.Clearing = "ACH" }},
		{"EndToEndId too long", func(x *Transfer) { x.Batch, x.Leg = 1<<64-1, 1<<32-1 }},
		{"no MsgId", func(x *Transfer) { x.MsgID = "" }},
	}
	for _, m := range mut {
		x := sampleTransfer(ClearingRTP)
		m.f(&x)
		if _, err := Pacs008(x); err == nil {
			t.Errorf("pacs.008 %s: accepted", m.name)
		}
		if _, err := Pacs009(x); err == nil {
			t.Errorf("pacs.009 %s: accepted", m.name)
		}
	}
}

func TestLegMismatch(t *testing.T) {
	ref7, _ := BatchReference(7)
	cases := []struct {
		name string
		p    Payment
	}{
		{"no reference", Payment{EndToEndID: "CS7-L0-1"}},
		{"batch mismatch", Payment{Reference: ref7, EndToEndID: "CS8-L0-1"}},
		{"bad reference", Payment{Reference: "RF00CS7", EndToEndID: "CS7-L0-1"}},
		{"bad e2e", Payment{Reference: ref7, EndToEndID: "INV-1"}},
	}
	for _, c := range cases {
		if _, err := c.p.Leg(); err == nil {
			t.Errorf("%s: mapped to a leg", c.name)
		}
	}
	if l, err := (Payment{Reference: ref7, EndToEndID: "CS7-L4-1"}).Leg(); err != nil || l != (LegRef{7, 4, 1}) {
		t.Fatalf("%+v %v", l, err)
	}
}

func TestParsePaymentRefusesOthers(t *testing.T) {
	c, _ := Camt054(Notification{MsgID: "N1", At: time.Now(), Account: "A", Owner: "Bank A"})
	for _, b := range [][]byte{[]byte("garbage"), []byte("<Foo/>"), c} {
		if _, err := ParsePayment(b); err == nil {
			t.Errorf("accepted %.60q", b)
		}
	}
}

func TestCamt054(t *testing.T) {
	ref, _ := BatchReference(42)
	at := time.Date(2026, 10, 6, 21, 0, 0, 0, time.UTC)
	b, err := Camt054(Notification{
		MsgID: "NTF-A-20261006", At: at, Account: "A-SETTLE-001", Owner: "Bank A",
		Entries: []NotificationEntry{
			{RailTxID: "CHIPS-20261006-000001", Rail: ClearingCHIPS, Amount: 30_000_000_000_000, BookedAt: at.Add(-time.Hour), EndToEndID: "CS42-L0-1", Reference: ref},
			{RailTxID: "RTP-20261006-00000002", Rail: ClearingRTP, Amount: 5_000_000_000_000, Credit: true, BookedAt: at, EndToEndID: "CS42-L3-1", Reference: ref},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	assertClean(t, b)
	doc, err := document.ParseIso20022Document(b)
	if err != nil {
		t.Fatalf("moov cannot read it: %v\n%s", err, b)
	}
	m := doc.InspectMessage().(*camt_v08.BankToCustomerDebitCreditNotificationV08)
	n := m.Ntfctn[0]
	if string(n.Acct.Id.Othr.Id) != "A-SETTLE-001" || len(n.Ntry) != 2 {
		t.Fatalf("%+v", n)
	}
	e0, e1 := n.Ntry[0], n.Ntry[1]
	if e0.CdtDbtInd != "DBIT" || e0.Amt.Value != 30_000_000 || string(*e0.AcctSvcrRef) != "CHIPS-20261006-000001" ||
		string(e0.Sts.Cd) != "BOOK" || string(*e0.NtryDtls[0].TxDtls[0].Refs.EndToEndId) != "CS42-L0-1" {
		t.Fatalf("entry 0: %+v", e0)
	}
	if e1.CdtDbtInd != "CRDT" || string(*e1.NtryDtls[0].TxDtls[0].RmtInf.Strd[0].CdtrRefInf.Ref) != ref {
		t.Fatalf("entry 1: %+v", e1)
	}
}

func TestAmounts(t *testing.T) {
	cases := []struct {
		units uint64
		dec   string
		ok    bool
	}{
		{1_000_000, "1.00", true},
		{10_000, "0.01", true},
		{10_000_000_000_000, "10000000.00", true},
		{5_000, "", false},
	}
	for _, c := range cases {
		got, err := ToDecimal(c.units)
		if (err == nil) != c.ok || got != c.dec {
			t.Errorf("%d: %q %v", c.units, got, err)
		}
	}
	if _, err := FromDecimal(1.005); err == nil {
		t.Error("sub-cent decimal accepted")
	}
	if v, err := FromDecimal(25000000.12); err != nil || v != 25_000_000_120_000 {
		t.Errorf("%d %v", v, err)
	}
}
