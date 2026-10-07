// Package deploy deploys the home-chain contracts from Foundry artifacts, with
// the same constructor wiring as contracts/script/DeployHome.s.sol: every
// contract-to-contract role is granted in a constructor from a precomputed
// CREATE address, so the deployer never holds a role.
//
// Two admin modes:
//
//   - TestAdmin (the default, used by the end-to-end tests and the demo): the
//     default admin of every contract is a plain test key (Config.Admin). There
//     is no TimelockController; governance calls (admit, setReceiverCap, …) are
//     sent directly by that key. This is a test convenience only: it gives one
//     key immediate control of governance, which the design (§2) forbids in
//     deployment.
//   - Timelock: as DeployHome.s.sol, a TimelockController (minDelay
//     Config.TimelockDelay, Config.Admin as its only proposer and executor) is
//     the default admin of every contract, and governance calls go through
//     schedule + execute. With a zero delay this runs on a development node in
//     two transactions per call.
//
// Production deployments use the Foundry script; this package exists so Go
// tests can stand up a fresh chain without a forge broadcast step.
package deploy

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"interbank-credit-settlement/internal/chain"
)

// ArtifactsEnv names the environment variable holding the Foundry artifacts
// directory (the `out` directory of a forge build).
const ArtifactsEnv = "ICS_ARTIFACTS"

// ArtifactsDir returns $ICS_ARTIFACTS, or <module root>/contracts/out.
func ArtifactsDir() (string, error) {
	if d := os.Getenv(ArtifactsEnv); d != "" {
		return d, nil
	}
	root, err := ModuleRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "contracts", "out"), nil
}

// ModuleRoot walks up from the working directory to the directory holding go.mod.
func ModuleRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("go.mod not found above the working directory")
		}
		dir = parent
	}
}

// Mode selects who is the default admin of the deployed contracts.
type Mode int

const (
	// TestAdmin: the Admin key is every contract's default admin (no timelock).
	TestAdmin Mode = iota
	// Timelock: a TimelockController is every contract's default admin.
	Timelock
)

func (m Mode) String() string {
	if m == Timelock {
		return "timelock"
	}
	return "test-admin"
}

// Member tiers (IMemberRegistry.Tier).
const (
	TierCredit      uint8 = 1
	TierPrefundOnly uint8 = 2
)

// Bank is a member to admit, with the deposit token it issues.
type Bank struct {
	ID          string // bytes32 member id, e.g. "BNKAUS30"
	TokenName   string // "Bank A deposit token"
	Symbol      string // "A-dT"
	Wallet      common.Address
	IssuerOps   common.Address
	IssuerAdmin common.Address // the token's ISSUER_ADMIN_ROLE; zero: the governance admin
	Tier        uint8          // TierCredit or TierPrefundOnly
}

// Config is the deployment's parameters.
type Config struct {
	Mode          Mode
	Deployer      chain.Account // sends the creations; holds no role afterwards
	Admin         chain.Account // TestAdmin: the default admin; Timelock: the timelock's proposer and executor
	Guardian      common.Address
	Operator      common.Address
	Signers       []common.Address // the listener's signer set (n)
	Threshold     int              // k
	AdminDelay    uint64           // AccessControlDefaultAdminRules delay, seconds
	TimelockDelay uint64           // Timelock mode: the timelock's minDelay (0 on a test chain)
	Banks         []Bank
}

// Deployment is the deployed home chain.
type Deployment struct {
	Client *chain.Client
	Mode   Mode
	Admin  chain.Account
	Config Config

	Timelock       *chain.Contract // nil in TestAdmin mode
	Registry       *chain.Contract
	Register       *chain.Contract
	Limits         *chain.Contract
	Ledger         *chain.Contract
	Attestor       *chain.Contract
	Batches        *chain.Contract
	DefaultManager *chain.Contract
	Tokens         map[[32]byte]*chain.Contract // by issuer member id

	salt uint64
}

