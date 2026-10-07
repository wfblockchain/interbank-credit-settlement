package e2e

// Cross-chain end-to-end tests (design §4) on three anvil chains: the home
// chain (domain 1, the World of the home tests), a permissioned spoke
// (domain 2) and a public spoke (domain 3), each its own anvil with its own
// chain id and port. The transport is internal/xchain: five attester
// processes (each with its own RPC connection to every chain, waiting for
// that chain's finality depth), one issuer signer per bank, and an untrusted
// relayer.

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"

	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/listener"
	"interbank-credit-settlement/internal/operator"
	"interbank-credit-settlement/internal/rails"
	"interbank-credit-settlement/internal/xchain"
)

const (
	domHome uint32 = 1
	domPerm uint32 = 2
	domPub  uint32 = 3
)

var chainIDs = map[uint32]int64{domHome: 31337, domPerm: 31338, domPub: 31339}

var domNames = map[uint32]string{domHome: "home", domPerm: "permissioned spoke", domPub: "public spoke"}

// startAnvilChain is StartAnvil with a chain id of our choosing.
func startAnvilChain(ctx context.Context, bin string, genesis time.Time, chainID int64) (*Anvil, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		port, err := freePort()
		if err != nil {
			return nil, err
		}
		cmd := exec.Command(bin, "--port", strconv.Itoa(port), "--host", "127.0.0.1",
			"--timestamp", strconv.FormatInt(genesis.Unix(), 10), "--silent", "--chain-id", strconv.FormatInt(chainID, 10))
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		a := &Anvil{URL: fmt.Sprintf("http://127.0.0.1:%d", port), cmd: cmd}
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			c, err := ethclient.DialContext(ctx, a.URL)
			if err == nil {
				var id *big.Int
				id, err = c.ChainID(ctx)
				c.Close()
				if err == nil && id.Int64() == chainID {
					return a, nil
				}
			}
			lastErr = err
			time.Sleep(50 * time.Millisecond)
		}
		a.Stop()
	}
	return nil, fmt.Errorf("anvil (chain %d) did not start: %v", chainID, lastErr)
}

// xOptions configures an xWorld.
type xOptions struct {
	Finality map[uint32]uint64 // per spoke; default 2 (permissioned) and 3 (public)
	// AttesterDial may return a DialFunc for attester i (fault injection).
	AttesterDial func(i int, x *xWorld) xchain.DialFunc
}

// xWorld is the home World plus two spokes and the cross-chain transport.
type xWorld struct {
	*World
	t      *testing.T
	Anvils map[uint32]*Anvil
	C      map[uint32]*chain.Client // the harness's own clients (domain 1 is World.C)
	Hub    *deploy.Hub
	Spokes map[uint32]*deploy.Spoke
	Net    *xchain.Network

	Domains     []xchain.Domain
	AttKeys     []*ecdsa.PrivateKey
	IssuerKeys  map[[32]byte]*ecdsa.PrivateKey
	Wallet      map[string]chain.Account
	Ops         map[string]chain.Account
	IssuerAdmin map[string]chain.Account // each bank's admin of its spoke tokens
	Admin       chain.Account
	Guardian    chain.Account
	Anyone      chain.Account // a stranger; also the relayer's gas account
}

func newXWorld(t *testing.T, start time.Time, o xOptions) *xWorld {
	t.Helper()
	w := newWorld(t, start)
	bin, err := AnvilBin()
	must(t, err)
	artifacts, err := deploy.ArtifactsDir()
	must(t, err)
	if o.Finality == nil {
		o.Finality = map[uint32]uint64{domPerm: 2, domPub: 3}
	}
	x := &xWorld{World: w, t: t, Anvils: map[uint32]*Anvil{domHome: w.Anvil}, C: map[uint32]*chain.Client{domHome: w.C},
		Spokes: map[uint32]*deploy.Spoke{}, IssuerKeys: map[[32]byte]*ecdsa.PrivateKey{}, Wallet: map[string]chain.Account{},
		Ops: map[string]chain.Account{}, IssuerAdmin: map[string]chain.Account{}, Admin: account("admin"), Guardian: account("guardian"),
		Anyone: account("relayer")}
	ctx := w.Ctx
	for _, d := range []uint32{domPerm, domPub} {
		a, err := startAnvilChain(ctx, bin, start.Add(-48*time.Hour), chainIDs[d])
		must(t, err)
		t.Cleanup(a.Stop)
		x.Anvils[d] = a
		c, err := chain.Dial(ctx, a.URL, artifacts)
		must(t, err)
		x.C[d] = c
		must(t, c.SetTime(ctx, start))
	}

	// Keys: five attesters (a strict majority of three signs) and one issuer
	// key per bank, all distinct from every other role.
	var attAddrs []common.Address
	for i := 0; i < 5; i++ {
		k := listener.KeyFromSeed(fmt.Sprintf("interbank-credit-settlement/xchain-attester-%d", i))
		x.AttKeys = append(x.AttKeys, k)
		attAddrs = append(attAddrs, crypto.PubkeyToAddress(k.PublicKey))
	}
	issuerAddrs := map[[32]byte]common.Address{}
	for _, b := range bankSpecs {
		k := listener.KeyFromSeed("interbank-credit-settlement/issuer-key/" + b.short)
		x.IssuerKeys[ID(b.short)] = k
		issuerAddrs[ID(b.short)] = crypto.PubkeyToAddress(k.PublicKey)
		x.Wallet[b.short] = account(b.short + "/wallet")
		x.Ops[b.short] = account(b.short + "/issuer-ops")
		x.IssuerAdmin[b.short] = account(b.short + "/issuer-admin")
	}
	gas := []chain.Account{x.Admin, x.Guardian, x.Anyone, w.Operator}
	for _, b := range bankSpecs {
		gas = append(gas, x.Wallet[b.short], x.Ops[b.short], x.IssuerAdmin[b.short])
	}
	for d, c := range x.C {
		accts := gas
		if d != domHome {
			accts = append(accts, account(fmt.Sprintf("spoke-%d/deployer", d)))
		}
		for _, a := range accts {
			must(t, c.FundGas(ctx, a.Addr))
		}
	}

	x.Hub, err = w.D.DeployHub(ctx, deploy.HubConfig{Domain: domHome, Attesters: attAddrs, Threshold: 3, IssuerKeys: issuerAddrs})
	must(t, err)
	w.Log("deployed the hub messenger %s on the home chain (attesters 3 of 5; issuer keys for A, B, C)", short(x.Hub.Messenger.Addr))
	bigCap := u(1_000_000 * M) // $1T: caps that do not bind unless a test lowers them
	for _, d := range []uint32{domPerm, domPub} {
		kind := deploy.DomainPermissioned
		if d == domPub {
			kind = deploy.DomainPublic
		}
		var banks []deploy.SpokeBank
		for _, b := range bankSpecs {
			banks = append(banks, deploy.SpokeBank{ID: b.id, TokenName: b.token, Symbol: b.symbol, Wallet: x.Wallet[b.short].Addr,
				IssuerOps: x.Ops[b.short].Addr, IssuerAdmin: x.IssuerAdmin[b.short].Addr, IssuerKey: issuerAddrs[ID(b.short)],
				SupplyCap: bigCap, RateCapacity: bigCap})
		}
		s, err := deploy.DeploySpoke(ctx, x.C[d], deploy.SpokeConfig{Mode: deploy.TestAdmin, Domain: d, HomeDomain: domHome, Kind: kind,
			Deployer: account(fmt.Sprintf("spoke-%d/deployer", d)), Admin: x.Admin, Guardian: x.Guardian.Addr, Operator: w.Operator.Addr,
			Attesters: attAddrs, Threshold: 3, AdminDelay: 86400, Banks: banks})
		must(t, err)
		rates := map[[32]byte]*big.Int{}
		for _, b := range bankSpecs {
			rates[ID(b.short)] = bigCap
		}
		must(t, x.Hub.Connect(ctx, s, rates))
		x.Spokes[d] = s
		w.Log("deployed the %s (domain %d, chain id %d): messenger %s, guard %s, A-dT/B-dT/C-dT; connected to the hub",
			domNames[d], d, chainIDs[d], short(s.Messenger.Addr), short(s.Guard.Addr))
	}

	x.Domains = []xchain.Domain{{ID: domHome, Name: domNames[domHome], URL: w.Anvil.URL, ChainID: big.NewInt(chainIDs[domHome]),
		Messenger: x.Hub.Messenger.Addr, Finality: 0, Home: true}}
	for _, d := range []uint32{domPerm, domPub} {
		x.Domains = append(x.Domains, xchain.Domain{ID: d, Name: domNames[d], URL: x.Anvils[d].URL, ChainID: big.NewInt(chainIDs[d]),
			Messenger: x.Spokes[d].Messenger.Addr, Finality: o.Finality[d]})
	}
	var dial func(int) xchain.DialFunc
	if o.AttesterDial != nil {
		dial = func(i int) xchain.DialFunc { return o.AttesterDial(i, x) }
	}
	w.Op.SetSpokeWindow(func(ctx context.Context, window uint8) error {
		for _, d := range []uint32{domPerm, domPub} {
			if _, err := x.send(d, x.Spokes[d].Guard, w.Operator, "setWindow", window); err != nil {
				return err
			}
		}
		return nil
	})
	w.Op.SetOpenElsewhere(func(ctx context.Context) (bool, error) {
		for _, d := range []uint32{domPerm, domPub} {
			for _, i := range bankSpecs {
				for _, h := range bankSpecs {
					if i.short == h.short {
						continue
					}
					v, err := x.Spokes[d].Guard.BigInt(ctx, "open", ID(i.short), ID(h.short))
					if err != nil {
						return false, err
					}
					if v.Sign() > 0 {
						return true, nil
					}
				}
			}
		}
		return false, nil
	})
	x.Net, err = xchain.NewNetwork(ctx, xchain.NetworkConfig{Domains: x.Domains, Artifacts: artifacts, Relayer: x.Anyone,
		AttesterKeys: x.AttKeys, Threshold: 3, IssuerKeys: x.IssuerKeys, AttesterDial: dial, Log: w.Log})
	must(t, err)
	t.Cleanup(x.Net.Close)
	w.Log("transport up: 5 attesters × 3 chains (own connections), 3 issuer signers, 1 relayer; finality home 0, perm %d, public %d blocks",
		o.Finality[domPerm], o.Finality[domPub])
	return x
}

