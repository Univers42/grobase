package newslettersvc

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeRepo is an in-memory newsletter repo for HTTP-layer tests.
type fakeRepo struct {
	existsActive   bool
	existsFound    bool
	confirmOK      bool
	unsubOK        bool
	recipients     []Recipient
	loggedSubject  string
	loggedCount    int
	lastInsertMail string
}

func (f *fakeRepo) bootstrap(context.Context) error { return nil }
func (f *fakeRepo) existing(_ context.Context, _ string) (int64, bool, *string, bool, error) {
	return 7, f.existsActive, nil, f.existsFound, nil
}
func (f *fakeRepo) reactivate(_ context.Context, id int64, token string, _ *string) (*Subscriber, error) {
	return &Subscriber{ID: id, Token: token, IsActive: true}, nil
}
func (f *fakeRepo) insert(_ context.Context, email string, _ *string, token string) (*Subscriber, error) {
	f.lastInsertMail = email
	return &Subscriber{ID: 1, Email: email, Token: token, IsActive: true}, nil
}
func (f *fakeRepo) confirm(context.Context, string) (bool, error)     { return f.confirmOK, nil }
func (f *fakeRepo) unsubscribe(context.Context, string) (bool, error) { return f.unsubOK, nil }
func (f *fakeRepo) listSubscribers(context.Context, int, int) ([]SubscriberSummary, error) {
	return []SubscriberSummary{{ID: 1, Email: "a@b.c"}}, nil
}
func (f *fakeRepo) stats(context.Context) (Stats, error) {
	return Stats{Total: 10, Active: 8, Confirmed: 6}, nil
}
func (f *fakeRepo) confirmedEmails(context.Context) ([]Recipient, error) { return f.recipients, nil }
func (f *fakeRepo) logSend(_ context.Context, subject string, count int, _ *string) error {
	f.loggedSubject, f.loggedCount = subject, count
	return nil
}
func (f *fakeRepo) history(context.Context, int) ([]SendLog, error) {
	return []SendLog{{ID: 1, Subject: "x"}}, nil
}

// recordingSender captures outbound mail and can be told to fail for specific
// recipients (to exercise campaign sent/failed counting).
type recordingSender struct {
	mu       sync.Mutex
	sent     []string
	failFor  map[string]bool
}

func (s *recordingSender) send(_ context.Context, to, _, _, _ string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sent = append(s.sent, to)
	if s.failFor[to] {
		return http.ErrServerClosed
	}
	return nil
}

func newSvc(f repo, sender emailSender) *Service {
	return &Service{
		log: slog.Default(), store: f, send: sender,
		baseURL: "http://base/newsletter/v1", batchSize: 2,
	}
}

