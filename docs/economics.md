# Economics: liquidity of three settlement designs

This is the output of the simulator in `internal/econ` (§5.5 of [design.md](design.md)), run by `cmd/econ`. The
flows are **synthetic**: generated from a few distribution assumptions, seeded, and not calibrated to any real
payment system's data. The numbers show how the designs respond to the same flows under stated assumptions; they
are not estimates of what any real network would need.

Reproduce with `go run ./cmd/econ` (defaults below; about 8 s). `go run ./cmd/econ -h` lists the parameters.

## Method

### Flows

For N banks, each simulated business day draws a fixed number of payments so that the expected value sent is
$1bn per bank per day:

- **Bank sizes:** weights ∝ 1/rank (Zipf, exponent 1). Payer and payee are drawn by weight, payee ≠ payer, so a
  few large banks send and receive most of the value.
- **Payment sizes:** lognormal, median $75k, σ = 2.0 (mean ≈ $554k). The tail is heavy: about 2% of payments
  exceed $5M and they carry nearly half of the value (≈46% in expectation).
- **Intraday seasonality:** submission times from two normal peaks (10:00 and 14:30 ET, σ = 75 min, weights
  0.55/0.45), truncated to 07:00–16:30 ET.
- **Reproducibility:** one `math/rand` source, seed 20261006, 5 days per N; the tables show per-day averages
  (peak exposure, collateral and pool: the maximum over the days).

### Designs

