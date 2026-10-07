package e2e

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/calendar"
	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
	"interbank-credit-settlement/internal/listener"
	"interbank-credit-settlement/internal/operator"
	"interbank-credit-settlement/internal/rails"
	"interbank-credit-settlement/internal/reconcile"
)

// USD is one dollar in 6-decimal units.
const USD uint64 = 1_000_000

// M is one million dollars in 6-decimal units.
const M uint64 = 1_000_000 * USD

// The fictional members (design §2) and the joint account's operator BIC.
var bankSpecs = []struct {
	short, id, name, token, symbol string
}{
	{"A", "BNKAUS30", "Bank A", "Bank A deposit token", "A-dT"},
	{"B", "BNKBUS30", "Bank B", "Bank B deposit token", "B-dT"},
	{"C", "BNKCUS30", "Bank C", "Bank C deposit token", "C-dT"},
}

// JointBIC identifies the central-bank joint account on rail messages.
const JointBIC = "OPERUS30"

// Options configures a World. Zero values take the defaults noted.
type Options struct {
	Start        time.Time // scenario start (Eastern); required
	Log          func(format string, args ...any)
	Collateral   uint64 // per bank, default $20M
	PoolShare    uint64 // per bank, default $5M
	PoolRequired uint64 // default $15M
	Elective     uint64 // every ordered pair, default $100M
	RTPFund      uint64 // each bank's RTP position, funded at Start if Fedwire is open; default $150M
	JointRTPFund uint64 // the COLLATERAL and POOL RTP positions, default $100M
	Signers      int    // listener signer processes, default 5
}

// Statement is the joint account statement the listener's signers check
// funding attestations against (collateral, pool shares, the required pool);
// RTP prefunds are read from the RTP simulator's positions.
type Statement struct {
	mu     sync.Mutex
	values map[[33]byte]*big.Int
	rtp    *rails.RTPSim
	dir    *operator.Directory
}

func skey(kind uint8, id [32]byte) [33]byte {
	var k [33]byte
	k[0] = kind
	copy(k[1:], id[:])
	return k
}

// Set records a value on the statement.
func (s *Statement) Set(kind uint8, id [32]byte, v uint64) {
	s.mu.Lock()
	s.values[skey(kind, id)] = new(big.Int).SetUint64(v)
	s.mu.Unlock()
}

