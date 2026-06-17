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

// DataPlane is a minimal client for the Rust data-plane-router's admin migrate
// endpoint, used to create a per-tenant schema for schema_per_tenant mounts.
type DataPlane struct {
	baseURL      string
	serviceToken string
	http         *http.Client
}

// NewDataPlane builds a client. baseURL e.g. http://data-plane-router-rust:4011.
func NewDataPlane(baseURL, serviceToken string) *DataPlane {
	return &DataPlane{
		baseURL:      strings.TrimRight(baseURL, "/"),
		serviceToken: serviceToken,
		http:         &http.Client{Timeout: 8 * time.Second},
	}
}

// ensureSchema runs `CREATE SCHEMA IF NOT EXISTS <schema>` against the mount's
// database via POST /v1/admin/migrate (admin-gated, idempotent marker). `schema`
// must already be sanitized by [tenantSchema] — it is interpolated into the DDL.
func (dp *DataPlane) ensureSchema(ctx context.Context, slug, schema string, m MountSpec) error {
	envelope := map[string]any{
		"identity": map[string]any{
			"tenant_id": slug,
			"user_id":   "provision-control",
			"source":    "service_token",
			"roles":     []string{"service_role"},
		},
		"mount": map[string]any{
			"id":             "provision-" + slug,
			"tenant_id":      slug,
			"engine":         m.Engine,
			"name":           m.Name,
			"credential_ref": map[string]any{"provider": "inline", "reference": m.Name, "version": "1"},
			"inline_dsn":     m.ConnectionString,
		},
		"name":       "baas-ensure-schema-" + schema,
		"statements": []string{"CREATE SCHEMA IF NOT EXISTS " + schema},
	}
	// The migrate envelope carries the inline DSN; scrub it from any echo.
	return dp.postAdmin(ctx, "/v1/admin/migrate", envelope, "data-plane migrate", true)
}

// evictVerify clears the data plane's key-verify cache (B3): without it a
// revoked key keeps authenticating there for up to the cache TTL (~30s).
// Same in-network admin trust model as ensureSchema (body-borne service
// identity). Callers treat failures as best-effort — the TTL still bounds
// the exposure when the data plane is unreachable.
func (dp *DataPlane) evictVerify(ctx context.Context) error {
	envelope := map[string]any{
		"identity": map[string]any{
			"tenant_id": "tenant-control",
			"user_id":   "revoke-control",
			"source":    "service_token",
			"roles":     []string{"service_role"},
		},
	}
	return dp.postAdmin(ctx, "/v1/admin/evict-verify", envelope, "data-plane evict-verify", false)
}

// postAdmin marshals a service-identity envelope and POSTs it to an admin
// endpoint (Content-Type + X-Service-Token + header propagation). A non-200 is
// an error labelled errLabel; redact scrubs any DSN echo from the body.
func (dp *DataPlane) postAdmin(ctx context.Context, path string, envelope map[string]any, errLabel string, redact bool) error {
	body, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dp.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if dp.serviceToken != "" {
		req.Header.Set("X-Service-Token", dp.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	resp, err := dp.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return dataPlaneRespErr(resp, errLabel, redact)
}

// dataPlaneRespErr returns nil on 200, else a labelled error built from a bounded
// body read (DSN-redacted when redact is set).
func dataPlaneRespErr(resp *http.Response, errLabel string, redact bool) error {
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	msg := strings.TrimSpace(string(b))
	if redact {
		msg = shared.RedactDSN(msg)
	}
	return fmt.Errorf("%s %d: %s", errLabel, resp.StatusCode, msg)
}
