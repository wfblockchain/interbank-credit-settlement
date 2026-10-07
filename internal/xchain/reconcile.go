package xchain

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/common"

	"interbank-credit-settlement/internal/chain"
	"interbank-credit-settlement/internal/deploy"
)

// ErrCrossChainBreak matches every *CrossChainBreak.
var ErrCrossChainBreak = errors.New("cross-chain reconciliation break")

// CrossChainBreak lists every failed cross-chain check.
type CrossChainBreak struct {
	Breaks []string
}

func (e *CrossChainBreak) Error() string {
	return fmt.Sprintf("%d cross-chain break(s): %s", len(e.Breaks), strings.Join(e.Breaks, "; "))
}

// Is makes errors.Is(err, ErrCrossChainBreak) true.
func (e *CrossChainBreak) Is(target error) bool { return target == ErrCrossChainBreak }

// IssuerTotals is one issuer's supply across chains and what accounts for it.
type IssuerTotals struct {
	Issuer      [32]byte
	Supply      map[uint32]*big.Int // per domain
	HomeOpen    *big.Int            // home tokens in the members' wallets (open + home part of pending)
	HomeEscrow  *big.Int            // home tokens locked in the hub for moves to spokes
	SpokeOpen   *big.Int            // Σ spoke used (the spokes' open positions)
	SpokeLocked *big.Int            // Σ spoke lockedTotal (cut, settled-pending-burn)
	SpokeEscrow *big.Int            // Σ spoke tokens locked for moves home
}

// Total is Σ supply over all chains.
func (t IssuerTotals) Total() *big.Int {
	s := new(big.Int)
	for _, v := range t.Supply {
		s.Add(s, v)
	}
	return s
}

// Report is a cross-chain reconciliation.
type Report struct {
	Issuers []IssuerTotals
}