// ---------------------------------------------------------------- harness

// produce mines blocks on a spoke (its block producer).
func (x *xWorld) produce(ctx context.Context, d uint32, n uint64) error {
	return x.C[d].RPC.CallContext(ctx, nil, "anvil_mine", hexutil.EncodeUint64(n))
}

// syncTime moves every spoke's clock up to the scenario clock (never back).
func (x *xWorld) syncTime() {
	now := x.Clock.Now()
	for _, d := range []uint32{domPerm, domPub} {
		h, err := x.C[d].Eth.HeaderByNumber(x.Ctx, nil)
		must(x.t, err)
		if int64(h.Time) < now.Unix() {
			must(x.t, x.C[d].SetTime(x.Ctx, now))
		}
	}
}

// relay runs the transport until nothing moves.
func (x *xWorld) relay() {
	x.t.Helper()
	x.syncTime()
	must(x.t, x.Net.Settle(x.Ctx, x.produce))
}

// warp moves one chain's clock forward.
func (x *xWorld) warp(d uint32, by time.Duration) {
	x.t.Helper()
	h, err := x.C[d].Eth.HeaderByNumber(x.Ctx, nil)
	must(x.t, err)
	must(x.t, x.C[d].SetTime(x.Ctx, time.Unix(int64(h.Time), 0).Add(by)))
}

func (x *xWorld) send(d uint32, k *chain.Contract, from chain.Account, method string, args ...any) (*types.Receipt, error) {
	return deploy.Send(x.Ctx, x.C[d], k, from, method, args...)
}

func (x *xWorld) big(d uint32, k *chain.Contract, method string, args ...any) *big.Int {
	x.t.Helper()
	v, err := k.BigInt(x.Ctx, method, args...)
	must(x.t, err)
	return v
}

func (x *xWorld) flag(k *chain.Contract, method string, args ...any) bool {
	x.t.Helper()
	v, err := k.Bool(x.Ctx, method, args...)
	must(x.t, err)
	return v
}

func (x *xWorld) eq(what string, got *big.Int, want uint64) {
	x.t.Helper()
	if got.Cmp(u(want)) != 0 {
		x.t.Fatalf("%s: %s, want %s", what, operator.Money(got), operator.Money(u(want)))
	}
}

func (x *xWorld) guard(d uint32) *chain.Contract { return x.Spokes[d].Guard }

func (x *xWorld) rtok(d uint32, issuer string) *chain.Contract { return x.Spokes[d].Token(ID(issuer)) }

func (x *xWorld) grant(d uint32, issuer, holder string, amount uint64) {
	x.t.Helper()
	_, err := x.send(domHome, x.Hub.Messenger, x.Operator, "grantEnvelope", d, ID(issuer), ID(holder), u(amount))
	must(x.t, err)
	x.Log("operator: grantEnvelope(%s, %s-dT held by %s, %s): headroom reserved at the hub, ENVELOPE_GRANT sent", domNames[d],
		issuer, holder, operator.Money(u(amount)))
}

// spokePay has the payer's issuerOps pay on a spoke; it returns the queue
// sequence number and whether the payment was queued.
func (x *xWorld) spokePay(d uint32, from, to string, amount uint64) (seq *big.Int, queued bool, err error) {
	ref := chain.RefOf(fmt.Sprintf("spoke-%d/%s→%s/%d/%d", d, from, to, amount, time.Now().UnixNano()))
	rcpt, err := x.send(d, x.guard(d), x.Ops[from], "pay", ID(to), u(amount), ref)
	if err != nil {
		return nil, false, err
	}
	g := x.guard(d)
	for _, l := range rcpt.Logs {
		if l.Address == g.Addr && (l.Topics[0] == g.EventID("Queued") || l.Topics[0] == g.EventID("Paid")) {
			return new(big.Int).SetBytes(l.Topics[1][:]), l.Topics[0] == g.EventID("Queued"), nil
		}
	}
	return nil, false, fmt.Errorf("pay: no Paid or Queued event")
}

func (x *xWorld) mustSpokePay(d uint32, from, to string, amount uint64) {
	x.t.Helper()
	_, q, err := x.spokePay(d, from, to, amount)
	must(x.t, err)
	if q {
		x.t.Fatalf("%s: %s → %s %s queued", domNames[d], from, to, operator.Money(u(amount)))
	}
	x.Log("%s: Bank %s pays Bank %s %s: %s-dT minted within the envelope", domNames[d], from, to, operator.Money(u(amount)), from)
}

