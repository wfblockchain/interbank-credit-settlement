package operator

import (
	"math/big"
	"math/rand"
	"testing"
	"time"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/iso20022"
	"interbank-credit-settlement/internal/rails"
)

func id(s string) [32]byte {
	var b [32]byte
	copy(b[:], s)
	return b
}

const mn = 1_000_000_000_000 // $1M in 6 decimals

func pair(i, h string, m int64) Pair {
	return Pair{Issuer: id(i), Holder: id(h), Amount: big.NewInt(m * mn)}
}

func TestBuildPlanLargestFirst(t *testing.T) {
	// A owes 35 net, B is owed 10, C is owed 25.
	pairs := []Pair{pair("A", "B", 30), pair("B", "C", 20), pair("C", "A", 5), pair("A", "C", 10)}
	legs := BuildPlan(pairs)
	want := []Leg{{id("A"), id("C"), big.NewInt(25 * mn)}, {id("A"), id("B"), big.NewInt(10 * mn)}}
	if len(legs) != len(want) {
		t.Fatalf("legs %+v", legs)
	}
	for k := range want {
		if legs[k].Payer != want[k].Payer || legs[k].Payee != want[k].Payee || legs[k].Amount.Cmp(want[k].Amount) != 0 {
			t.Fatalf("leg %d %+v, want %+v", k, legs[k], want[k])
		}
	}
	if err := CheckPlan(pairs, legs); err != nil {
		t.Fatal(err)
	}
	// Two debtors, two creditors: largest debtor pays largest creditor first.
	pairs = []Pair{pair("D", "B", 50), pair("C", "A", 20), pair("D", "A", 10)}
	legs = BuildPlan(pairs)
	if legs[0].Payer != id("D") || legs[0].Payee != id("B") || legs[0].Amount.Cmp(big.NewInt(50*mn)) != 0 {
		t.Fatalf("first leg %+v", legs[0])
	}
	if err := CheckPlan(pairs, legs); err != nil {
		t.Fatal(err)
	}
	// Bilateral flows that net to zero need no legs.
	if legs := BuildPlan([]Pair{pair("A", "B", 7), pair("B", "A", 7)}); len(legs) != 0 {
		t.Fatalf("legs %+v", legs)
	}
}

func TestBuildPlanRandomAlwaysVerifies(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	names := []string{"A", "B", "C", "D", "E", "F"}
	for it := 0; it < 500; it++ {
		var pairs []Pair
		for k := 0; k < 1+r.Intn(15); k++ {
			i, h := names[r.Intn(len(names))], names[r.Intn(len(names))]
			if i == h {
				continue
			}
			pairs = append(pairs, Pair{Issuer: id(i), Holder: id(h), Amount: big.NewInt(1 + r.Int63n(1e15))})
		}
		legs := BuildPlan(pairs)
		if err := CheckPlan(pairs, legs); err != nil {
			t.Fatalf("iteration %d: %v", it, err)
		}
		members := map[[32]byte]bool{}
		for _, p := range pairs {
			members[p.Issuer], members[p.Holder] = true, true
		}
		if len(members) > 0 && len(legs) > len(members)-1 {
			t.Fatalf("%d legs for %d members", len(legs), len(members))
		}
	}
	if err := CheckPlan([]Pair{pair("A", "B", 5)}, []Leg{{id("A"), id("B"), big.NewInt(4 * mn)}}); err == nil {
		t.Fatal("short plan accepted")
	}
}

func TestSplitParts(t *testing.T) {
	if p := SplitParts(100*mn, rails.RTPLimit); len(p) != 10 || p[9] != 10*mn {
		t.Fatalf("%v", p)
	}
	if p := SplitParts(25*mn, rails.RTPLimit); len(p) != 3 || p[0] != 10*mn || p[2] != 5*mn {
		t.Fatalf("%v", p)
	}
	if p := SplitParts(250*mn, 0); len(p) != 1 {
		t.Fatalf("%v", p)
	}
}

func TestChooseRailAndSchedule(t *testing.T) {
	at := func(s string) time.Time {
		v, err := time.ParseInLocation("2006-01-02 15:04", s, calendar.ET)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	cases := []struct {
		now  string
		rail rails.Rail
		dl   string
	}{
		{"2026-10-06 10:00", rails.CHIPS, "2026-10-06 11:00"}, // in session
		{"2026-10-06 16:30", rails.CHIPS, "2026-10-06 17:00"}, // end of day: deadline is the cut-off
		{"2026-10-06 16:50", rails.RTP, "2026-10-06 17:50"},   // too little session left
		{"2026-10-05 21:30", rails.CHIPS, "2026-10-05 22:30"}, // the evening session of the next business day
		{"2026-10-10 10:00", rails.RTP, "2026-10-10 11:00"},   // Saturday
		{"2026-10-12 10:00", rails.RTP, "2026-10-12 11:00"},   // Columbus Day holiday
	}
	for _, c := range cases {
		rc := ChooseRail(at(c.now), time.Hour, 15*time.Minute)
		if rc.Rail != c.rail || !rc.Deadline.Equal(at(c.dl)) {
			t.Fatalf("%s: %s %s", c.now, rc.Rail, rc.Deadline.In(calendar.ET))
		}
	}
	ins, err := Schedule(7, []Leg{{id("A"), id("B"), big.NewInt(25 * mn)}, {id("C"), id("B"), big.NewInt(3 * mn)}},
		RailChoice{Rail: rails.RTP, Deadline: at("2026-10-10 11:00"), Limit: rails.RTPLimit})
	if err != nil {
		t.Fatal(err)
	}
	ref, _ := iso20022.BatchReference(7)
	want := []string{"CS7-L0-1", "CS7-L0-2", "CS7-L0-3", "CS7-L1-1"}
	if len(ins) != len(want) {
		t.Fatalf("%+v", ins)
	}
	for k, in := range ins {
		if in.EndToEndID != want[k] || in.Reference != ref || in.Rail != rails.RTP || in.Amount > rails.RTPLimit {
			t.Fatalf("instruction %d: %+v", k, in)
		}
	}
}

func TestMoney(t *testing.T) {
	for v, want := range map[int64]string{0: "$0", 1_000_000: "$1", 2_500_000_000_000: "$2,500,000", -1_500_000: "-$1.50"} {
		if got := Money(big.NewInt(v)); got != want {
			t.Fatalf("%d: %s, want %s", v, got, want)
		}
	}
}