| Design | Rule | "Liquidity used" |
|---|---|---|
| (a) gross RTGS | every payment settles alone in central-bank money; incoming funds are not counted on | Σ outflows (each bank needs its whole day's outflow) |
| (b1) prefunded netting, release on submission | a bank's balance nets continuously; every payment must be released when submitted | Σ opening prefunds = Σ per bank of max over the day of (cumulative out − cumulative in). This equals gross RTGS with incoming funds recycled at once. |
| (b2) prefunded netting, FIFO queue to cut-off (CHIPS-like) | as (b1), but a payment may wait in its payer's FIFO queue for incoming funds; everything must be released by 17:00 | Σ opening prefunds, minimised per bank by binary search (to $10k), others fixed, two passes, largest bank first |
| (c) this model | credit within limits (§3.4–3.5), net fiat settlement at cuts (§3.7) | Σ fiat legs paid + Σ payments paid gross outside the ledger |

**This model, as simulated:**

- Limits: mandatory $5M per pair; elective limit of grantor g to debtor d = 10% of the *expected* daily gross flow
  d→g (from the size weights, not the realised day), capped at $100M; receiver cap $100M; debit cap = min($1bn,
  Σ bilateral limits). All banks are CREDIT tier with full collateral.
- A payment that passes checks (3)–(5) of §3.5 is final at once; otherwise it is queued (FIFO; `drain` stops at
  the first entry still failing, §3.5). A payment larger than its static capacity (bilateral limit, receiver cap or
  debit cap) can never pass and is paid gross over the fiat rail at once.
- Cuts: the receiver cap trigger (`CapReached`, at 100% of the cap), a receiver call whenever a payment queues,
  and the end-of-day cut at 16:30 ET. One batch is in flight at a time; a batch completes 30 minutes after its cut
  (fiat legs paid and attested), and only then is its exposure released and the queue drained. Legs run from net
  debtors to net creditors, largest first.
- At 16:30 ET credit stops: the batch in flight completes, the remainder is cut and settled, and anything still
  queued is cancelled and paid gross outside the ledger (§3.5 queue expiry).
- **Collateral** = mandatory backing: a bank receiving full mandatory limits from N−1 grantors needs $5M × (N−1)
  of collateral (the EURO1 rule of §3.4), so N(N−1) × $5M in total. **Pool** = the two largest debit caps (cover-2,
  §3.8).

### Metrics

- **Efficiency** = value settled ÷ liquidity used, with each design's own definition of liquidity above.
- **Opening balances needed** puts the designs on one footing: the central-bank balance each bank must hold at the
  start of the day, summed over banks. For (a) it is the whole outflow; for (b1)/(b2) the prefunds; for (c) the
  peak cumulative net fiat outflow of each bank (its legs paid, and its payments outside the ledger, net of fiat
  received), i.e. with incoming fiat recycled.
- **Fiat settlements**: central-bank-money payments: every payment for (a); opening fundings and closing payouts
  for (b); legs plus payments outside the ledger for (c).
- **Peak exposure**: the largest Σ over banks of positive net positions (unsettled interbank credit, open and in
  the batch in flight). Zero for (a) and (b), which extend no credit.
- **Mean delay**: value-weighted time from submission to settlement (queueing); payments outside the ledger
  count from submission to when they are paid.

## Results

#### N = 10 banks (per-day averages over 5 days, seed 20261006)

| Design | Value settled | Liquidity used | Efficiency (value / liquidity) | Opening balances needed | Fiat settlements | Peak exposure | Collateral + pool | Mean delay (value-weighted) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| (a) gross RTGS | $10.0bn | $10.0bn | 1.0 | $10.0bn | 18045 | 0 | — | 0 min |
| (b1) prefunded netting, release on submission | $10.0bn | $1.7bn | 6.1 | $1.7bn | 19 | 0 | — | 0 min |
| (b2) prefunded netting, FIFO queue to cut-off | $10.0bn | $1.2bn | 8.3 | $1.2bn | 13 | 0 | — | 8 min |
| (c) this model | $10.0bn | $3.6bn | 2.8 | $1.6bn | 212 | $283M | $450M + $602M = $1.1bn | 3 min |

This model: 17 batches/day (0 at a receiver cap, 16 on a receiver call, the rest end of day), 154 fiat legs; 80.4% of value through the credit ledger; $2.0bn paid gross outside it, of which $1.9bn larger than the limits and $19M still queued at the end-of-day cut.

#### N = 20 banks (per-day averages over 5 days, seed 20261006)

| Design | Value settled | Liquidity used | Efficiency (value / liquidity) | Opening balances needed | Fiat settlements | Peak exposure | Collateral + pool | Mean delay (value-weighted) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| (a) gross RTGS | $20.3bn | $20.3bn | 1.0 | $20.3bn | 36089 | 0 | — | 0 min |
| (b1) prefunded netting, release on submission | $20.3bn | $2.9bn | 6.9 | $2.9bn | 39 | 0 | — | 0 min |
| (b2) prefunded netting, FIFO queue to cut-off | $20.3bn | $2.1bn | 9.9 | $2.1bn | 26 | 0 | — | 9 min |
| (c) this model | $20.3bn | $7.5bn | 2.7 | $2.9bn | 528 | $371M | $1.9bn + $1.0bn = $2.9bn | 2 min |

This model: 18 batches/day (0 at a receiver cap, 17 on a receiver call, the rest end of day), 349 fiat legs; 75.7% of value through the credit ledger; $4.9bn paid gross outside it, of which $4.8bn larger than the limits and $76M still queued at the end-of-day cut.

#### N = 40 banks (per-day averages over 5 days, seed 20261006)

| Design | Value settled | Liquidity used | Efficiency (value / liquidity) | Opening balances needed | Fiat settlements | Peak exposure | Collateral + pool | Mean delay (value-weighted) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| (a) gross RTGS | $42.4bn | $42.4bn | 1.0 | $42.4bn | 72179 | 0 | — | 0 min |
| (b1) prefunded netting, release on submission | $42.4bn | $7.7bn | 5.5 | $7.7bn | 79 | 0 | — | 0 min |
| (b2) prefunded netting, FIFO queue to cut-off | $42.4bn | $5.9bn | 7.2 | $5.9bn | 56 | 0 | — | 11 min |
| (c) this model | $42.4bn | $17.7bn | 2.4 | $7.6bn | 1273 | $591M | $7.8bn + $1.6bn = $9.4bn | 4 min |

This model: 18 batches/day (0 at a receiver cap, 17 on a receiver call, the rest end of day), 725 fiat legs; 68.8% of value through the credit ledger; $13.2bn paid gross outside it, of which $12.8bn larger than the limits and $436M still queued at the end-of-day cut.

### Sensitivity (N = 20, one parameter changed at a time)

| Run | (c) liquidity used | (c) opening balances | (c) via credit | (c) batches/day | (c) peak exposure | (c) collateral + pool | (b2) opening balances |
|---|---:|---:|---:|---:|---:|---:|---:|
| defaults | $7.5bn | $2.9bn | 75.7% | 18 | $371M | $2.9bn | $2.1bn |
| elective limits 0 (mandatory only) | $11.9bn | $3.1bn | 46.7% | 20 | $126M | $2.1bn | $2.1bn |
| elective factor 0.5 | $5.9bn | $2.8bn | 86.7% | 14 | $579M | $3.9bn | $2.1bn |
| batch latency 5 min | $8.5bn | $2.9bn | 76.1% | 46 | $244M | $2.9bn | $2.1bn |
| CapReached at 50% of the cap | $7.5bn | $2.9bn | 75.7% | 18 | $371M | $2.9bn | $2.1bn |
| lighter tail (σ = 1.2) | $1.6bn | $1.4bn | 99.7% | 10 | $438M | $2.9bn | $1.3bn |
| seed 7 | $7.4bn | $3.4bn | 76.1% | 17 | $365M | $2.9bn | $2.6bn |

## What the numbers say

- **This model does not beat prefunded netting on liquidity in these runs.** Its opening-balance need is about
  the same as release-on-submission netting (b1) and 29–38% above the queued, CHIPS-like design (b2), at every N
  tried; on top of that it ties up collateral and a loss pool ($1.1bn at N = 10, $9.4bn at N = 40). Only with a
  lighter size tail (σ = 1.2, where nearly all value fits within the limits) does it come close to (b2), and it
  still needs the collateral and pool.
- **The heavy tail is the main reason.** With $5M mandatory limits and elective limits sized to a tenth of a day's
  bilateral flow, 19–30% of the value is in payments larger than any limit, which this model pays gross. Larger
  elective limits move more value onto the ledger (87% at factor 0.5) but raise the debit caps and so the cover-2
  pool. Without elective limits the model degrades towards gross settlement.
- **"Liquidity used" overstates (c) against (b).** It counts every fiat leg and every outside payment at face value
  (a flow), while (b)'s prefund is a balance that is reused all day (a stock). The opening-balance column is the
  like-for-like comparison.
- **One batch in flight bounds the cut rate.** With a 30-minute completion time the system runs about 18 batches a
  day, almost all receiver calls; the receiver-cap trigger at 100% rarely fires because the payment that would
  cross the cap queues and calls first, and lowering the trigger relabels cuts without changing the totals.
  Faster completion (5 minutes) gives more, smaller batches and lower exposure, not lower liquidity.
- **Against gross RTGS without recycling**, every netting design, this one included, cuts "liquidity used" by a factor of
  2.4–10 in these runs.
- What the model offers that these figures do not price: each payment is final when it passes the checks (no
  queueing delay for in-limit payments), RTP-funded settlement outside CHIPS hours, and credit exposure that is
  bounded per pair and per bank and covered by a defaulter-pays waterfall. Whether those are worth the extra
  collateral is not answered here.

## Limits and assumptions

- Synthetic flows only: the size distribution, bank-size weights and intraday shape are assumptions, not fits to
  any data. Real flows have customer-driven correlation, time-critical payments and recurring bilateral patterns
  that are not modelled.
- Days are independent and start flat: every design settles to zero by the end of the day; no overnight
  positions, no off-hours (RTP) traffic and no cross-chain spokes are simulated.
- (b2) is a per-payer FIFO release with a locally minimised prefund (coordinate descent from (b1)). A real CHIPS
  release algorithm offsets queued payments bilaterally and multilaterally and uses closing-position funding, so
  it may need less than (b2) here; (b2) is not a model of CHIPS's actual algorithm.
- In (c), payments larger than the limits are paid gross with no netting; a bank could route them through a
  netting system instead, which would lower (c)'s figures. That hybrid is not simulated.
- Banks do not adapt: no payment timing strategies, no splitting of large payments, no receiver calls other than
  on a queue, no lowering of receiver caps.
- No defaults are simulated; collateral and pool are the amounts the rules require, not losses.
- The 30-minute batch completion time is an assumption covering fiat legs plus attestation.
