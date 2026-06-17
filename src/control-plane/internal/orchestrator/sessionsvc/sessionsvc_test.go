package sessionsvc

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeRepo records calls and returns canned results so the HTTP layer (auth
// gating, routing precedence, status mapping, body shaping) is tested without a
// live Postgres.
type fakeRepo struct {
	lastUserID, lastToken, lastDevice, lastIP, lastExcept, lastID string
	lastDays                                                      int
	createErr, revokeErr                                          error
	valid                                                         bool
	revokedN, deletedN                                            int
}

func (f *fakeRepo) bootstrap(context.Context) error { return nil }
func (f *fakeRepo) create(_ context.Context, userID, token, device, ip string) (*Session, error) {
	f.lastUserID, f.lastToken, f.lastDevice, f.lastIP = userID, token, device, ip
	if f.createErr != nil {
		return nil, f.createErr
	}
	return &Session{ID: "sess-1", UserID: userID, SessionToken: token, ExpiresAt: time.Now()}, nil
}
func (f *fakeRepo) userSessions(_ context.Context, userID, cur string) ([]Session, error) {
	f.lastUserID, f.lastToken = userID, cur
	yes := true
	return []Session{{ID: "a", SessionToken: cur, IsCurrent: &yes}}, nil
}
func (f *fakeRepo) validate(_ context.Context, token string) (bool, *Session, error) {
	f.lastToken = token
	if !f.valid {
		return false, nil, nil
	}
	return true, &Session{ID: "sess-1", ExpiresAt: time.Now().Add(time.Hour)}, nil
}
func (f *fakeRepo) extend(_ context.Context, token string, days int) (*Session, error) {
	f.lastToken, f.lastDays = token, days
	return &Session{ID: "sess-1", ExpiresAt: time.Now().Add(time.Hour)}, nil
}
func (f *fakeRepo) revoke(_ context.Context, id, userID string) error {
	f.lastID, f.lastUserID = id, userID
	return f.revokeErr
}
func (f *fakeRepo) revokeAll(_ context.Context, userID, except string) (int, error) {
	f.lastUserID, f.lastExcept = userID, except
	return f.revokedN, nil
}
func (f *fakeRepo) activeSessions(_ context.Context, userID string) ([]Session, error) {
	f.lastUserID = userID
	return []Session{{ID: "a"}}, nil
}
func (f *fakeRepo) stats(context.Context) (Stats, error) {
	return Stats{Total: 5, Active: 3, Expired: 2, ActiveUsers: 2}, nil
}
func (f *fakeRepo) forceRevoke(_ context.Context, id string) error { f.lastID = id; return f.revokeErr }
func (f *fakeRepo) forceRevokeAll(_ context.Context, userID string) (int, error) {
	f.lastUserID = userID
	return f.revokedN, nil
}
func (f *fakeRepo) cleanupExpired(context.Context) (int, error) { return f.deletedN, nil }

func newSvc(f *fakeRepo) *Service { return &Service{log: slog.Default(), store: f} }

func do(svc *Service, method, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	svc.Mount(mux)
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func userHdr() map[string]string { return map[string]string{"X-Baas-User-Id": "u-1"} }
func adminHdr() map[string]string {
	return map[string]string{"X-Baas-User-Id": "svc", "X-Baas-Role": "service_role"}
}

func TestCreateRequiresIdentity(t *testing.T) {
	rec := do(newSvc(&fakeRepo{}), "POST", "/sessions", `{"token":"t"}`, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestCreateThreadsUserAndFields(t *testing.T) {
	f := &fakeRepo{}
	rec := do(newSvc(f), "POST", "/sessions",
		`{"token":"tok","deviceInfo":"iPhone","ipAddress":"1.2.3.4"}`, userHdr())
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	if f.lastUserID != "u-1" || f.lastToken != "tok" || f.lastDevice != "iPhone" || f.lastIP != "1.2.3.4" {
		t.Errorf("store got user=%q token=%q device=%q ip=%q", f.lastUserID, f.lastToken, f.lastDevice, f.lastIP)
	}
}

func TestCreateMissingTokenIs400(t *testing.T) {
	rec := do(newSvc(&fakeRepo{}), "POST", "/sessions", `{"token":""}`, userHdr())
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestValidateIsPublicAndShapesResponse(t *testing.T) {
	// invalid token: no identity header required, valid:false, no session key.
	rec := do(newSvc(&fakeRepo{valid: false}), "POST", "/sessions/validate", `{"token":"x"}`, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var resp map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp["valid"] != false {
		t.Errorf("valid = %v, want false", resp["valid"])
	}
	if _, ok := resp["session"]; ok {
		t.Errorf("invalid result must omit session key")
	}
	// valid token carries the session.
	rec = do(newSvc(&fakeRepo{valid: true}), "POST", "/sessions/validate", `{"token":"x"}`, nil)
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp["valid"] != true || resp["session"] == nil {
		t.Errorf("valid result must carry session, got %v", resp)
	}
}

func TestExtendParsesDaysFromAuthBearer(t *testing.T) {
	f := &fakeRepo{}
	h := userHdr()
	h["Authorization"] = "Bearer the-token"
	rec := do(newSvc(f), "POST", "/sessions/extend", `{"days":"30"}`, h)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if f.lastToken != "the-token" || f.lastDays != 30 {
		t.Errorf("extend got token=%q days=%d, want the-token/30", f.lastToken, f.lastDays)
	}
}

func TestRevokeMapsStoreErrors(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{nil, http.StatusOK},
		{errNotFound, http.StatusNotFound},
		{errForbidden, http.StatusForbidden},
	}
	for _, c := range cases {
		f := &fakeRepo{revokeErr: c.err}
		rec := do(newSvc(f), "DELETE", "/sessions/abc", ``, userHdr())
		if rec.Code != c.want {
			t.Errorf("revoke err=%v → status %d, want %d", c.err, rec.Code, c.want)
		}
		if c.err == nil && f.lastID != "abc" {
			t.Errorf("revoke id not threaded: %q", f.lastID)
		}
	}
}

func TestRevokeAllExcludesCurrentToken(t *testing.T) {
	f := &fakeRepo{revokedN: 4}
	h := userHdr()
	h["Authorization"] = "Bearer keep-me"
	rec := do(newSvc(f), "POST", "/sessions/revoke-all", ``, h)
	if rec.Code != http.StatusOK || f.lastExcept != "keep-me" {
		t.Errorf("status=%d except=%q, want 200/keep-me", rec.Code, f.lastExcept)
	}
}

// TestAdminGate pins that admin routes require service_role and that Go's mux
// routes /sessions/admin/* to the admin handlers (not the {id} wildcard).
func TestAdminGate(t *testing.T) {
	// a plain user is forbidden from admin/all
	rec := do(newSvc(&fakeRepo{}), "GET", "/sessions/admin/all", ``, userHdr())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin admin/all = %d, want 403", rec.Code)
	}
	// service_role passes
	rec = do(newSvc(&fakeRepo{}), "GET", "/sessions/admin/all", ``, adminHdr())
	if rec.Code != http.StatusOK {
		t.Fatalf("admin admin/all = %d, want 200", rec.Code)
	}
}

func TestAdminStatsShape(t *testing.T) {
	rec := do(newSvc(&fakeRepo{}), "GET", "/sessions/admin/stats", ``, adminHdr())
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var st Stats
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if st.Total != 5 || st.Active != 3 || st.ActiveUsers != 2 {
		t.Errorf("stats shape off: %+v", st)
	}
}

// TestAdminForceRevokeRoutesToAdminHandler proves DELETE /sessions/admin/{id}
// hits the admin handler (service_role enforced), NOT DELETE /sessions/{id}.
func TestAdminForceRevokeRoutesToAdminHandler(t *testing.T) {
	// user header (no role) must be rejected by the admin handler with 403,
	// whereas the user revoke handler would have returned 200.
	rec := do(newSvc(&fakeRepo{}), "DELETE", "/sessions/admin/xyz", ``, userHdr())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("admin force-revoke as non-admin = %d, want 403 (routing/precedence)", rec.Code)
	}
}

func TestAdminCleanupCount(t *testing.T) {
	f := &fakeRepo{deletedN: 9}
	rec := do(newSvc(f), "POST", "/sessions/admin/cleanup", ``, adminHdr())
	var resp map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if rec.Code != http.StatusOK || resp["deletedCount"].(float64) != 9 {
		t.Errorf("cleanup = %d %v, want 200 deletedCount=9", rec.Code, resp)
	}
}

func TestNameIsSession(t *testing.T) {
	if (&Service{}).Name() != "session" {
		t.Errorf("Name() must be %q", "session")
	}
}
