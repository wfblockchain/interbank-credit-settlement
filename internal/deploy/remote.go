package deploy

// Cross-chain deployment (design §4), with the same wiring as
// contracts/script/DeployRemote.s.sol: the HubMessenger on the home chain, and
// on each spoke a SpokeMessenger, its SpokeExposureGuard and one
// RemoteObligationToken per bank. Every contract-to-contract role is granted in
// a constructor (the guard's address is precomputed for the messenger), so the
// deployer never holds a role. What the script returns as timelock batches
// (hubWiring, spokeWiring) is sent here as governance calls: directly from the
// admin key in TestAdmin mode, through schedule + execute in Timelock mode.

import (
	"context"
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/chain"
)

// Domain kinds (IExposureLedger.DomainKind).
const (
	DomainNone         uint8 = 0
	DomainPermissioned uint8 = 1
	DomainPublic       uint8 = 2
)

// HubConfig is the hub messenger's parameters. The home deployment supplies
// the admin, guardian, operator and mode.
type HubConfig struct {
	Domain     uint32           // the home domain (1)
	Attesters  []common.Address // the operator's attesters (n)
	Threshold  uint8            // a strict majority of them
	IssuerKeys map[[32]byte]common.Address
}

// Hub is the deployed hub messenger.
type Hub struct {
	D         *Deployment
	Config    HubConfig
	Messenger *chain.Contract
	Spokes    map[uint32]*Spoke
}

// DeployHub deploys the HubMessenger on the home chain and wires it as
// DeployRemote.hubWiring does: the ledger's MESSENGER_ROLE, the batches hook,
// MOVER_ROLE and MESSENGER_ROLE on every home token, and the issuer keys.
// Spokes are added with Connect.
func (d *Deployment) DeployHub(ctx context.Context, cfg HubConfig) (*Hub, error) {
	if cfg.Domain == 0 {
		cfg.Domain = 1
	}
	if len(cfg.Attesters) == 0 || cfg.Threshold == 0 || int(cfg.Threshold)*2 <= len(cfg.Attesters) {
		return nil, fmt.Errorf("deploy hub: threshold %d is not a strict majority of %d attesters", cfg.Threshold, len(cfg.Attesters))
	}
	admin := d.Admin.Addr
	if d.Timelock != nil {
		admin = d.Timelock.Addr
	}
	delay := new(big.Int).SetUint64(d.Config.AdminDelay)
	m, err := Create(ctx, d.Client, d.Config.Deployer, "HubMessenger", delay, admin, cfg.Domain, d.Ledger.Addr, d.Batches.Addr,
		d.Registry.Addr, d.Config.Guardian, d.Config.Operator, cfg.Attesters, cfg.Threshold)
	if err != nil {
		return nil, err
	}
	h := &Hub{D: d, Config: cfg, Messenger: m, Spokes: map[uint32]*Spoke{}}
	if err := d.AdminCall(ctx, d.Ledger, "grantRole", role("MESSENGER_ROLE"), m.Addr); err != nil {
		return nil, err
	}
	if err := d.AdminCall(ctx, d.Batches, "setCrossChain", m.Addr); err != nil {
		return nil, err
	}
	for _, b := range d.Config.Banks {
		id := chain.Bytes32(b.ID)
		t := d.Tokens[id]
		for _, r := range []string{"MOVER_ROLE", "MESSENGER_ROLE"} {
			if err := d.AdminCall(ctx, t, "grantRole", role(r), m.Addr); err != nil {
				return nil, err
			}
		}
		key, ok := cfg.IssuerKeys[id]
		if !ok {
			return nil, fmt.Errorf("deploy hub: no issuer key for %s", b.ID)
		}
		if err := d.AdminCall(ctx, m, "setIssuerKey", id, key); err != nil {
			return nil, err
		}
	}
	if err := h.Verify(ctx); err != nil {
		return nil, err
	}
	return h, nil
}

