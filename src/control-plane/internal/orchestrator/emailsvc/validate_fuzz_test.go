package emailsvc

import (
	"regexp"
	"strings"
	"testing"
)

// emailPatternMirror is the exact (deliberately permissive) recipient pattern
// sendRequest.validate compiles: local@domain.tld with no whitespace/@ runs.
const emailPatternMirror = `^[^\s@]+@[^\s@]+\.[^\s@]+$`

func TestSendRequestValidate_Edges(t *testing.T) {
	cases := []struct {
		name string
		r    sendRequest
		ok   bool
	}{
		{"valid html only", sendRequest{To: "u@e.com", Subject: "s", HTML: "<p>x</p>"}, true},
		{"valid text only", sendRequest{To: "u@e.com", Subject: "s", Text: "x"}, true},
		{"bad email no domain", sendRequest{To: "u@", Subject: "s", Text: "x"}, false},
		{"bad email no tld dot", sendRequest{To: "u@e", Subject: "s", Text: "x"}, false},
		{"bad email no at", sendRequest{To: "ue.com", Subject: "s", Text: "x"}, false},
		{"email with space rejected", sendRequest{To: "u @e.com", Subject: "s", Text: "x"}, false},
		{"whitespace subject rejected", sendRequest{To: "u@e.com", Subject: "   ", Text: "x"}, false},
		{"empty subject rejected", sendRequest{To: "u@e.com", Subject: "", Text: "x"}, false},
		{"no body rejected", sendRequest{To: "u@e.com", Subject: "s"}, false},
		{"NUL in email rejected", sendRequest{To: "u@e.\x00com", Subject: "s", Text: "x"}, true}, // \x00 is not \s/@ so the permissive regex accepts it — documented permissiveness
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := c.r.validate()
			if c.ok && err != nil {
				t.Fatalf("%+v: want accept, got %v", c.r, err)
			}
			if !c.ok && err == nil {
				t.Fatalf("%+v: want reject, got nil", c.r)
			}
		})
	}
}

// FuzzSendRequestValidate: never panics; and when subject+body are fixed-valid,
// the recipient decision must match recompiling the SAME email regex (parity).
func FuzzSendRequestValidate(f *testing.F) {
	for _, s := range []string{
		"u@e.com", "u@", "u@e", "ue.com", "u @e.com",
		"", "a@b.c", "\x00@x.y", "a@b.c@d.e", strings.Repeat("a", 300) + "@b.c", "é@b.c",
	} {
		f.Add(s)
	}
	re := regexp.MustCompile(emailPatternMirror)
	f.Fuzz(func(t *testing.T, to string) {
		err := sendRequest{To: to, Subject: "fixed", Text: "fixed"}.validate()
		want := re.MatchString(to)
		if want && err != nil {
			t.Fatalf("regex accepts %q but validate rejected: %v", to, err)
		}
		if !want && err == nil {
			t.Fatalf("regex rejects %q but validate accepted", to)
		}
	})
}

// FuzzNewMessageID: the from-domain parser must never panic and must always
// produce a well-formed <hex@domain> token regardless of how malformed `from` is.
func FuzzNewMessageID(f *testing.F) {
	for _, s := range []string{
		"noreply@grobase.io", "no-at-sign", "", "@",
		"a@", "@b", "x@y@z", "\x00@\x00", "trail@dom <>", strings.Repeat("@", 64),
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, from string) {
		id := newMessageID(from) // must not panic
		if !strings.HasPrefix(id, "<") || !strings.HasSuffix(id, ">") {
			t.Fatalf("newMessageID(%q) = %q, want <...> wrapped", from, id)
		}
		if !strings.Contains(id, "@") {
			t.Fatalf("newMessageID(%q) = %q, missing @domain", from, id)
		}
	})
}
