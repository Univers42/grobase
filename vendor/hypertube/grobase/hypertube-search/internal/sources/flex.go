package sources

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
)

// flexString decodes a field that may arrive as a JSON string, a number, or an
// array of either — archive.org's advancedsearch returns multi-value fields as
// arrays and numeric fields (year/downloads) un-quoted. The first value wins.
type flexString string

// UnmarshalJSON accepts string | number | array(first), defaulting to empty.
func (f *flexString) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || string(b) == "null" {
		return nil
	}
	switch b[0] {
	case '"':
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		*f = flexString(s)
	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(b, &arr); err != nil {
			return err
		}
		if len(arr) > 0 {
			return f.UnmarshalJSON(arr[0])
		}
	default:
		*f = flexString(b)
	}
	return nil
}

// flexInt decodes a number that may be quoted or array-wrapped; 0 when absent
// or non-integer (delegates the shape handling to flexString).
type flexInt int

// UnmarshalJSON keeps the first parseable integer, 0 otherwise.
func (n *flexInt) UnmarshalJSON(b []byte) error {
	var s flexString
	if err := s.UnmarshalJSON(b); err != nil {
		return err
	}
	if v, err := strconv.Atoi(strings.TrimSpace(string(s))); err == nil {
		*n = flexInt(v)
	}
	return nil
}
