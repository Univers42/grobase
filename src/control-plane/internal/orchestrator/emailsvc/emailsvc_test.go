/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   emailsvc_test.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:57 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:58 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package emailsvc

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// newTestService builds a Service with a capturing transport so the HTTP
// surface + message building are asserted without a live SMTP server.
func newTestService() (*Service, *message) {
	s := New(slog.Default())
	s.from = "noreply@grobase.test"
	holder := &message{}
	s.send = func(m *message) error { *holder = *m; return nil }
	return s, holder
}

func post(s *Service, body any) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	s.Mount(mux)
	buf, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPost, "/send", bytes.NewReader(buf))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestSendSuccessReturnsMessageID(t *testing.T) {
	s, captured := newTestService()
	rec := post(s, map[string]string{
		"to":      "user@example.com",
		"subject": "Welcome",
		"html":    "<p>hi</p>",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		MessageID string `json:"messageId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !strings.HasPrefix(resp.MessageID, "<") || !strings.Contains(resp.MessageID, "@grobase.test>") {
		t.Errorf("messageId = %q, want <hex@grobase.test>", resp.MessageID)
	}
	// The transport saw the from override + the recipient + the html body.
	if captured.from != "noreply@grobase.test" || captured.to != "user@example.com" {
		t.Errorf("captured envelope off: from=%q to=%q", captured.from, captured.to)
	}
	if captured.messageID != resp.MessageID {
		t.Errorf("response messageId %q != built %q", resp.MessageID, captured.messageID)
	}
}

func TestSendValidation(t *testing.T) {
	cases := []struct {
		name string
		body map[string]string
	}{
		{"bad_email", map[string]string{"to": "not-an-email", "subject": "s", "text": "t"}},
		{"empty_subject", map[string]string{"to": "u@e.com", "subject": "  ", "text": "t"}},
		{"no_body", map[string]string{"to": "u@e.com", "subject": "s"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s, _ := newTestService()
			rec := post(s, c.body)
			if rec.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400 (body=%s)", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestSendTransportErrorIsBadGateway(t *testing.T) {
	s := New(slog.Default())
	s.send = func(m *message) error { return http.ErrServerClosed }
	rec := post(s, map[string]string{"to": "u@e.com", "subject": "s", "text": "t"})
	if rec.Code != http.StatusBadGateway {
		t.Errorf("status = %d, want 502", rec.Code)
	}
}

// TestMessageBytesMultipart pins the wire shape: when both html and text are
// present the message is multipart/alternative carrying BOTH representations,
// with the required RFC 5322 headers.
func TestMessageBytesMultipart(t *testing.T) {
	m := &message{
		from:      "noreply@grobase.test",
		to:        "user@example.com",
		subject:   "Héllo", // exercises Q-encoding of the header
		html:      "<p>hi</p>",
		text:      "hi",
		messageID: "<abc@grobase.test>",
	}
	raw := string(m.bytes())
	mustContain := []string{
		"From: noreply@grobase.test\r\n",
		"To: user@example.com\r\n",
		"Message-ID: <abc@grobase.test>\r\n",
		"MIME-Version: 1.0\r\n",
		"Content-Type: multipart/alternative; boundary=",
		"Content-Type: text/plain; charset=utf-8",
		"Content-Type: text/html; charset=utf-8",
		"<p>hi</p>",
	}
	for _, want := range mustContain {
		if !strings.Contains(raw, want) {
			t.Errorf("rendered message missing %q\n---\n%s", want, raw)
		}
	}
	// Subject is Q-encoded, not raw UTF-8.
	if strings.Contains(raw, "Subject: Héllo") {
		t.Errorf("subject must be MIME-encoded, got raw UTF-8")
	}
}

// TestMessageBytesSingleRepresentation: html-only and text-only collapse to the
// single matching Content-Type (no multipart wrapper).
func TestMessageBytesSingleRepresentation(t *testing.T) {
	htmlOnly := (&message{from: "f@x.test", to: "t@x.test", subject: "s", html: "<b>x</b>", messageID: "<1@x>"}).bytes()
	if !strings.Contains(string(htmlOnly), "Content-Type: text/html; charset=utf-8\r\n\r\n<b>x</b>") {
		t.Errorf("html-only should be a single text/html part:\n%s", htmlOnly)
	}
	if strings.Contains(string(htmlOnly), "multipart/alternative") {
		t.Errorf("html-only must not be multipart")
	}
	textOnly := (&message{from: "f@x.test", to: "t@x.test", subject: "s", text: "plain", messageID: "<2@x>"}).bytes()
	if !strings.Contains(string(textOnly), "Content-Type: text/plain; charset=utf-8\r\n\r\nplain") {
		t.Errorf("text-only should be a single text/plain part:\n%s", textOnly)
	}
}

func TestNewMessageIDUsesFromDomain(t *testing.T) {
	id := newMessageID("noreply@mail.grobase.io")
	if !strings.HasSuffix(id, "@mail.grobase.io>") || !strings.HasPrefix(id, "<") {
		t.Errorf("messageID = %q, want <hex@mail.grobase.io>", id)
	}
	// Two mints must differ (uniqueness).
	if newMessageID("a@b.c") == newMessageID("a@b.c") {
		t.Errorf("message IDs must be unique")
	}
}

func TestNameIsEmail(t *testing.T) {
	if New(slog.Default()).Name() != "email" {
		t.Errorf("Name() must be %q", "email")
	}
}
