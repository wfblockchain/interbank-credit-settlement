package rails

import (
	"errors"
	"testing"
	"time"

	"interbank-credit-settlement/internal/calendar"
)

func et(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02 15:04", s, calendar.ET)
	if err != nil {
		panic(err)
	}
	return t
}

func TestCHIPSSessionAndIDs(t *testing.T) {
	clk := NewManualClock(et("2026-10-05 21:00")) // Monday evening: Tuesday's session
	c := NewCHIPS(clk, "A", "B")
	cases := []struct {
		at      string
		amount  uint64
		wantErr error
		wantID  string
	}{
		{"2026-10-05 21:00", 50_000_000_000_000_000, nil, "CHIPS-20261006-000001"}, // $50bn: no size limit
		{"2026-10-06 16:59", 1_000_000, nil, "CHIPS-20261006-000002"},
		{"2026-10-06 17:00", 1_000_000, ErrClosed, ""},
		{"2026-10-06 20:00", 1_000_000, ErrClosed, ""},
		{"2026-10-06 21:00", 1_000_000, nil, "CHIPS-20261007-000001"},
		{"2026-10-10 12:00", 1_000_000, ErrClosed, ""}, // Saturday
		{"2026-10-12 12:00", 1_000_000, ErrClosed, ""}, // Columbus Day
		{"2026-10-12 21:00", 1_000_000, nil, "CHIPS-20261013-000001"},
	}
	for _, tc := range cases {
		clk.Set(et(tc.at))
		e, err := c.Pay("A", "B", tc.amount, []byte("<msg/>"))
		if !errors.Is(err, tc.wantErr) {
			t.Fatalf("%s: err %v, want %v", tc.at, err, tc.wantErr)
		}
		if err == nil && (e.TxID != tc.wantID || !e.Final || !e.FinalAt.Equal(et(tc.at)) || e.Rail != CHIPS) {
			t.Fatalf("%s: entry %+v", tc.at, e)
		}
	}
	if pos := c.ClosingPositions(et("2026-10-06 00:00")); pos["A"] != -50_000_000_001_000_000 || pos["B"] != 50_000_000_001_000_000 {
		t.Fatalf("closing positions %v", pos)
	}
	clk.Set(et("2026-10-06 10:00"))
	for _, bad := range []struct {
		payer, payee string
		amount       uint64
		err          error
	}{
		{"A", "A", 1, ErrSameAccount},
		{"A", "Z", 1, ErrUnknownAccount},
		{"A", "B", 0, ErrZeroAmount},
	} {
		if _, err := c.Pay(bad.payer, bad.payee, bad.amount, nil); !errors.Is(err, bad.err) {
			t.Errorf("%+v: %v", bad, err)
		}
	}
}

func TestRTPLimitPrefundAndFunding(t *testing.T) {
	clk := NewManualClock(et("2026-10-10 12:00")) // Saturday
	r := NewRTP(clk, "A", "B")
	if _, err := r.Fund("A", 1); !errors.Is(err, ErrFedwireClosed) {
		t.Fatalf("funded on a Saturday: %v", err)
	}
	clk.Set(et("2026-10-09 18:30")) // Friday, Fedwire open until 19:00
	if _, err := r.Fund("A", 25_000_000_000_000); err != nil {
		t.Fatal(err)
	}
	clk.Set(et("2026-10-10 03:00")) // Saturday night: RTP is open
	cases := []struct {
		amount  uint64
		wantErr error
	}{
		{RTPLimit + 1, ErrOverLimit},
		{RTPLimit, nil},
		{RTPLimit, nil},
		{RTPLimit, ErrInsufficient}, // $5M left
		{5_000_000_000_000, nil},
		{1, ErrInsufficient},
	}
	for i, tc := range cases {
		e, err := r.Pay("A", "B", tc.amount, nil)
		if !errors.Is(err, tc.wantErr) {
			t.Fatalf("case %d: %v, want %v", i, err, tc.wantErr)
		}
		if err == nil && (!e.Final || e.Kind != KindPayment || e.TxID == "") {
			t.Fatalf("case %d: %+v", i, e)
		}
	}
	if r.Position("A") != 0 || r.Position("B") != 25_000_000_000_000 {
		t.Fatalf("positions %d %d", r.Position("A"), r.Position("B"))
	}
	if _, err := r.Defund("B", 1); !errors.Is(err, ErrFedwireClosed) {
		t.Fatalf("defunded off hours: %v", err)
	}
	clk.Set(et("2026-10-12 21:30")) // Columbus Day evening opens Tuesday's Fedwire day
	if _, err := r.Defund("B", 30_000_000_000_000); !errors.Is(err, ErrInsufficient) {
		t.Fatalf("over-defund: %v", err)
	}
	if _, err := r.Defund("B", 25_000_000_000_000); err != nil {
		t.Fatal(err)
	}
}

