package iso20022

import (
	"encoding/xml"
	"fmt"
	"time"

	"github.com/moov-io/iso20022/pkg/camt_v08"
	"github.com/moov-io/iso20022/pkg/common"
	"github.com/moov-io/iso20022/pkg/document"
	"github.com/moov-io/iso20022/pkg/utils"
)

// Notification is a camt.054 debit/credit notification of one rail account.
// It is reconciliation output (rail journal ↔ listener log ↔ chain), never
// an input to signing.
type Notification struct {
	MsgID   string
	At      time.Time
	Account string // the bank's rail account
	Owner   string // the bank's name, e.g. "Bank A"
	Entries []NotificationEntry
}

// NotificationEntry is one booked settlement payment on the account.
type NotificationEntry struct {
	RailTxID   string // CHIPS release sequence or RTP transaction id
	Rail       string // ClearingCHIPS or ClearingRTP
	Amount     uint64 // 6 decimals, whole cents
	Credit     bool   // true: received; false: paid
	BookedAt   time.Time
	EndToEndID string
	Reference  string // the batch's RF reference
}

// Camt054 writes a camt.054.001.08 notification. moov-io's Validate is not
// run on it: camt.054's choices (entry status, booking date, account id) are
// modelled with non-pointer branches, so a correctly filled message never
// passes it. The tests read every document back through moov-io's parser and
// check that no empty choice branch or zero date is left in the XML.
func Camt054(n Notification) ([]byte, error) {
	if n.MsgID == "" || n.Account == "" || n.Owner == "" {
		return nil, fmt.Errorf("camt.054: MsgId, account and owner are required")
	}
	d, err := document.NewDocument(utils.DocumentCamt05400108NameSpace)
	if err != nil {
		return nil, err
	}
	m := d.InspectMessage().(*camt_v08.BankToCustomerDebitCreditNotificationV08)
	at := common.ISODateTime(n.At.UTC().Truncate(time.Second))
	m.GrpHdr = camt_v08.GroupHeader81{MsgId: common.Max35Text(n.MsgID), CreDtTm: at}
	ntf := camt_v08.AccountNotification17{
		Id:      common.Max35Text(n.MsgID),
		CreDtTm: &at,
		Acct: camt_v08.CashAccount39{
			Id:   camt_v08.AccountIdentification4Choice{Othr: camt_v08.GenericAccountIdentification1{Id: common.Max34Text(n.Account)}},
			Ownr: &camt_v08.PartyIdentification135{Nm: max140(n.Owner)},
		},
	}
	for _, e := range n.Entries {
		v, err := toFloat(e.Amount)
		if err != nil {
			return nil, fmt.Errorf("camt.054 entry %s: %w", e.RailTxID, err)
		}
		ind, fam := common.CreditDebitCode("DBIT"), camt_v08.ExternalBankTransactionFamily1Code("ICDT")
		if e.Credit {
			ind, fam = "CRDT", "RCDT"
		}
		booked := camt_v08.DateAndDateTime2Choice{DtTm: common.ISODateTime(e.BookedAt.UTC().Truncate(time.Second))}
		rail := common.Max500Text(e.Rail)
		ntry := camt_v08.ReportEntry10{
			NtryRef:     max35(e.RailTxID),
			Amt:         camt_v08.ActiveOrHistoricCurrencyAndAmount{Value: v, Ccy: "USD"},
			CdtDbtInd:   ind,
			Sts:         camt_v08.EntryStatus1Choice{Cd: "BOOK"},
			BookgDt:     &booked,
			AcctSvcrRef: max35(e.RailTxID),
			BkTxCd: camt_v08.BankTransactionCodeStructure4{Domn: &camt_v08.BankTransactionCodeStructure5{
				Cd:   "PMNT",
				Fmly: camt_v08.BankTransactionCodeStructure6{Cd: fam, SubFmlyCd: "OTHR"},
			}},
			AddtlNtryInf: &rail,
		}
		txd := camt_v08.EntryTransaction10{Refs: &camt_v08.TransactionReferences6{
			EndToEndId: max35(e.EndToEndID),
			ClrSysRef:  max35(e.RailTxID),
		}}
		if e.Reference != "" {
			txd.RmtInf = &camt_v08.RemittanceInformation16{Strd: []camt_v08.StructuredRemittanceInformation16{{
				CdtrRefInf: &camt_v08.CreditorReferenceInformation2{
					Tp:  &camt_v08.CreditorReferenceType2{CdOrPrtry: camt_v08.CreditorReferenceType1Choice{Cd: "SCOR"}, Issr: max35("ISO")},
					Ref: max35(e.Reference),
				},
			}}}
		}
		ntry.NtryDtls = []camt_v08.EntryDetails9{{TxDtls: []camt_v08.EntryTransaction10{txd}}}
		ntf.Ntry = append(ntf.Ntry, ntry)
	}
	m.Ntfctn = []camt_v08.AccountNotification17{ntf}
	obj := d.(*document.Iso20022DocumentObject)
	obj.XMLName = xml.Name{Local: "Document"}
	obj.Attrs = []xml.Attr{{Name: xml.Name{Local: "xmlns"}, Value: utils.DocumentCamt05400108NameSpace}}
	return marshal(d)
}
