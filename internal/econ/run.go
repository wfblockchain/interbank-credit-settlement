package econ

import (
	"fmt"
	"math/rand"
	"strings"
)

// Run simulates c.Days days and returns, per design, the per-day average
// (peak exposure, collateral and pool: the maximum over days).
func Run(c Config) []Result {
	r := rand.New(rand.NewSource(c.Seed))
	var sums [4]Result
	var delays [4]float64
	for d := 0; d < c.Days; d++ {
		ps := GenerateDay(r, c)
		day := []Result{
			GrossRTGS(ps),
			NettingImmediate(ps, c.Banks),
			NettingQueued(ps, c.Banks, 2, 1_000_000), // $10k precision
			ThisModel(ps, c),
		}
		for i, x := range day {
			s := &sums[i]
			s.Design = x.Design
			s.Value += x.Value
			s.Liquidity += x.Liquidity
			s.FiatSettlements += x.FiatSettlements
			s.Batches += x.Batches
			s.CapCuts += x.CapCuts
			s.CallCuts += x.CallCuts
			s.Legs += x.Legs
			s.ViaCredit += x.ViaCredit
			s.Outside += x.Outside
			s.Cancelled += x.Cancelled
			s.FiatStock += x.FiatStock
			s.Unreleased += x.Unreleased
			delays[i] += x.DelayMinutes * float64(x.Value)
			s.PeakExposure = max(s.PeakExposure, x.PeakExposure)
			s.Collateral = max(s.Collateral, x.Collateral)
			s.Pool = max(s.Pool, x.Pool)
		}
	}
	out := make([]Result, len(sums))
	n := int64(c.Days)
	for i, s := range sums {
		if s.Value > 0 {
			s.DelayMinutes = delays[i] / float64(s.Value)
		}
		s.Value /= n
		s.Liquidity /= n
		s.ViaCredit /= n
		s.Outside /= n
		s.Cancelled /= n
		s.FiatStock /= n
		s.Unreleased /= n
		s.FiatSettlements = int(int64(s.FiatSettlements) / n)
		s.Batches = int(int64(s.Batches) / n)
		s.CapCuts = int(int64(s.CapCuts) / n)
		s.CallCuts = int(int64(s.CallCuts) / n)
		s.Legs = int(int64(s.Legs) / n)
		out[i] = s
	}
	return out
}

// usd formats cents as a short dollar figure ($12.3bn, $450M, $75k).
func usd(c int64) string {
	v := float64(c) / 100
	switch {
	case v == 0:
		return "0"
	case v >= 1e9:
		return fmt.Sprintf("$%.1fbn", v/1e9)
	case v >= 1e6:
		return fmt.Sprintf("$%.0fM", v/1e6)
	case v >= 1e3:
		return fmt.Sprintf("$%.0fk", v/1e3)
	}
	return fmt.Sprintf("$%.0f", v)
}

// Markdown renders the results of one N as a table and a line of detail on
// this model's run.
func Markdown(c Config, rs []Result) string {
	var b strings.Builder
	fmt.Fprintf(&b, "#### N = %d banks (per-day averages over %d days, seed %d)\n\n", c.Banks, c.Days, c.Seed)
	b.WriteString("| Design | Value settled | Liquidity used | Efficiency (value / liquidity) | Opening balances needed | Fiat settlements | Peak exposure | Collateral + pool | Mean delay (value-weighted) |\n")
	b.WriteString("|---|---:|---:|---:|---:|---:|---:|---:|---:|\n")
	for _, r := range rs {
		cp := "—"
		exp := "0"
		if r.Collateral+r.Pool > 0 {
			cp = fmt.Sprintf("%s + %s = %s", usd(r.Collateral), usd(r.Pool), usd(r.Collateral+r.Pool))
			exp = usd(r.PeakExposure)
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %.1f | %s | %d | %s | %s | %.0f min |\n",
			r.Design, usd(r.Value), usd(r.Liquidity), r.Efficiency(), usd(r.Stock()), r.FiatSettlements, exp, cp, r.DelayMinutes)
	}
	for _, r := range rs {
		if r.Unreleased > 0 {
			fmt.Fprintf(&b, "\nWarning: %s left %s unreleased.\n", r.Design, usd(r.Unreleased))
		}
		if r.Batches > 0 || r.ViaCredit > 0 {
			via := 100 * float64(r.ViaCredit) / float64(r.Value)
			fmt.Fprintf(&b, "\nThis model: %d batches/day (%d at a receiver cap, %d on a receiver call, the rest end of day), %d fiat legs; "+
				"%.1f%% of value through the credit ledger; %s paid gross outside it, of which %s larger than the limits and %s still queued at the end-of-day cut.\n",
				r.Batches, r.CapCuts, r.CallCuts, r.Legs, via, usd(r.Outside), usd(r.Outside-r.Cancelled), usd(r.Cancelled))
		}
	}
	return b.String()
}
