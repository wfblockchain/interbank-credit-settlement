package reconcile

import (
	"errors"
	"math/big"
	"testing"
	"time"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/listener"
	"interbank-credit-settlement/internal/rails"
)

type fixture struct {
	chips *rails.CHIPSSim
	rtp   *rails.RTPSim
	pay   rails.Entry
	other rails.Entry
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	at, _ := time.ParseInLocation("2006-01-02 15:04", "2026-10-06 10:00", calendar.ET)
	clk := rails.NewManualClock(at)
	f := fixture{chips: rails.NewCHIPS(clk, "A", "B"), rtp: rails.NewRTP(clk, "A", "B")}
	msg, err := iso20022.Pacs009(iso20022.Transfer{MsgID: "M1", CreatedAt: at, SettleDate: calendar.Date(at),
		Clearing: iso20022.ClearingCHIPS, Batch: 1, Leg: 0, Part: 1, Amount: 5_000_000,
		Debtor:   iso20022.Bank{BIC: "BNKAUS30", Name: "Bank A", Account: "A"},
		Creditor: iso20022.Bank{BIC: "BNKBUS30", Name: "Bank B", Account: "B"}})
	if err != nil {
		t.Fatal(err)
	}
	if f.pay, err = f.chips.Pay("A", "B", 5_000_000, msg); err != nil {
		t.Fatal(err)
	}
	// A rail payment that is not a settlement payment (no leg reference).
	if f.other, err = f.chips.Pay("B", "A", 1_000_000, []byte("<Document/>")); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f fixture) journals() []*rails.Journal {
	return []*rails.Journal{f.chips.Journal(), f.rtp.Journal()}
}

func (f fixture) sub() listener.Submission {
	return listener.Submission{RailTxID: f.pay.TxID, Payment: listener.Payment{Batch: 1, Leg: 0, Rail: 1,
		RailTxID: listener.RailTxHash(f.pay.TxID), Amount: big.NewInt(5_000_000)}}
}

func (f fixture) onChain() ChainPayment {
	return ChainPayment{Batch: 1, Leg: 0, Rail: 1, RailTxID: listener.RailTxHash(f.pay.TxID), Amount: big.NewInt(5_000_000)}
}

func TestCheckClean(t *testing.T) {
	f := newFixture(t)
	if err := Check(Inputs{Journals: f.journals(), Listener: []listener.Submission{f.sub()}, Chain: []ChainPayment{f.onChain()}}); err != nil {
		t.Fatal(err)
	}
}

func TestCheckBreaks(t *testing.T) {
	f := newFixture(t)
	phantom := ChainPayment{Batch: 1, Leg: 1, Rail: 2, RailTxID: listener.RailTxHash("RTP-X"), Amount: big.NewInt(1)}
	wrongAmt := f.onChain()
	wrongAmt.Amount = big.NewInt(4_000_000)
	cases := []struct {
		name string
		in   Inputs
		want []Kind
	}{
		{"phantom attestation", Inputs{Listener: []listener.Submission{f.sub()}, Chain: []ChainPayment{f.onChain(), phantom}},
			[]Kind{ChainWithoutRail, ChainWithoutListener}},
		{"listener submission missing on chain", Inputs{Listener: []listener.Submission{f.sub()}},
			[]Kind{ListenerWithoutChain, RailUnaccounted}},
		{"amount differs", Inputs{Listener: []listener.Submission{f.sub()}, Chain: []ChainPayment{wrongAmt}},
			[]Kind{AmountMismatch}},
		{"settlement payment unaccounted", Inputs{}, []Kind{RailUnaccounted}},
		{"recorded twice", Inputs{Listener: []listener.Submission{f.sub()}, Chain: []ChainPayment{f.onChain(), f.onChain()}},
			[]Kind{DuplicateRecord}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			c.in.Journals = f.journals()
			err := Check(c.in)
			var be *BreakError
			if !errors.As(err, &be) || !errors.Is(err, ErrBreak) {
				t.Fatalf("got %v", err)
			}
			for _, k := range c.want {
				if !be.Has(k) {
					t.Fatalf("missing %q in %v", k, err)
				}
			}
			if len(be.Breaks) != len(c.want) {
				t.Fatalf("breaks %v, want %v", be.Breaks, c.want)
			}
		})
	}
	// A settlement payment in manual review is accounted for.
	if err := Check(Inputs{Journals: f.journals(), Reviewed: map[string]bool{f.pay.TxID: true}}); err != nil {
		t.Fatal(err)
	}
}