func nonceOf(t *testing.T, rcpt *types.Receipt, m *chain.Contract) uint64 {
	t.Helper()
	for _, l := range rcpt.Logs {
		if l.Address == m.Addr && l.Topics[0] == m.EventID("MoveLocked") {
			return new(big.Int).SetBytes(l.Topics[1][:]).Uint64()
		}
	}
	t.Fatal("no MoveLocked")
	return 0
}

// moveOut moves `amount` of issuer's token held by holder from home to a spoke.
func (x *xWorld) moveOut(d uint32, issuer, holder string, amount uint64, ttl time.Duration) uint64 {
	x.t.Helper()
	_, err := x.send(domHome, x.D.Token(ID(issuer)), x.Wallet[holder], "approve", x.Hub.Messenger.Addr, u(amount))
	must(x.t, err)
	h, err := x.C[domHome].Eth.HeaderByNumber(x.Ctx, nil)
	must(x.t, err)
	rcpt, err := x.send(domHome, x.Hub.Messenger, x.Wallet[holder], "sendMint", ID(issuer), ID(holder), u(amount), d,
		x.Wallet[holder].Addr, h.Time+uint64(ttl/time.Second))
	must(x.t, err)
	n := nonceOf(x.t, rcpt, x.Hub.Messenger)
	x.Log("Bank %s's wallet sends %s of %s-dT home → %s (move #%d): locked in the hub messenger, MINT sent", holder,
		operator.Money(u(amount)), issuer, domNames[d], n)
	return n
}

// moveHome moves `amount` from a spoke back home.
func (x *xWorld) moveHome(d uint32, issuer, holder string, amount uint64, ttl time.Duration) uint64 {
	x.t.Helper()
	h, err := x.C[d].Eth.HeaderByNumber(x.Ctx, nil)
	must(x.t, err)
	m := x.Spokes[d].Messenger
	rcpt, err := x.send(d, m, x.Wallet[holder], "sendMint", ID(issuer), ID(holder), u(amount), domHome, x.Wallet[holder].Addr,
		h.Time+uint64(ttl/time.Second))
	must(x.t, err)
	n := nonceOf(x.t, rcpt, m)
	x.Log("Bank %s's wallet sends %s of %s-dT %s → home (move #%d): locked on the spoke, MINT sent", holder,
		operator.Money(u(amount)), issuer, domNames[d], n)
	return n
}

// supply is an issuer's supply per domain and in total.
func (x *xWorld) supply(issuer string) (map[uint32]*big.Int, *big.Int) {
	x.t.Helper()
	per := map[uint32]*big.Int{}
	s, err := x.D.TokenSupply(x.Ctx, ID(issuer))
	must(x.t, err)
	per[domHome] = s
	total := new(big.Int).Set(s)
	for _, d := range []uint32{domPerm, domPub} {
		v := x.big(d, x.rtok(d, issuer), "totalSupply")
		per[d] = v
		total.Add(total, v)
	}
	return per, total
}

func (x *xWorld) logSupply(issuer string) *big.Int {
	per, total := x.supply(issuer)
	x.Log("%s-dT supply: home %s + permissioned %s + public %s = %s", issuer, operator.Money(per[domHome]),
		operator.Money(per[domPerm]), operator.Money(per[domPub]), operator.Money(total))
	return total
}

// reconcile runs the cross-chain reconciliation and fails on any break.
func (x *xWorld) reconcile() {
	x.t.Helper()
	if p := x.Net.Relayer.Pending(); len(pendingReal(p)) > 0 {
		x.t.Fatalf("messages still in flight: %+v", pendingReal(p))
	}
	rep, err := xchain.Reconcile(x.Ctx, x.Hub)
	if err != nil {
		x.t.Fatalf("cross-chain reconciliation: %v", err)
	}
	var parts []string
	for _, it := range rep.Issuers {
		parts = append(parts, fmt.Sprintf("%s %s", deploy.IDString(it.Issuer), operator.Money(it.Total())))
	}
	x.Log("cross-chain reconciliation clean (supply = open + pending + escrows + spoke open + locked, per issuer; envelopes nested; accountant): %s",
		strings.Join(parts, ", "))
}

// pendingReal drops messages that never had a majority (a lying attester's
// fabrications): those are not in flight, they are refused by omission.
func pendingReal(p []xchain.Pending) []xchain.Pending {
	var out []xchain.Pending
	for _, m := range p {
		if m.Signers >= 3 {
			out = append(out, m)
		}
	}
	return out
}

func (x *xWorld) deliveries(kind uint8, src uint32) []xchain.Delivery {
	var out []xchain.Delivery
	for _, d := range x.Net.Relayer.Log() {
		if d.Envelope.Kind == kind && d.Envelope.Source == src {
			out = append(out, d)
		}
	}
	return out
}

func (x *xWorld) inbound(d uint32, src uint32, nonce uint64) uint8 {
	x.t.Helper()
	out, err := x.Net.Relayer.Messenger(d).Call(x.Ctx, "inbound", src, nonce)
	must(x.t, err)
	return out[0].(uint8)
}

func (x *xWorld) moveStatus(d uint32, nonce uint64) uint8 {
	x.t.Helper()
	out, err := x.Net.Relayer.Messenger(d).Call(x.Ctx, "move", nonce)
	must(x.t, err)
	m, err := deploy.Decode[xchain.Move](out[0])
	must(x.t, err)
	return m.Status
}

// mintRefusedReason reads the reason of the last MintRefused on a messenger.
func (x *xWorld) mintRefusedReason(d uint32, src uint32, nonce uint64) (uint8, bool) {
	x.t.Helper()
	m := x.Net.Relayer.Messenger(d)
	head, err := x.C[d].Head(x.Ctx)
	must(x.t, err)
	logs, err := m.EventsWithTopic(x.Ctx, "MintRefused", xchain.TopicUint(uint64(src)), 0, head)
	must(x.t, err)
	for _, l := range logs {
		if l.Topics[2] == xchain.TopicUint(nonce) {
			return uint8(new(big.Int).SetBytes(l.Data).Uint64()), true
		}
	}
	return 0, false
}

func requireErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("want an error containing %q, got %v", want, err)
	}
}

// ---------------------------------------------------------------- X1

