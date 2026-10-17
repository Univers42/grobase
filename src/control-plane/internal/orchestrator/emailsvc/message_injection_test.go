// W150-7 (devil verdict on WAF rule 10150): the WAF stops inspecting the html
// and text fields of POST /email/v1/send, so the mail itself must guarantee
// that a body cannot reach the SMTP headers.
//
// Caveat: this checks the bytes message.bytes() renders, not what net/smtp
// puts on the wire; dot-stuffing of "\r\n.\r\n" is the stdlib's and is not
// exercised here.

package emailsvc

import (
	"net/http"
	"regexp"
	"strings"
	"testing"
)

const injectedBody = "hello\r\nBcc: victim@example.com\r\n" +
	"and bare\nBcc: victim@example.com\n" +
	"--mb_0123456789abcdef01234567\r\n" +
	"--mb_0123456789abcdef01234567--\r\n" +
	"Content-Type: text/html\r\n" +
	"\r\n.\r\nRCPT TO:<victim@example.com>\r\n"

const injectedSubject = "Hi\r\nBcc: x@y.z"

var boundaryRe = regexp.MustCompile(`boundary="(mb_[0-9a-f]{24})"`)

// splitMessage returns the header block (before the first blank line) and the body.
func splitMessage(t *testing.T, raw string) (string, string) {
	t.Helper()
	head, body, ok := strings.Cut(raw, "\r\n\r\n")
	if !ok {
		t.Fatalf("no header terminator in message:\n%q", raw)
	}
	return head, body
}

func headerCount(head, name string) int {
	n := 0
	for _, line := range strings.Split(head, "\r\n") {
		if strings.HasPrefix(strings.ToLower(line), strings.ToLower(name)+":") {
			n++
		}
	}
	return n
}

func TestBodyCannotReachSMTPHeaders(t *testing.T) {
	cases := []struct {
		name       string
		html, text string
		multipart  bool
	}{
		{"html only", injectedBody, "", false},
		{"text only", "", injectedBody, false},
		{"html and text", injectedBody, injectedBody, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, captured := newTestService()
			rec := post(s, map[string]string{
				"to": "user@example.com", "subject": injectedSubject,
				"html": tc.html, "text": tc.text,
			})
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
			}
			head, body := splitMessage(t, string(captured.bytes()))

			// A header line, not a substring: the Q-encoded subject legitimately
			// holds the text "Bcc:" inside its encoded word.
			if headerCount(head, "Bcc") != 0 {
				t.Errorf("header block carries a Bcc header:\n%q", head)
			}
			for _, name := range []string{"To", "Subject", "From"} {
				if got := headerCount(head, name); got != 1 {
					t.Errorf("%s headers = %d, want 1\n%q", name, got, head)
				}
			}
			for _, line := range strings.Split(head, "\r\n") {
				if strings.HasPrefix(line, "Subject:") && !strings.Contains(line, "=?utf-8?q?") {
					t.Errorf("subject with control bytes is not Q-encoded: %q", line)
				}
			}

			if !tc.multipart {
				if !strings.Contains(body, "\r\nBcc: victim@example.com\r\n") {
					t.Errorf("injected text missing from the body: %q", body)
				}
				return
			}
			m := boundaryRe.FindStringSubmatch(head)
			if m == nil {
				t.Fatalf("no real boundary in headers: %q", head)
			}
			if strings.Contains(injectedBody, m[1]) {
				t.Fatalf("test input collides with the real boundary %s", m[1])
			}
			// Splitting on the real boundary only: the boundary-looking lines in
			// the body must not add a delimiter.
			parts := strings.Split(body, "--"+m[1])
			// parts: "", text part, html part, "--\r\n"
			if len(parts) != 4 {
				t.Fatalf("parts = %d, want 4 (real boundary only)\n%q", len(parts), body)
			}
			for _, part := range parts[1:3] {
				partHead, partBody, ok := strings.Cut(part, "\r\n\r\n")
				if !ok || strings.Contains(strings.ToLower(partHead), "bcc:") ||
					!strings.Contains(partBody, "Bcc: victim@example.com") {
					t.Errorf("injected text escaped its part:\n%q", part)
				}
			}
		})
	}
}

func TestCRLFInToIsRejected(t *testing.T) {
	s, _ := newTestService()
	rec := post(s, map[string]string{
		"to": "user@example.com\r\nBcc: victim@example.com", "subject": "x", "text": "x",
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}