// Verify checks what DeployRemote.verifyHub checks, plus the wiring.
func (h *Hub) Verify(ctx context.Context) error {
	d := h.D
	admin := d.Admin.Addr
	if d.Timelock != nil {
		admin = d.Timelock.Addr
	}
	if err := noDeployerRoles(ctx, h.Messenger, d.Config.Deployer.Addr); err != nil {
		return err
	}
	if err := wantAddr(ctx, h.Messenger, "defaultAdmin", admin); err != nil {
		return err
	}
	for _, l := range []struct {
		method string
		want   common.Address
	}{{"ledger", d.Ledger.Addr}, {"batches", d.Batches.Addr}, {"registry", d.Registry.Addr}} {
		if err := wantAddr(ctx, h.Messenger, l.method, l.want); err != nil {
			return err
		}
	}
	if err := wantAddr(ctx, d.Batches, "crossChain", h.Messenger.Addr); err != nil {
		return err
	}
	checks := []hasRole{
		{h.Messenger, d.Config.Guardian, "GUARDIAN_ROLE"},
		{h.Messenger, d.Config.Operator, "OPERATOR_ROLE"},
		{d.Ledger, h.Messenger.Addr, "MESSENGER_ROLE"},
	}
	for _, t := range d.Tokens {
		checks = append(checks, hasRole{t, h.Messenger.Addr, "MOVER_ROLE"}, hasRole{t, h.Messenger.Addr, "MESSENGER_ROLE"})
	}
	if err := checkRoles(ctx, checks); err != nil {
		return err
	}
	out, err := h.Messenger.Call(ctx, "threshold")
	if err != nil {
		return err
	}
	if out[0].(uint8) != h.Config.Threshold {
		return fmt.Errorf("hub threshold %d, want %d", out[0], h.Config.Threshold)
	}
	for id, key := range h.Config.IssuerKeys {
		if err := wantAddr(ctx, h.Messenger, "issuerKey", key, id); err != nil {
			return err
		}
	}
	return nil
}

// SpokeBank is a member on a spoke: its wallet and issuerOps there, its key
// for MINT messages, its token's supply cap there and the inbound rate limit
// from home.
type SpokeBank struct {
	ID           string
	TokenName    string
	Symbol       string
	Wallet       common.Address
	IssuerOps    common.Address
	IssuerAdmin  common.Address // the spoke token's ISSUER_ADMIN_ROLE; zero: the governance admin
	IssuerKey    common.Address
	SupplyCap    *big.Int
	RateCapacity *big.Int // per window (one hour)
}

// SpokeConfig is a spoke's parameters (DeployRemote.Config).
type SpokeConfig struct {
	Mode          Mode
	Domain        uint32
	HomeDomain    uint32 // default 1
	Kind          uint8  // DomainPermissioned or DomainPublic
	Deployer      chain.Account
	Admin         chain.Account // TestAdmin: the default admin; Timelock: the timelock's proposer and executor
	Guardian      common.Address
	Operator      common.Address
	Attesters     []common.Address
	Threshold     uint8
	AdminDelay    uint64
	TimelockDelay uint64
	Banks         []SpokeBank
}

// Spoke is a deployed spoke chain.
type Spoke struct {
	Client    *chain.Client
	Config    SpokeConfig
	Timelock  *chain.Contract // nil in TestAdmin mode
	Messenger *chain.Contract
	Guard     *chain.Contract
	Tokens    map[[32]byte]*chain.Contract // by issuer member id
	Wallets   map[[32]byte]common.Address

	gov governor
}

// Domain is the spoke's domain id.
func (s *Spoke) Domain() uint32 { return s.Config.Domain }

// Token returns the spoke token issued by member id.
func (s *Spoke) Token(id [32]byte) *chain.Contract { return s.Tokens[id] }

// AdminCall is a governance call on the spoke (see Deployment.AdminCall).
func (s *Spoke) AdminCall(ctx context.Context, target *chain.Contract, method string, args ...any) error {
	return s.gov.call(ctx, target, method, args...)
}

