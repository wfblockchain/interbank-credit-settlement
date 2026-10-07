package iso20022

import (
	"encoding/xml"
	"fmt"
	"regexp"
	"time"

	"github.com/moov-io/iso20022/pkg/common"
	"github.com/moov-io/iso20022/pkg/document"
	"github.com/moov-io/iso20022/pkg/pacs_v08"
	"github.com/moov-io/iso20022/pkg/utils"
)

// Message types.
const (
	Pacs008Type = "pacs.008.001.08"
	Pacs009Type = "pacs.009.001.08"
	Camt054Type = "camt.054.001.08"

	Pacs009NameSpace = "urn:iso:std:iso:20022:tech:xsd:pacs.009.001.08"
)

// Clearing systems a leg settles over.
const (
	ClearingCHIPS = "CHIPS"
	ClearingRTP   = "RTP"
)

// Bank is a settlement member as it appears on a rail message.
type Bank struct {
	BIC     string // SWIFT-test-style member id, e.g. BNKAUS30
	Name    string // e.g. "Bank A"
	Account string // the bank's account on the rail
}

// Transfer is one settlement payment: part n of leg `Leg` of batch `Batch`.
type Transfer struct {
	MsgID      string
	CreatedAt  time.Time
	SettleDate time.Time // interbank settlement date: its calendar date in its own location (pass an Eastern date)
	Clearing   string    // ClearingCHIPS or ClearingRTP
	Batch      uint64
	Leg        uint32
	Part       uint32
	Amount     uint64 // 6 decimals; must be whole cents
	Debtor     Bank
	Creditor   Bank
}

var bicRE = regexp.MustCompile(`^[A-Z0-9]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$`)

func (t Transfer) check() (e2e, ref string, err error) {
	if t.MsgID == "" || len(t.MsgID) > 35 {
		return "", "", fmt.Errorf("MsgId must be 1–35 characters")
	}
	if t.Clearing != ClearingCHIPS && t.Clearing != ClearingRTP {
		return "", "", fmt.Errorf("clearing system %q is not CHIPS or RTP", t.Clearing)
	}
	if t.Amount == 0 {
		return "", "", fmt.Errorf("amount is zero")
	}
	for _, b := range []Bank{t.Debtor, t.Creditor} {
		if !bicRE.MatchString(b.BIC) || b.Account == "" || len(b.Account) > 34 || b.Name == "" {
			return "", "", fmt.Errorf("bank %+v: BIC, name and account (≤34) are required", b)
		}
	}
	if t.Debtor.BIC == t.Creditor.BIC {
		return "", "", fmt.Errorf("debtor and creditor are the same bank")
	}
	if e2e, err = EndToEndID(t.Batch, t.Leg, t.Part); err != nil {
		return "", "", err
	}
	if ref, err = BatchReference(t.Batch); err != nil {
		return "", "", err
	}
	return e2e, ref, nil
}

func max35(s string) *common.Max35Text   { v := common.Max35Text(s); return &v }
func max140(s string) *common.Max140Text { v := common.Max140Text(s); return &v }

func agent8(bic string) pacs_v08.BranchAndFinancialInstitutionIdentification6 {
	b := common.BICFIDec2014Identifier(bic)
	return pacs_v08.BranchAndFinancialInstitutionIdentification6{FinInstnId: pacs_v08.FinancialInstitutionIdentification18{BICFI: &b}}
}

func account8(id string) *pacs_v08.CashAccount38 {
	return &pacs_v08.CashAccount38{Id: pacs_v08.AccountIdentification4Choice{Othr: pacs_v08.GenericAccountIdentification1{Id: common.Max34Text(id)}}}
}

