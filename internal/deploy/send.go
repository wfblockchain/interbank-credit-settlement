package deploy

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"interbank-credit-settlement/internal/chain"
)

// go-ethereum's bind.WaitMined polls for the receipt once a second; on a
// development node that mines on submission the receipt is there within
// milliseconds, so this package sends through its own transactor and polls
// fast. Reverts are explained with the chain client's custom-error decoder,
// exactly as chain.Contract.Send does.

func boundFor(c *chain.Client, k *chain.Contract) *bind.BoundContract {
	return bind.NewBoundContract(k.Addr, k.ABI, c.Eth, c.Eth, c.Eth)
}

// WaitReceipt polls for a transaction's receipt every few milliseconds.
func WaitReceipt(ctx context.Context, c *chain.Client, hash common.Hash) (*types.Receipt, error) {
	delay := 2 * time.Millisecond
	for {
		r, err := c.Eth.TransactionReceipt(ctx, hash)
		if err == nil {
			return r, nil
		}
		if !errors.Is(err, ethereum.NotFound) && !strings.Contains(err.Error(), "not found") {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
		if delay < 100*time.Millisecond {
			delay *= 2
		}
	}
}

// Send submits a transaction to k from `from` and waits for its receipt. A
// revert comes back naming the contract's custom error and its arguments.
func Send(ctx context.Context, c *chain.Client, k *chain.Contract, from chain.Account, method string, args ...any) (*types.Receipt, error) {
	opts, err := bind.NewKeyedTransactorWithChainID(from.Key, c.ChainID)
	if err != nil {
		return nil, err
	}
	opts.Context = ctx
	tx, err := boundFor(c, k).Transact(opts, method, args...)
	if err != nil {
		return nil, fmt.Errorf("%s.%s: %s", k.Name, method, c.Explain(err))
	}
	rcpt, err := WaitReceipt(ctx, c, tx.Hash())
	if err != nil {
		return nil, err
	}
	if rcpt.Status != types.ReceiptStatusSuccessful {
		return rcpt, fmt.Errorf("%s.%s: reverted in block %d", k.Name, method, rcpt.BlockNumber)
	}
	return rcpt, nil
}

// Send is Send on the deployment's client.
func (d *Deployment) Send(ctx context.Context, k *chain.Contract, from chain.Account, method string, args ...any) (*types.Receipt, error) {
	return Send(ctx, d.Client, k, from, method, args...)
}

// Create deploys an artifact (from the client's artifacts directory) and
// binds it.
func Create(ctx context.Context, c *chain.Client, from chain.Account, name string, args ...any) (*chain.Contract, error) {
	ct, err := c.At(name, common.Address{}) // loads the ABI and registers its errors
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(filepath.Join(c.Artifacts, name+".sol", name+".json"))
	if err != nil {
		return nil, err
	}
	var a struct {
		Bytecode struct {
			Object string `json:"object"`
		} `json:"bytecode"`
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, err
	}
	code, err := hex.DecodeString(strings.TrimPrefix(a.Bytecode.Object, "0x"))
	if err != nil {
		return nil, err
	}
	opts, err := bind.NewKeyedTransactorWithChainID(from.Key, c.ChainID)
	if err != nil {
		return nil, err
	}
	opts.Context = ctx
	addr, tx, _, err := bind.DeployContract(opts, ct.ABI, code, c.Eth, args...)
	if err != nil {
		return nil, fmt.Errorf("deploy %s: %s", name, c.Explain(err))
	}
	rcpt, err := WaitReceipt(ctx, c, tx.Hash())
	if err != nil {
		return nil, err
	}
	if rcpt.Status != types.ReceiptStatusSuccessful {
		return nil, fmt.Errorf("deploy %s: reverted", name)
	}
	return c.At(name, addr)
}
