package econ

import (
	"sort"
)

// Result is one design's outcome over one day (or averaged over days).
type Result struct {
	Design string

	Value           int64   // cents settled
	Liquidity       int64   // cents, as the design defines it (see docs/economics.md)
	FiatSettlements int     // payments made in central-bank money
	PeakExposure    int64   // cents of unsettled interbank credit at the worst moment
	Collateral      int64   // cents of mandatory-limit backing (this model only)
	Pool            int64   // cents of cover-2 loss pool (this model only)
	DelayMinutes    float64 // value-weighted mean delay from submission to settlement

	// This model only.
	Batches    int
	CapCuts    int
	CallCuts   int
	ViaCredit  int64 // cents settled through the credit ledger
	Outside    int64 // cents paid gross outside the ledger: larger than the limits, or cancelled at the cut
	Cancelled  int64 // of Outside: cents still queued at the end-of-day cut
	FiatStock  int64 // Σ per bank of the peak cumulative net fiat outflow
	Legs       int
	Unreleased int64 // CHIPS-like only: cents not released (infeasible run); 0 when reported
}

// Stock is the sum over banks of the opening central-bank balance the design
// needs: the whole outflow for gross RTGS without recycling, the prefunds for
// the netting designs, and for this model the peak cumulative net fiat outflow
// (legs and payments outside the ledger, incoming fiat recycled).
func (r Result) Stock() int64 {
	switch {
	case r.Batches > 0 || r.ViaCredit > 0:
		return r.FiatStock
	default:
		return r.Liquidity
	}
}

// Efficiency is value settled per unit of liquidity.
func (r Result) Efficiency() float64 {
	if r.Liquidity == 0 {
		return 0
	}
	return float64(r.Value) / float64(r.Liquidity)
}

func total(ps []Payment) int64 {
	var s int64
	for _, p := range ps {
		s += p.Amount
	}
	return s
}

// GrossRTGS is design (a): every payment settles individually in central-bank
// money with no recycling of incoming funds, so each bank needs its peak
// cumulative outflow, i.e. its whole day's outflow: liquidity = Σ outflows.
func GrossRTGS(ps []Payment) Result {
	v := total(ps)
	return Result{Design: "(a) gross RTGS", Value: v, Liquidity: v, FiatSettlements: len(ps)}
}

// immediatePrefunds is the opening balance each bank needs so that every
// payment is released at submission, with incoming payments credited at once:
// max over time of (cumulative out − cumulative in), floored at 0.
func immediatePrefunds(ps []Payment, n int) []int64 {
	run := make([]int64, n)
	peak := make([]int64, n)
	for _, p := range ps {
		run[p.From] += p.Amount
		run[p.To] -= p.Amount
		if run[p.From] > peak[p.From] {
			peak[p.From] = run[p.From]
		}
	}
	return peak
}

// release simulates continuous netting with per-payer FIFO queues: a payment
// is released as soon as its payer's balance covers it and every earlier
// payment of that payer has been released; incoming releases are credited at
// once and may release the payee's queue in turn. It returns the cents left
// unreleased at the cut-off and Σ amount × delay (seconds).
func release(ps []Payment, n int, pre []int64) (unreleased int64, delay float64) {
	bal := append([]int64(nil), pre...)
	queues := make([][]int, n)
	heads := make([]int, n)
	work := make([]int, 0, n)
	for idx, p := range ps {
		t := p.At
		queues[p.From] = append(queues[p.From], idx)
		work = append(work[:0], p.From)
		for len(work) > 0 {
			b := work[len(work)-1]
			work = work[:len(work)-1]
			for heads[b] < len(queues[b]) {
				q := ps[queues[b][heads[b]]]
				if bal[b] < q.Amount {
					break
				}
				bal[b] -= q.Amount
				bal[q.To] += q.Amount
				heads[b]++
				delay += float64(q.Amount) * float64(t-q.At)
				work = append(work, q.To)
			}
		}
	}
	for b := 0; b < n; b++ {
		for _, i := range queues[b][heads[b]:] {
			unreleased += ps[i].Amount
		}
	}
	return unreleased, delay
}