// X1. Envelopes on the permissioned spoke; payments on both spokes and at
// home; the end-of-day cut reaches both spokes; their BATCH_LOCKED reports
// complete the batch; one CHIPS payment attested 3 of 5 settles home and
// spokes; BURN_BATCH burns on both spokes; exposure zero everywhere.
func TestXChain_X1_CutAcrossThreeChains(t *testing.T) {
	day := Date("2026-10-06") // a Tuesday
	x := newXWorld(t, At(day, 9, 0), xOptions{})
	ctx := x.Ctx
	must(t, x.AdvanceTo(At(day, 10, 0)))

	x.Log("— the operator grants envelopes: permissioned spoke from credit, public spoke from Bank A's free collateral —")
	free, err := x.D.Register.BigInt(ctx, "freeCollateral", ID("A"))
	must(t, err)
	x.Log("Bank A's free collateral: %s", operator.Money(free))
	x.grant(domPerm, "A", "B", 10*M)
	x.grant(domPerm, "B", "A", 4*M)
	x.grant(domPub, "A", "B", 5*M)
	pc, err := x.D.Register.BigInt(ctx, "publicCommitted", ID("A"))
	must(t, err)
	x.eq("public envelope drawn from A's collateral", pc, 5*M)
	x.relay()
	x.eq("perm env A→B", x.big(domPerm, x.guard(domPerm), "env", ID("A"), ID("B")), 10*M)
	x.eq("perm env B→A", x.big(domPerm, x.guard(domPerm), "env", ID("B"), ID("A")), 4*M)
	x.eq("public env A→B", x.big(domPub, x.guard(domPub), "env", ID("A"), ID("B")), 5*M)
	for _, d := range x.deliveries(xchain.KindEnvelopeGrant, domHome) {
		if d.Outcome != xchain.Delivered || len(d.Signers) < 3 || d.Issuer {
			t.Fatalf("grant delivery %+v", d)
		}
	}

	x.Log("— a day of payments on three chains —")
	x.mustSpokePay(domPerm, "A", "B", 6*M)
	x.mustSpokePay(domPerm, "B", "A", 2*M)
	x.mustSpokePay(domPub, "A", "B", 3*M)
	seq, q, err := x.spokePay(domPerm, "A", "B", 5*M)
	if err != nil || !q {
		t.Fatalf("a payment beyond the envelope must queue: queued=%v err=%v", q, err)
	}
	x.Log("permissioned spoke: a further $5M from Bank A queues locally (6 + 5 > the $10M envelope); Bank A cancels it")
	_, err = x.send(domPerm, x.guard(domPerm), x.Ops["A"], "cancel", seq)
	must(t, err)
	res, err := x.Banks["A"].Pay(ctx, ID("B"), 5*M)
	must(t, err)
	if res.Queued {
		t.Fatalf("home payment queued: %+v", res)
	}
	x.Log("home: Bank A pays Bank B $5M")

	x.Log("— 16:30 ET: the operator cuts; the plan must wait for both spokes —")
	must(t, x.AdvanceTo(At(day, 16, 29)))
	x.Clock.Set(At(day, 16, 30))
	must(t, x.Step())
	bt, err := x.D.Batch(ctx, 1)
	must(t, err)
	if bt.Status != deploy.StatusCut {
		t.Fatalf("batch 1 is %s before the spokes report, want CUT", deploy.StatusName(bt.Status))
	}
	x.Log("operator: the plan waits (submitPlan is refused on chain until every spoke has reported)")
	epoch := bt.Epoch
	reported := func() bool {
		v, err := x.Hub.Messenger.Bool(ctx, "spokesReported", epoch)
		must(t, err)
		return v
	}
	if reported() {
		t.Fatal("spokes reported before any CUT was relayed")
	}
	x.relay()
	for _, d := range []uint32{domPerm, domPub} {
		cuts := 0
		for _, dl := range x.deliveries(xchain.KindCut, domHome) {
			if dl.Envelope.Dest == d && dl.Outcome == xchain.Delivered {
				cuts++
			}
		}
		if cuts != 1 {
			t.Fatalf("%s: %d CUT deliveries", domNames[d], cuts)
		}
		var pairs, closing int
		for _, dl := range x.deliveries(xchain.KindBatchLocked, d) {
			if dl.Outcome != xchain.Delivered {
				t.Fatalf("BATCH_LOCKED %+v", dl)
			}
			if dl.Envelope.Member == ([32]byte{}) {
				closing++
				if dl.Envelope.Amount.Uint64() != uint64(pairs) {
					t.Fatalf("%s: closing BATCH_LOCKED carries %s pairs, saw %d", domNames[d], dl.Envelope.Amount, pairs)
				}
			} else {
				pairs++
			}
		}
		if closing != 1 {
			t.Fatalf("%s: %d closing reports", domNames[d], closing)
		}
		x.Log("%s: CUT delivered; BATCH_LOCKED reported %d pair(s) and the closing count", domNames[d], pairs)
	}
	if !reported() {
		t.Fatal("spokesReported false after the reports")
	}
	x.eq("perm locked A→B", x.big(domPerm, x.guard(domPerm), "lockedTotal", ID("A"), ID("B")), 6*M)
	x.eq("perm env A→B after the cut", x.big(domPerm, x.guard(domPerm), "env", ID("A"), ID("B")), 4*M)
	x.eq("hub envelope perm A→B after the cut", x.big(domHome, x.D.Ledger, "envelope", domPerm, ID("A"), ID("B")), 4*M)
	x.eq("pending A→B at the hub", x.big(domHome, x.D.Ledger, "pending", ID("A"), ID("B")), 5*M+6*M+3*M)
	x.reconcile()

	x.Log("— every spoke has reported: the operator plans, Bank A pays over CHIPS, the listener attests —")
	must(t, x.Step())
	recs := x.Op.Records()
	if len(recs) != 1 || recs[0].Trigger != deploy.TriggerEndOfDay || recs[0].Rail != rails.CHIPS {
		t.Fatalf("records %+v", recs)
	}
	if len(recs[0].Legs) != 1 || recs[0].Legs[0].Payer != ID("A") || recs[0].Legs[0].Payee != ID("B") || recs[0].Legs[0].Amount.Cmp(u(12*M)) != 0 {
		t.Fatalf("plan %+v, want one leg A → B $12M (5 + 6 + 3 − 2)", recs[0].Legs)
	}
	pairs, err := x.D.PendingPairs(ctx, epoch)
	must(t, err)
	out, err := x.Hub.Messenger.Call(ctx, "remotePairs", epoch)
	must(t, err)
	remote, err := deploy.Decode[[]struct {
		Domain uint32
		Issuer [32]byte
		Holder [32]byte
		Amount *big.Int
	}](out[0])
	must(t, err)
	if len(pairs) != 4 || len(remote) != 3 {
		t.Fatalf("batch pairs %d (want 4: 1 home + 3 remote), remote %d", len(pairs), len(remote))
	}
	if n := len(x.CHIPS.Journal().Entries()); n != 1 {
		t.Fatalf("%d CHIPS payments, want 1", n)
	}
	subs := x.Listener.Log()
	if len(subs) != 1 || subs[0].Err != nil || len(subs[0].Signers) != 3 {
		t.Fatalf("listener log %+v", subs)
	}
	requireFinalized(t, x.World, 1)
	x.Log("one CHIPS payment (%s, $12M) attested 3 of 5: batch 1 COMPLETE; home pair burned at finalize", subs[0].RailTxID)

	x.Log("— anyone sends the settlement burns; BURN_BATCH lands on both spokes —")
	_, err = x.send(domHome, x.Hub.Messenger, x.Anyone, "sendBurns", epoch)
	must(t, err)
	_, err = x.send(domHome, x.Hub.Messenger, x.Anyone, "sendBurns", epoch)
	requireErr(t, err, "BurnsAlreadySent")
	x.relay()
	if n := len(x.deliveries(xchain.KindBurnBatch, domHome)); n != 3 {
		t.Fatalf("%d BURN_BATCH deliveries, want 3", n)
	}
	for _, d := range []uint32{domPerm, domPub} {
		for _, i := range []string{"A", "B"} {
			x.eq(fmt.Sprintf("%s %s-dT supply", domNames[d], i), x.big(d, x.rtok(d, i), "totalSupply"), 0)
		}
	}

	x.Log("— the operator hands the unused envelopes back: spoke first, then the hub —")
	for _, d := range []uint32{domPerm, domPub} {
		for _, p := range [][2]string{{"A", "B"}, {"B", "A"}} {
			free := x.big(d, x.guard(d), "available", ID(p[0]), ID(p[1]))
			free.Add(free, x.big(d, x.guard(d), "releasable", ID(p[0]), ID(p[1])))
			if free.Sign() == 0 {
				continue
			}
			_, err := x.send(d, x.Spokes[d].Messenger, x.Operator, "releaseEnvelope", ID(p[0]), ID(p[1]), free)
			must(t, err)
			x.Log("%s: releaseEnvelope(%s-dT held by %s, %s)", domNames[d], p[0], p[1], operator.Money(free))
		}
	}
	x.relay()
	for _, d := range []uint32{domPerm, domPub} {
		for _, p := range [][2]string{{"A", "B"}, {"B", "A"}} {
			x.eq(fmt.Sprintf("hub envelope %s %s→%s", domNames[d], p[0], p[1]), x.big(domHome, x.D.Ledger, "envelope", d, ID(p[0]), ID(p[1])), 0)
			x.eq(fmt.Sprintf("%s env %s→%s", domNames[d], p[0], p[1]), x.big(d, x.guard(d), "env", ID(p[0]), ID(p[1])), 0)
		}
	}
	pc, err = x.D.Register.BigInt(ctx, "publicCommitted", ID("A"))
	must(t, err)
	x.eq("A's collateral committed to public envelopes", pc, 0)
	for _, i := range []string{"A", "B", "C"} {
		_, total := x.supply(i)
		x.eq(i+"-dT supply on all chains", total, 0)
	}
	requireNoExposure(t, x.World)
	requireClean(t, x.World)
	x.reconcile()
}

