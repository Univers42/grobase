package tenants

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

const (
	relayToken = "tok"
	relayKey   = "kong-service-key"
)

// dataPlaneStub stands in for data-plane-router-rust: it refuses unsigned
// requests, records the forwarded body, and answers with status/answer.
type dataPlaneStub struct {
	hits   atomic.Int32
	body   atomic.Value
	status int
	answer string
	delay  time.Duration
}

func (s *dataPlaneStub) serve(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.hits.Add(1)
		if !serviceauth.VerifyServiceRequest(r, relayToken) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		b, _ := io.ReadAll(r.Body)
		s.body.Store(b)
		time.Sleep(s.delay)
		w.WriteHeader(s.status)
		_, _ = io.WriteString(w, s.answer)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func relayMux(dp *DataPlane, kongKey string) *http.ServeMux {
	svc := &Service{log: slog.New(slog.NewTextHandler(io.Discard, nil)), dataPlane: dp}
	mux := http.NewServeMux()
	Mount(mux, Deps{Svc: svc, ServiceToken: relayToken, KongServiceKey: kongKey})
	return mux
}

// sdkBody is the shape sdks/js sends: a caller-declared identity that must not
// survive, and mount fields the Go side does not model that must.
const sdkBody = `{
  "identity": {"tenant_id": "t-other", "user_id": "u1", "source": "jwt", "roles": ["anon"]},
  "mount": {"id": "m1", "tenant_id": "t-acme", "engine": "postgresql", "name": "db",
            "isolation": {"mode": "schema_per_tenant", "schema": "t_acme"},
            "pool_policy": {"max_connections": 3},
            "replica_inline_dsn": "postgres://replica/db",
            "credential_ref": {"provider": "inline", "reference": "db", "version": "2"}},
  "name": "m-001", "statements": ["CREATE TABLE t (id int)"]
}`

func post(mux http.Handler, path, body string, set func(*http.Request)) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if set != nil {
		set(req)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func withAPIKey(key string) func(*http.Request) {
	return func(r *http.Request) { r.Header.Set("apikey", key) }
}

func withServiceSignature(body string) func(*http.Request) {
	return func(r *http.Request) { serviceauth.SignRequest(r, relayToken, []byte(body)) }
}

func TestAdminRelayForwardsSignedWithServiceIdentity(t *testing.T) {
	for _, mode := range []string{"", "hmac"} {
		for arm, set := range map[string]func(*http.Request){
			"kong_service_key": withAPIKey(relayKey),
			"service_token":    withServiceSignature(sdkBody),
		} {
			t.Run("mode="+mode+"/"+arm, func(t *testing.T) {
				t.Setenv("SERVICE_TOKEN_MODE", mode)
				const result = `{"name":"m-001","status":"applied","statements_run":1}`
				stub := &dataPlaneStub{status: http.StatusOK, answer: result}
				rec := post(relayMux(NewDataPlane(stub.serve(t).URL, relayToken), relayKey), "/v1/admin/migrate", sdkBody, set)
				if rec.Code != http.StatusOK || rec.Body.String() != result {
					t.Fatalf("relay = %d %q, want 200 %q", rec.Code, rec.Body.String(), result)
				}
				var got, sent map[string]json.RawMessage
				_ = json.Unmarshal(stub.body.Load().([]byte), &got)
				_ = json.Unmarshal([]byte(sdkBody), &sent)
				var id struct {
					TenantID string   `json:"tenant_id"`
					UserID   string   `json:"user_id"`
					Roles    []string `json:"roles"`
				}
				_ = json.Unmarshal(got["identity"], &id)
				if id.TenantID != "t-acme" || id.UserID != "admin-api:"+arm || len(id.Roles) != 1 || id.Roles[0] != "service_role" {
					t.Errorf("forwarded identity = %+v, want t-acme service_role from %s", id, arm)
				}
				for _, k := range []string{"mount", "name", "statements"} {
					if !jsonEqual(t, got[k], sent[k]) {
						t.Errorf("%s changed in transit: %s -> %s", k, sent[k], got[k])
					}
				}
			})
		}
	}
}

func jsonEqual(t *testing.T, a, b json.RawMessage) bool {
	t.Helper()
	var x, y bytes.Buffer
	if json.Compact(&x, a) != nil || json.Compact(&y, b) != nil {
		return false
	}
	var u, v any
	_ = json.Unmarshal(x.Bytes(), &u)
	_ = json.Unmarshal(y.Bytes(), &v)
	ub, _ := json.Marshal(u)
	vb, _ := json.Marshal(v)
	return bytes.Equal(ub, vb)
}

func TestAdminRelayRotateRelaysTheDrainCount(t *testing.T) {
	const drained = `{"pool_key":"t-acme/m1/2","pools_drained":2}`
	stub := &dataPlaneStub{status: http.StatusOK, answer: drained}
	rec := post(relayMux(NewDataPlane(stub.serve(t).URL, relayToken), relayKey), "/v1/admin/rotate", sdkBody, withAPIKey(relayKey))
	if rec.Code != http.StatusOK || rec.Body.String() != drained {
		t.Fatalf("rotate = %d %q, want 200 %q", rec.Code, rec.Body.String(), drained)
	}
}

func TestAdminRelayRefusesEveryOtherCaller(t *testing.T) {
	stub := &dataPlaneStub{status: http.StatusOK, answer: `{}`}
	dp := NewDataPlane(stub.serve(t).URL, relayToken)
	cases := map[string]struct {
		kongKey string
		set     func(*http.Request)
	}{
		"no credential":  {relayKey, nil},
		"wrong apikey":   {relayKey, withAPIKey("anon-key")},
		"bearer only":    {relayKey, func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+relayKey) }},
		"consumer claim": {relayKey, func(r *http.Request) { r.Header.Set("X-Consumer-Username", "service_role") }},
		"arm off":        {"", withAPIKey("")},
		"arm off, key":   {"", withAPIKey(relayKey)},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			if rec := post(relayMux(dp, c.kongKey), "/v1/admin/migrate", sdkBody, c.set); rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", rec.Code)
			}
		})
	}
	if n := stub.hits.Load(); n != 0 {
		t.Fatalf("data plane reached %d times by refused callers", n)
	}
}