// Reconcile checks design §4.5 invariants 1 and 2 and the global accountant
// across the home chain and every connected spoke, reading each chain:
//
//   - per issuer: Σ supply on all chains = home open + home part of pending +
//     hub escrow of pending moves + Σ spoke (open + locked + escrow of pending
//     moves), with the escrows read from the messengers' move records and every
//     wallet balance matching its share;
//   - per spoke and pair: used ≤ env on the spoke ≤ the hub's envelope;
//   - per issuer and spoke: returned ≤ sent at the hub.
//
// Run it when the transport is quiet (no message in flight that changes a
// balance); it returns a *CrossChainBreak listing every failure.
func Reconcile(ctx context.Context, h *deploy.Hub) (Report, error) {
	d := h.D
	var breaks []string
	fail := func(format string, args ...any) { breaks = append(breaks, fmt.Sprintf(format, args...)) }
	big0 := func() *big.Int { return new(big.Int) }

	ids := make([][32]byte, 0, len(d.Config.Banks))
	for _, b := range d.Config.Banks {
		ids = append(ids, chain.Bytes32(b.ID))
	}
	homeWallet := map[[32]byte]common.Address{}
	for _, id := range ids {
		m, err := d.Member(ctx, id)
		if err != nil {
			return Report{}, err
		}
		homeWallet[id] = m.Wallet
	}
	doms := make([]uint32, 0, len(h.Spokes))
	for dom := range h.Spokes {
		doms = append(doms, dom)
	}
	sort.Slice(doms, func(i, j int) bool { return doms[i] < doms[j] })

	// Remote pairs of the batch in flight that the hub has not cleared yet.
	remotePending := map[[2][32]byte]*big.Int{}
	pe, err := callU64(ctx, d.Ledger, "pendingEpoch")
	if err != nil {
		return Report{}, err
	}
	if pe != 0 {
		cleared, err := d.Ledger.BigInt(ctx, "clearedPairs", pe)
		if err != nil {
			return Report{}, err
		}
		count, err := d.Ledger.BigInt(ctx, "pendingPairCount", pe)
		if err != nil {
			return Report{}, err
		}
		for k := cleared.Uint64(); k < count.Uint64(); k++ {
			out, err := d.Ledger.Call(ctx, "pendingPair", pe, new(big.Int).SetUint64(k))
			if err != nil {
				return Report{}, err
			}
			pp, err := deploy.Decode[struct {
				Issuer [32]byte
				Holder [32]byte
				Amount *big.Int
				Remote bool
			}](out[0])
			if err != nil {
				return Report{}, err
			}
			if pp.Remote {
				key := [2][32]byte{pp.Issuer, pp.Holder}
				if remotePending[key] == nil {
					remotePending[key] = big0()
				}
				remotePending[key].Add(remotePending[key], pp.Amount)
			}
		}
	}

	// Escrow of pending moves, per messenger, from its move records.
	hubEscrow, err := pendingMoves(ctx, h.Messenger)
	if err != nil {
		return Report{}, err
	}
	spokeEscrow := map[uint32]map[[2][32]byte]*big.Int{}
	for _, dom := range doms {
		if spokeEscrow[dom], err = pendingMoves(ctx, h.Spokes[dom].Messenger); err != nil {
			return Report{}, err
		}
	}
	get := func(m map[[2][32]byte]*big.Int, i, hd [32]byte) *big.Int {
		if v := m[[2][32]byte{i, hd}]; v != nil {
			return v
		}
		return big0()
	}

	var rep Report
	for _, i := range ids {
		t := IssuerTotals{Issuer: i, Supply: map[uint32]*big.Int{}, HomeOpen: big0(), HomeEscrow: big0(), SpokeOpen: big0(),
			SpokeLocked: big0(), SpokeEscrow: big0()}
		tok := d.Tokens[i]
		s, err := tok.BigInt(ctx, "totalSupply")
		if err != nil {
			return rep, err
		}
		t.Supply[h.Config.Domain] = s
		walletSum := big0()
		for _, hd := range ids {
			open, err := d.Ledger.BigInt(ctx, "open", i, hd)
			if err != nil {
				return rep, err
			}
			pend, err := d.Ledger.BigInt(ctx, "pending", i, hd)
			if err != nil {
				return rep, err
			}
			homePart := new(big.Int).Add(open, pend)
			homePart.Sub(homePart, get(remotePending, i, hd))
			bal, err := tok.BigInt(ctx, "balanceOf", homeWallet[hd])
			if err != nil {
				return rep, err
			}
			if bal.Cmp(homePart) != 0 {
				fail("home %s balance of %s is %s, ledger open+pending (home part) %s", idString(i), idString(hd), bal, homePart)
			}
			walletSum.Add(walletSum, bal)
			t.HomeOpen.Add(t.HomeOpen, homePart)
			t.HomeEscrow.Add(t.HomeEscrow, get(hubEscrow, i, hd))
		}
		hubBal, err := tok.BigInt(ctx, "balanceOf", h.Messenger.Addr)
		if err != nil {
			return rep, err
		}
		if hubBal.Cmp(t.HomeEscrow) != 0 {
			fail("hub holds %s of %s, pending moves to spokes %s", hubBal, idString(i), t.HomeEscrow)
		}
		if new(big.Int).Add(walletSum, hubBal).Cmp(s) != 0 {
			fail("home %s supply %s held outside the member wallets and the hub", idString(i), s)
		}
		for _, dom := range doms {
			sp := h.Spokes[dom]
			rt := sp.Token(i)
			ss, err := rt.BigInt(ctx, "totalSupply")
			if err != nil {
				return rep, err
			}
			t.Supply[dom] = ss
			sum := big0()
			for _, hd := range ids {
				used, err := sp.Guard.BigInt(ctx, "used", i, hd)
				if err != nil {
					return rep, err
				}
				env, err := sp.Guard.BigInt(ctx, "env", i, hd)
				if err != nil {
					return rep, err
				}
				lt, err := sp.Guard.BigInt(ctx, "lockedTotal", i, hd)
				if err != nil {
					return rep, err
				}
				hubEnv, err := d.Ledger.BigInt(ctx, "envelope", dom, i, hd)
				if err != nil {
					return rep, err
				}
				if used.Cmp(env) > 0 || env.Cmp(hubEnv) > 0 {
					fail("domain %d %s→%s: used %s, env %s, hub envelope %s (want used ≤ env ≤ hub)", dom, idString(i), idString(hd),
						used, env, hubEnv)
				}
				esc := get(spokeEscrow[dom], i, hd)
				w := sp.Wallets[hd]
				bal, err := rt.BigInt(ctx, "balanceOf", w)
				if err != nil {
					return rep, err
				}
				lockedOf, err := rt.BigInt(ctx, "lockedOf", w)
				if err != nil {
					return rep, err
				}
				want := new(big.Int).Add(used, lt)
				want.Add(want, esc)
				if bal.Cmp(want) != 0 {
					fail("domain %d %s held by %s: balance %s, open %s + locked %s + move escrow %s", dom, idString(i), idString(hd),
						bal, used, lt, esc)
				}
				if lockedOf.Cmp(new(big.Int).Add(lt, esc)) != 0 {
					fail("domain %d %s held by %s: token lock %s, guard locked %s + move escrow %s", dom, idString(i), idString(hd),
						lockedOf, lt, esc)
				}
				sum.Add(sum, bal)
				t.SpokeOpen.Add(t.SpokeOpen, used)
				t.SpokeLocked.Add(t.SpokeLocked, lt)
				t.SpokeEscrow.Add(t.SpokeEscrow, esc)
			}
			if sum.Cmp(ss) != 0 {
				fail("domain %d %s supply %s, member balances %s", dom, idString(i), ss, sum)
			}
			sent, err := h.Messenger.BigInt(ctx, "sent", i, dom)
			if err != nil {
				return rep, err
			}
			ret, err := h.Messenger.BigInt(ctx, "returned", i, dom)
			if err != nil {
				return rep, err
			}
			if ret.Cmp(sent) > 0 {
				fail("accountant: %s returned from domain %d %s > sent %s", idString(i), dom, ret, sent)
			}
		}
		rhs := new(big.Int).Add(t.HomeOpen, t.HomeEscrow)
		rhs.Add(rhs, t.SpokeOpen)
		rhs.Add(rhs, t.SpokeLocked)
		rhs.Add(rhs, t.SpokeEscrow)
		if t.Total().Cmp(rhs) != 0 {
			fail("%s: Σ supply %s ≠ open+pending+escrows+spoke open+locked %s", idString(i), t.Total(), rhs)
		}
		rep.Issuers = append(rep.Issuers, t)
	}
	if len(breaks) > 0 {
		return rep, &CrossChainBreak{Breaks: breaks}
	}
	return rep, nil
}

