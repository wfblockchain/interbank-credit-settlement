package iso20022

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"

	"github.com/moov-io/iso20022/pkg/document"
)

// Amounts are uint256-style integers with 6 decimals (1 USD = 1_000_000);
// rails move whole cents.
const (
	unitsPerUSD  = 1_000_000
	unitsPerCent = 10_000
)

// ToDecimal renders a 6-decimal amount as an ISO decimal with two decimals,
// refusing amounts that are not whole cents.
func ToDecimal(amount uint64) (string, error) {
	if amount%unitsPerCent != 0 {
		return "", fmt.Errorf("amount %d is not a whole number of cents", amount)
	}
	c := amount / unitsPerCent
	return fmt.Sprintf("%d.%02d", c/100, c%100), nil
}

func toFloat(amount uint64) (float64, error) {
	s, err := ToDecimal(amount)
	if err != nil {
		return 0, err
	}
	return strconv.ParseFloat(s, 64)
}

// FromDecimal converts an ISO amount back to 6-decimal units, refusing
// fractions of a cent.
func FromDecimal(v float64) (uint64, error) {
	if v < 0 || math.IsNaN(v) || v > 1e13 {
		return 0, fmt.Errorf("amount %v out of range", v)
	}
	c := math.Round(v * 100)
	if math.Abs(c-v*100) > 1e-6 {
		return 0, fmt.Errorf("amount %v has more than two decimals", v)
	}
	return uint64(c) * unitsPerCent, nil
}

// marshal renders a moov document as XML and cleans it.
func marshal(doc document.Iso20022Document) ([]byte, error) {
	raw, err := xml.Marshal(doc)
	if err != nil {
		return nil, err
	}
	return finish(raw)
}

// finish cleans raw XML and prepends the XML header.
func finish(raw []byte) ([]byte, error) {
	out, err := clean(raw)
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), out...), nil
}

type node struct {
	start    xml.StartElement
	children []*node
	text     string
}

// clean fixes what moov-io marshals but the XSDs reject:
//
//   - an XSD choice is a Go struct whose unused branch is written as an empty
//     element (<Prtry></Prtry>);
//   - a zero ISODate/ISODateTime is written as 0001-01-01;
//   - a float64 amount is written by encoding/xml in exponent form
//     (2.5e+07), which xs:decimal does not allow.
//
// It drops elements that carry nothing (no attributes other than a namespace,
// no text, no remaining children), drops zero dates, rewrites any element with
// a Ccy attribute to a plain two-decimal number, and indents the result.
func clean(in []byte) ([]byte, error) {
	d := xml.NewDecoder(bytes.NewReader(in))
	root := &node{}
	stack := []*node{root}
	for {
		tok, err := d.RawToken()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		top := stack[len(stack)-1]
		switch t := tok.(type) {
		case xml.StartElement:
			n := &node{start: t.Copy()}
			top.children = append(top.children, n)
			stack = append(stack, n)
		case xml.EndElement:
			stack = stack[:len(stack)-1]
		case xml.CharData:
			top.text += string(t)
		}
	}
	var b bytes.Buffer
	e := xml.NewEncoder(&b)
	e.Indent("", "  ")
	for _, n := range root.children {
		empty, err := prune(n)
		if err != nil {
			return nil, err
		}
		if empty {
			continue
		}
		if err := emit(e, n); err != nil {
			return nil, err
		}
	}
	if err := e.Flush(); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func prune(n *node) (bool, error) {
	kept := n.children[:0]
	for _, c := range n.children {
		empty, err := prune(c)
		if err != nil {
			return false, err
		}
		if !empty {
			kept = append(kept, c)
		}
	}
	n.children = kept
	text := strings.TrimSpace(n.text)
	if text == "0001-01-01" || strings.HasPrefix(text, "0001-01-01T") {
		text = ""
	}
	if text != "" && hasAttr(n.start, "Ccy") {
		v, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return false, fmt.Errorf("amount %q in <%s>: %w", text, n.start.Name.Local, err)
		}
		text = strconv.FormatFloat(v, 'f', 2, 64)
	}
	n.text = text
	return len(n.children) == 0 && text == "" && len(n.start.Attr) == 0, nil
}

func hasAttr(s xml.StartElement, local string) bool {
	for _, a := range s.Attr {
		if a.Name.Local == local {
			return true
		}
	}
	return false
}

func emit(e *xml.Encoder, n *node) error {
	if err := e.EncodeToken(n.start); err != nil {
		return err
	}
	if n.text != "" {
		if err := e.EncodeToken(xml.CharData(n.text)); err != nil {
			return err
		}
	}
	for _, c := range n.children {
		if err := emit(e, c); err != nil {
			return err
		}
	}
	return e.EncodeToken(n.start.End())
}

// rootNamespace returns the default namespace of the document element.
func rootNamespace(b []byte) (string, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	for {
		tok, err := d.Token()
		if err != nil {
			return "", fmt.Errorf("no document element: %w", err)
		}
		if s, ok := tok.(xml.StartElement); ok {
			if s.Name.Local != "Document" {
				return "", fmt.Errorf("root element is <%s>, want <Document>", s.Name.Local)
			}
			return s.Name.Space, nil
		}
	}
}