// Deploy deploys the home contracts, admits the configured banks and verifies
// the role wiring.
func Deploy(ctx context.Context, c *chain.Client, cfg Config) (*Deployment, error) {
	if len(cfg.Signers) == 0 || cfg.Threshold <= 0 || cfg.Threshold > len(cfg.Signers) {
		return nil, fmt.Errorf("deploy: threshold %d over %d signers", cfg.Threshold, len(cfg.Signers))
	}
	if cfg.Guardian == (common.Address{}) || cfg.Operator == (common.Address{}) {
		return nil, errors.New("deploy: guardian and operator are required")
	}
	d := &Deployment{Client: c, Mode: cfg.Mode, Admin: cfg.Admin, Config: cfg, Tokens: map[[32]byte]*chain.Contract{}}
	delay := new(big.Int).SetUint64(cfg.AdminDelay)
	admin := cfg.Admin.Addr
	if cfg.Mode == Timelock {
		gov := []common.Address{cfg.Admin.Addr}
		tl, err := Create(ctx, c, cfg.Deployer, "TimelockController", new(big.Int).SetUint64(cfg.TimelockDelay), gov, gov, common.Address{})
		if err != nil {
			return nil, err
		}
		d.Timelock = tl
		admin = tl.Addr
	}

	n, err := c.Eth.PendingNonceAt(ctx, cfg.Deployer.Addr)
	if err != nil {
		return nil, err
	}
	at := func(k uint64) common.Address { return crypto.CreateAddress(cfg.Deployer.Addr, n+k) }
	pRegistry, pRegister, pLimits, pLedger, pAttestor, pBatches, pDM := at(0), at(1), at(2), at(3), at(4), at(5), at(6)

	type step struct {
		dst  **chain.Contract
		name string
		want common.Address
		args []any
	}
	k := big.NewInt(int64(cfg.Threshold))
	steps := []step{
		{&d.Registry, "MemberRegistry", pRegistry, []any{delay, admin, cfg.Guardian, pDM}},
		{&d.Register, "CollateralRegister", pRegister, []any{delay, admin, pAttestor, pLedger, pDM, pLimits}},
		{&d.Limits, "CreditLimits", pLimits, []any{delay, admin, pRegistry, pRegister, cfg.Guardian, cfg.Operator}},
		{&d.Ledger, "ExposureLedger", pLedger, []any{delay, admin, pRegistry, pLimits, pRegister, pBatches, cfg.Operator}},
		{&d.Attestor, "SettlementAttestor", pAttestor, []any{delay, admin, pBatches, pRegister, cfg.Guardian, cfg.Signers, k}},
		{&d.Batches, "SettlementBatches", pBatches, []any{delay, admin, pRegistry, pLedger, pRegister, pAttestor, pDM, cfg.Operator}},
		{&d.DefaultManager, "DefaultManager", pDM, []any{delay, admin, pRegistry, pRegister, pLimits, pBatches}},
	}
	for _, s := range steps {
		ct, err := Create(ctx, c, cfg.Deployer, s.name, s.args...)
		if err != nil {
			return nil, err
		}
		if ct.Addr != s.want {
			return nil, fmt.Errorf("deploy %s at %s, predicted %s (the deployer sent another transaction)", s.name, ct.Addr, s.want)
		}
		*s.dst = ct
	}
	for _, b := range cfg.Banks {
		ia := b.IssuerAdmin
		if ia == (common.Address{}) {
			ia = cfg.Admin.Addr
		}
		tok, err := Create(ctx, c, cfg.Deployer, "ObligationToken", delay, admin, b.TokenName, b.Symbol,
			chain.Bytes32(b.ID), pLedger, pBatches, ia, cfg.Guardian)
		if err != nil {
			return nil, err
		}
		d.Tokens[chain.Bytes32(b.ID)] = tok
	}
	if err := d.Verify(ctx); err != nil {
		return nil, err
	}
	for _, b := range cfg.Banks {
		tier := b.Tier
		if tier == 0 {
			tier = TierCredit
		}
		if err := d.AdminCall(ctx, d.Registry, "admit", chain.Bytes32(b.ID), b.Wallet, b.IssuerOps,
			d.Tokens[chain.Bytes32(b.ID)].Addr, tier); err != nil {
			return nil, err
		}
	}
	return d, nil
}

// AdminCall performs a governance call: directly from the admin key in
// TestAdmin mode, through schedule + execute on the timelock otherwise.
func (d *Deployment) AdminCall(ctx context.Context, target *chain.Contract, method string, args ...any) error {
	if d.Mode != Timelock {
		_, err := d.Send(ctx, target, d.Admin, method, args...)
		return err
	}
	data, err := target.ABI.Pack(method, args...)
	if err != nil {
		return fmt.Errorf("%s.%s: %w", target.Name, method, err)
	}
	d.salt++
	var salt [32]byte
	new(big.Int).SetUint64(d.salt).FillBytes(salt[:])
	zero := [32]byte{}
	minDelay := new(big.Int).SetUint64(d.Config.TimelockDelay)
	if _, err := d.Send(ctx, d.Timelock, d.Admin, "schedule", target.Addr, big.NewInt(0), data, zero, salt, minDelay); err != nil {
		return fmt.Errorf("schedule %s.%s: %w", target.Name, method, err)
	}
	if d.Config.TimelockDelay > 0 {
		return fmt.Errorf("schedule %s.%s: timelock delay %ds — execute it later", target.Name, method, d.Config.TimelockDelay)
	}
	if _, err := d.Send(ctx, d.Timelock, d.Admin, "execute", target.Addr, big.NewInt(0), data, zero, salt); err != nil {
		return fmt.Errorf("execute %s.%s: %w", target.Name, method, err)
	}
	return nil
}

func role(name string) [32]byte {
	if name == "DEFAULT_ADMIN_ROLE" {
		return [32]byte{}
	}
	return crypto.Keccak256Hash([]byte(name))
}

