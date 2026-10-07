// Package iso20022 writes and reads the ISO 20022 messages of the settlement
// legs (§5.2 of docs/design.md):
//
//   - pacs.008.001.08 FI-to-FI customer credit transfer, one per RTP leg part
//     (and usable on CHIPS);
//   - pacs.009.001.08 financial institution credit transfer, for CHIPS
//     FI-to-FI legs;
//   - camt.054.001.08 debit/credit notification, reconciliation output only.
//
// Every settlement payment carries the batch's ISO 11649 creditor reference
// ("RF" + check digits + "CS" + batch) and an EndToEndId "CS<batch>-L<leg>-<n>";
// ParsePayment maps a message back to (batch, leg, n).
package iso20022

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// BatchPrefix starts the body of every batch reference and EndToEndId.
const BatchPrefix = "CS"

// maxRFBody is the ISO 11649 limit: 25 characters in total, 4 of them "RFcc".
const maxRFBody = 21

// mod97 computes the ISO 7064 MOD 97-10 remainder of an alphanumeric string,
// letters mapped A=10 … Z=35.
func mod97(s string) (int, error) {
	r := 0
	for _, c := range s {
		switch {
		case c >= '0' && c <= '9':
			r = (r*10 + int(c-'0')) % 97
		case c >= 'A' && c <= 'Z':
			r = (r*100 + int(c-'A'+10)) % 97
		default:
			return 0, fmt.Errorf("character %q is not alphanumeric", c)
		}
	}
	return r, nil
}

// normalizeRF removes the print-format spaces and upper-cases.
func normalizeRF(s string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(s), " ", ""))
}

// CreditorReference builds the ISO 11649 structured creditor reference for
// body (1–21 alphanumeric characters, case-insensitive).
func CreditorReference(body string) (string, error) {
	body = normalizeRF(body)
	if len(body) == 0 || len(body) > maxRFBody {
		return "", fmt.Errorf("RF body must be 1–%d characters, got %d", maxRFBody, len(body))
	}
	r, err := mod97(body + "RF00")
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("RF%02d%s", 98-r, body), nil
}

// ValidateCreditorReference checks an ISO 11649 reference (print format with
// spaces accepted): "RF", two check digits, 1–21 alphanumerics, and the
// rearranged MOD 97-10 remainder equal to 1.
func ValidateCreditorReference(ref string) error {
	s := normalizeRF(ref)
	if len(s) < 5 || len(s) > 4+maxRFBody {
		return fmt.Errorf("RF reference %q: length %d outside 5–25", ref, len(s))
	}
	if s[:2] != "RF" || s[2] < '0' || s[2] > '9' || s[3] < '0' || s[3] > '9' {
		return fmt.Errorf("RF reference %q: must start RF and two check digits", ref)
	}
	r, err := mod97(s[4:] + s[:4])
	if err != nil {
		return fmt.Errorf("RF reference %q: %w", ref, err)
	}
	if r != 1 {
		return fmt.Errorf("RF reference %q: check digits do not verify", ref)
	}
	return nil
}

// BatchReference is the reference of settlement batch `batch`, as
// SettlementBatches.reference(batch) returns it: "RF" + check digits + "CS" +
// the decimal batch number.
func BatchReference(batch uint64) (string, error) {
	return CreditorReference(BatchPrefix + strconv.FormatUint(batch, 10))
}

// ErrNotBatchReference is returned for a valid RF reference that does not name
// a settlement batch.
var ErrNotBatchReference = errors.New("not a settlement batch reference")

// ParseBatchReference validates ref and returns its batch number. Only the
// canonical form (no leading zeros, upper case, no spaces) is accepted, so a
// batch has exactly one reference.
func ParseBatchReference(ref string) (uint64, error) {
	if err := ValidateCreditorReference(ref); err != nil {
		return 0, err
	}
	body := ref[4:]
	if !strings.HasPrefix(body, BatchPrefix) {
		return 0, fmt.Errorf("%q: %w", ref, ErrNotBatchReference)
	}
	batch, err := strconv.ParseUint(body[len(BatchPrefix):], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%q: %w", ref, ErrNotBatchReference)
	}
	if canon, _ := BatchReference(batch); canon != ref {
		return 0, fmt.Errorf("%q is not canonical (want %q): %w", ref, canon, ErrNotBatchReference)
	}
	return batch, nil
}

// MaxEndToEndID is the length limit of EndToEndId (Max35Text).
const MaxEndToEndID = 35

// EndToEndID returns "CS<batch>-L<leg>-<n>" for part n of leg `leg` of batch
// `batch`. leg is the index of the leg in the submitted plan; n numbers the
// payments that pay it (1 for a CHIPS leg, 1.. for RTP parts and top-ups).
func EndToEndID(batch uint64, leg uint32, n uint32) (string, error) {
	s := fmt.Sprintf("%s%d-L%d-%d", BatchPrefix, batch, leg, n)
	if len(s) > MaxEndToEndID {
		return "", fmt.Errorf("EndToEndId %q is %d characters, limit %d", s, len(s), MaxEndToEndID)
	}
	return s, nil
}

// ParseEndToEndID is the inverse of EndToEndID; only the canonical form is
// accepted.
func ParseEndToEndID(s string) (batch uint64, leg uint32, n uint32, err error) {
	bad := func() (uint64, uint32, uint32, error) {
		return 0, 0, 0, fmt.Errorf("EndToEndId %q is not CS<batch>-L<leg>-<n>", s)
	}
	if len(s) > MaxEndToEndID || !strings.HasPrefix(s, BatchPrefix) {
		return bad()
	}
	parts := strings.Split(s[len(BatchPrefix):], "-")
	if len(parts) != 3 || !strings.HasPrefix(parts[1], "L") {
		return bad()
	}
	b, err1 := strconv.ParseUint(parts[0], 10, 64)
	l, err2 := strconv.ParseUint(parts[1][1:], 10, 32)
	k, err3 := strconv.ParseUint(parts[2], 10, 32)
	if err1 != nil || err2 != nil || err3 != nil {
		return bad()
	}
	if canon, _ := EndToEndID(b, uint32(l), uint32(k)); canon != s {
		return bad()
	}
	return b, uint32(l), uint32(k), nil
}