// The apikey arm is scoped to the relay: the other service-token routes keep
// refusing a caller that holds only the Kong service key.
func TestKongServiceKeyDoesNotOpenOtherAdminRoutes(t *testing.T) {
	rec := post(relayMux(nil, relayKey), "/v1/provision", `{}`, withAPIKey(relayKey))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("/v1/provision with the Kong key = %d, want 401", rec.Code)
	}
}

func TestAdminRelayRejectsBeforeForwarding(t *testing.T) {
	stub := &dataPlaneStub{status: http.StatusOK, answer: `{}`}
	mux := relayMux(NewDataPlane(stub.serve(t).URL, relayToken), relayKey)
	big := `{"pad":"` + strings.Repeat("a", adminRelayMaxBody) + `"}`
	if rec := post(mux, "/v1/admin/migrate", big, withAPIKey(relayKey)); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized body = %d, want 413", rec.Code)
	}
	for _, body := range []string{`[]`, `{"mount":{}}`, `not json`} {
		if rec := post(mux, "/v1/admin/migrate", body, withAPIKey(relayKey)); rec.Code != http.StatusBadRequest {
			t.Errorf("body %s = %d, want 400", body, rec.Code)
		}
	}
	if n := stub.hits.Load(); n != 0 {
		t.Fatalf("data plane reached %d times by rejected bodies", n)
	}
}

func TestAdminRelayDataPlaneDownOrUnset(t *testing.T) {
	if rec := post(relayMux(nil, relayKey), "/v1/admin/migrate", sdkBody, withAPIKey(relayKey)); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("no data plane = %d, want 503", rec.Code)
	}
	gone := httptest.NewServer(http.NotFoundHandler())
	gone.Close()
	rec := post(relayMux(NewDataPlane(gone.URL, relayToken), relayKey), "/v1/admin/migrate", sdkBody, withAPIKey(relayKey))
	if rec.Code != http.StatusBadGateway || strings.Contains(rec.Body.String(), "127.0.0.1") {
		t.Errorf("unreachable data plane = %d %q, want 502 without the address", rec.Code, rec.Body.String())
	}
}

func TestAdminRelayRedactsDSNOnErrorBodies(t *testing.T) {
	stub := &dataPlaneStub{
		status: http.StatusBadGateway,
		answer: `{"error":"connect postgres://app:s3cret@db/app failed; host=db password=s3cret"}`,
	}
	rec := post(relayMux(NewDataPlane(stub.serve(t).URL, relayToken), relayKey), "/v1/admin/migrate", sdkBody, withAPIKey(relayKey))
	if rec.Code != http.StatusBadGateway || strings.Contains(rec.Body.String(), "s3cret") {
		t.Fatalf("relay = %d %q, want 502 with the password redacted", rec.Code, rec.Body.String())
	}
}

// A migration slower than the 8 s provisioning client still answers through
// the relay: the relay uses its own client, sized past Kong's 60 s read timeout.
func TestAdminRelayOutlivesTheProvisioningTimeout(t *testing.T) {
	if adminRelayTimeout < 60*time.Second {
		t.Fatalf("adminRelayTimeout = %s, must cover Kong's 60 s upstream read timeout", adminRelayTimeout)
	}
	stub := &dataPlaneStub{status: http.StatusOK, answer: `{}`, delay: 50 * time.Millisecond}
	dp := NewDataPlane(stub.serve(t).URL, relayToken)
	dp.http.Timeout = time.Millisecond
	if rec := post(relayMux(dp, relayKey), "/v1/admin/migrate", sdkBody, withAPIKey(relayKey)); rec.Code != http.StatusOK {
		t.Fatalf("slow migration = %d, want 200", rec.Code)
	}
}