func fundings(pre []int64, ps []Payment) int {
	n := len(pre)
	bal := append([]int64(nil), pre...)
	for _, p := range ps {
		bal[p.From] -= p.Amount
		bal[p.To] += p.Amount
	}
	c := 0
	for i := 0; i < n; i++ {
		if pre[i] > 0 {
			c++ // opening funding
		}
		if bal[i] > 0 {
			c++ // closing payout
		}
	}
	return c
}

// NettingImmediate is design (b1): prefunded continuous netting where every
// payment must be released at submission. Liquidity = Σ opening prefunds. (It
// equals gross RTGS with incoming payments recycled at once.)
func NettingImmediate(ps []Payment, n int) Result {
	pre := immediatePrefunds(ps, n)
	var s int64
	for _, x := range pre {
		s += x
	}
	return Result{Design: "(b1) prefunded netting, release on submission", Value: total(ps), Liquidity: s, FiatSettlements: fundings(pre, ps)}
}

// NettingQueued is design (b2), CHIPS-like: prefunded continuous netting with
// per-payer FIFO queues, where a payment may wait for incoming funds but must
// be released by the cut-off. The minimum prefunds are found by coordinate
// descent: starting from the release-on-submission prefunds (feasible), each
// bank's prefund is binary-searched down to the least that keeps every payment
// releasable, others fixed, for `rounds` passes, largest bank first.
// Feasibility is monotone in each prefund. The result is a local minimum of
// Σ prefunds, not necessarily the global one; a real release algorithm that
// offsets queued payments multilaterally could need less.
func NettingQueued(ps []Payment, n int, rounds int, tolerance int64) Result {
	pre := immediatePrefunds(ps, n)
	for r := 0; r < rounds; r++ {
		changed := false
		for i := 0; i < n; i++ {
			orig := pre[i]
			lo, hi := int64(0), orig
			pre[i] = 0
			if u, _ := release(ps, n, pre); u == 0 {
				hi = 0
			}
			for hi-lo > tolerance {
				mid := lo + (hi-lo)/2
				pre[i] = mid
				if u, _ := release(ps, n, pre); u == 0 {
					hi = mid
				} else {
					lo = mid
				}
			}
			if hi != orig {
				changed = true
			}
			pre[i] = hi
		}
		if !changed {
			break
		}
	}
	u, d := release(ps, n, pre)
	var s int64
	for _, x := range pre {
		s += x
	}
	v := total(ps)
	return Result{Design: "(b2) prefunded netting, FIFO queue to cut-off", Value: v, Liquidity: s,
		FiatSettlements: fundings(pre, ps), DelayMinutes: d / float64(v) / 60, Unreleased: u}
}

// ---- This model (c) ----

type model struct {
	c   Config
	n   int
	lim [][]int64 // bilateralLimit[grantor][debtor]
	rc  []int64   // receiver caps
	tr  []int64   // CapReached trigger levels
	dc  []int64   // debit caps

	open, pend [][]int64 // [issuer][holder]
	net        []int64   // netPosition, open + pending
	pendNet    []int64
	pendUntil  int // -1: no batch in flight
	cutReq     bool
	reqCAP     bool
	eod        bool
	queue      []Payment
	fiatOut    []int64
	fiatPeak   []int64

	res      Result
	delaySum float64
}

func newModel(c Config) *model {
	n := c.Banks
	w := Weights(c)
	m := &model{c: c, n: n, pendUntil: -1}
	m.lim = make([][]int64, n)
	m.open = make([][]int64, n)
	m.pend = make([][]int64, n)
	for i := 0; i < n; i++ {
		m.lim[i] = make([]int64, n)
		m.open[i] = make([]int64, n)
		m.pend[i] = make([]int64, n)
	}
	m.rc = make([]int64, n)
	m.dc = make([]int64, n)
	m.tr = make([]int64, n)
	m.net = make([]int64, n)
	m.pendNet = make([]int64, n)
	m.fiatOut = make([]int64, n)
	m.fiatPeak = make([]int64, n)
	for g := 0; g < n; g++ {
		m.rc[g] = cents(c.ReceiverCap)
		m.tr[g] = cents(c.ReceiverCap * c.TriggerLevel)
		for d := 0; d < n; d++ {
			if g == d {
				continue
			}
			el := c.ElectiveFactor * ExpectedFlow(c, w, d, g)
			if el > c.ElectiveMax {
				el = c.ElectiveMax
			}
			m.lim[g][d] = cents(c.Mandatory) + cents(el)
		}
	}
	for d := 0; d < n; d++ {
		var s int64
		for g := 0; g < n; g++ {
			s += m.lim[g][d]
		}
		if mx := cents(c.SystemMax); s > mx {
			s = mx
		}
		m.dc[d] = s
	}
	return m
}