// DeploySpoke deploys a spoke as DeployRemote.deploySpoke does and wires its
// members as spokeWiring does. The hub is wired in with Hub.Connect.
func DeploySpoke(ctx context.Context, c *chain.Client, cfg SpokeConfig) (*Spoke, error) {
	if cfg.HomeDomain == 0 {
		cfg.HomeDomain = 1
	}
	if cfg.Domain == cfg.HomeDomain {
		return nil, fmt.Errorf("deploy spoke: domain %d is the home domain", cfg.Domain)
	}
	if cfg.Kind != DomainPermissioned && cfg.Kind != DomainPublic {
		return nil, fmt.Errorf("deploy spoke: kind %d", cfg.Kind)
	}
	if cfg.Guardian == (common.Address{}) || cfg.Operator == (common.Address{}) {
		return nil, errors.New("deploy spoke: guardian and operator are required")
	}
	s := &Spoke{Client: c, Config: cfg, Tokens: map[[32]byte]*chain.Contract{}, Wallets: map[[32]byte]common.Address{}}
	s.gov = governor{c: c, mode: cfg.Mode, admin: cfg.Admin, delay: cfg.TimelockDelay}
	admin := cfg.Admin.Addr
	if cfg.Mode == Timelock {
		g := []common.Address{cfg.Admin.Addr}
		tl, err := Create(ctx, c, cfg.Deployer, "TimelockController", new(big.Int).SetUint64(cfg.TimelockDelay), g, g, common.Address{})
		if err != nil {
			return nil, err
		}
		s.Timelock, s.gov.timelock, admin = tl, tl, tl.Addr
	}
	n, err := c.Eth.PendingNonceAt(ctx, cfg.Deployer.Addr)
	if err != nil {
		return nil, err
	}
	pGuard := crypto.CreateAddress(cfg.Deployer.Addr, n+1)
	delay := new(big.Int).SetUint64(cfg.AdminDelay)
	if s.Messenger, err = Create(ctx, c, cfg.Deployer, "SpokeMessenger", delay, admin, cfg.Domain, cfg.HomeDomain, pGuard,
		cfg.Guardian, cfg.Operator, cfg.Attesters, cfg.Threshold); err != nil {
		return nil, err
	}
	if s.Guard, err = Create(ctx, c, cfg.Deployer, "SpokeExposureGuard", delay, admin, cfg.Domain, cfg.Kind, s.Messenger.Addr,
		cfg.Guardian, cfg.Operator); err != nil {
		return nil, err
	}
	if s.Guard.Addr != pGuard {
		return nil, fmt.Errorf("deploy spoke %d: guard at %s, predicted %s", cfg.Domain, s.Guard.Addr, pGuard)
	}
	for _, b := range cfg.Banks {
		ia := b.IssuerAdmin
		if ia == (common.Address{}) {
			ia = cfg.Admin.Addr
		}
		t, err := Create(ctx, c, cfg.Deployer, "RemoteObligationToken", delay, admin, b.TokenName, b.Symbol, chain.Bytes32(b.ID),
			s.Guard.Addr, ia, cfg.Guardian)
		if err != nil {
			return nil, err
		}
		s.Tokens[chain.Bytes32(b.ID)] = t
	}
	if err := s.Verify(ctx); err != nil {
		return nil, err
	}
	for _, b := range cfg.Banks {
		id := chain.Bytes32(b.ID)
		s.Wallets[id] = b.Wallet
		calls := []struct {
			target *chain.Contract
			method string
			args   []any
		}{
			{s.Guard, "setMember", []any{id, b.Wallet, b.IssuerOps, s.Tokens[id].Addr}},
			{s.Guard, "setSupplyCap", []any{id, b.SupplyCap}},
			{s.Messenger, "setIssuerKey", []any{id, b.IssuerKey}},
			{s.Messenger, "setRateLimit", []any{cfg.HomeDomain, id, b.RateCapacity, uint64(0)}},
		}
		for _, k := range calls {
			if err := s.AdminCall(ctx, k.target, k.method, k.args...); err != nil {
				return nil, err
			}
		}
	}
	return s, nil
}

