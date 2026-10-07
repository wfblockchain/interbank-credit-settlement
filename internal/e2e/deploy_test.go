package e2e

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
)

// Timelock mode deploys as DeployHome.s.sol does: a TimelockController is
// every contract's default admin and governance calls (here, admitting the
// banks) go through schedule + execute; the governance key alone can do
// nothing.
func TestDeployTimelockMode(t *testing.T) {
	bin, err := AnvilBin()
	if err != nil {
		t.Skipf("SKIP end-to-end test: %v (e.g. ANVIL_BIN=/path/to/anvil)", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	a, err := StartAnvil(ctx, bin, time.Unix(1_790_000_000, 0))
	must(t, err)
	defer a.Stop()
	dir, err := deploy.ArtifactsDir()
	must(t, err)
	c, err := chain.Dial(ctx, a.URL, dir)
	must(t, err)
	deployer, gov, guardian, op := account("deployer"), account("admin"), account("guardian"), account("operator")
	var signers []common.Address
	for i := 0; i < 5; i++ {
		signers = append(signers, account(fmt.Sprintf("signer-%d", i)).Addr)
	}
	var banks []deploy.Bank
	for _, b := range bankSpecs {
		banks = append(banks, deploy.Bank{ID: b.id, TokenName: b.token, Symbol: b.symbol, Wallet: account(b.short + "/wallet").Addr,
			IssuerOps: account(b.short + "/issuer-ops").Addr})
	}
	for _, x := range []chain.Account{deployer, gov} {
		must(t, c.FundGas(ctx, x.Addr))
	}
	d, err := deploy.Deploy(ctx, c, deploy.Config{Mode: deploy.Timelock, Deployer: deployer, Admin: gov, Guardian: guardian.Addr,
		Operator: op.Addr, Signers: signers, Threshold: 3, AdminDelay: 86400, Banks: banks})
	must(t, err)
	if d.Timelock == nil {
		t.Fatal("no timelock")
	}
	out, err := d.Batches.Call(ctx, "defaultAdmin")
	must(t, err)
	if out[0].(common.Address) != d.Timelock.Addr {
		t.Fatalf("default admin %s, want the timelock %s", out[0], d.Timelock.Addr)
	}
	ids, err := d.MemberIDs(ctx)
	must(t, err)
	if len(ids) != 3 {
		t.Fatalf("%d members admitted through the timelock", len(ids))
	}
	// The governance key cannot act directly.
	_, err = d.Send(ctx, d.Limits, gov, "setReceiverCap", ID("A"), u(1))
	if err == nil || !strings.Contains(err.Error(), "AccessControlUnauthorizedAccount") {
		t.Fatalf("direct governance call: %v", err)
	}
	// Through the timelock it can.
	must(t, d.AdminCall(ctx, d.Limits, "setReceiverCap", ID("A"), u(7*M)))
	capA, err := d.Limits.BigInt(ctx, "receiverCap", ID("A"))
	must(t, err)
	if capA.Cmp(u(7*M)) != 0 {
		t.Fatalf("receiver cap %s", capA)
	}
}
