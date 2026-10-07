package iso20022

import (
	"encoding/xml"
	"fmt"
	"time"
)

// moov-io/iso20022 v0.2.1 models pacs.009.001.09 but not pacs.009.001.08, the
// version CHIPS and Fedwire use. The subset written here follows the
// pacs.009.001.08 schema's element order (FinancialInstitutionCreditTransferV08,
// GroupHeader93, CreditTransferTransaction36). In this version RmtInf is
// RemittanceInformation2 (unstructured only), so the RF reference is carried
// as the single Ustrd line.

type fiCdtTrfDoc struct {
	XMLName xml.Name `xml:"Document"`
	Xmlns   string   `xml:"xmlns,attr"`
	Msg     fiCdtTrf `xml:"FICdtTrf"`
}

type fiCdtTrf struct {
	GrpHdr struct {
		MsgId    string `xml:"MsgId"`
		CreDtTm  string `xml:"CreDtTm"`
		NbOfTxs  string `xml:"NbOfTxs"`
		SttlmInf struct {
			SttlmMtd string `xml:"SttlmMtd"`
			ClrSys   *struct {
				Cd    string `xml:"Cd,omitempty"`
				Prtry string `xml:"Prtry,omitempty"`
			} `xml:"ClrSys,omitempty"`
		} `xml:"SttlmInf"`
	} `xml:"GrpHdr"`
	CdtTrfTxInf []fiTx `xml:"CdtTrfTxInf"`
}

type fiPmtId struct {
	InstrId    string `xml:"InstrId,omitempty"`
	EndToEndId string `xml:"EndToEndId"`
	TxId       string `xml:"TxId,omitempty"`
}

type fiAmt struct {
	Value string `xml:",chardata"`
	Ccy   string `xml:"Ccy,attr"`
}

type fiInstn struct {
	FinInstnId struct {
		BICFI string `xml:"BICFI,omitempty"`
		Nm    string `xml:"Nm,omitempty"`
	} `xml:"FinInstnId"`
}

type fiAcct struct {
	Id struct {
		Othr struct {
			Id string `xml:"Id"`
		} `xml:"Othr"`
	} `xml:"Id"`
}

type fiTx struct {
	PmtId          fiPmtId  `xml:"PmtId"`
	IntrBkSttlmAmt fiAmt    `xml:"IntrBkSttlmAmt"`
	IntrBkSttlmDt  string   `xml:"IntrBkSttlmDt"`
	InstgAgt       *fiInstn `xml:"InstgAgt,omitempty"`
	InstdAgt       *fiInstn `xml:"InstdAgt,omitempty"`
	Dbtr           fiInstn  `xml:"Dbtr"`
	DbtrAcct       *fiAcct  `xml:"DbtrAcct,omitempty"`
	Cdtr           fiInstn  `xml:"Cdtr"`
	CdtrAcct       *fiAcct  `xml:"CdtrAcct,omitempty"`
	RmtInf         *struct {
		Ustrd []string `xml:"Ustrd"`
	} `xml:"RmtInf,omitempty"`
}

func instn(b Bank, withName bool) fiInstn {
	var i fiInstn
	i.FinInstnId.BICFI = b.BIC
	if withName {
		i.FinInstnId.Nm = b.Name
	}
	return i
}

func acct(id string) *fiAcct {
	var a fiAcct
	a.Id.Othr.Id = id
	return &a
}