// pendingMoves sums, per (issuer, holder), the moves a messenger holds
// PENDING (locked at their source), from its move records.
func pendingMoves(ctx context.Context, m *chain.Contract) (map[[2][32]byte]*big.Int, error) {
	next, err := callU64(ctx, m, "nextNonce")
	if err != nil {
		return nil, err
	}
	out := map[[2][32]byte]*big.Int{}
	for n := uint64(1); n < next; n++ {
		res, err := m.Call(ctx, "move", n)
		if err != nil {
			return nil, err
		}
		mv, err := deploy.Decode[Move](res[0])
		if err != nil {
			return nil, err
		}
		if mv.Status != MovePending {
			continue
		}
		k := [2][32]byte{mv.Issuer, mv.Holder}
		if out[k] == nil {
			out[k] = new(big.Int)
		}
		out[k].Add(out[k], mv.Amount)
	}
	return out, nil
}

func callU64(ctx context.Context, c *chain.Contract, method string, args ...any) (uint64, error) {
	out, err := c.Call(ctx, method, args...)
	if err != nil {
		return 0, err
	}
	switch v := out[0].(type) {
	case uint64:
		return v, nil
	case *big.Int:
		return v.Uint64(), nil
	}
	return 0, fmt.Errorf("%s.%s: unexpected %T", c.Name, method, out[0])
}