// ---------------------------------------------------------------- X2

// X2. A home → spoke move by lock-then-burn (MINT with both keys, MINT_ACK
// burns the source lock); then moves the destination refuses (the spoke
// token paused; spoke-native tokens the hub never sent) and one cancelled
// after its deadline during a transport outage: MINT_CANCEL unlocks at the
// source; supply conserved on every chain.
func TestXChain_X2_TokenMoves(t *testing.T) {
	day := Date("2026-10-06")
	x := newXWorld(t, At(day, 9, 0), xOptions{})
	ctx := x.Ctx
	must(t, x.AdvanceTo(At(day, 10, 0)))
	_, err := x.Banks["A"].Pay(ctx, ID("B"), 10*M)
	must(t, err)
	x.Log("home: Bank A pays Bank B $10M; Bank B's wallet holds $10M of A-dT")
	homeBal := func(issuer, holder string) *big.Int {
		return x.big(domHome, x.D.Token(ID(issuer)), "balanceOf", x.Wallet[holder].Addr)
	}

	x.Log("— (1) lock-then-burn: $4M of A-dT home → permissioned spoke —")
	n1 := x.moveOut(domPerm, "A", "B", 4*M, 24*time.Hour)
	x.eq("locked in the hub", x.big(domHome, x.D.Token(ID("A")), "balanceOf", x.Hub.Messenger.Addr), 4*M)
	x.eq("A's supply before the mint is proven", x.big(domHome, x.D.Token(ID("A")), "totalSupply"), 10*M)
	x.eq("hub envelope perm A→B", x.big(domHome, x.D.Ledger, "envelope", domPerm, ID("A"), ID("B")), 4*M)
	x.relay()
	mints := x.deliveries(xchain.KindMint, domHome)
	if len(mints) != 1 || mints[0].Outcome != xchain.Delivered || !mints[0].Issuer || len(mints[0].Signers) < 3 {
		t.Fatalf("MINT deliveries %+v", mints)
	}
	if st := x.inbound(domPerm, domHome, n1); st != xchain.InboundMinted {
		t.Fatalf("spoke inbound %d", st)
	}
	if st := x.moveStatus(domHome, n1); st != xchain.MoveCompleted {
		t.Fatalf("move status %d", st)
	}
	x.eq("B's A-dT on the spoke", x.big(domPerm, x.rtok(domPerm, "A"), "balanceOf", x.Wallet["B"].Addr), 4*M)
	x.eq("hub escrow after MINT_ACK", x.big(domHome, x.D.Token(ID("A")), "balanceOf", x.Hub.Messenger.Addr), 0)
	x.eq("home A-dT after the burn", x.big(domHome, x.D.Token(ID("A")), "totalSupply"), 6*M)
	x.eq("spoke env = used", x.big(domPerm, x.guard(domPerm), "env", ID("A"), ID("B")), 4*M)
	x.Log("MINT delivered with an attester majority + Bank A's own key; MINT_ACK burned the hub's lock")
	x.eq("A-dT conserved", x.logSupply("A"), 10*M)
	x.reconcile()

	x.Log("— (2) the destination refuses: Bank A's issuer admin pauses A-dT on the permissioned spoke —")
	_, err = x.send(domPerm, x.rtok(domPerm, "A"), x.IssuerAdmin["A"], "pause")
	must(t, err)
	n2 := x.moveOut(domPerm, "A", "B", 2*M, 24*time.Hour)
	x.eq("B's home A-dT while locked", homeBal("A", "B"), 4*M)
	x.relay()
	if st := x.inbound(domPerm, domHome, n2); st != xchain.InboundCancelled {
		t.Fatalf("spoke inbound %d, want CANCELLED", st)
	}
	if r, ok := x.mintRefusedReason(domPerm, domHome, n2); !ok || r != 5 {
		t.Fatalf("MintRefused reason %d (found %v), want 5 (R_BLOCKED)", r, ok)
	}
	if st := x.moveStatus(domHome, n2); st != xchain.MoveCancelled {
		t.Fatalf("move status %d, want CANCELLED", st)
	}
	x.eq("B's home A-dT unlocked", homeBal("A", "B"), 6*M)
	x.Log("spoke refused the MINT (paused token) → MINT_CANCEL → the hub unlocked $2M to Bank B")
	x.eq("A-dT conserved", x.logSupply("A"), 10*M)
	_, err = x.send(domPerm, x.rtok(domPerm, "A"), x.IssuerAdmin["A"], "unpause")
	must(t, err)

	x.Log("— (3) the hub refuses: spoke-native C-dT cannot be sent home (the hub never sent it) —")
	x.grant(domPerm, "C", "B", 5*M)
	x.relay()
	x.mustSpokePay(domPerm, "C", "B", 3*M)
	n3 := x.moveHome(domPerm, "C", "B", 3*M, 24*time.Hour)
	x.eq("spoke lock", x.big(domPerm, x.rtok(domPerm, "C"), "lockedOf", x.Wallet["B"].Addr), 3*M)
	x.eq("spoke env lowered first", x.big(domPerm, x.guard(domPerm), "env", ID("C"), ID("B")), 2*M)
	x.relay()
	if st := x.inbound(domHome, domPerm, n3); st != xchain.InboundCancelled {
		t.Fatalf("hub inbound %d, want CANCELLED", st)
	}
	if r, ok := x.mintRefusedReason(domHome, domPerm, n3); !ok || r != 13 {
		t.Fatalf("hub MintRefused reason %d (found %v), want 13 (R_ACCOUNTANT)", r, ok)
	}
	x.eq("home C-dT", x.big(domHome, x.D.Token(ID("C")), "totalSupply"), 0)
	x.eq("spoke unlocked", x.big(domPerm, x.rtok(domPerm, "C"), "lockedOf", x.Wallet["B"].Addr), 0)
	x.eq("spoke used restored", x.big(domPerm, x.guard(domPerm), "used", ID("C"), ID("B")), 3*M)
	x.eq("spoke env restored", x.big(domPerm, x.guard(domPerm), "env", ID("C"), ID("B")), 5*M)
	x.Log("hub refused (global accountant: sent 0 to the spoke) → MINT_CANCEL → the spoke unlocked $3M of C-dT")
	x.eq("C-dT conserved", x.logSupply("C"), 3*M)

	x.Log("— (4) transport outage: a MINT outlives its deadline and is cancelled at the destination —")
	x.Net.Relayer.Hold(domPerm, true)
	n4 := x.moveOut(domPerm, "A", "B", 1*M, 15*time.Minute)
	x.relay()
	var held bool
	for _, p := range x.Net.Relayer.Pending() {
		if p.Envelope.Kind == xchain.KindMint && p.Envelope.Nonce == n4 && p.Signers >= 3 {
			held = true
		}
	}
	if !held {
		t.Fatal("the attested MINT is not waiting at the relayer")
	}
	x.warp(domPerm, 20*time.Minute)
	x.Log("permissioned spoke clock +20m: the MINT's deadline has passed; transport restored")
	x.Net.Relayer.Hold(domPerm, false)
	x.relay()
	exp := x.deliveries(xchain.KindMint, domHome)
	if last := exp[len(exp)-1]; last.Envelope.Nonce != n4 || last.Outcome != xchain.Expired || last.Issuer {
		t.Fatalf("last MINT delivery %+v, want cancelled after its deadline by attesters only", last)
	}
	if st := x.inbound(domPerm, domHome, n4); st != xchain.InboundCancelled {
		t.Fatalf("spoke inbound %d", st)
	}
	if st := x.moveStatus(domHome, n4); st != xchain.MoveCancelled {
		t.Fatalf("move status %d", st)
	}
	msg, sigs, ok := x.Net.Relayer.Signatures(xchain.MsgID{Source: domHome, Nonce: n4})
	if !ok {
		t.Fatal("no signatures kept")
	}
	_, err = x.Net.Relayer.Submit(ctx, domPerm, msg, sigs, nil)
	requireErr(t, err, "NonceUsed")
	if _, err := x.Net.Issuers[ID("A")].CoSign(ctx, msg); !errors.Is(err, xchain.ErrNoSourceLock) {
		t.Fatalf("issuer co-signed a cancelled move: %v", err)
	}
	x.eq("B's home A-dT unlocked", homeBal("A", "B"), 6*M)
	x.Log("cancelExpired with the attesters' signatures → MINT_CANCEL → unlocked at home; the MINT can never land (NonceUsed), and Bank A's signer will not co-sign it")
	x.eq("A-dT conserved", x.logSupply("A"), 10*M)
	x.eq("C-dT conserved", x.logSupply("C"), 3*M)
	x.reconcile()
}