func do(svc *Service, method, path, body string, h map[string]string) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	svc.Mount(mux)
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for k, v := range h {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func adminHdr() map[string]string {
	return map[string]string{"X-Baas-User-Id": "svc", "X-Baas-Role": "service_role"}
}

func TestSubscribeNewSendsConfirmation(t *testing.T) {
	f := &fakeRepo{existsFound: false}
	rs := &recordingSender{}
	rec := do(newSvc(f, rs.send), "POST", "/subscribe", `{"email":"new@x.io","firstName":"Jane"}`, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp["subscribed"] != true {
		t.Errorf("want subscribed:true, got %v", resp)
	}
	if len(rs.sent) != 1 || rs.sent[0] != "new@x.io" {
		t.Errorf("confirmation not sent to new@x.io, got %v", rs.sent)
	}
}

func TestSubscribeActiveConflicts(t *testing.T) {
	f := &fakeRepo{existsFound: true, existsActive: true}
	rec := do(newSvc(f, (&recordingSender{}).send), "POST", "/subscribe", `{"email":"dup@x.io"}`, nil)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", rec.Code)
	}
}

func TestSubscribeInactiveReactivates(t *testing.T) {
	f := &fakeRepo{existsFound: true, existsActive: false}
	rs := &recordingSender{}
	rec := do(newSvc(f, rs.send), "POST", "/subscribe", `{"email":"back@x.io"}`, nil)
	var resp map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if rec.Code != http.StatusCreated || resp["reactivated"] != true {
		t.Errorf("want 201 reactivated, got %d %v", rec.Code, resp)
	}
	if len(rs.sent) != 1 {
		t.Errorf("reactivate must resend confirmation, sent=%v", rs.sent)
	}
}

func TestSubscribeBadEmail(t *testing.T) {
	rec := do(newSvc(&fakeRepo{}, (&recordingSender{}).send), "POST", "/subscribe", `{"email":"nope"}`, nil)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestConfirmAndUnsubscribeTokens(t *testing.T) {
	// confirm hit
	rec := do(newSvc(&fakeRepo{confirmOK: true}, (&recordingSender{}).send), "GET", "/confirm/tok", ``, nil)
	if rec.Code != http.StatusOK {
		t.Errorf("confirm valid = %d, want 200", rec.Code)
	}
	// confirm miss → 404
	rec = do(newSvc(&fakeRepo{confirmOK: false}, (&recordingSender{}).send), "GET", "/confirm/tok", ``, nil)
	if rec.Code != http.StatusNotFound {
		t.Errorf("confirm invalid = %d, want 404", rec.Code)
	}
	// unsubscribe miss → 404
	rec = do(newSvc(&fakeRepo{unsubOK: false}, (&recordingSender{}).send), "GET", "/unsubscribe/tok", ``, nil)
	if rec.Code != http.StatusNotFound {
		t.Errorf("unsubscribe invalid = %d, want 404", rec.Code)
	}
}

func TestAdminRoutesRequireServiceRole(t *testing.T) {
	for _, path := range []string{"/admin/subscribers", "/admin/stats", "/admin/campaigns/history"} {
		rec := do(newSvc(&fakeRepo{}, (&recordingSender{}).send), "GET", path, ``, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without identity = %d, want 401", path, rec.Code)
		}
		rec = do(newSvc(&fakeRepo{}, (&recordingSender{}).send), "GET", path, ``,
			map[string]string{"X-Baas-User-Id": "u"})
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s as non-admin = %d, want 403", path, rec.Code)
		}
	}
}

// TestCampaignCountsSentAndFailed pins the batching + sent/failed accounting and
// that the send is recorded with the SUCCESS count (parity with the Node path).
func TestCampaignCountsSentAndFailed(t *testing.T) {
	f := &fakeRepo{recipients: []Recipient{
		{Email: "a@x.io"}, {Email: "b@x.io"}, {Email: "c@x.io"},
	}}
	rs := &recordingSender{failFor: map[string]bool{"b@x.io": true}}
	rec := do(newSvc(f, rs.send), "POST", "/admin/campaigns/send",
		`{"subject":"Hi","html":"<p>hi</p>"}`, adminHdr())
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Sent   int `json:"sent"`
		Failed int `json:"failed"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.Sent != 2 || resp.Failed != 1 {
		t.Errorf("sent/failed = %d/%d, want 2/1", resp.Sent, resp.Failed)
	}
	if len(rs.sent) != 3 {
		t.Errorf("all 3 recipients should be attempted, got %d", len(rs.sent))
	}
	if f.loggedSubject != "Hi" || f.loggedCount != 2 {
		t.Errorf("send_log = %q/%d, want Hi/2 (success count)", f.loggedSubject, f.loggedCount)
	}
}

func TestCampaignNoSubscribers(t *testing.T) {
	f := &fakeRepo{recipients: nil}
	rec := do(newSvc(f, (&recordingSender{}).send), "POST", "/admin/campaigns/send",
		`{"subject":"Hi","html":"<p>x</p>"}`, adminHdr())
	var resp struct{ Sent, Failed int }
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if rec.Code != http.StatusOK || resp.Sent != 0 || resp.Failed != 0 {
		t.Errorf("empty campaign = %d %+v, want 200 0/0", rec.Code, resp)
	}
}

func TestCampaignValidation(t *testing.T) {
	rec := do(newSvc(&fakeRepo{}, (&recordingSender{}).send), "POST", "/admin/campaigns/send",
		`{"subject":"","html":""}`, adminHdr())
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestNameIsNewsletter(t *testing.T) {
	if (&Service{}).Name() != "newsletter" {
		t.Errorf("Name() must be %q", "newsletter")
	}
}