func TestRTPReturnRequestNeverReverses(t *testing.T) {
	clk := NewManualClock(et("2026-10-06 10:00"))
	r := NewRTP(clk, "A", "B")
	if _, err := r.Fund("A", 3_000_000); err != nil {
		t.Fatal(err)
	}
	pay, err := r.Pay("A", "B", 2_000_000, []byte("<pacs/>"))
	if err != nil {
		t.Fatal(err)
	}
	rr, err := r.RequestReturn(pay.TxID, "DUPL", []byte("<camt056/>"))
	if err != nil {
		t.Fatal(err)
	}
	if rr.Kind != KindReturnRequest || rr.Final || rr.OrigTxID != pay.TxID {
		t.Fatalf("return request %+v", rr)
	}
	if r.Position("A") != 1_000_000 || r.Position("B") != 2_000_000 {
		t.Fatal("a return request moved money")
	}
	got, _ := r.Journal().Find(pay.TxID)
	if !got.Final || got.Amount != 2_000_000 {
		t.Fatal("the posted payment changed")
	}
	// A return is a new, separate payment.
	back, err := r.Pay("B", "A", 2_000_000, nil)
	if err != nil || back.TxID == pay.TxID {
		t.Fatalf("return payment %+v %v", back, err)
	}
	if _, err := r.RequestReturn("RTP-nope", "DUPL", nil); !errors.Is(err, ErrNoSuchPayment) {
		t.Fatal(err)
	}
}

func TestFeedFaults(t *testing.T) {
	clk := NewManualClock(et("2026-10-06 10:00"))
	c := NewCHIPS(clk, "A", "B", "C")
	j := c.Journal()

	p1, _ := c.Pay("A", "B", 1_000_000, []byte("m1"))
	j.DelayNext(1)
	p2, _ := c.Pay("A", "B", 2_000_000, []byte("m2"))
	p3, _ := c.Pay("A", "C", 3_000_000, []byte("m3"))
	if err := j.Redeliver(p1.TxID); err != nil {
		t.Fatal(err)
	}
	cp, err := c.CopyReference(p1.TxID, "C")
	if err != nil {
		t.Fatal(err)
	}
	if cp.PayerAcct != "C" || cp.PayeeAcct != "B" || string(cp.Message) != "m1" || !cp.Final {
		t.Fatalf("copied reference %+v", cp)
	}
	j.DeliverNonFinal(Entry{TxID: "CHIPS-QUEUED-1", PayerAcct: "A", PayeeAcct: "B", Amount: 9})

	feed, cur := j.Read(0)
	var ids []string
	for _, e := range feed {
		ids = append(ids, e.TxID)
	}
	want := []string{p1.TxID, p3.TxID, p1.TxID, cp.TxID, "CHIPS-QUEUED-1"}
	if len(ids) != len(want) {
		t.Fatalf("feed %v, want %v", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("feed %v, want %v", ids, want)
		}
	}
	if feed[4].Final {
		t.Fatal("non-final delivery marked final")
	}
	// The record has every settled payment once, in order, and never the
	// non-final one.
	if rec := j.Entries(); len(rec) != 4 || rec[1].TxID != p2.TxID {
		t.Fatalf("record %+v", rec)
	}
	// The delayed entry arrives later, at the reader's cursor.
	wait := j.Changed()
	if err := j.Release(p2.TxID); err != nil {
		t.Fatal(err)
	}
	select {
	case <-wait:
	default:
		t.Fatal("Changed not signalled")
	}
	late, next := j.Read(cur)
	if len(late) != 1 || late[0].TxID != p2.TxID || next != cur+1 {
		t.Fatalf("late delivery %+v", late)
	}
	if err := j.Release(p2.TxID); err == nil {
		t.Fatal("released twice")
	}
}