// ---------------------------------------------------------------- X3

// lyingSource is a node that adds one fabricated MessageSent log.
type lyingSource struct {
	xchain.Source
	messenger common.Address
	armed     *atomic.Bool
	done      atomic.Bool
	fake      xchain.Envelope
}

func (s *lyingSource) FilterLogs(ctx context.Context, q ethereum.FilterQuery) ([]types.Log, error) {
	logs, err := s.Source.FilterLogs(ctx, q)
	if err != nil || !s.armed.Load() || q.ToBlock == nil || s.done.Load() {
		return logs, err
	}
	s.done.Store(true)
	return append(logs, xchain.MessageSentLog(s.messenger, q.ToBlock.Uint64(), s.fake)), nil
}

// X3. A forged MINT with the wrong issuer key is refused; a delivered
// message cannot be replayed (on chain, and by a fresh relayer); one
// attester's node serves the wrong chain and another's fabricates a log, yet
// the honest majority carries every real message and nothing fabricated
// mints; an exhausted inbound rate limit is retried after the bucket refills.
func TestXChain_X3_Faults(t *testing.T) {
	day := Date("2026-10-06")
	var armed atomic.Bool
	const fakeNonce = 9_000
	var liar *lyingSource
	x := newXWorld(t, At(day, 9, 0), xOptions{AttesterDial: func(i int, x *xWorld) xchain.DialFunc {
		switch i {
		case 4: // its permissioned-spoke node is really the public spoke's
			return func(ctx context.Context, d xchain.Domain) (xchain.Source, error) {
				if d.ID == domPerm {
					d.URL = x.Anvils[domPub].URL
				}
				return xchain.DialOwn(ctx, d)
			}
		case 3: // its permissioned-spoke node fabricates a MINT of $50M A-dT
			return func(ctx context.Context, d xchain.Domain) (xchain.Source, error) {
				s, err := xchain.DialOwn(ctx, d)
				if err != nil || d.ID != domPerm {
					return s, err
				}
				liar = &lyingSource{Source: s, messenger: d.Messenger, armed: &armed, fake: xchain.Envelope{
					Version: xchain.Version, Kind: xchain.KindMint, Source: domPerm, Dest: domHome, Nonce: fakeNonce,
					Member: ID("A"), Counterparty: ID("B"), Recipient: account("B/wallet").Addr, Amount: u(50 * M),
					Deadline: uint64(At(day, 23, 0).Unix())}}
				return liar, nil
			}
		}
		return nil
	}})
	ctx := x.Ctx
	must(t, x.AdvanceTo(At(day, 10, 0)))
	_, err := x.Banks["A"].Pay(ctx, ID("B"), 10*M)
	must(t, err)

	x.Log("— (1) a forged MINT: three attester keys, but Bank B's key signs for A-dT —")
	forged := xchain.Envelope{Version: xchain.Version, Kind: xchain.KindMint, Source: domPub, Dest: domHome, Nonce: 70_001,
		Member: ID("A"), Counterparty: ID("B"), Recipient: x.Wallet["B"].Addr, Amount: u(5 * M), Deadline: uint64(At(day, 23, 0).Unix())}
	fm := forged.Encode()
	dg := xchain.Digest(x.Spokes[domPub].Messenger.Addr, x.Hub.Messenger.Addr, fm)
	out, err := x.Hub.Messenger.Call(ctx, "messageDigest", fm)
	must(t, err)
	if common.Hash(out[0].([32]byte)) != dg {
		t.Fatal("the Go digest differs from the messenger's messageDigest")
	}
	keys := append([]*ecdsa.PrivateKey(nil), x.AttKeys[:3]...)
	sort.Slice(keys, func(i, j int) bool {
		a, b := crypto.PubkeyToAddress(keys[i].PublicKey), crypto.PubkeyToAddress(keys[j].PublicKey)
		return bytes.Compare(a[:], b[:]) < 0
	})
	var fsigs [][]byte
	for _, k := range keys {
		s, err := xchain.Sign(k, dg)
		must(t, err)
		fsigs = append(fsigs, s)
	}
	wrong, err := xchain.Sign(x.IssuerKeys[ID("B")], dg)
	must(t, err)
	_, err = x.Net.Relayer.Submit(ctx, domHome, fm, fsigs, wrong)
	requireErr(t, err, "BadIssuerSignature")
	x.Log("hub: %v", err)
	if _, err := x.Net.Issuers[ID("B")].CoSign(ctx, fm); !errors.Is(err, xchain.ErrNotOwnToken) {
		t.Fatalf("Bank B's signer: %v", err)
	}
	if _, err := x.Net.Issuers[ID("A")].CoSign(ctx, fm); !errors.Is(err, xchain.ErrNoSourceLock) {
		t.Fatalf("Bank A's signer: %v", err)
	}
	x.Log("Bank B's signer refuses (not its token); Bank A's signer refuses (no lock on the public spoke, read from its own node)")
	if st := x.inbound(domHome, domPub, 70_001); st != xchain.InboundNone {
		t.Fatalf("hub inbound %d", st)
	}
	x.eq("home A-dT", x.big(domHome, x.D.Token(ID("A")), "totalSupply"), 10*M)

	x.Log("— (2) two faulty attester nodes on the permissioned spoke: one serves the wrong chain, one fabricates a $50M MINT —")
	armed.Store(true)
	x.moveOut(domPerm, "A", "B", 4*M, 24*time.Hour)
	x.relay()
	x.moveHome(domPerm, "A", "B", 1*M, 24*time.Hour)
	x.relay()
	if liar == nil || !liar.done.Load() {
		t.Fatal("the lying node never served its fabricated log")
	}
	var wrongChain bool
	for _, f := range x.Net.Attesters[4].Faults() {
		if f.Domain == domPerm && errors.Is(f.Err, xchain.ErrWrongChain) {
			wrongChain = true
			x.Log("attester-4 refuses to sign from its node: %v", f.Err)
		}
	}
	if !wrongChain {
		t.Fatalf("attester-4 faults %v", x.Net.Attesters[4].Faults())
	}
	a4 := x.Net.Attesters[4].Address()
	fromPerm := 0
	for _, d := range x.Net.Relayer.Log() {
		if d.Envelope.Source != domPerm {
			continue
		}
		fromPerm++
		if d.Outcome != xchain.Delivered || len(d.Signers) < 3 {
			t.Fatalf("delivery from the permissioned spoke %+v", d)
		}
		for _, s := range d.Signers {
			if s == a4 {
				t.Fatalf("the wrong-chain attester's signature carried %s", d.Envelope)
			}
		}
	}
	if fromPerm < 2 {
		t.Fatalf("%d deliveries from the permissioned spoke", fromPerm)
	}
	var fake *xchain.Pending
	for _, p := range x.Net.Relayer.Pending() {
		if p.Envelope.Source == domPerm && p.Envelope.Nonce == fakeNonce {
			p := p
			fake = &p
		}
	}
	if fake == nil || fake.Signers != 1 || fake.Attempts != 0 {
		t.Fatalf("fabricated MINT at the relayer: %+v", fake)
	}
	if st := x.inbound(domHome, domPerm, fakeNonce); st != xchain.InboundNone {
		t.Fatalf("hub inbound for the fabricated nonce %d", st)
	}
	if _, err := x.Net.Issuers[ID("A")].CoSign(ctx, fake.Message); !errors.Is(err, xchain.ErrNoSourceLock) {
		t.Fatalf("Bank A's signer on the fabricated MINT: %v", err)
	}
	x.Log("the fabricated MINT has 1 signature of the 3 needed: never submitted; Bank A's signer finds no such lock; the real moves were carried without attester-4 (attester-3's node lies about one log only, so it still signs the real ones)")
	x.eq("home A-dT (6 after the move out, +1 back)", x.big(domHome, x.D.Token(ID("A")), "totalSupply"), 7*M)
	x.eq("A-dT conserved", x.logSupply("A"), 10*M)

	x.Log("— (3) replay: a delivered message again, on chain and through a fresh relayer —")
	acks := x.deliveries(xchain.KindMintAck, domPerm)
	if len(acks) == 0 {
		t.Fatal("no MINT_ACK from the spoke")
	}
	msg, sigs, ok := x.Net.Relayer.Signatures(acks[0].Envelope.ID())
	if !ok {
		t.Fatal("no signatures")
	}
	_, err = x.Net.Relayer.Submit(ctx, domHome, msg, sigs, nil)
	requireErr(t, err, "NonceUsed")
	x.Log("hub: replayed %s refused: %v", acks[0].Envelope, err)
	artifacts, err := deploy.ArtifactsDir()
	must(t, err)
	var attAddrs []common.Address
	for _, a := range x.Net.Attesters {
		attAddrs = append(attAddrs, a.Address())
	}
	var cos []xchain.CoSigner
	for _, s := range x.Net.Issuers {
		cos = append(cos, s)
	}
	fresh, err := xchain.NewRelayer(ctx, xchain.RelayerConfig{Domains: x.Domains, Artifacts: artifacts, Account: x.Anyone,
		Attesters: attAddrs, Threshold: 3, Issuers: cos})
	must(t, err)
	for _, a := range x.Net.Attesters {
		for _, at := range a.Attestations() {
			must(t, fresh.Collect(at))
		}
	}
	_, err = fresh.Deliver(ctx)
	must(t, err)
	flog := fresh.Log()
	if len(flog) == 0 {
		t.Fatal("the fresh relayer saw nothing")
	}
	for _, d := range flog {
		if d.Outcome != xchain.AlreadyDelivered || d.Tx != (common.Hash{}) {
			t.Fatalf("fresh relayer: %+v", d)
		}
	}
	x.Log("a fresh relayer fed every attestation so far skipped all %d messages: each nonce already consumed at its destination", len(flog))

	x.Log("— (4) the inbound rate limit: governance sets $5M per hour for A-dT from home on the permissioned spoke —")
	must(t, x.Spokes[domPerm].AdminCall(ctx, x.Spokes[domPerm].Messenger, "setRateLimit", domHome, ID("A"), u(5*M), uint64(3600)))
	x.moveOut(domPerm, "A", "B", 4*M, 24*time.Hour)
	x.relay()
	x.moveOut(domPerm, "A", "B", 3*M, 24*time.Hour)
	x.relay()
	x.relay() // a second round: still short, retried again
	var limited *xchain.Pending
	for _, p := range x.Net.Relayer.Pending() {
		if p.Envelope.Kind == xchain.KindMint && p.Envelope.Source == domHome && p.Envelope.Amount.Cmp(u(3*M)) == 0 {
			p := p
			limited = &p
		}
	}
	if limited == nil || limited.Attempts < 2 || limited.LastErr == nil || !strings.Contains(limited.LastErr.Error(), "RateLimited") {
		t.Fatalf("rate-limited MINT %+v", limited)
	}
	x.Log("the $3M MINT is waiting: %d attempts, %v", limited.Attempts, limited.LastErr)
	x.warp(domPerm, 30*time.Minute)
	x.Log("permissioned spoke clock +30m: the bucket refills $2.5M (now ≥ $3M)")
	x.relay()
	if st := x.inbound(domPerm, domHome, limited.Envelope.Nonce); st != xchain.InboundMinted {
		t.Fatalf("after the refill: inbound %d", st)
	}
	x.eq("B's A-dT on the spoke", x.big(domPerm, x.rtok(domPerm, "A"), "balanceOf", x.Wallet["B"].Addr), 3*M+4*M+3*M)
	x.eq("A-dT conserved", x.logSupply("A"), 10*M)
	x.reconcile()
}