// Verify checks what DeployRemote.verifySpoke checks.
func (s *Spoke) Verify(ctx context.Context) error {
	cfg := s.Config
	admin := cfg.Admin.Addr
	if s.Timelock != nil {
		admin = s.Timelock.Addr
		for _, r := range []string{"DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"} {
			if ok, err := s.Timelock.Bool(ctx, "hasRole", role(r), cfg.Deployer.Addr); err != nil || ok {
				return fmt.Errorf("spoke %d timelock: deployer holds %s (%v)", cfg.Domain, r, err)
			}
		}
		if ok, err := s.Timelock.Bool(ctx, "hasRole", role("PROPOSER_ROLE"), cfg.Admin.Addr); err != nil || !ok {
			return fmt.Errorf("spoke %d timelock: governance is not proposer (%v)", cfg.Domain, err)
		}
	}
	all := []*chain.Contract{s.Messenger, s.Guard}
	for _, t := range s.Tokens {
		all = append(all, t)
	}
	for _, ct := range all {
		if err := noDeployerRoles(ctx, ct, cfg.Deployer.Addr); err != nil {
			return err
		}
		if err := wantAddr(ctx, ct, "defaultAdmin", admin); err != nil {
			return err
		}
	}
	if err := wantAddr(ctx, s.Messenger, "guard", s.Guard.Addr); err != nil {
		return err
	}
	for _, v := range []struct {
		ct     *chain.Contract
		method string
		want   uint64
	}{
		{s.Messenger, "LOCAL_DOMAIN", uint64(cfg.Domain)},
		{s.Messenger, "HOME_DOMAIN", uint64(cfg.HomeDomain)},
		{s.Messenger, "threshold", uint64(cfg.Threshold)},
		{s.Guard, "DOMAIN", uint64(cfg.Domain)},
		{s.Guard, "KIND", uint64(cfg.Kind)},
	} {
		out, err := v.ct.Call(ctx, v.method)
		if err != nil {
			return err
		}
		var got uint64
		switch x := out[0].(type) {
		case uint8:
			got = uint64(x)
		case uint32:
			got = uint64(x)
		default:
			return fmt.Errorf("%s.%s: unexpected %T", v.ct.Name, v.method, out[0])
		}
		if got != v.want {
			return fmt.Errorf("spoke %d: %s.%s is %d, want %d", cfg.Domain, v.ct.Name, v.method, got, v.want)
		}
	}
	checks := []hasRole{
		{s.Guard, s.Messenger.Addr, "MESSENGER_ROLE"},
		{s.Guard, cfg.Guardian, "GUARDIAN_ROLE"},
		{s.Guard, cfg.Operator, "OPERATOR_ROLE"},
		{s.Messenger, cfg.Guardian, "GUARDIAN_ROLE"},
		{s.Messenger, cfg.Operator, "OPERATOR_ROLE"},
	}
	for _, b := range cfg.Banks {
		t := s.Tokens[chain.Bytes32(b.ID)]
		ia := b.IssuerAdmin
		if ia == (common.Address{}) {
			ia = cfg.Admin.Addr
		}
		out, err := t.Call(ctx, "issuer")
		if err != nil {
			return err
		}
		if out[0].([32]byte) != chain.Bytes32(b.ID) {
			return fmt.Errorf("spoke %d: %s issuer mismatch", cfg.Domain, b.Symbol)
		}
		checks = append(checks, hasRole{t, s.Guard.Addr, "LEDGER_ROLE"}, hasRole{t, s.Guard.Addr, "MESSENGER_ROLE"},
			hasRole{t, cfg.Guardian, "GUARDIAN_ROLE"}, hasRole{t, ia, "ISSUER_ADMIN_ROLE"})
	}
	return checkRoles(ctx, checks)
}

