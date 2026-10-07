// Package listener is the matching and signing core of the operator's
// settlement listener (§5.3 of docs/design.md), independent of the chain
// client.
//
// n Signers each hold their own ECDSA key and read each rail's finality feed
// with their own cursor. A Signer signs an EIP-712 Payment only for a journal
// entry that is a final payment, whose ISO 20022 message maps to an open
// (batch, leg), whose payer and payee rail accounts match that leg (or an
// allowed waterfall payer), and whose rail transaction it has not signed
// before. Everything else goes to manual review and is never signed. An
// Aggregator collects k signatures per payment, orders them strictly
// ascending by signer address, and produces the SettlementAttestor call.
package listener

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/math"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/signer/core/apitypes"
)

// EIP-712 domain of the SettlementAttestor (§3.6).
const (
	DomainName    = "CreditSettlementAttestor"
	DomainVersion = "1"
)

// PaymentTypeString is the EIP-712 encodeType of Payment.
const PaymentTypeString = "Payment(uint64 batch,uint32 leg,uint8 rail,bytes32 railTxId,address payerAcct,bytes32 payer,bytes32 payee,uint256 amount,uint64 finalAt)"

// Domain identifies the attestor contract the signatures are for.
type Domain struct {
	ChainID           *big.Int
	VerifyingContract common.Address
}

// Payment is the attested fact: a final rail payment that pays (part of) leg
// Leg of batch Batch. Field order and types match the Solidity struct.
type Payment struct {
	Batch     uint64
	Leg       uint32
	Rail      uint8
	RailTxID  [32]byte // keccak256 of the rail's transaction id string
	PayerAcct common.Address
	Payer     [32]byte // member id, or bytes32("COLLATERAL") / bytes32("POOL")
	Payee     [32]byte
	Amount    *big.Int
	FinalAt   uint64 // unix seconds
}

// RailTxHash is the bytes32 form of a rail transaction id.
func RailTxHash(id string) [32]byte { return crypto.Keccak256Hash([]byte(id)) }

// typedData builds the go-ethereum TypedData for p under d.
func typedData(d Domain, p Payment) apitypes.TypedData {
	return apitypes.TypedData{
		Types: apitypes.Types{
			"EIP712Domain": {
				{Name: "name", Type: "string"},
				{Name: "version", Type: "string"},
				{Name: "chainId", Type: "uint256"},
				{Name: "verifyingContract", Type: "address"},
			},
			"Payment": {
				{Name: "batch", Type: "uint64"},
				{Name: "leg", Type: "uint32"},
				{Name: "rail", Type: "uint8"},
				{Name: "railTxId", Type: "bytes32"},
				{Name: "payerAcct", Type: "address"},
				{Name: "payer", Type: "bytes32"},
				{Name: "payee", Type: "bytes32"},
				{Name: "amount", Type: "uint256"},
				{Name: "finalAt", Type: "uint64"},
			},
		},
		PrimaryType: "Payment",
		Domain: apitypes.TypedDataDomain{
			Name:              DomainName,
			Version:           DomainVersion,
			ChainId:           (*math.HexOrDecimal256)(new(big.Int).Set(d.ChainID)),
			VerifyingContract: d.VerifyingContract.Hex(),
		},
		Message: apitypes.TypedDataMessage{
			"batch":     new(big.Int).SetUint64(p.Batch),
			"leg":       new(big.Int).SetUint64(uint64(p.Leg)),
			"rail":      new(big.Int).SetUint64(uint64(p.Rail)),
			"railTxId":  p.RailTxID[:],
			"payerAcct": p.PayerAcct.Hex(),
			"payer":     p.Payer[:],
			"payee":     p.Payee[:],
			"amount":    new(big.Int).Set(p.Amount),
			"finalAt":   new(big.Int).SetUint64(p.FinalAt),
		},
	}
}

// Digest is the EIP-712 digest keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(p)).
func Digest(d Domain, p Payment) (common.Hash, error) {
	if d.ChainID == nil || p.Amount == nil {
		return common.Hash{}, fmt.Errorf("chain id and amount are required")
	}
	h, _, err := apitypes.TypedDataAndHash(typedData(d, p))
	if err != nil {
		return common.Hash{}, err
	}
	return common.BytesToHash(h), nil
}

// SignDigest signs a digest with v in {27, 28}, as ecrecover and
// OpenZeppelin's ECDSA expect.
func SignDigest(key *ecdsa.PrivateKey, digest common.Hash) ([]byte, error) {
	sig, err := crypto.Sign(digest[:], key)
	if err != nil {
		return nil, err
	}
	sig[64] += 27
	return sig, nil
}

// Recover returns the address that produced sig over digest.
func Recover(digest common.Hash, sig []byte) (common.Address, error) {
	if len(sig) != 65 || (sig[64] != 27 && sig[64] != 28) {
		return common.Address{}, fmt.Errorf("signature must be 65 bytes with v 27/28")
	}
	s := append([]byte(nil), sig...)
	s[64] -= 27
	pub, err := crypto.SigToPub(digest[:], s)
	if err != nil {
		return common.Address{}, err
	}
	return crypto.PubkeyToAddress(*pub), nil
}
