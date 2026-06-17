package tenants

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// AdapterRegistry is a minimal client for the Go adapter-registry's
// POST /databases. Mounts carry DSNs that the adapter-registry encrypts at rest
// (AES-256-GCM); tenant-control has no crypto, so mount registration must go
// through it. Used by Provision to reconcile a tenant's data mounts.
type AdapterRegistry struct {
	baseURL      string
	serviceToken string
	http         *http.Client
}

// NewAdapterRegistry builds a client. baseURL e.g. http://adapter-registry-go:3021.
func NewAdapterRegistry(baseURL, serviceToken string) *AdapterRegistry {
	return &AdapterRegistry{
		baseURL:      strings.TrimRight(baseURL, "/"),
		serviceToken: serviceToken,
		http:         &http.Client{Timeout: 5 * time.Second},
	}
}

// newRequest builds an adapter-registry request with the canonical tenant-scope
// and service-token headers + context header propagation.
func (ar *AdapterRegistry) newRequest(ctx context.Context, method, path, tenantScope string, body io.Reader) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, ar.baseURL+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Baas-Tenant-Id", tenantScope)
	if ar.serviceToken != "" {
		req.Header.Set("X-Service-Token", ar.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	return req, nil
}

// register POSTs /databases scoped to tenantScope. Returns the new mount id and
// a status of "created" (HTTP 201) or "exists" (HTTP 409, already registered).
//
// IMPORTANT: tenantScope must be the value the *query path* uses to look the
// mount up — the tenant slug (`VerifyKey` returns the slug, the api-key
// middleware sets `x-baas-tenant-id` to it, and the query-router scopes the
// adapter-registry lookup by it). Scoping by anything else would make the mount
// unreachable. We send it as X-Baas-Tenant-Id (the canonical signed header).
func (ar *AdapterRegistry) register(ctx context.Context, tenantScope string, m MountSpec) (id, status string, err error) {
	body, err := json.Marshal(map[string]string{
		"engine":            m.Engine,
		"name":              m.Name,
		"connection_string": m.ConnectionString,
		"isolation":         m.Isolation,
	})
	if err != nil {
		return "", "", err
	}
	req, err := ar.newRequest(ctx, http.MethodPost, "/databases", tenantScope, bytes.NewReader(body))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := ar.http.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	return ar.parseRegisterResp(ctx, resp, tenantScope, m.Name)
}

// parseRegisterResp interprets a POST /databases response: 201 → (id,"created"),
// 409 → recover the existing id by name ("exists", idempotent re-provision), any
// other status → a DSN-redacted error.
func (ar *AdapterRegistry) parseRegisterResp(ctx context.Context, resp *http.Response, tenantScope, name string) (string, string, error) {
	switch resp.StatusCode {
	case http.StatusCreated:
		var out struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return out.ID, "created", nil
	case http.StatusConflict:
		// Idempotency: the mount already exists. Recover its id (by name,
		// tenant-scoped) so a re-provision still returns a usable mount id —
		// without it, every reconcile after the first loses the db_id, which
		// breaks resumable bulk provisioning and re-run scale experiments.
		id, _ := ar.findMountID(ctx, tenantScope, name)
		return id, "exists", nil
	default:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", "", fmt.Errorf("adapter-registry %d: %s", resp.StatusCode, shared.RedactDSN(strings.TrimSpace(string(b))))
	}
}