// Connect wires a spoke to the hub, on both chains: the home ledger's domain
// kind, the hub's remote and its inbound rate limits from the spoke (per
// bank, capacity per hour), and the spoke's remote (the hub).
func (h *Hub) Connect(ctx context.Context, s *Spoke, rateCapacity map[[32]byte]*big.Int) error {
	d := h.D
	dom := s.Config.Domain
	if err := d.AdminCall(ctx, d.Ledger, "setDomainKind", dom, s.Config.Kind); err != nil {
		return err
	}
	if err := d.AdminCall(ctx, h.Messenger, "setRemote", dom, s.Messenger.Addr); err != nil {
		return err
	}
	for _, b := range d.Config.Banks {
		id := chain.Bytes32(b.ID)
		capacity, ok := rateCapacity[id]
		if !ok {
			return fmt.Errorf("connect spoke %d: no rate capacity for %s", dom, b.ID)
		}
		if err := d.AdminCall(ctx, h.Messenger, "setRateLimit", dom, id, capacity, uint64(0)); err != nil {
			return err
		}
	}
	if err := s.AdminCall(ctx, s.Messenger, "setRemote", h.Config.Domain, h.Messenger.Addr); err != nil {
		return err
	}
	if err := wantAddr(ctx, h.Messenger, "remote", s.Messenger.Addr, dom); err != nil {
		return err
	}
	if err := wantAddr(ctx, s.Messenger, "remote", h.Messenger.Addr, h.Config.Domain); err != nil {
		return err
	}
	h.Spokes[dom] = s
	return nil
}

// ---------------------------------------------------------------- helpers

// governor sends governance calls on a chain without a home Deployment.
type governor struct {
	c        *chain.Client
	mode     Mode
	admin    chain.Account
	timelock *chain.Contract
	delay    uint64
	salt     uint64
}

func (g *governor) call(ctx context.Context, target *chain.Contract, method string, args ...any) error {
	if g.mode != Timelock {
		_, err := Send(ctx, g.c, target, g.admin, method, args...)
		return err
	}
	data, err := target.ABI.Pack(method, args...)
	if err != nil {
		return fmt.Errorf("%s.%s: %w", target.Name, method, err)
	}
	g.salt++
	var salt [32]byte
	new(big.Int).SetUint64(g.salt).FillBytes(salt[:])
	zero := [32]byte{}
	if _, err := Send(ctx, g.c, g.timelock, g.admin, "schedule", target.Addr, big.NewInt(0), data, zero, salt,
		new(big.Int).SetUint64(g.delay)); err != nil {
		return fmt.Errorf("schedule %s.%s: %w", target.Name, method, err)
	}
	if g.delay > 0 {
		return fmt.Errorf("schedule %s.%s: timelock delay %ds — execute it later", target.Name, method, g.delay)
	}
	if _, err := Send(ctx, g.c, g.timelock, g.admin, "execute", target.Addr, big.NewInt(0), data, zero, salt); err != nil {
		return fmt.Errorf("execute %s.%s: %w", target.Name, method, err)
	}
	return nil
}

type hasRole struct {
	ct   *chain.Contract
	who  common.Address
	role string
}

func checkRoles(ctx context.Context, checks []hasRole) error {
	for _, h := range checks {
		ok, err := h.ct.Bool(ctx, "hasRole", role(h.role), h.who)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("%s: %s lacks %s", h.ct.Name, h.who, h.role)
		}
	}
	return nil
}

func noDeployerRoles(ctx context.Context, ct *chain.Contract, deployer common.Address) error {
	for _, r := range []string{"DEFAULT_ADMIN_ROLE", "GUARDIAN_ROLE", "OPERATOR_ROLE", "LEDGER_ROLE", "MESSENGER_ROLE", "ISSUER_ADMIN_ROLE"} {
		ok, err := ct.Bool(ctx, "hasRole", role(r), deployer)
		if err != nil {
			return err
		}
		if ok {
			return fmt.Errorf("%s: deployer holds %s", ct.Name, r)
		}
	}
	return nil
}

func wantAddr(ctx context.Context, ct *chain.Contract, method string, want common.Address, args ...any) error {
	out, err := ct.Call(ctx, method, args...)
	if err != nil {
		return err
	}
	if got := out[0].(common.Address); got != want {
		return fmt.Errorf("%s.%s is %s, want %s", ct.Name, method, got, want)
	}
	return nil
}
