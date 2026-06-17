package gdprsvc

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeRepo is an in-memory gdpr repo for HTTP-layer tests.
type fakeRepo struct {
	consent        *Consent
	consentMissing bool
	pending        bool
	delReq         *DeletionRequest
	delReqStatus   string
	withdrawn      int
	lastSetConsent bool
	lastUpdateType string
}

func (f *fakeRepo) bootstrap(context.Context) error { return nil }
func (f *fakeRepo) userConsents(context.Context, string) ([]Consent, error) {
	return []Consent{{ID: 1, ConsentType: "marketing"}}, nil
}
func (f *fakeRepo) userConsent(context.Context, string, string) (*Consent, error) {
	if f.consentMissing {
		return nil, nil
	}
	if f.consent != nil {
		return f.consent, nil
	}
	return &Consent{ID: 1, ConsentType: "marketing", IsGranted: true}, nil
}
func (f *fakeRepo) setConsent(_ context.Context, _, ctype string, consented bool) (*Consent, error) {
	f.lastSetConsent = consented
	return &Consent{ID: 1, ConsentType: ctype, IsGranted: consented}, nil
}
func (f *fakeRepo) updateConsent(_ context.Context, _, ctype string, consented bool) (*Consent, error) {
	f.lastUpdateType = ctype
	return &Consent{ID: 1, ConsentType: ctype, IsGranted: consented}, nil
}
func (f *fakeRepo) withdrawNonEssential(context.Context, string) (int, error) {
	return f.withdrawn, nil
}
func (f *fakeRepo) pendingExists(context.Context, string) (bool, error) { return f.pending, nil }
func (f *fakeRepo) createDeletion(_ context.Context, userID string, _ *string) (*DeletionRequest, error) {
	return &DeletionRequest{ID: 1, UserID: userID, Status: "pending"}, nil
}
func (f *fakeRepo) myRequest(context.Context, string) (*DeletionRequest, error) {
	if f.delReq != nil {
		return f.delReq, nil
	}
	return nil, nil
}
func (f *fakeRepo) cancelRequest(context.Context, string) (*DeletionRequest, error) {
	if f.delReq == nil {
		return nil, errNotFound
	}
	return f.delReq, nil
}
func (f *fakeRepo) allRequests(context.Context, string) ([]DeletionRequest, error) {
	return []DeletionRequest{{ID: 1, Status: "pending"}}, nil
}
func (f *fakeRepo) getRequest(context.Context, string) (*DeletionRequest, error) {
	if f.delReq == nil {
		return nil, errNotFound
	}
	return f.delReq, nil
}
func (f *fakeRepo) updateRequest(_ context.Context, _, status, _ string, _ *string) (*DeletionRequest, error) {
	return &DeletionRequest{ID: 1, Status: status}, nil
}

func newSvc(f repo) (*Service, *struct {
	exported bool
	deleted  bool
}) {
	flags := &struct {
		exported bool
		deleted  bool
	}{}
	svc := &Service{
		log:   slog.Default(),
		store: f,
		doExport: func(context.Context, string) map[string]any {
			flags.exported = true
			return map[string]any{"notes": 3}
		},
		doDeletion: func(context.Context, string) { flags.deleted = true },
	}
	return svc, flags
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

func userHdr() map[string]string { return map[string]string{"X-Baas-User-Id": "u-1"} }
func adminHdr() map[string]string {
	return map[string]string{"X-Baas-User-Id": "svc", "X-Baas-Role": "service_role"}
}

func TestConsentRoutesRequireUser(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{})
	for _, p := range []string{"GET /consents", "POST /consents", "GET /export", "POST /deletion-requests"} {
		parts := strings.SplitN(p, " ", 2)
		rec := do(svc, parts[0], parts[1], `{}`, nil)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without identity = %d, want 401", p, rec.Code)
		}
	}
}

func TestSetConsentValidationAndCreate(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{})
	// missing consented → 400
	rec := do(svc, "POST", "/consents", `{"consent_type":"marketing"}`, userHdr())
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("missing consented = %d, want 400", rec.Code)
	}
	// valid → 201
	f := &fakeRepo{}
	svc, _ = newSvc(f)
	rec = do(svc, "POST", "/consents", `{"consent_type":"marketing","consented":true}`, userHdr())
	if rec.Code != http.StatusCreated || !f.lastSetConsent {
		t.Errorf("set consent = %d, consented=%v; want 201/true", rec.Code, f.lastSetConsent)
	}
}

func TestGetConsentReturnsNullWhenMissing(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{consentMissing: true})
	rec := do(svc, "GET", "/consents/marketing", ``, userHdr())
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "null" {
		t.Errorf("missing consent = %d %q, want 200 null", rec.Code, rec.Body.String())
	}
}