// collateralAndPool: mandatory limits are backed by the debtor's collateral
// (EURO1: the mandatory limits a member receives total at most its
// collateral), so full mandatory limits need Mandatory × (N−1) per bank; the
// pool covers the two largest debit caps.
func (m *model) collateralAndPool() (int64, int64) {
	coll := cents(m.c.Mandatory) * int64(m.n) * int64(m.n-1)
	caps := append([]int64(nil), m.dc...)
	sort.Slice(caps, func(i, j int) bool { return caps[i] > caps[j] })
	pool := caps[0]
	if len(caps) > 1 {
		pool += caps[1]
	}
	return coll, pool
}

func (m *model) gross(i, h int) int64 { return m.open[i][h] + m.pend[i][h] }

// fits applies checks (3)–(5) of §3.5.
func (m *model) fits(p Payment) bool {
	i, h, a := p.From, p.To, p.Amount
	if m.gross(i, h)+a-m.gross(h, i) > m.lim[h][i] {
		return false
	}
	if m.net[h]+a > m.rc[h] {
		return false
	}
	return -(m.net[i] - a) <= m.dc[i]
}

// oversized: the payment cannot pass even with no positions; a bank routes it
// over the fiat rail gross instead.
func (m *model) oversized(p Payment) bool {
	return p.Amount > m.lim[p.To][p.From] || p.Amount > m.rc[p.To] || p.Amount > m.dc[p.From]
}

func (m *model) accept(p Payment, t int) {
	m.open[p.From][p.To] += p.Amount
	m.net[p.To] += p.Amount
	m.net[p.From] -= p.Amount
	m.res.ViaCredit += p.Amount
	m.delaySum += float64(p.Amount) * float64(t-p.At)
	var exp int64
	for _, x := range m.net {
		if x > 0 {
			exp += x
		}
	}
	if exp > m.res.PeakExposure {
		m.res.PeakExposure = exp
	}
	if m.net[p.To] >= m.tr[p.To] {
		m.cutReq, m.reqCAP = true, true
	}
}

func (m *model) fiat(from, to int, a int64) {
	m.fiatOut[from] += a
	m.fiatOut[to] -= a
	if m.fiatOut[from] > m.fiatPeak[from] {
		m.fiatPeak[from] = m.fiatOut[from]
	}
}

func (m *model) outside(p Payment, t int) {
	m.res.Outside += p.Amount
	m.res.Liquidity += p.Amount
	m.res.FiatSettlements++
	m.delaySum += float64(p.Amount) * float64(t-p.At)
	m.fiat(p.From, p.To, p.Amount)
}

// cut snapshots open into the batch (one batch in flight) and schedules its
// completion.
func (m *model) cut(t int) {
	any := false
	for i := 0; i < m.n; i++ {
		m.pendNet[i] = 0
	}
	for i := 0; i < m.n; i++ {
		for h := 0; h < m.n; h++ {
			if a := m.open[i][h]; a != 0 {
				any = true
				m.pend[i][h] += a
				m.open[i][h] = 0
				m.pendNet[h] += a
				m.pendNet[i] -= a
			}
		}
	}
	if !any {
		m.cutReq, m.reqCAP = false, false
		return
	}
	switch {
	case m.eod:
	case m.reqCAP:
		m.res.CapCuts++
	default:
		m.res.CallCuts++
	}
	m.cutReq, m.reqCAP = false, false
	m.res.Batches++
	// Legs: net debtors pay net creditors, largest first.
	var debt, cred []int64
	for _, x := range m.pendNet {
		if x < 0 {
			debt = append(debt, -x)
			m.res.Liquidity += -x
		} else if x > 0 {
			cred = append(cred, x)
		}
	}
	m.res.Legs += legCount(debt, cred)
	m.pendUntil = t + m.c.SettleLatency
}

