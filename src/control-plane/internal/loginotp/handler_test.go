package loginotp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type memStore struct{ rows []*otpRow }

func (m *memStore) insertCode(_ context.Context, _, hash string, exp time.Time) error {
	m.rows = append(m.rows, &otpRow{id: "r", codeHash: hash, expiresAt: exp})
	return nil
}

func (m *memStore) latestLive(context.Context, string) (otpRow, error) {
	if len(m.rows) == 0 {
		return otpRow{}, ErrNoCode
	}
	return *m.rows[len(m.rows)-1], nil
}

func (m *memStore) bumpAttempt(context.Context, string) error {
	m.rows[len(m.rows)-1].attempts++
	return nil
}

func (m *memStore) consume(context.Context, string) error {
	m.rows = m.rows[:len(m.rows)-1]
	return nil
}

type harness struct {
	svc     *Service
	mux     *http.ServeMux
	now     time.Time
	sendErr error
	subject string
	body    string
}

func newHarness() *harness {
	h := &harness{now: time.Unix(1_800_000_000, 0)}
	h.svc = &Service{
		log:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		now:         func() time.Time { return h.now },
		pepper:      []byte("pepper"),
		jwtSecret:   []byte("jwt-secret"),
		ttl:         5 * time.Minute,
		maxAttempts: 3,
		store:       &memStore{},
		appName:     "acme",
	}
	h.svc.send = func(_, subject, body string) error {
		h.subject, h.body = subject, body
		return h.sendErr
	}
	h.mux = http.NewServeMux()
	Mount(h.mux, h.svc)
	return h
}

func (h *harness) post(path string, body any) *httptest.ResponseRecorder {
	buf, _ := json.Marshal(body)
	rec := httptest.NewRecorder()
	h.mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(buf)))
	return rec
}

func (h *harness) mailedCode(t *testing.T) string {
	t.Helper()
	m := regexp.MustCompile(`\b\d{6}\b`).FindString(h.body)
	if m == "" {
		t.Fatalf("no code in body %q", h.body)
	}
	return m
}

func TestRequestSendOK(t *testing.T) {
	h := newHarness()
	rec := h.post("/v1/auth/otp/request", map[string]string{"email": "a@x.test"})
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"sent":true`) {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
}

func TestRequestAppNameInSubjectAndBody(t *testing.T) {
	h := newHarness()
	h.post("/v1/auth/otp/request", map[string]string{"email": "a@x.test"})
	if h.subject != "Your acme sign-in code" || !strings.Contains(h.body, "Your acme verification code") {
		t.Errorf("subject=%q body=%q", h.subject, h.body)
	}
}

func TestRequestSendFailureIs502(t *testing.T) {
	h := newHarness()
	h.sendErr = errors.New("relay down")
	rec := h.post("/v1/auth/otp/request", map[string]string{"email": "a@x.test"})
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "send_failed") {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
}

func TestVerifyRightCodeReturnsSignedProof(t *testing.T) {
	h := newHarness()
	h.post("/v1/auth/otp/request", map[string]string{"email": "A@x.test"})
	rec := h.post("/v1/auth/otp/verify", map[string]string{"email": "A@x.test", "code": h.mailedCode(t)})
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Verified bool   `json:"verified"`
		Proof    string `json:"proof"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	claims := jwt.MapClaims{}
	_, err := jwt.ParseWithClaims(out.Proof, claims, func(*jwt.Token) (any, error) { return []byte("jwt-secret"), nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithAudience("otp-proof"), jwt.WithTimeFunc(h.svc.now))
	if err != nil || !out.Verified || claims["otp"] != "a@x.test" {
		t.Fatalf("verified=%v claims=%v err=%v", out.Verified, claims, err)
	}
}

func TestVerifyWrongCodeIs401(t *testing.T) {
	h := newHarness()
	h.post("/v1/auth/otp/request", map[string]string{"email": "a@x.test"})
	if rec := h.post("/v1/auth/otp/verify", map[string]string{"email": "a@x.test", "code": "nope"}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestVerifyAttemptCapIs429(t *testing.T) {
	h := newHarness()
	h.post("/v1/auth/otp/request", map[string]string{"email": "a@x.test"})
	good := h.mailedCode(t)
	for i := 0; i < 3; i++ {
		h.post("/v1/auth/otp/verify", map[string]string{"email": "a@x.test", "code": "000000x"})
	}
	if rec := h.post("/v1/auth/otp/verify", map[string]string{"email": "a@x.test", "code": good}); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestVerifyExpiredIs410(t *testing.T) {
	h := newHarness()
	h.post("/v1/auth/otp/request", map[string]string{"email": "a@x.test"})
	h.now = h.now.Add(6 * time.Minute)
	if rec := h.post("/v1/auth/otp/verify", map[string]string{"email": "a@x.test", "code": h.mailedCode(t)}); rec.Code != http.StatusGone {
		t.Fatalf("got %d", rec.Code)
	}
}
