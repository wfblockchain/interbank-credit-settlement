// Command operator-demo starts anvil, deploys the home-chain contracts, and
// runs the operator, the five-signer listener and three simulated banks
// through a narrated business day (Friday), a weekend (and the Monday
// Columbus Day holiday, off-hours all day) and the next business day, then
// prints a summary table of every settlement batch.
//
//	ANVIL_BIN=/path/to/anvil ICS_ARTIFACTS=contracts/out go run ./cmd/operator-demo
//
// anvil is found via -anvil, $ANVIL_BIN or PATH; the Foundry artifacts via
// -artifacts, $ICS_ARTIFACTS or contracts/out (run `forge build` first).
package main

import (
	"context"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/e2e"
	"interbank-credit-settlement/internal/operator"
	"interbank-credit-settlement/internal/rails"
)

func main() {
	anvil := flag.String("anvil", "", "anvil binary (default: $ANVIL_BIN, then PATH)")
	artifacts := flag.String("artifacts", "", "Foundry artifacts directory (default: $ICS_ARTIFACTS, then contracts/out)")
	quiet := flag.Bool("quiet", false, "print only the summary")
	flag.Parse()
	if *anvil != "" {
		os.Setenv(e2e.AnvilEnv, *anvil)
	}
	if *artifacts != "" {
		os.Setenv(deploy.ArtifactsEnv, *artifacts)
	}
	if err := run(*quiet); err != nil {
		fmt.Fprintln(os.Stderr, "operator-demo:", err)
		os.Exit(1)
	}
}

type pay struct {
	from, to string
	amt      uint64
}

func run(quiet bool) error {
	bin, err := e2e.AnvilBin()
	if err != nil {
		return err
	}
	logf := func(format string, args ...any) { fmt.Printf(format+"\n", args...) }
	if quiet {
		logf = func(string, ...any) {}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	fri, sat, sun, mon, tue := e2e.Date("2026-10-09"), e2e.Date("2026-10-10"), e2e.Date("2026-10-11"), e2e.Date("2026-10-12"), e2e.Date("2026-10-13")
	w, err := e2e.NewWorld(ctx, bin, e2e.Options{Start: e2e.At(fri, 8, 0), Log: logf})
	if err != nil {
		return err
	}
	defer w.Close()
	M := e2e.M

	payAll := func(ps ...pay) error {
		for _, p := range ps {
			if _, err := w.Banks[p.from].Pay(ctx, e2e.ID(p.to), p.amt); err != nil {
				return err
			}
		}
		return w.Step()
	}
	banner := func(s string) { w.Log("════ %s ════", s) }

	banner("Friday: a business day")
	if err := w.AdvanceTo(e2e.At(fri, 9, 30)); err != nil {
		return err
	}
	w.Log("Bank A's customers send Bank B's customers $100M in four transfers; Bank B reaches its receiver cap")
	if err := payAll(pay{"A", "B", 25 * M}, pay{"A", "B", 25 * M}, pay{"A", "B", 25 * M}, pay{"A", "B", 25 * M}); err != nil {
		return err
	}
	if err := w.AdvanceTo(e2e.At(fri, 11, 0)); err != nil {
		return err
	}
	if err := payAll(pay{"B", "C", 30 * M}, pay{"C", "A", 12 * M}, pay{"A", "C", 8 * M}); err != nil {
		return err
	}
	if err := w.AdvanceTo(e2e.At(fri, 13, 0)); err != nil {
		return err
	}
	w.Log("Bank C asks to be settled now (receiver call)")
	if err := w.Banks["C"].RequestSettlement(ctx); err != nil {
		return err
	}
	if err := w.Step(); err != nil {
		return err
	}
	if err := w.AdvanceTo(e2e.At(fri, 15, 0)); err != nil {
		return err
	}
	if err := payAll(pay{"A", "B", 7 * M}, pay{"C", "B", 9 * M}, pay{"B", "A", 3 * M}); err != nil {
		return err
	}
	if err := w.AdvanceTo(e2e.At(fri, 17, 30)); err != nil {
		return err
	}

	banner("Saturday: off hours, RTP only, within attested prefunds")
	if err := w.AdvanceTo(e2e.At(sat, 10, 0)); err != nil {
		return err
	}
	if err := payAll(pay{"A", "B", 60 * M}, pay{"A", "B", 40 * M}); err != nil {
		return err
	}
	if _, err := w.Banks["A"].Pay(ctx, e2e.ID("C"), 60*M); err != nil {
		w.Log("Bank A → Bank C $60M refused: %s", firstLine(err))
	}
	if err := payAll(pay{"C", "B", 5 * M}); err != nil {
		return err
	}

	banner("Sunday and the Columbus Day holiday: still off hours")
	if err := w.AdvanceTo(e2e.At(sun, 14, 0)); err != nil {
		return err
	}
	if err := payAll(pay{"C", "A", 5 * M}); err != nil {
		return err
	}
	if err := w.AdvanceTo(e2e.At(mon, 12, 0)); err != nil {
		return err
	}
	if err := payAll(pay{"B", "A", 2 * M}); err != nil {
		return err
	}

	banner("Tuesday: the business window reopened at Monday 21:00 ET")
	if err := w.AdvanceTo(e2e.At(tue, 17, 30)); err != nil {
		return err
	}
	if err := w.Op.Reconcile(ctx); err != nil {
		return fmt.Errorf("final reconciliation: %w", err)
	}
	return summary(w)
}

func firstLine(err error) string {
	s := err.Error()
	if i := strings.Index(s, "reverted "); i >= 0 {
		return s[i:]
	}
	return s
}

func summary(w *e2e.World) error {
	fmt.Println()
	fmt.Println("Settlement batches")
	tw := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "batch\ttrigger\tcut (ET)\trail\tlegs\tpayments\tsettled\tstatus\tcomplete (ET)\tburned\tdrained")
	var chips, rtp int
	total := new(big.Int)
	for _, r := range w.Op.Records() {
		bt, err := w.D.Batch(w.Ctx, r.Batch)
		if err != nil {
			return err
		}
		st := deploy.StatusName(bt.Status)
		if bt.Finalized {
			st += ", finalized"
		}
		if r.Defaulted {
			st += " (default)"
		}
		for _, in := range r.Instructions {
			if in.Rail == rails.CHIPS {
				chips++
			} else {
				rtp++
			}
		}
		total.Add(total, r.Settled())
		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%d\n", r.Batch, deploy.TriggerName(r.Trigger), et(r.CutAt), r.Rail,
			len(r.Legs), len(r.Instructions), operator.Money(r.Settled()), st, et(r.CompleteAt), operator.Money(r.Burned), r.Drained)
	}
	if err := tw.Flush(); err != nil {
		return err
	}
	review := 0
	for _, rv := range w.Listener.ManualReview() {
		review += len(rv)
	}
	x, err := w.Exposure()
	if err != nil {
		return err
	}
	fmt.Println()
	fmt.Printf("fiat settled: %s in %d CHIPS and %d RTP payments; %d listener attestations (3-of-5); %d manual-review items\n",
		operator.Money(total), chips, rtp, len(w.Listener.Log()), review)
	fmt.Printf("open exposure at the end: %s; reconciliation: clean; operator halted: %v\n", operator.Money(x), w.Op.Halted() != nil)
	return nil
}

func et(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.In(calendar.ET).Format("Mon 15:04")
}
