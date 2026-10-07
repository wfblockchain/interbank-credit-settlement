package econ

import (
	"math/rand"
	"reflect"
	"testing"
)

const usd1M = int64(100_000_000) // $1M in cents

func TestGenerateDay(t *testing.T) {
	c := DefaultConfig(10)
	ps := GenerateDay(rand.New(rand.NewSource(1)), c)
	if len(ps) == 0 {
		t.Fatal("no payments")
	}
	for i, p := range ps {
		if p.From == p.To || p.From < 0 || p.To >= c.Banks || p.Amount <= 0 {
			t.Fatalf("payment %d: %+v", i, p)
		}
		if p.At < c.FirstPayment || p.At >= c.LastPayment {
			t.Fatalf("payment %d at %d outside the window", i, p.At)
		}
		if i > 0 && ps[i-1].At > p.At {
			t.Fatal("not sorted by time")
		}
	}
	// Same seed, same day; another seed, another day.
	again := GenerateDay(rand.New(rand.NewSource(1)), c)
	if !reflect.DeepEqual(ps, again) {
		t.Fatal("generation is not reproducible")
	}
	if other := GenerateDay(rand.New(rand.NewSource(2)), c); reflect.DeepEqual(ps, other) {
		t.Fatal("seed ignored")
	}
}

func TestPrefundDesigns(t *testing.T) {
	cases := []struct {
		name      string
		ps        []Payment
		immediate int64 // Σ release-on-submission prefunds
		queued    int64 // Σ FIFO-to-cut-off prefunds
	}{
		{
			name: "two-way flow recycles",
			// A pays B 10 at t=1, B pays A 10 at t=2: A needs 10, B needs 0.
			ps:        []Payment{{At: 1, From: 0, To: 1, Amount: 10 * usd1M}, {At: 2, From: 1, To: 0, Amount: 10 * usd1M}},
			immediate: 10 * usd1M, queued: 10 * usd1M,
		},
		{
			name: "mutual gridlock needs one side funded",
			// B pays A 10 at t=1 before receiving A's 10 at t=2. Immediate
			// release needs B=10; with a queue B could wait for A, but A has
			// nothing either, so one of them must be funded: still 10.
			ps:        []Payment{{At: 1, From: 1, To: 0, Amount: 10 * usd1M}, {At: 2, From: 0, To: 1, Amount: 10 * usd1M}},
			immediate: 10 * usd1M, queued: 10 * usd1M,
		},
		{
			name: "a chain needs only its head funded when payers can wait",
			// C→A 5 at t=1 (C not yet funded), A→B 5 at t=2, B→C 5 at t=3.
			ps: []Payment{
				{At: 1, From: 2, To: 0, Amount: 5 * usd1M},
				{At: 2, From: 0, To: 1, Amount: 5 * usd1M},
				{At: 3, From: 1, To: 2, Amount: 5 * usd1M},
			},
			immediate: 5 * usd1M, queued: 5 * usd1M,
		},
		{
			name: "out-of-order inflow",
			// A→B 4 at t=1, A→B 6 at t=2, B→A 10 at t=3. Immediate: A needs 10.
			ps: []Payment{
				{At: 1, From: 0, To: 1, Amount: 4 * usd1M},
				{At: 2, From: 0, To: 1, Amount: 6 * usd1M},
				{At: 3, From: 1, To: 0, Amount: 10 * usd1M},
			},
			immediate: 10 * usd1M, queued: 10 * usd1M,
		},
	}
	for _, c := range cases {
		im := NettingImmediate(c.ps, 3)
		q := NettingQueued(c.ps, 3, 3, 1)
		if im.Liquidity != c.immediate {
			t.Errorf("%s: immediate %d, want %d", c.name, im.Liquidity, c.immediate)
		}
		if q.Liquidity != c.queued || q.Unreleased != 0 {
			t.Errorf("%s: queued %d (unreleased %d), want %d", c.name, q.Liquidity, q.Unreleased, c.queued)
		}
		if g := GrossRTGS(c.ps); g.Liquidity != total(c.ps) || g.Efficiency() != 1 {
			t.Errorf("%s: gross %+v", c.name, g)
		}
	}
}

// With a queue, a bank whose early payment would need funding can wait for a
// later inflow that arrives from a funded bank.
func TestQueuedCanBeatImmediate(t *testing.T) {
	ps := []Payment{
		{At: 1, From: 1, To: 2, Amount: 10 * usd1M}, // B pays C before it is paid
		{At: 2, From: 0, To: 1, Amount: 10 * usd1M}, // A pays B
		{At: 3, From: 2, To: 0, Amount: 10 * usd1M}, // C pays A
	}
	im := NettingImmediate(ps, 3)
	q := NettingQueued(ps, 3, 3, 1)
	if im.Liquidity != 20*usd1M { // B=10 at t=1, A=10 at t=2
		t.Fatalf("immediate %d", im.Liquidity)
	}
	if q.Liquidity != 10*usd1M || q.DelayMinutes <= 0 {
		t.Fatalf("queued %d delay %v", q.Liquidity, q.DelayMinutes)
	}
}

