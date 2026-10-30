package tenants

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// registryRelayPrefix is where Kong's /admin/v1 route lands on tenant-control
// (kong.yml admin-adapters); the rest of the path is the registry's own.
const registryRelayPrefix = "/v1/admin/registry"

// registryRelayMaxBody matches Kong's request-size-limiting on /admin/v1.
const registryRelayMaxBody = 64 << 10

// Caveat: a registry answer above 8 MiB (a list of roughly 15k mounts) is cut and
// relayed as a 502; raise the cap if one tenant ever holds that many.
const registryRelayMaxAnswer = 8 << 20

var errAnswerTooLarge = errors.New("adapter registry answer exceeds 8 MiB")

// registryRelayRoutes maps each relayed pattern to callerOnly: true means the relay
// never signs it, false means it signs for an apikey-only caller. The signed four
// are the routes Kong could reach before the registry required service auth (devil
// D2 N3); connect, PATCH and DELETE always needed the caller's own signature, so
// they are forwarded unsigned and the registry keeps refusing an apikey-only caller
// exactly as before.
var registryRelayRoutes = map[string]bool{
	"POST /databases":                false,
	"GET /databases":                 false,
	"GET /databases/{id}":            false,
	"GET /databases/{id}/descriptor": false,
	"GET /databases/{id}/connect":    true,
	"PATCH /databases/{id}":          true,
	"DELETE /databases/{id}":         true,
	"DELETE /databases/{id}/self":    true,
}

// registryRelayHeaders reach the registry from the caller; apikey and Kong's
// consumer headers never do.
var registryRelayHeaders = []string{
	"Content-Type", "X-Baas-Tenant-Id", "X-Baas-User-Id", "X-User-Id", "X-Tenant-Id",
	"X-Baas-Identity-Auth",
}

// callerServiceHeaders are the caller's own service credentials; when present they
// travel untouched and the registry verifies them over the path it sees.
var callerServiceHeaders = []string{"X-Service-Auth", "X-Service-Token"}

// mountRegistryRelay registers the relay for every pattern in registryRelayRoutes.
func (rt *routes) mountRegistryRelay(mux *http.ServeMux) {
	for pattern, callerOnly := range registryRelayRoutes {
		method, path, _ := strings.Cut(pattern, " ")
		mux.HandleFunc(method+" "+registryRelayPrefix+path, rt.registryRelay(callerOnly))
	}
}

// registryRelay forwards one Kong call to the adapter-registry. A caller that brought
// its own service auth is forwarded as is; otherwise the caller must hold the Kong
// service apikey, and the relay signs the call unless callerOnly.
// Caveat: the relay inherits the registry client's 5 s timeout, so a registry call
// slower than that is a 502 where Kong's direct route allowed 60 s.
func (rt *routes) registryRelay(callerOnly bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		raw, ok := readBoundedBody(w, r, registryRelayMaxBody)
		if !ok {
			return
		}
		arm := registryRelayArm(r, rt.kongServiceKey)
		if arm == "" {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token or service API key required")
			return
		}
		ar := rt.svc.AdapterClient()
		if ar == nil {
			httpx.WriteError(w, http.StatusServiceUnavailable, "unavailable", "adapter registry not configured")
			return
		}
		sign := arm == "kong_service_key" && !callerOnly
		path := strings.TrimPrefix(r.URL.EscapedPath(), registryRelayPrefix)
		status, resp, err := ar.relay(r, path, raw, sign)
		rt.svc.log.Info("registry relay", "route", r.Pattern, "arm", arm, "signed", sign, "status", status)
		if err != nil {
			rt.svc.log.Warn("registry relay: adapter registry unreachable", "route", r.Pattern, "err", httpx.RedactDSN(err.Error()))
			httpx.WriteError(w, http.StatusBadGateway, "bad_gateway", "adapter registry unreachable")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(httpx.RedactDSN(string(resp))))
	}
}

// registryRelayArm names how the caller authenticated to the relay, or "".
func registryRelayArm(r *http.Request, kongServiceKey string) string {
	for _, h := range callerServiceHeaders {
		if r.Header.Get(h) != "" {
			return "caller_signed"
		}
	}
	if serviceauth.SecureCompare(r.Header.Get("apikey"), kongServiceKey) {
		return "kong_service_key"
	}
	return ""
}

// relay sends one call to the registry, copying only registryRelayHeaders and, when
// the relay does not sign, the caller's own service credentials.
func (ar *AdapterRegistry) relay(in *http.Request, path string, body []byte, sign bool) (int, []byte, error) {
	ctx := in.Context()
	out, err := http.NewRequestWithContext(ctx, in.Method, ar.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	out.URL.RawQuery = in.URL.RawQuery
	copyHeaders(out, in, registryRelayHeaders)
	if sign {
		serviceauth.SignRequest(out, ar.serviceToken, body)
	} else {
		copyHeaders(out, in, callerServiceHeaders)
	}
	observability.PropagateHeaders(ctx, out)
	resp, err := ar.http.Do(out)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	answer, err := io.ReadAll(io.LimitReader(resp.Body, registryRelayMaxAnswer+1))
	if err == nil && len(answer) > registryRelayMaxAnswer {
		err = errAnswerTooLarge
	}
	return resp.StatusCode, answer, err
}

func copyHeaders(out, in *http.Request, names []string) {
	for _, h := range names {
		if v := in.Header.Get(h); v != "" {
			out.Header.Set(h, v)
		}
	}
}