func legCount(debt, cred []int64) int {
	sort.Slice(debt, func(i, j int) bool { return debt[i] > debt[j] })
	sort.Slice(cred, func(i, j int) bool { return cred[i] > cred[j] })
	legs, i, j := 0, 0, 0
	for i < len(debt) && j < len(cred) {
		a := debt[i]
		if cred[j] < a {
			a = cred[j]
		}
		legs++
		debt[i] -= a
		cred[j] -= a
		if debt[i] == 0 {
			i++
		}
		if cred[j] == 0 {
			j++
		}
	}
	return legs
}

// complete pays the batch's legs, releases the exposure, drains the queue and
// cuts again if asked.
func (m *model) complete(t int) {
	for i := 0; i < m.n; i++ {
		for h := 0; h < m.n; h++ {
			m.pend[i][h] = 0
		}
	}
	for i := 0; i < m.n; i++ {
		m.net[i] -= m.pendNet[i]
		m.fiatOut[i] -= m.pendNet[i]
		if m.fiatOut[i] > m.fiatPeak[i] {
			m.fiatPeak[i] = m.fiatOut[i]
		}
		m.pendNet[i] = 0
	}
	m.pendUntil = -1
	if m.eod {
		return
	}
	m.drain(t)
	if m.cutReq || len(m.queue) > 0 {
		m.cut(t)
	}
}

// drain retries the queue from the head and stops at the first entry that
// still fails (§3.5).
func (m *model) drain(t int) {
	k := 0
	for k < len(m.queue) && m.fits(m.queue[k]) {
		m.accept(m.queue[k], t)
		k++
	}
	m.queue = m.queue[k:]
	if len(m.queue) > 0 {
		m.cutReq = true
	}
}

func (m *model) advance(t int) {
	for m.pendUntil >= 0 && m.pendUntil <= t {
		m.complete(m.pendUntil)
	}
}

// ThisModel is design (c): payments within limits settle at once on the
// credit ledger; positions settle net in fiat at cuts (receiver cap reached,
// receiver call when a payment queues, end of day). Liquidity = Σ fiat legs
// paid + payments routed outside the limits.
func ThisModel(ps []Payment, c Config) Result {
	m := newModel(c)
	m.res.Design = "(c) this model"
	m.res.Collateral, m.res.Pool = m.collateralAndPool()
	for _, p := range ps {
		m.advance(p.At)
		switch {
		case m.oversized(p):
			m.outside(p, p.At)
		case m.fits(p):
			m.accept(p, p.At)
			if len(m.queue) > 0 {
				m.drain(p.At)
			}
		default:
			m.queue = append(m.queue, p)
			m.cutReq = true
		}
		if m.cutReq && m.pendUntil < 0 {
			m.cut(p.At)
		}
	}
	// End of day: no credit after the cut. Finish the batch in flight, cut
	// the rest, and pay anything still queued gross.
	m.advance(c.LastPayment)
	m.eod = true
	t := c.LastPayment
	if m.pendUntil >= 0 {
		t = m.pendUntil
		m.complete(t)
	}
	m.cut(t)
	if m.pendUntil >= 0 {
		t = m.pendUntil
		m.complete(t)
	}
	for _, p := range m.queue {
		m.outside(p, c.LastPayment)
		m.res.Cancelled += p.Amount
	}
	m.queue = nil
	m.res.FiatSettlements += m.res.Legs
	m.res.Value = total(ps)
	for _, x := range m.fiatPeak {
		m.res.FiatStock += x
	}
	m.res.DelayMinutes = m.delaySum / float64(m.res.Value) / 60
	return m.res
}