func TestUpdateConsentNotFound(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{consentMissing: true})
	rec := do(svc, "PUT", "/consents/marketing", `{"consented":false}`, userHdr())
	if rec.Code != http.StatusNotFound {
		t.Fatalf("update missing consent = %d, want 404", rec.Code)
	}
}

func TestWithdrawNonEssentialRoutesNotToTypeWildcard(t *testing.T) {
	// DELETE /consents/non-essential must hit withdraw (returns {updated:N}),
	// NOT a {type} handler.
	f := &fakeRepo{withdrawn: 4}
	svc, _ := newSvc(f)
	rec := do(svc, "DELETE", "/consents/non-essential", ``, userHdr())
	var resp map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if rec.Code != http.StatusOK || resp["updated"].(float64) != 4 {
		t.Errorf("withdraw = %d %v, want 200 updated=4", rec.Code, resp)
	}
}

func TestExportWrapsWebhookData(t *testing.T) {
	svc, flags := newSvc(&fakeRepo{})
	rec := do(svc, "GET", "/export", ``, userHdr())
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var resp map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp["formatVersion"] != "1.0" || resp["userId"] != "u-1" {
		t.Errorf("export envelope off: %v", resp)
	}
	if resp["data"] == nil || !flags.exported {
		t.Errorf("export must call the webhook and wrap its data: %v", resp)
	}
}

func TestCreateDeletionConflictsWhenPending(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{pending: true})
	rec := do(svc, "POST", "/deletion-requests", `{"reason":"done"}`, userHdr())
	if rec.Code != http.StatusConflict {
		t.Fatalf("pending exists = %d, want 409", rec.Code)
	}
}

func TestCreateDeletionOK(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{pending: false})
	rec := do(svc, "POST", "/deletion-requests", `{"reason":"done"}`, userHdr())
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201", rec.Code)
	}
}

func TestCancelDeletionNotFound(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{delReq: nil})
	rec := do(svc, "DELETE", "/deletion-requests/mine", ``, userHdr())
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cancel with none = %d, want 404", rec.Code)
	}
}

func TestAdminDeletionRequiresServiceRole(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{})
	rec := do(svc, "GET", "/deletion-requests/admin", ``, userHdr())
	if rec.Code != http.StatusForbidden {
		t.Fatalf("admin list as user = %d, want 403", rec.Code)
	}
	rec = do(svc, "GET", "/deletion-requests/admin", ``, adminHdr())
	if rec.Code != http.StatusOK {
		t.Fatalf("admin list as service_role = %d, want 200", rec.Code)
	}
}

// TestProcessCompletedFiresErasureWebhook pins the lifecycle: completing a
// request fires the deletion webhook and persists the new status; an
// already-completed request is rejected 400.
func TestProcessCompletedFiresErasureWebhook(t *testing.T) {
	f := &fakeRepo{delReq: &DeletionRequest{ID: 1, UserID: "u-9", Status: "pending"}}
	svc, flags := newSvc(f)
	rec := do(svc, "POST", "/deletion-requests/admin/1/process",
		`{"status":"completed","admin_note":"anonymised"}`, adminHdr())
	if rec.Code != http.StatusOK {
		t.Fatalf("process = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if !flags.deleted {
		t.Errorf("completing a request must fire the erasure webhook")
	}
	// already completed → 400
	f2 := &fakeRepo{delReq: &DeletionRequest{ID: 1, Status: "completed"}}
	svc2, _ := newSvc(f2)
	rec = do(svc2, "POST", "/deletion-requests/admin/1/process", `{"status":"completed"}`, adminHdr())
	if rec.Code != http.StatusBadRequest {
		t.Errorf("re-complete = %d, want 400", rec.Code)
	}
}

func TestProcessRejectedDoesNotFireWebhook(t *testing.T) {
	f := &fakeRepo{delReq: &DeletionRequest{ID: 1, UserID: "u-9", Status: "pending"}}
	svc, flags := newSvc(f)
	rec := do(svc, "POST", "/deletion-requests/admin/1/process", `{"status":"rejected"}`, adminHdr())
	if rec.Code != http.StatusOK || flags.deleted {
		t.Errorf("rejected = %d, fired=%v; want 200, no webhook", rec.Code, flags.deleted)
	}
}

func TestProcessInvalidStatus(t *testing.T) {
	svc, _ := newSvc(&fakeRepo{delReq: &DeletionRequest{ID: 1, Status: "pending"}})
	rec := do(svc, "POST", "/deletion-requests/admin/1/process", `{"status":"bogus"}`, adminHdr())
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid status = %d, want 400", rec.Code)
	}
}

func TestNameIsGdpr(t *testing.T) {
	if (&Service{}).Name() != "gdpr" {
		t.Errorf("Name() must be %q", "gdpr")
	}
}
