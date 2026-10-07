package listener

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/math"
	"github.com/ethereum/go-ethereum/signer/core/apitypes"
)

// FundingTypeString is the EIP-712 encodeType of Funding (§3.6).
const FundingTypeString = "Funding(uint8 kind,bytes32 member,uint256 value,uint64 asOf,uint64 nonce)"

// Funding is an attested off-chain resource value (ICollateralRegister.Kind:
// 0 COLLATERAL, 1 POOL, 2 RTP_PREFUND, 3 POOL_REQUIRED with member 0).
type Funding struct {
	Kind   uint8
	Member [32]byte
	Value  *big.Int
	AsOf   uint64
	Nonce  uint64
}

// abiFunding mirrors the Solidity tuple for packing.
type abiFunding struct {
	Kind   uint8
	Member [32]byte
	Value  *big.Int
	AsOf   uint64
	Nonce  uint64
}

// FundingDigest is the EIP-712 digest of f under d.
func FundingDigest(d Domain, f Funding) (common.Hash, error) {
	if d.ChainID == nil || f.Value == nil {
		return common.Hash{}, fmt.Errorf("chain id and value are required")
	}
	td := apitypes.TypedData{
		Types: apitypes.Types{
			"EIP712Domain": {
				{Name: "name", Type: "string"},
				{Name: "version", Type: "string"},
				{Name: "chainId", Type: "uint256"},
				{Name: "verifyingContract", Type: "address"},
			},
			"Funding": {
				{Name: "kind", Type: "uint8"},
				{Name: "member", Type: "bytes32"},
				{Name: "value", Type: "uint256"},
				{Name: "asOf", Type: "uint64"},
				{Name: "nonce", Type: "uint64"},
			},
		},
		PrimaryType: "Funding",
		Domain: apitypes.TypedDataDomain{
			Name:              DomainName,
			Version:           DomainVersion,
			ChainId:           (*math.HexOrDecimal256)(new(big.Int).Set(d.ChainID)),
			VerifyingContract: d.VerifyingContract.Hex(),
		},
		Message: apitypes.TypedDataMessage{
			"kind":   new(big.Int).SetUint64(uint64(f.Kind)),
			"member": f.Member[:],
			"value":  new(big.Int).Set(f.Value),
			"asOf":   new(big.Int).SetUint64(f.AsOf),
			"nonce":  new(big.Int).SetUint64(f.Nonce),
		},
	}
	h, _, err := apitypes.TypedDataAndHash(td)
	if err != nil {
		return common.Hash{}, err
	}
	return common.BytesToHash(h), nil
}

// FundingSource is a signer's independent view of the off-chain resources:
// the central-bank joint account statement (collateral, pool shares, the
// required pool) and the RTP prefunded positions.
type FundingSource interface {
	FundingValue(kind uint8, member [32]byte) (*big.Int, bool)
}

// ErrFundingMismatch: the claimed value differs from the signer's source.
var ErrFundingMismatch = fmt.Errorf("funding value disagrees with the signer's source")

// SignFunding signs f iff the signer's source reports exactly f.Value for
// (kind, member).
func (s *Signer) SignFunding(d Domain, f Funding, src FundingSource) (common.Hash, []byte, error) {
	v, ok := src.FundingValue(f.Kind, f.Member)
	if !ok || v.Cmp(f.Value) != 0 {
		return common.Hash{}, nil, fmt.Errorf("kind %d member %x: source %v, claim %s: %w", f.Kind, f.Member[:8], v, f.Value, ErrFundingMismatch)
	}
	dg, err := FundingDigest(d, f)
	if err != nil {
		return common.Hash{}, nil, err
	}
	sig, err := SignDigest(s.key, dg)
	if err != nil {
		return common.Hash{}, nil, err
	}
	return dg, sig, nil
}
