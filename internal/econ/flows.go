// Package econ is the economics simulator of §5.5 of docs/design.md: it
// generates synthetic interbank payment flows and runs them through three
// settlement designs, reporting the liquidity each needs, how efficiently it
// uses it, how many fiat settlements it makes and, for this model, the credit
// exposure and the collateral and loss pool it requires.
//
// Everything is synthetic and seeded; no real data is used. Amounts are in
// cents (int64) and times in seconds after midnight Eastern of a business day.
package econ

import (
	"math"
	"math/rand"
	"sort"
)

// Config is a simulation's parameters. Zero values take the defaults of
// DefaultConfig.
type Config struct {
	Banks int   // N
	Days  int   // business days simulated; results are per-day averages
	Seed  int64 // RNG seed

	// Flows.
	ValuePerBank  float64 // average daily value sent per bank, USD
	MedianSize    float64 // median payment, USD
	Sigma         float64 // lognormal sigma of payment size (heavy tail)
	Concentration float64 // bank size weights ∝ 1/rank^Concentration
	FirstPayment  int     // seconds after midnight: first submission (07:00)
	LastPayment   int     // seconds after midnight: submissions end (16:30, the end-of-day cut)

	// This model (§3.4, §3.7).
	Mandatory      float64 // mandatory bilateral limit per pair, USD ($5M)
	ElectiveMax    float64 // cap on an elective limit, USD ($100M)
	ElectiveFactor float64 // elective[g][d] = factor × expected daily gross flow d→g, capped
	ReceiverCap    float64 // receiver cap, USD ($100M)
	TriggerLevel   float64 // CapReached fires at net position ≥ TriggerLevel × receiver cap (1.0)
	SystemMax      float64 // cap on any debit cap, USD ($1B)
	SettleLatency  int     // seconds from cut to batch completion (fiat legs paid and attested)

	// CHIPS-like design.
	CHIPSCutoff int // seconds after midnight: payment cut-off (17:00)
}

// DefaultConfig is the configuration docs/economics.md reports.
func DefaultConfig(banks int) Config {
	return Config{
		Banks: banks, Days: 5, Seed: 20261006,
		ValuePerBank: 1e9, MedianSize: 75_000, Sigma: 2.0, Concentration: 1.0,
		FirstPayment: 7 * 3600, LastPayment: 16*3600 + 30*60,
		Mandatory: 5e6, ElectiveMax: 100e6, ElectiveFactor: 0.10, ReceiverCap: 100e6, TriggerLevel: 1.0, SystemMax: 1e9,
		SettleLatency: 30 * 60,
		CHIPSCutoff:   17 * 3600,
	}
}

func cents(usd float64) int64 { return int64(math.Round(usd * 100)) }

// Payment is one synthetic interbank payment.
type Payment struct {
	At     int // seconds after midnight
	From   int
	To     int
	Amount int64 // cents
}

// Weights are the banks' size weights, summing to 1, largest first.
func Weights(c Config) []float64 {
	w := make([]float64, c.Banks)
	s := 0.0
	for i := range w {
		w[i] = 1 / math.Pow(float64(i+1), c.Concentration)
		s += w[i]
	}
	for i := range w {
		w[i] /= s
	}
	return w
}

// ExpectedFlow is the expected daily gross value (USD) bank d sends to bank
// g under the generator: what a bank can know in advance, used to size
// elective limits without looking at the realised day.
func ExpectedFlow(c Config, w []float64, d, g int) float64 {
	total := c.ValuePerBank * float64(c.Banks)
	return total * w[d] * w[g] / (1 - w[d])
}

func pick(r *rand.Rand, cum []float64) int {
	x := r.Float64()
	i := sort.SearchFloat64s(cum, x)
	if i >= len(cum) {
		i = len(cum) - 1
	}
	return i
}

// intraday draws a submission time: two peaks (mid-morning and early
// afternoon) truncated to [FirstPayment, LastPayment).
func intraday(r *rand.Rand, c Config) int {
	for {
		var t float64
		if r.Float64() < 0.55 {
			t = 10*3600 + r.NormFloat64()*75*60
		} else {
			t = 14*3600 + 30*60 + r.NormFloat64()*75*60
		}
		if int(t) >= c.FirstPayment && int(t) < c.LastPayment {
			return int(t)
		}
	}
}

// GenerateDay draws one business day of payments, sorted by time. The count
// is fixed so that the expected value is Banks × ValuePerBank; sizes are
// lognormal (median MedianSize, sigma Sigma); payer and payee are drawn by
// size weight, payee ≠ payer.
func GenerateDay(r *rand.Rand, c Config) []Payment {
	w := Weights(c)
	cum := make([]float64, len(w))
	s := 0.0
	for i, x := range w {
		s += x
		cum[i] = s
	}
	mean := c.MedianSize * math.Exp(c.Sigma*c.Sigma/2)
	n := int(math.Round(c.ValuePerBank * float64(c.Banks) / mean))
	mu := math.Log(c.MedianSize)
	ps := make([]Payment, 0, n)
	for i := 0; i < n; i++ {
		from := pick(r, cum)
		to := pick(r, cum)
		for to == from {
			to = pick(r, cum)
		}
		amt := cents(math.Exp(mu + c.Sigma*r.NormFloat64()))
		if amt < 100 {
			amt = 100
		}
		ps = append(ps, Payment{At: intraday(r, c), From: from, To: to, Amount: amt})
	}
	sort.SliceStable(ps, func(i, j int) bool { return ps[i].At < ps[j].At })
	return ps
}