// Verify checks what DeployHome.verifyRoles checks: the governance admin is
// every contract's default admin, the deployer holds no role anywhere, and
// each contract-to-contract role is held by the right contract.
func (d *Deployment) Verify(ctx context.Context) error {
	cfg := d.Config
	admin := cfg.Admin.Addr
	if d.Timelock != nil {
		admin = d.Timelock.Addr
		for _, r := range []string{"DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"} {
			if ok, err := d.Timelock.Bool(ctx, "hasRole", role(r), cfg.Deployer.Addr); err != nil || ok {
				return fmt.Errorf("timelock: deployer holds %s (%v)", r, err)
			}
		}
		for _, r := range []string{"PROPOSER_ROLE", "EXECUTOR_ROLE"} {
			if ok, err := d.Timelock.Bool(ctx, "hasRole", role(r), cfg.Admin.Addr); err != nil || !ok {
				return fmt.Errorf("timelock: governance lacks %s (%v)", r, err)
			}
		}
	}
	all := []*chain.Contract{d.Registry, d.Register, d.Limits, d.Ledger, d.Attestor, d.Batches, d.DefaultManager}
	for _, t := range d.Tokens {
		all = append(all, t)
	}
	roles := []string{"DEFAULT_ADMIN_ROLE", "GUARDIAN_ROLE", "OPERATOR_ROLE", "LEDGER_ROLE", "BATCHES_ROLE", "ATTESTOR_ROLE",
		"MESSENGER_ROLE", "MOVER_ROLE", "DEFAULT_MANAGER_ROLE", "ISSUER_ADMIN_ROLE"}
	for _, ct := range all {
		for _, r := range roles {
			ok, err := ct.Bool(ctx, "hasRole", role(r), cfg.Deployer.Addr)
			if err != nil {
				return err
			}
			if ok {
				return fmt.Errorf("%s: deployer holds %s", ct.Name, r)
			}
		}
		out, err := ct.Call(ctx, "defaultAdmin")
		if err != nil {
			return err
		}
		if got := out[0].(common.Address); got != admin {
			return fmt.Errorf("%s: default admin %s, want %s", ct.Name, got, admin)
		}
	}
	type has struct {
		ct   *chain.Contract
		who  common.Address
		role string
	}
	checks := []has{
		{d.Registry, d.DefaultManager.Addr, "DEFAULT_MANAGER_ROLE"},
		{d.Registry, cfg.Guardian, "GUARDIAN_ROLE"},
		{d.Register, d.Attestor.Addr, "ATTESTOR_ROLE"},
		{d.Register, d.Ledger.Addr, "LEDGER_ROLE"},
		{d.Register, d.DefaultManager.Addr, "DEFAULT_MANAGER_ROLE"},
		{d.Limits, cfg.Guardian, "GUARDIAN_ROLE"},
		{d.Limits, cfg.Operator, "OPERATOR_ROLE"},
		{d.Ledger, d.Batches.Addr, "BATCHES_ROLE"},
		{d.Ledger, cfg.Operator, "OPERATOR_ROLE"},
		{d.Attestor, cfg.Guardian, "GUARDIAN_ROLE"},
		{d.Batches, d.Attestor.Addr, "ATTESTOR_ROLE"},
		{d.Batches, d.DefaultManager.Addr, "DEFAULT_MANAGER_ROLE"},
		{d.Batches, cfg.Operator, "OPERATOR_ROLE"},
	}
	for _, b := range cfg.Banks {
		t := d.Tokens[chain.Bytes32(b.ID)]
		ia := b.IssuerAdmin
		if ia == (common.Address{}) {
			ia = cfg.Admin.Addr
		}
		checks = append(checks, has{t, d.Ledger.Addr, "LEDGER_ROLE"}, has{t, d.Batches.Addr, "BATCHES_ROLE"},
			has{t, cfg.Guardian, "GUARDIAN_ROLE"}, has{t, ia, "ISSUER_ADMIN_ROLE"})
	}
	for _, h := range checks {
		ok, err := h.ct.Bool(ctx, "hasRole", role(h.role), h.who)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("%s: %s lacks %s", h.ct.Name, h.who, h.role)
		}
	}
	links := []struct {
		ct     *chain.Contract
		method string
		want   common.Address
	}{
		{d.Batches, "ledger", d.Ledger.Addr},
		{d.Ledger, "registry", d.Registry.Addr},
		{d.Attestor, "batches", d.Batches.Addr},
		{d.DefaultManager, "batches", d.Batches.Addr},
	}
	for _, l := range links {
		out, err := l.ct.Call(ctx, l.method)
		if err != nil {
			return err
		}
		if out[0].(common.Address) != l.want {
			return fmt.Errorf("%s.%s is %s, want %s", l.ct.Name, l.method, out[0], l.want)
		}
	}
	th, err := d.Attestor.BigInt(ctx, "threshold")
	if err != nil {
		return err
	}
	if th.Int64() != int64(cfg.Threshold) {
		return fmt.Errorf("attestor threshold %s, want %d", th, cfg.Threshold)
	}
	return nil
}

// Token returns the deposit token issued by member id.
func (d *Deployment) Token(id [32]byte) *chain.Contract { return d.Tokens[id] }