// Pacs009 writes a pacs.009.001.08 financial institution credit transfer for
// one CHIPS settlement payment between two banks.
func Pacs009(t Transfer) ([]byte, error) {
	e2e, ref, err := t.check()
	if err != nil {
		return nil, err
	}
	amt, err := ToDecimal(t.Amount)
	if err != nil {
		return nil, err
	}
	var doc fiCdtTrfDoc
	doc.Xmlns = Pacs009NameSpace
	h := &doc.Msg.GrpHdr
	h.MsgId = t.MsgID
	h.CreDtTm = t.CreatedAt.UTC().Format("2006-01-02T15:04:05Z")
	h.NbOfTxs = "1"
	h.SttlmInf.SttlmMtd = "CLRG"
	h.SttlmInf.ClrSys = &struct {
		Cd    string `xml:"Cd,omitempty"`
		Prtry string `xml:"Prtry,omitempty"`
	}{}
	if t.Clearing == ClearingCHIPS {
		h.SttlmInf.ClrSys.Cd = "CHI"
	} else {
		h.SttlmInf.ClrSys.Prtry = t.Clearing
	}
	instg, instd := instn(t.Debtor, false), instn(t.Creditor, false)
	tx := fiTx{
		PmtId:          fiPmtId{InstrId: e2e, EndToEndId: e2e, TxId: e2e},
		IntrBkSttlmAmt: fiAmt{Value: amt, Ccy: "USD"},
		IntrBkSttlmDt:  t.SettleDate.Format("2006-01-02"),
		InstgAgt:       &instg,
		InstdAgt:       &instd,
		Dbtr:           instn(t.Debtor, true),
		DbtrAcct:       acct(t.Debtor.Account),
		Cdtr:           instn(t.Creditor, true),
		CdtrAcct:       acct(t.Creditor.Account),
		RmtInf: &struct {
			Ustrd []string `xml:"Ustrd"`
		}{Ustrd: []string{ref}},
	}
	doc.Msg.CdtTrfTxInf = []fiTx{tx}
	raw, err := xml.Marshal(doc)
	if err != nil {
		return nil, err
	}
	return finish(raw)
}

func parsePacs009(b []byte) (Payment, error) {
	var doc fiCdtTrfDoc
	if err := xml.Unmarshal(b, &doc); err != nil {
		return Payment{}, fmt.Errorf("pacs.009: %w", err)
	}
	m := doc.Msg
	if len(m.CdtTrfTxInf) != 1 || m.GrpHdr.NbOfTxs != "1" {
		return Payment{}, fmt.Errorf("pacs.009: want exactly one transaction, got %d (NbOfTxs %q)", len(m.CdtTrfTxInf), m.GrpHdr.NbOfTxs)
	}
	tx := m.CdtTrfTxInf[0]
	if tx.IntrBkSttlmAmt.Ccy != "USD" {
		return Payment{}, fmt.Errorf("pacs.009: currency %q is not USD", tx.IntrBkSttlmAmt.Ccy)
	}
	var v float64
	if _, err := fmt.Sscan(tx.IntrBkSttlmAmt.Value, &v); err != nil {
		return Payment{}, fmt.Errorf("pacs.009: amount %q", tx.IntrBkSttlmAmt.Value)
	}
	amount, err := FromDecimal(v)
	if err != nil {
		return Payment{}, fmt.Errorf("pacs.009: %w", err)
	}
	p := Payment{
		Type:        Pacs009Type,
		MsgID:       m.GrpHdr.MsgId,
		EndToEndID:  tx.PmtId.EndToEndId,
		Amount:      amount,
		Currency:    tx.IntrBkSttlmAmt.Ccy,
		DebtorBIC:   tx.Dbtr.FinInstnId.BICFI,
		CreditorBIC: tx.Cdtr.FinInstnId.BICFI,
	}
	if tx.DbtrAcct != nil {
		p.DebtorAccount = tx.DbtrAcct.Id.Othr.Id
	}
	if tx.CdtrAcct != nil {
		p.CreditorAccount = tx.CdtrAcct.Id.Othr.Id
	}
	if d, err := time.Parse("2006-01-02", tx.IntrBkSttlmDt); err == nil {
		p.SettleDate = d
	}
	if tx.RmtInf != nil {
		for _, u := range tx.RmtInf.Ustrd {
			if ValidateCreditorReference(u) == nil {
				p.Reference = u
				break
			}
		}
	}
	return p, nil
}