// ---------------------------------------------------------------- X4

// X4. SUSPEND of Bank C reaches both spokes: C-dT paused there, every
// envelope C is party to cut to what is in use, and new spoke payments to and
// from C refused; a second SUSPEND raises nothing.
func TestXChain_X4_SuspendPropagates(t *testing.T) {
	day := Date("2026-10-06")
	x := newXWorld(t, At(day, 9, 0), xOptions{})
	ctx := x.Ctx
	must(t, x.AdvanceTo(At(day, 10, 0)))
	x.grant(domPerm, "C", "A", 5*M)
	x.grant(domPerm, "A", "C", 5*M)
	x.grant(domPerm, "A", "B", 5*M)
	x.grant(domPub, "C", "B", 3*M)
	x.grant(domPub, "A", "C", 2*M)
	x.relay()
	x.mustSpokePay(domPerm, "C", "A", 2*M)
	x.mustSpokePay(domPerm, "A", "C", 1*M)
	x.mustSpokePay(domPub, "C", "B", 1*M)

	x.Log("— the guardian suspends Bank C at home; anyone broadcasts SUSPEND —")
	_, err := x.send(domHome, x.Hub.Messenger, x.Anyone, "sendSuspend", ID("C"))
	requireErr(t, err, "MemberInGoodStanding")
	_, err = x.D.Send(ctx, x.D.Registry, x.Guardian, "suspend", ID("C"), chain.Bytes32("PCA"))
	must(t, err)
	_, err = x.send(domHome, x.Hub.Messenger, x.Anyone, "sendSuspend", ID("C"))
	must(t, err)
	x.relay()
	sus := x.deliveries(xchain.KindSuspend, domHome)
	if len(sus) != 2 {
		t.Fatalf("%d SUSPEND deliveries, want 2", len(sus))
	}
	type envState struct{ env, used, releasable uint64 }
	want := map[uint32]map[[2]string]envState{
		domPerm: {{"C", "A"}: {2 * M, 2 * M, 3 * M}, {"A", "C"}: {1 * M, 1 * M, 4 * M}, {"A", "B"}: {5 * M, 0, 0}},
		domPub:  {{"C", "B"}: {1 * M, 1 * M, 2 * M}, {"A", "C"}: {0, 0, 2 * M}},
	}
	for d, pairs := range want {
		g := x.guard(d)
		for p, s := range pairs {
			x.eq(fmt.Sprintf("%s env %s→%s", domNames[d], p[0], p[1]), x.big(d, g, "env", ID(p[0]), ID(p[1])), s.env)
			x.eq(fmt.Sprintf("%s used %s→%s", domNames[d], p[0], p[1]), x.big(d, g, "used", ID(p[0]), ID(p[1])), s.used)
			x.eq(fmt.Sprintf("%s releasable %s→%s", domNames[d], p[0], p[1]), x.big(d, g, "releasable", ID(p[0]), ID(p[1])), s.releasable)
		}
		if !x.flag(x.rtok(d, "C"), "paused") {
			t.Fatalf("%s: C-dT not paused", domNames[d])
		}
		if x.flag(x.rtok(d, "A"), "paused") {
			t.Fatalf("%s: A-dT paused", domNames[d])
		}
		x.Log("%s: C-dT paused; C's envelopes cut to what is in use (headroom parked as releasable); A→B untouched", domNames[d])
	}

	x.Log("— new spoke payments to and from Bank C are refused —")
	for _, c := range []struct {
		d        uint32
		from, to string
	}{{domPerm, "C", "A"}, {domPerm, "A", "C"}, {domPub, "C", "B"}, {domPub, "A", "C"}} {
		_, _, err := x.spokePay(c.d, c.from, c.to, 1*USD)
		requireErr(t, err, "MemberSuspended")
	}
	x.mustSpokePay(domPerm, "A", "B", 1*M)
	x.Log("payments with Bank C refused on both spokes (MemberSuspended); Bank A → Bank B still pays")

	x.Log("— a second SUSPEND (the guardian's) raises nothing —")
	before := map[string]*big.Int{}
	for d, pairs := range want {
		for p := range pairs {
			k := fmt.Sprint(d, p)
			before[k] = x.big(d, x.guard(d), "env", ID(p[0]), ID(p[1]))
		}
	}
	_, err = x.send(domHome, x.Hub.Messenger, x.Guardian, "sendSuspend", ID("C"))
	must(t, err)
	x.relay()
	for d, pairs := range want {
		for p := range pairs {
			got := x.big(d, x.guard(d), "env", ID(p[0]), ID(p[1]))
			if got.Cmp(before[fmt.Sprint(d, p)]) != 0 {
				t.Fatalf("%s env %v changed by a second SUSPEND", domNames[d], p)
			}
		}
	}
	x.reconcile()
}

