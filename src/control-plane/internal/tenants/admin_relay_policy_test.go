package tenants

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

func TestParseCallerPolicy(t *testing.T) {
	for raw, want := range map[string]CallerPolicy{
		"": CallerPolicyOff, "off": CallerPolicyOff, " Shadow ": CallerPolicyShadow, "ENFORCE": CallerPolicyEnforce,
	} {
		if got, err := ParseCallerPolicy(raw); err != nil || got != want {
			t.Errorf("ParseCallerPolicy(%q) = %v, %v; want %v", raw, got, err, want)
		}
	}
	for _, raw := range []string{"on", "enforced", "1"} {
		if _, err := ParseCallerPolicy(raw); err == nil {
			t.Errorf("ParseCallerPolicy(%q) accepted an unknown value; boot must refuse it", raw)
		}
	}
}

const relayPrevToken = "prev-secret-0b5e"

func signedWith(token string) func(*http.Request) {
	return func(r *http.Request) { serviceauth.SignRequest(r, token, []byte(sdkBody)) }
}

func both(r *http.Request) {
	withServiceSignature(sdkBody)(r)
	withAPIKey(relayKey)(r)
}

// devil D1-P1 (2026-10-30): under enforce the relay's service_token arm is refused,
// the apikey arm still serves (also when both credentials are sent), and the PREV
// token is the same arm. Under shadow the token still serves with one would_deny line.
func TestAdminRelayCallerPolicy(t *testing.T) {
	cases := []struct {
		policy  CallerPolicy
		name    string
		set     func(*http.Request)
		status  int
		denials int
	}{
		{CallerPolicyOff, "token", signedWith(relayToken), http.StatusOK, 0},
		{CallerPolicyOff, "prev", signedWith(relayPrevToken), http.StatusOK, 0},
		{CallerPolicyShadow, "token", signedWith(relayToken), http.StatusOK, 1},
		{CallerPolicyShadow, "prev", signedWith(relayPrevToken), http.StatusOK, 1},
		{CallerPolicyShadow, "apikey", withAPIKey(relayKey), http.StatusOK, 0},
		{CallerPolicyShadow, "both", both, http.StatusOK, 0},
		{CallerPolicyEnforce, "token", signedWith(relayToken), http.StatusUnauthorized, 0},
		{CallerPolicyEnforce, "prev", signedWith(relayPrevToken), http.StatusUnauthorized, 0},
		{CallerPolicyEnforce, "apikey", withAPIKey(relayKey), http.StatusOK, 0},
		{CallerPolicyEnforce, "both", both, http.StatusOK, 0},
	}
	for _, mode := range []string{"", "hmac"} {
		for _, c := range cases {
			t.Run("mode="+mode+"/policy="+c.policy.String()+"/"+c.name, func(t *testing.T) {
				t.Setenv("SERVICE_TOKEN_MODE", mode)
				t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", relayPrevToken)
				stub := &dataPlaneStub{status: http.StatusOK, answer: `{}`}
				var logs bytes.Buffer
				mux := policyRelayMux(NewDataPlane(stub.serve(t).URL, relayToken), c.policy, &logs)
				rec := post(mux, "/v1/admin/migrate", sdkBody, c.set)
				if rec.Code != c.status {
					t.Fatalf("relay = %d %s, want %d", rec.Code, rec.Body.String(), c.status)
				}
				if c.status != http.StatusOK && stub.hits.Load() != 0 {
					t.Errorf("a refused relay reached the data plane %d times", stub.hits.Load())
				}
				if n := strings.Count(logs.String(), adminRelayWouldDeny); n != c.denials {
					t.Errorf("would_deny lines = %d, want %d:\n%s", n, c.denials, logs.String())
				}
				if strings.Contains(logs.String(), relayPrevToken) {
					t.Error("the relay logged a token value")
				}
			})
		}
	}
}

func TestAdminRelayEnforceNamesThePolicy(t *testing.T) {
	stub := &dataPlaneStub{status: http.StatusOK, answer: `{}`}
	mux := policyRelayMux(NewDataPlane(stub.serve(t).URL, relayToken), CallerPolicyEnforce, io.Discard)
	rec := post(mux, "/v1/admin/rotate", sdkBody, withServiceSignature(sdkBody))
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "DATA_PLANE_CALLER_POLICY=enforce") {
		t.Fatalf("enforce refusal = %d %s, want 401 naming the policy", rec.Code, rec.Body.String())
	}
}

func policyRelayMux(dp *DataPlane, policy CallerPolicy, logs io.Writer) *http.ServeMux {
	svc := &Service{log: slog.New(slog.NewTextHandler(logs, nil)), dataPlane: dp}
	mux := http.NewServeMux()
	Mount(mux, Deps{Svc: svc, ServiceToken: relayToken, KongServiceKey: relayKey, CallerPolicy: policy})
	return mux
}