// FundingValue implements listener.FundingSource.
func (s *Statement) FundingValue(kind uint8, id [32]byte) (*big.Int, bool) {
	if kind == deploy.KindRTPPrefund {
		p, ok := s.dir.Get(id)
		if !ok {
			return nil, false
		}
		return new(big.Int).SetUint64(s.rtp.Position(p.RTPAcct)), true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.values[skey(kind, id)]
	return v, ok
}

// World is a complete home-chain deployment with its back office.
type World struct {
	Ctx   context.Context
	Opts  Options
	Anvil *Anvil
	C     *chain.Client
	D     *deploy.Deployment

	Clock *rails.ManualClock
	CHIPS *rails.CHIPSSim
	RTP   *rails.RTPSim
	Dir   *operator.Directory

	Banks      map[string]*operator.Bank // "A", "B", "C"
	Collateral *operator.RailPayer       // the joint account's COLLATERAL sub-account
	Pool       *operator.RailPayer       // the joint account's POOL sub-account
	Statement  *Statement

	Book     *listener.ChainBook
	Listener *listener.Runner
	Op       *operator.Operator
	Recon    *reconcile.Reconciler

	Operator   chain.Account
	SignerKeys []*ecdsa.PrivateKey

	cancel context.CancelFunc
}

func account(name string) chain.Account {
	k := listener.KeyFromSeed("interbank-credit-settlement/" + name)
	return chain.Account{Name: name, Key: k, Addr: crypto.PubkeyToAddress(k.PublicKey)}
}

// ID is a member id ("A" → bytes32("BNKAUS30")); also COLLATERAL and POOL.
func ID(short string) [32]byte {
	for _, b := range bankSpecs {
		if b.short == short {
			return chain.Bytes32(b.id)
		}
	}
	return chain.Bytes32(short)
}

// NewWorld starts anvil and builds everything. Close it when done.
func NewWorld(ctx context.Context, bin string, o Options) (_ *World, err error) {
	if o.Start.IsZero() {
		return nil, fmt.Errorf("world: Options.Start is required")
	}
	def := func(v *uint64, d uint64) {
		if *v == 0 {
			*v = d
		}
	}
	def(&o.Collateral, 20*M)
	def(&o.PoolShare, 5*M)
	def(&o.PoolRequired, 15*M)
	def(&o.Elective, 100*M)
	def(&o.RTPFund, 150*M)
	def(&o.JointRTPFund, 100*M)
	if o.Signers == 0 {
		o.Signers = 5
	}
	w := &World{Opts: o, Clock: rails.NewManualClock(o.Start), Banks: map[string]*operator.Bank{}}
	raw := o.Log
	if raw == nil {
		raw = func(string, ...any) {}
	}
	o.Log = func(format string, args ...any) {
		raw("[%s] "+format, append([]any{w.Clock.Now().In(calendar.ET).Format("Mon 01-02 15:04:05")}, args...)...)
	}
	w.Opts.Log = o.Log
	ctx, w.cancel = context.WithCancel(ctx)
	w.Ctx = ctx
	defer func() {
		if err != nil {
			w.Close()
		}
	}()

	if w.Anvil, err = StartAnvil(ctx, bin, o.Start.Add(-48*time.Hour)); err != nil {
		return nil, err
	}
	artifacts, err := deploy.ArtifactsDir()
	if err != nil {
		return nil, err
	}
	if w.C, err = chain.Dial(ctx, w.Anvil.URL, artifacts); err != nil {
		return nil, err
	}

	deployer, admin, guardian, submitter := account("deployer"), account("admin"), account("guardian"), account("submitter")
	w.Operator = account("operator")
	var signerAddrs []common.Address
	for i := 0; i < o.Signers; i++ {
		k := listener.KeyFromSeed(fmt.Sprintf("interbank-credit-settlement/signer-%d", i))
		w.SignerKeys = append(w.SignerKeys, k)
		signerAddrs = append(signerAddrs, crypto.PubkeyToAddress(k.PublicKey))
	}
	gas := []chain.Account{deployer, admin, guardian, submitter, w.Operator}
	var banks []deploy.Bank
	ops := map[string]chain.Account{}
	for _, b := range bankSpecs {
		wallet, op := account(b.short+"/wallet"), account(b.short+"/issuer-ops")
		ops[b.short] = op
		gas = append(gas, op)
		banks = append(banks, deploy.Bank{ID: b.id, TokenName: b.token, Symbol: b.symbol, Wallet: wallet.Addr,
			IssuerOps: op.Addr, Tier: deploy.TierCredit})
	}
	for _, a := range gas {
		if err := w.C.FundGas(ctx, a.Addr); err != nil {
			return nil, err
		}
	}
	threshold := 3
	if o.Signers < 3 {
		threshold = o.Signers
	}
	w.D, err = deploy.Deploy(ctx, w.C, deploy.Config{Mode: deploy.TestAdmin, Deployer: deployer, Admin: admin,
		Guardian: guardian.Addr, Operator: w.Operator.Addr, Signers: signerAddrs, Threshold: threshold,
		AdminDelay: 86400, Banks: banks})
	if err != nil {
		return nil, err
	}
	o.Log("deployed the home chain (test-admin mode, no timelock): ledger %s, batches %s, attestor %s (k=%d of n=%d)",
		short(w.D.Ledger.Addr), short(w.D.Batches.Addr), short(w.D.Attestor.Addr), threshold, o.Signers)
	if err := w.C.SetTime(ctx, o.Start); err != nil {
		return nil, err
	}

	// Rails and the directory.
	w.CHIPS = rails.NewCHIPS(w.Clock)
	w.RTP = rails.NewRTP(w.Clock)
	var parts []operator.Participant
	for _, b := range bankSpecs {
		parts = append(parts, operator.Participant{ID: chain.Bytes32(b.id), BIC: b.id, Name: b.name,
			CHIPSAcct: b.id + "-CHIPS", RTPAcct: b.id + "-RTP"})
	}
	parts = append(parts,
		operator.Participant{ID: listener.CollateralPayer, BIC: JointBIC, Name: "Joint account (collateral)",
			CHIPSAcct: JointBIC + "-COLL-CHIPS", RTPAcct: JointBIC + "-COLL-RTP"},
		operator.Participant{ID: listener.PoolPayer, BIC: JointBIC, Name: "Joint account (loss pool)",
			CHIPSAcct: JointBIC + "-POOL-CHIPS", RTPAcct: JointBIC + "-POOL-RTP"})
	w.Dir = operator.NewDirectory(parts...)
	w.Book = listener.NewChainBook(w.D)
	for _, p := range parts {
		w.CHIPS.Open(p.CHIPSAcct)
		w.RTP.Open(p.RTPAcct)
		w.Book.SetAccount(rails.CHIPS, p.CHIPSAcct, p.ID)
		w.Book.SetAccount(rails.RTP, p.RTPAcct, p.ID)
	}
	payers := map[[32]byte]operator.Payer{}
	for _, b := range bankSpecs {
		p, _ := w.Dir.Get(chain.Bytes32(b.id))
		bank := &operator.Bank{RailPayer: operator.NewRailPayer(p, w.Dir, w.CHIPS, w.RTP, w.Clock, o.Log), Ops: ops[b.short], D: w.D}
		w.Banks[b.short] = bank
		payers[p.ID] = bank
	}
	cp, _ := w.Dir.Get(listener.CollateralPayer)
	pp, _ := w.Dir.Get(listener.PoolPayer)
	w.Collateral = operator.NewRailPayer(cp, w.Dir, w.CHIPS, w.RTP, w.Clock, o.Log)
	w.Pool = operator.NewRailPayer(pp, w.Dir, w.CHIPS, w.RTP, w.Clock, o.Log)
	payers[cp.ID], payers[pp.ID] = w.Collateral, w.Pool
	w.Statement = &Statement{values: map[[33]byte]*big.Int{}, rtp: w.RTP, dir: w.Dir}

	// The listener: five signer processes reading both rails' finality feeds.
	w.Listener, err = listener.NewRunner(ctx, listener.RunnerConfig{Deployment: w.D, Submitter: submitter, Keys: w.SignerKeys,
		Book: w.Book, Feeds: map[rails.Rail]listener.Feed{rails.CHIPS: w.CHIPS.Journal(), rails.RTP: w.RTP.Journal()},
		Funding: w.Statement, Log: o.Log})
	if err != nil {
		return nil, err
	}
	w.Listener.Start(ctx)

	// Credit: every bank grants every other bank the elective limit.
	for _, g := range bankSpecs {
		for _, d := range bankSpecs {
			if g.short != d.short {
				if err := w.Banks[g.short].SetElective(ctx, chain.Bytes32(d.id), o.Elective); err != nil {
					return nil, err
				}
			}
		}
	}
	o.Log("elective limits: every bank grants every other bank %s", operator.Money(new(big.Int).SetUint64(o.Elective)))

	// Attested resources: collateral, pool shares, the required pool, and the
	// RTP prefunds (funded over Fedwire if it is open).
	for _, b := range bankSpecs {
		if err := w.Attest(deploy.KindCollateral, chain.Bytes32(b.id), o.Collateral); err != nil {
			return nil, err
		}
		if err := w.Attest(deploy.KindPool, chain.Bytes32(b.id), o.PoolShare); err != nil {
			return nil, err
		}
	}
	if err := w.Attest(deploy.KindPoolRequired, [32]byte{}, o.PoolRequired); err != nil {
		return nil, err
	}
	if _, ok := calendar.FedwireOpen(o.Start); ok {
		for _, p := range parts {
			amt := o.RTPFund
			if p.ID == listener.CollateralPayer || p.ID == listener.PoolPayer {
				amt = o.JointRTPFund
			}
			if _, err := w.RTP.Fund(p.RTPAcct, amt); err != nil {
				return nil, err
			}
		}
		o.Log("Fedwire: RTP prefunded positions funded (%s per bank)", operator.Money(new(big.Int).SetUint64(o.RTPFund)))
		for _, b := range bankSpecs {
			if err := w.AttestPrefund(b.short); err != nil {
				return nil, err
			}
		}
	}

	w.Recon = &reconcile.Reconciler{D: w.D, Journals: []*rails.Journal{w.CHIPS.Journal(), w.RTP.Journal()}, Listener: w.Listener}
	w.Op = operator.New(operator.Config{Deployment: w.D, Account: w.Operator, Clock: w.Clock, Directory: w.Dir, Payers: payers,
		Reconcile: w.Recon.Run, Log: o.Log})
	if err := w.Step(); err != nil {
		return nil, err
	}
	return w, nil
}

func short(a common.Address) string { return a.Hex()[:10] }

// Close stops the listener and anvil.
func (w *World) Close() {
	if w.Listener != nil {
		w.Listener.Stop()
	}
	if w.cancel != nil {
		w.cancel()
	}
	w.Anvil.Stop()
}

// Log narrates at the scenario's time.
func (w *World) Log(format string, args ...any) { w.Opts.Log(format, args...) }

// Attest updates the joint account statement and has the listener attest it.
func (w *World) Attest(kind uint8, id [32]byte, value uint64) error {
	w.Statement.Set(kind, id, value)
	return w.Listener.AttestFunding(w.Ctx, listener.Funding{Kind: kind, Member: id, Value: new(big.Int).SetUint64(value)}, w.Clock.Now())
}

// AttestPrefund attests a bank's current RTP position as its RTP prefund.
func (w *World) AttestPrefund(short string) error {
	p, _ := w.Dir.Get(ID(short))
	return w.Listener.AttestFunding(w.Ctx, listener.Funding{Kind: deploy.KindRTPPrefund, Member: p.ID,
		Value: new(big.Int).SetUint64(w.RTP.Position(p.RTPAcct))}, w.Clock.Now())
}

// Step runs the operator and the listener at the current time until nothing
// changes: plan, pay-in, attestations, completion, finalize.
func (w *World) Step() error {
	for i := 0; i < 32; i++ {
		progressed, err := w.Op.Tick(w.Ctx)
		if err != nil {
			return err
		}
		n := len(w.Listener.Log())
		if err := w.Listener.Sync(w.Ctx); err != nil {
			return err
		}
		if !progressed && len(w.Listener.Log()) == n {
			return nil
		}
	}
	return fmt.Errorf("world did not settle")
}

// AdvanceTo moves the clock to t, stopping at every window change, end-of-day
// cut and pay-in deadline on the way, and steps at each stop.
func (w *World) AdvanceTo(t time.Time) error {
	for {
		now := w.Clock.Now()
		if !now.Before(t) {
			return nil
		}
		next := t
		cands := []time.Time{calendar.NextWindowChange(now), calendar.NextEndOfDayCut(now)}
		if cur := w.Op.Current(); cur != nil && !cur.Deadline.IsZero() {
			cands = append(cands, cur.Deadline.Add(time.Second))
		}
		for _, c := range cands {
			if c.After(now) && c.Before(next) {
				next = c
			}
		}
		w.Clock.Set(next)
		if err := w.Step(); err != nil {
			return err
		}
	}
}

// At is hh:mm Eastern on the date of day.
func At(day time.Time, hh, mm int) time.Time { return calendar.At(day, hh, mm) }

// Date parses an Eastern date "2006-01-02".
func Date(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02", s, calendar.ET)
	if err != nil {
		panic(err)
	}
	return t
}

// Exposure is the sum of every member's positive net position: zero when
// nothing is owed between banks.
func (w *World) Exposure() (*big.Int, error) {
	total := new(big.Int)
	for _, b := range bankSpecs {
		n, err := w.D.NetPosition(w.Ctx, chain.Bytes32(b.id))
		if err != nil {
			return nil, err
		}
		if n.Sign() > 0 {
			total.Add(total, n)
		}
	}
	return total, nil
}

// Supply is the total deposit-token supply across issuers.
func (w *World) Supply() (*big.Int, error) {
	total := new(big.Int)
	for _, b := range bankSpecs {
		s, err := w.D.TokenSupply(w.Ctx, chain.Bytes32(b.id))
		if err != nil {
			return nil, err
		}
		total.Add(total, s)
	}
	return total, nil
}