// ---------------------------------------------------------------- X5

// X5. A day with payments only on a spoke: the home epoch is empty, but the
// end-of-day cut still happens and the spoke positions settle the same day.
func TestXChain_X5_SpokeOnlyDay(t *testing.T) {
	day := Date("2026-10-06")
	x := newXWorld(t, At(day, 9, 0), xOptions{})
	ctx := x.Ctx
	must(t, x.AdvanceTo(At(day, 10, 0)))
	x.grant(domPerm, "A", "B", 10*M)
	x.relay()
	x.mustSpokePay(domPerm, "A", "B", 7*M)
	eh, err := x.D.EpochHash(ctx)
	must(t, err)
	if eh != ([32]byte{}) {
		t.Fatal("home epoch should be empty on a spoke-only day")
	}
	must(t, x.AdvanceTo(At(day, 16, 29)))
	x.Clock.Set(At(day, 16, 30))
	must(t, x.Step())
	if n := len(x.Op.Records()); n != 1 {
		t.Fatalf("%d batches cut, want 1 (the spoke holds open positions)", n)
	}
	x.Log("16:30 ET: home epoch empty, spoke positions open → the end-of-day cut happens")
	x.relay()
	must(t, x.Step())
	recs := x.Op.Records()
	if len(recs[0].Legs) != 1 || recs[0].Legs[0].Amount.Cmp(u(7*M)) != 0 {
		t.Fatalf("plan %+v, want one leg A → B $7M", recs[0].Legs)
	}
	requireFinalized(t, x.World, 1)
	bt, err := x.D.Batch(ctx, 1)
	must(t, err)
	_, err = x.send(domHome, x.Hub.Messenger, x.Anyone, "sendBurns", bt.Epoch)
	must(t, err)
	x.relay()
	x.eq("permissioned A-dT supply after the burn", x.big(domPerm, x.rtok(domPerm, "A"), "totalSupply"), 0)
	x.Log("spoke-only day settled the same business day; A-dT burned on the permissioned spoke")
}

// ---------------------------------------------------------------- X6

// X6. No unsecured credit overnight on a spoke: after the end-of-day cut the
// operator moves every spoke to OFF_HOURS; a credit payment on the
// permissioned spoke is refused, while the public spoke (collateral-backed)
// keeps working. The next business window reopens the permissioned spoke.
func TestXChain_X6_SpokeOffHours(t *testing.T) {
	day := Date("2026-10-06")
	x := newXWorld(t, At(day, 9, 0), xOptions{})
	must(t, x.AdvanceTo(At(day, 10, 0)))
	x.grant(domPerm, "A", "B", 10*M)
	x.grant(domPub, "A", "B", 5*M)
	x.relay()
	x.mustSpokePay(domPerm, "A", "B", 1*M)
	must(t, x.AdvanceTo(At(day, 16, 29)))
	x.Clock.Set(At(day, 16, 31))
	must(t, x.Step())
	_, _, err := x.spokePay(domPerm, "A", "B", 1*M)
	requireErr(t, err, "OffHoursCredit")
	x.Log("16:31 ET: permissioned spoke refuses credit off-hours (OffHoursCredit)")
	x.mustSpokePay(domPub, "A", "B", 1*M)
	x.Log("public spoke still pays: its envelope is covered by Bank A's collateral")
	must(t, x.AdvanceTo(At(Date("2026-10-07"), 9, 0)))
	x.relay()
	x.mustSpokePay(domPerm, "A", "B", 1*M)
	x.Log("next business window: the permissioned spoke reopens")
}
