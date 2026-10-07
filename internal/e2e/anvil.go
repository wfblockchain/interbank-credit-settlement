// Package e2e stands up the home chain on anvil with the rails simulators, the
// five-signer listener, the operator and the simulated banks (World), and
// holds the end-to-end tests that drive them through business days,
// weekends, faults and a default. cmd/operator-demo uses the same World.
package e2e

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/ethclient"
)

// AnvilEnv names the environment variable holding the anvil binary.
const AnvilEnv = "ANVIL_BIN"

// ErrNoAnvil: neither $ANVIL_BIN nor an anvil on PATH.
var ErrNoAnvil = errors.New("anvil not found: set ANVIL_BIN or put anvil on PATH")

// AnvilBin finds anvil: $ANVIL_BIN, else PATH.
func AnvilBin() (string, error) {
	if b := os.Getenv(AnvilEnv); b != "" {
		if _, err := os.Stat(b); err != nil {
			return "", fmt.Errorf("%s=%s: %w", AnvilEnv, b, err)
		}
		return b, nil
	}
	if b, err := exec.LookPath("anvil"); err == nil {
		return b, nil
	}
	return "", ErrNoAnvil
}

// Anvil is a running anvil node.
type Anvil struct {
	URL string
	cmd *exec.Cmd
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// StartAnvil starts anvil on a free port with its genesis block at genesis,
// and waits until it answers.
func StartAnvil(ctx context.Context, bin string, genesis time.Time) (*Anvil, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		port, err := freePort()
		if err != nil {
			return nil, err
		}
		cmd := exec.Command(bin, "--port", strconv.Itoa(port), "--host", "127.0.0.1",
			"--timestamp", strconv.FormatInt(genesis.Unix(), 10), "--silent", "--chain-id", "31337")
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		a := &Anvil{URL: fmt.Sprintf("http://127.0.0.1:%d", port), cmd: cmd}
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			c, err := ethclient.DialContext(ctx, a.URL)
			if err == nil {
				_, err = c.ChainID(ctx)
				c.Close()
				if err == nil {
					return a, nil
				}
			}
			lastErr = err
			time.Sleep(50 * time.Millisecond)
		}
		a.Stop()
	}
	return nil, fmt.Errorf("anvil did not start: %v", lastErr)
}

// Stop kills the node.
func (a *Anvil) Stop() {
	if a == nil || a.cmd == nil || a.cmd.Process == nil {
		return
	}
	_ = a.cmd.Process.Kill()
	_, _ = a.cmd.Process.Wait()
}
