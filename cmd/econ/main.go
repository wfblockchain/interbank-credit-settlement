// Command econ runs the economics simulator (internal/econ) and prints one
// markdown table per bank count. The defaults reproduce docs/economics.md.
//
//	go run ./cmd/econ                      # N = 10, 20, 40
//	go run ./cmd/econ -banks 20 -days 10 -seed 7 -elective-factor 0
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"interbank-credit-settlement/internal/econ"
)

func main() {
	banks := flag.String("banks", "10,20,40", "comma-separated bank counts")
	days := flag.Int("days", 0, "business days to simulate (0: default)")
	seed := flag.Int64("seed", 0, "RNG seed (0: default)")
	value := flag.Float64("value-per-bank", 0, "average daily value sent per bank, USD (0: default)")
	median := flag.Float64("median", 0, "median payment, USD (0: default)")
	sigma := flag.Float64("sigma", 0, "lognormal sigma of payment size (0: default)")
	elective := flag.Float64("elective-factor", -1, "elective limit as a fraction of expected daily bilateral flow (-1: default)")
	trigger := flag.Float64("trigger", 0, "CapReached trigger as a fraction of the receiver cap (0: default 1.0)")
	latency := flag.Int("latency", 0, "seconds from cut to batch completion (0: default)")
	flag.Parse()

	for _, s := range strings.Split(*banks, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || n < 2 {
			fmt.Fprintf(os.Stderr, "bad bank count %q\n", s)
			os.Exit(2)
		}
		c := econ.DefaultConfig(n)
		if *days > 0 {
			c.Days = *days
		}
		if *seed != 0 {
			c.Seed = *seed
		}
		if *value > 0 {
			c.ValuePerBank = *value
		}
		if *median > 0 {
			c.MedianSize = *median
		}
		if *sigma > 0 {
			c.Sigma = *sigma
		}
		if *elective >= 0 {
			c.ElectiveFactor = *elective
		}
		if *trigger > 0 {
			c.TriggerLevel = *trigger
		}
		if *latency > 0 {
			c.SettleLatency = *latency
		}
		fmt.Println(econ.Markdown(c, econ.Run(c)))
	}
}
