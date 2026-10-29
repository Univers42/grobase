package tenants

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// verifyingServer answers 200 only when the request passes the same
// serviceauth check the adapter-registry and data plane run on their side.
func verifyingServer(t *testing.T, token string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !serviceauth.VerifyServiceRequest(r, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// In hmac mode the receivers reject a plain X-Service-Token, so every outbound
// call must carry a signature the receiver accepts, in both modes.
func TestOutboundCallsAuthenticateInBothModes(t *testing.T) {
	for _, mode := range []string{"", "hmac"} {
		t.Run("mode="+mode, func(t *testing.T) {
			t.Setenv("SERVICE_TOKEN_MODE", mode)
			ctx := context.Background()

			ar := NewAdapterRegistry(verifyingServer(t, "tok").URL, "tok")
			if deleted, err := ar.deleteMount(ctx, "t-acme", "db1"); err != nil || !deleted {
				t.Fatalf("deleteMount = (%v, %v), want (true, nil)", deleted, err)
			}

			dp := NewDataPlane(verifyingServer(t, "tok").URL, "tok")
			if err := dp.evictVerify(ctx); err != nil {
				t.Fatalf("evictVerify: %v", err)
			}
		})
	}
}