// Pacs008 writes a pacs.008.001.08 for one settlement payment. The batch's RF
// reference is in RmtInf/Strd/CdtrRefInf/Ref (typed SCOR, issuer ISO) and the
// EndToEndId (also used as InstrId and TxId) names batch, leg and part.
func Pacs008(t Transfer) ([]byte, error) {
	e2e, ref, err := t.check()
	if err != nil {
		return nil, err
	}
	amt, err := toFloat(t.Amount)
	if err != nil {
		return nil, err
	}
	d, err := document.NewDocument(utils.DocumentPacs00800108NameSpace)
	if err != nil {
		return nil, err
	}
	m := d.InspectMessage().(*pacs_v08.FIToFICustomerCreditTransferV08)
	settle := common.ISODate(time.Date(t.SettleDate.Year(), t.SettleDate.Month(), t.SettleDate.Day(), 0, 0, 0, 0, time.UTC))
	m.GrpHdr = pacs_v08.GroupHeader93{
		MsgId:   common.Max35Text(t.MsgID),
		CreDtTm: common.ISODateTime(t.CreatedAt.UTC().Truncate(time.Second)),
		NbOfTxs: "1",
		SttlmInf: pacs_v08.SettlementInstruction7{
			SttlmMtd: "CLRG",
			ClrSys:   clearing8(t.Clearing),
		},
	}
	dbtrAgt, cdtrAgt := agent8(t.Debtor.BIC), agent8(t.Creditor.BIC)
	scor := pacs_v08.DocumentType3Code("SCOR")
	tx := pacs_v08.CreditTransferTransaction39{
		PmtId:          pacs_v08.PaymentIdentification7{InstrId: max35(e2e), EndToEndId: common.Max35Text(e2e), TxId: max35(e2e)},
		IntrBkSttlmAmt: pacs_v08.ActiveCurrencyAndAmount{Value: amt, Ccy: "USD"},
		IntrBkSttlmDt:  &settle,
		ChrgBr:         "SLEV",
		InstgAgt:       &dbtrAgt,
		InstdAgt:       &cdtrAgt,
		Dbtr:           pacs_v08.PartyIdentification135{Nm: max140(t.Debtor.Name)},
		DbtrAcct:       account8(t.Debtor.Account),
		DbtrAgt:        dbtrAgt,
		CdtrAgt:        cdtrAgt,
		Cdtr:           pacs_v08.PartyIdentification135{Nm: max140(t.Creditor.Name)},
		CdtrAcct:       account8(t.Creditor.Account),
		RmtInf: &pacs_v08.RemittanceInformation16{Strd: []pacs_v08.StructuredRemittanceInformation16{{
			CdtrRefInf: &pacs_v08.CreditorReferenceInformation2{
				Tp:  &pacs_v08.CreditorReferenceType2{CdOrPrtry: pacs_v08.CreditorReferenceType1Choice{Cd: scor}, Issr: max35("ISO")},
				Ref: max35(ref),
			},
		}}},
	}
	m.CdtTrfTxInf = []pacs_v08.CreditTransferTransaction39{tx}
	if err := validate008(m); err != nil {
		return nil, fmt.Errorf("pacs.008 failed validation: %w", err)
	}
	obj := d.(*document.Iso20022DocumentObject)
	obj.XMLName = xml.Name{Local: "Document"}
	obj.Attrs = []xml.Attr{{Name: xml.Name{Local: "xmlns"}, Value: utils.DocumentPacs00800108NameSpace}}
	return marshal(d)
}

// clearing8 names the clearing system. CHIPS has the external code CHI; RTP has
// no external code, so it goes in the proprietary branch.
func clearing8(c string) *pacs_v08.ClearingSystemIdentification3Choice {
	if c == ClearingCHIPS {
		return &pacs_v08.ClearingSystemIdentification3Choice{Cd: "CHI"}
	}
	return &pacs_v08.ClearingSystemIdentification3Choice{Prtry: max35(c)}
}

// validate008 runs moov-io's Validate on the message. moov validates both
// branches of an XSD choice that it models as plain struct fields, so a
// correctly filled choice (Cd set, Prtry empty, or the reverse) always fails.
// The choices this package fills are therefore checked here by hand and
// removed from a copy before moov validates the rest; clean() removes the
// empty branch from the XML.
func validate008(m *pacs_v08.FIToFICustomerCreditTransferV08) error {
	c := *m
	c.GrpHdr.SttlmInf.ClrSys = nil
	if cs := m.GrpHdr.SttlmInf.ClrSys; cs != nil {
		if (cs.Cd == "") == (cs.Prtry == nil) {
			return fmt.Errorf("ClrSys must have exactly one of Cd and Prtry")
		}
		if cs.Cd != "" {
			if err := cs.Cd.Validate(); err != nil {
				return err
			}
		} else if err := cs.Prtry.Validate(); err != nil {
			return err
		}
	}
	c.CdtTrfTxInf = make([]pacs_v08.CreditTransferTransaction39, len(m.CdtTrfTxInf))
	for i, tx := range m.CdtTrfTxInf {
		if tx.RmtInf != nil {
			rmt := *tx.RmtInf
			rmt.Strd = make([]pacs_v08.StructuredRemittanceInformation16, len(tx.RmtInf.Strd))
			for j, s := range tx.RmtInf.Strd {
				if s.CdtrRefInf != nil && s.CdtrRefInf.Tp != nil {
					if err := s.CdtrRefInf.Tp.CdOrPrtry.Cd.Validate(); err != nil {
						return err
					}
					if s.CdtrRefInf.Tp.CdOrPrtry.Prtry != "" {
						return fmt.Errorf("CdtrRefInf/Tp/CdOrPrtry has both branches")
					}
					ri := *s.CdtrRefInf
					ri.Tp = nil
					s.CdtrRefInf = &ri
				}
				rmt.Strd[j] = s
			}
			tx.RmtInf = &rmt
		}
		c.CdtTrfTxInf[i] = tx
	}
	return c.Validate()
}
