package tenants

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// adminRelayMaxBody matches Kong's request-size-limiting on /admin/v1/{migrate,rotate}.
// It is enforced before auth because rotation.Accept reads the whole body.
const adminRelayMaxBody = 256 << 10

// adminRelay serves POST /v1/admin/{migrate,rotate} for Kong (G1f, ADR 0008).
// Kong cannot sign, so it forwards here; tenant-control authenticates the
// caller, replaces the caller-declared identity with a service_role one for the
// mount's tenant, and forwards the rest of the body untouched, signed. The
// data plane's status and body are relayed, DSN-redacted.
func (rt *routes) adminRelay(path string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		raw, ok := readBoundedBody(w, r, adminRelayMaxBody)
		if !ok {
			return
		}
		arm := rt.adminRelayCaller(r)
		if arm == "" {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token or service API key required")
			return
		}
		body, tenant, err := withServiceIdentity(raw, arm)
		if err != nil {
			httpx.WriteError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}
		dp := rt.svc.dataPlane
		if dp == nil {
			httpx.WriteError(w, http.StatusServiceUnavailable, "unavailable", "data plane not configured")
			return
		}
		status, resp, err := dp.postSigned(r.Context(), dp.relayHTTP, path, body)
		rt.svc.log.Info("admin relay", "route", path, "arm", arm, "tenant", tenant,
			"migration", migrationName(raw), "status", status)
		if err != nil {
			rt.svc.log.Warn("admin relay: data plane unreachable", "route", path, "err", httpx.RedactDSN(err.Error()))
			httpx.WriteError(w, http.StatusBadGateway, "bad_gateway", "data plane unreachable")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(httpx.RedactDSN(string(resp))))
	}
}

// adminRelayCaller names the credential that authenticated r, or "" when none
// did. The apikey arm exists only on these two routes and only when
// KONG_SERVICE_API_KEY is set; there is deliberately no Bearer arm.
func (rt *routes) adminRelayCaller(r *http.Request) string {
	if rt.rotation.Accept(r, rt.serviceToken) {
		return "service_token"
	}
	if serviceauth.SecureCompare(r.Header.Get("apikey"), rt.kongServiceKey) {
		return "kong_service_key"
	}
	return ""
}

// withServiceIdentity replaces only the "identity" member of the envelope, so
// mount fields this package does not model (isolation, pool_policy,
// replica_inline_dsn, ...) reach the data plane unchanged.
func withServiceIdentity(raw []byte, arm string) ([]byte, string, error) {
	var env map[string]json.RawMessage
	if err := json.Unmarshal(raw, &env); err != nil || env == nil {
		return nil, "", errors.New("body must be a JSON object")
	}
	var mount struct {
		TenantID string `json:"tenant_id"`
	}
	if err := json.Unmarshal(env["mount"], &mount); err != nil || mount.TenantID == "" {
		return nil, "", errors.New("mount.tenant_id is required")
	}
	identity, err := json.Marshal(map[string]any{
		"tenant_id": mount.TenantID,
		"user_id":   "admin-api:" + arm,
		"source":    "service_token",
		"roles":     []string{"service_role"},
	})
	if err != nil {
		return nil, "", err
	}
	env["identity"] = identity
	out, err := json.Marshal(env)
	return out, mount.TenantID, err
}

// migrationName is the envelope's "name" for the audit line; statements are
// never logged.
func migrationName(raw []byte) string {
	var env struct {
		Name string `json:"name"`
	}
	_ = json.Unmarshal(raw, &env)
	return env.Name
}

// readBoundedBody reads at most limit bytes of r's body, writing 413 or 400 and
// returning ok=false on failure. It restores r.Body because a service-token check
// in HMAC mode reads the body again.
func readBoundedBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, bool) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			httpx.WriteError(w, http.StatusRequestEntityTooLarge, "payload_too_large", fmt.Sprintf("body exceeds %d KiB", limit>>10))
			return nil, false
		}
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "unreadable body")
		return nil, false
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	return raw, true
}