func smallConfig() Config {
	c := DefaultConfig(3)
	c.ElectiveFactor = 0 // limits = $5M mandatory
	c.ReceiverCap = 8e6
	c.SettleLatency = 600
	return c
}

func TestThisModelHandScenario(t *testing.T) {
	c := smallConfig()
	ps := []Payment{
		{At: 8 * 3600, From: 0, To: 1, Amount: 3 * usd1M},     // fits
		{At: 8*3600 + 60, From: 2, To: 1, Amount: 4 * usd1M},  // fits: B net +7
		{At: 8*3600 + 120, From: 0, To: 1, Amount: 2 * usd1M}, // A→B bilateral 5 ok, B net 9 > 8 → queued, cut
		{At: 8*3600 + 180, From: 1, To: 0, Amount: 6 * usd1M}, // larger than the $5M limit → outside
		{At: 9 * 3600, From: 2, To: 0, Amount: 1 * usd1M},     // after the batch completes
	}
	r := ThisModel(ps, c)
	// Batch 1 (receiver call) at 08:02 settles A→B 3, C→B 4: legs A 3 + C 4.
	// It completes at 08:12 and the queued A→B 2 is accepted then. With 09:00
	// C→A 1, the end-of-day cut nets B +2, A −1, C −1: two legs of 1.
	if r.Outside != 6*usd1M || r.Cancelled != 0 {
		t.Fatalf("outside %d cancelled %d", r.Outside, r.Cancelled)
	}
	if r.ViaCredit+r.Outside != r.Value {
		t.Fatal("value not conserved")
	}
	if r.Liquidity != (7+2+6)*usd1M {
		t.Fatalf("liquidity %d", r.Liquidity)
	}
	if r.Batches != 2 || r.CallCuts != 1 || r.Legs != 4 {
		t.Fatalf("batches %d calls %d legs %d", r.Batches, r.CallCuts, r.Legs)
	}
	if r.PeakExposure != 7*usd1M {
		t.Fatalf("peak exposure %d", r.PeakExposure)
	}
	// Queued 10 minutes (08:02 → 08:12) on $2M of $16M.
	if want := 2.0 * 10 / 16; r.DelayMinutes < want-1e-9 || r.DelayMinutes > want+1e-9 {
		t.Fatalf("delay %v, want %v", r.DelayMinutes, want)
	}
	// Collateral: 3 banks × 2 grantors × $5M; pool: two largest debit caps
	// (2 × $5M each).
	if r.Collateral != 30*usd1M || r.Pool != 20*usd1M {
		t.Fatalf("collateral %d pool %d", r.Collateral, r.Pool)
	}
}

func TestThisModelCancelsAtCut(t *testing.T) {
	c := smallConfig()
	c.SettleLatency = 9 * 3600 // the first batch is still in flight at the 16:30 cut
	ps := []Payment{
		{At: 8 * 3600, From: 0, To: 1, Amount: 5 * usd1M},
		{At: 8*3600 + 60, From: 0, To: 1, Amount: 1 * usd1M}, // bilateral 6 > 5 → queued until the cut
	}
	r := ThisModel(ps, c)
	if r.Cancelled != usd1M || r.Outside != usd1M || r.ViaCredit != 5*usd1M {
		t.Fatalf("%+v", r)
	}
}

func TestLegCount(t *testing.T) {
	cases := []struct {
		debt, cred []int64
		legs       int
	}{
		{[]int64{10}, []int64{10}, 1},
		{[]int64{10}, []int64{4, 6}, 2},
		{[]int64{5, 5}, []int64{10}, 2},
		{[]int64{7, 3}, []int64{6, 4}, 3},
		{nil, nil, 0},
	}
	for _, c := range cases {
		if got := legCount(append([]int64(nil), c.debt...), append([]int64(nil), c.cred...)); got != c.legs {
			t.Errorf("%v→%v: %d legs, want %d", c.debt, c.cred, got, c.legs)
		}
	}
}

func TestRunReproducibleAndConsistent(t *testing.T) {
	c := DefaultConfig(6)
	c.Days = 2
	c.ValuePerBank = 2e8
	a, b := Run(c), Run(c)
	if !reflect.DeepEqual(a, b) {
		t.Fatal("same seed, different results")
	}
	if len(a) != 4 {
		t.Fatalf("%d designs", len(a))
	}
	for _, r := range a {
		if r.Value != a[0].Value {
			t.Fatalf("%s settled %d, gross %d", r.Design, r.Value, a[0].Value)
		}
		if r.Unreleased != 0 {
			t.Fatalf("%s left value unreleased", r.Design)
		}
	}
	if a[2].Liquidity > a[1].Liquidity {
		t.Fatal("queued netting needs more than release on submission")
	}
	if a[3].ViaCredit+a[3].Outside != a[3].Value {
		t.Fatal("this model lost value")
	}
	if md := Markdown(c, a); len(md) == 0 {
		t.Fatal("empty report")
	}
}
