package iso20022

import (
	"fmt"
	"time"

	"github.com/moov-io/iso20022/pkg/document"
	"github.com/moov-io/iso20022/pkg/pacs_v08"
	"github.com/moov-io/iso20022/pkg/utils"
)

// Payment is a settlement payment message read back, flattened.
type Payment struct {
	Type            string // Pacs008Type or Pacs009Type
	MsgID           string
	EndToEndID      string
	Reference       string // the RF creditor reference, "" when absent
	Amount          uint64 // 6 decimals
	Currency        string
	SettleDate      time.Time
	DebtorBIC       string
	DebtorAccount   string
	CreditorBIC     string
	CreditorAccount string
}

// LegRef is what a settlement payment pays: part N of leg Leg of batch Batch.
type LegRef struct {
	Batch uint64
	Leg   uint32
	N     uint32
}

// ParsePayment reads a pacs.008.001.08 or pacs.009.001.08 carrying exactly one
// transaction.
func ParsePayment(b []byte) (Payment, error) {
	ns, err := rootNamespace(b)
	if err != nil {
		return Payment{}, err
	}
	switch ns {
	case utils.DocumentPacs00800108NameSpace:
		return parsePacs008(b)
	case Pacs009NameSpace:
		return parsePacs009(b)
	}
	return Payment{}, fmt.Errorf("unsupported message namespace %q", ns)
}

func parsePacs008(b []byte) (Payment, error) {
	doc, err := document.ParseIso20022Document(b)
	if err != nil {
		return Payment{}, fmt.Errorf("pacs.008: %w", err)
	}
	m, ok := doc.InspectMessage().(*pacs_v08.FIToFICustomerCreditTransferV08)
	if !ok {
		return Payment{}, fmt.Errorf("pacs.008: not an FI-to-FI customer credit transfer")
	}
	if len(m.CdtTrfTxInf) != 1 || m.GrpHdr.NbOfTxs != "1" {
		return Payment{}, fmt.Errorf("pacs.008: want exactly one transaction, got %d (NbOfTxs %q)", len(m.CdtTrfTxInf), m.GrpHdr.NbOfTxs)
	}
	tx := m.CdtTrfTxInf[0]
	if tx.IntrBkSttlmAmt.Ccy != "USD" {
		return Payment{}, fmt.Errorf("pacs.008: currency %q is not USD", tx.IntrBkSttlmAmt.Ccy)
	}
	amount, err := FromDecimal(tx.IntrBkSttlmAmt.Value)
	if err != nil {
		return Payment{}, fmt.Errorf("pacs.008: %w", err)
	}
	p := Payment{
		Type:       Pacs008Type,
		MsgID:      string(m.GrpHdr.MsgId),
		EndToEndID: string(tx.PmtId.EndToEndId),
		Amount:     amount,
		Currency:   string(tx.IntrBkSttlmAmt.Ccy),
	}
	if tx.IntrBkSttlmDt != nil {
		p.SettleDate = time.Time(*tx.IntrBkSttlmDt)
	}
	if bic := tx.DbtrAgt.FinInstnId.BICFI; bic != nil {
		p.DebtorBIC = string(*bic)
	}
	if bic := tx.CdtrAgt.FinInstnId.BICFI; bic != nil {
		p.CreditorBIC = string(*bic)
	}
	if tx.DbtrAcct != nil {
		p.DebtorAccount = string(tx.DbtrAcct.Id.Othr.Id)
	}
	if tx.CdtrAcct != nil {
		p.CreditorAccount = string(tx.CdtrAcct.Id.Othr.Id)
	}
	if tx.RmtInf != nil {
		for _, s := range tx.RmtInf.Strd {
			if s.CdtrRefInf != nil && s.CdtrRefInf.Ref != nil {
				p.Reference = string(*s.CdtrRefInf.Ref)
				break
			}
		}
	}
	return p, nil
}

// Leg maps the payment to (batch, leg, n): the RF reference must be a valid
// batch reference, the EndToEndId must parse, and both must name the same
// batch. Anything else is not a settlement payment of this model.
func (p Payment) Leg() (LegRef, error) {
	if p.Reference == "" {
		return LegRef{}, fmt.Errorf("payment %q carries no creditor reference", p.EndToEndID)
	}
	batch, err := ParseBatchReference(p.Reference)
	if err != nil {
		return LegRef{}, err
	}
	b2, leg, n, err := ParseEndToEndID(p.EndToEndID)
	if err != nil {
		return LegRef{}, err
	}
	if b2 != batch {
		return LegRef{}, fmt.Errorf("EndToEndId %q names batch %d but the reference %q names batch %d", p.EndToEndID, b2, p.Reference, batch)
	}
	return LegRef{Batch: batch, Leg: leg, N: n}, nil
}

// ParseLeg reads a payment message and maps it to its leg.
func ParseLeg(b []byte) (Payment, LegRef, error) {
	p, err := ParsePayment(b)
	if err != nil {
		return Payment{}, LegRef{}, err
	}
	l, err := p.Leg()
	return p, l, err
}
