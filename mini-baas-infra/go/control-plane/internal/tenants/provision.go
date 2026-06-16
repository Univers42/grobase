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
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ar.baseURL+"/databases", bytes.NewReader(body))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Baas-Tenant-Id", tenantScope)
	if ar.serviceToken != "" {
		req.Header.Set("X-Service-Token", ar.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)

	resp, err := ar.http.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()

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
		id, _ := ar.findMountID(ctx, tenantScope, m.Name)
		return id, "exists", nil
	default:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		// Redact any DSN the upstream may have echoed back before surfacing it.
		return "", "", fmt.Errorf("adapter-registry %d: %s", resp.StatusCode, shared.RedactDSN(strings.TrimSpace(string(b))))
	}
}

// findMountID resolves an already-registered mount's id by name, tenant-scoped
// (the GET /databases list the same X-Baas-Tenant-Id sees). Best-effort: a
// lookup failure returns "" so the reconcile still reports "exists".
func (ar *AdapterRegistry) findMountID(ctx context.Context, tenantScope, name string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ar.baseURL+"/databases", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("X-Baas-Tenant-Id", tenantScope)
	if ar.serviceToken != "" {
		req.Header.Set("X-Service-Token", ar.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	resp, err := ar.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("list databases: %d", resp.StatusCode)
	}
	var list []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&list); err != nil {
		return "", err
	}
	for _, d := range list {
		if d.Name == name {
			return d.ID, nil
		}
	}
	return "", fmt.Errorf("mount %q not found in list", name)
}

// MountView is one mount row as the self-serve builder surfaces it (no secret
// material — exactly the adapter-registry's public TenantDatabase projection).
type MountView struct {
	ID            string  `json:"id"`
	TenantID      string  `json:"tenant_id"`
	Engine        string  `json:"engine"`
	Name          string  `json:"name"`
	CreatedAt     string  `json:"created_at"`
	LastHealthyAt *string `json:"last_healthy_at"`
}

// listMounts GETs /databases scoped to tenantScope (the SAME X-Baas-Tenant-Id the
// query path uses), returning the caller's OWN mounts only. Cross-tenant
// isolation is by construction: the adapter-registry's GET /databases is RLS-
// scoped to the asserted tenant, so a caller can never list another tenant's
// mounts.
func (ar *AdapterRegistry) listMounts(ctx context.Context, tenantScope string) ([]MountView, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ar.baseURL+"/databases", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Baas-Tenant-Id", tenantScope)
	if ar.serviceToken != "" {
		req.Header.Set("X-Service-Token", ar.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	resp, err := ar.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("list databases: %d: %s", resp.StatusCode, shared.RedactDSN(strings.TrimSpace(string(b))))
	}
	out := make([]MountView, 0)
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

// deleteMount DELETEs a mount by id, CALLER-SCOPED. It calls the adapter-registry's
// caller-scoped delete (DELETE /databases/{id}/self) which binds `AND tenant_id =
// $caller` in the SQL, so a mount UUID is NEVER a bearer capability: tenant A
// cannot delete tenant B's mount even if it guessed the uuid. Returns
// (deleted bool, err). A 404 (no such mount FOR THIS CALLER) maps to deleted=false.
func (ar *AdapterRegistry) deleteMount(ctx context.Context, tenantScope, id string) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, ar.baseURL+"/databases/"+id+"/self", nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("X-Baas-Tenant-Id", tenantScope)
	if ar.serviceToken != "" {
		req.Header.Set("X-Service-Token", ar.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	resp, err := ar.http.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound:
		return false, nil
	default:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return false, fmt.Errorf("delete database: %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
}

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
	body, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dp.baseURL+"/v1/admin/migrate", bytes.NewReader(body))
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
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		// The migrate envelope carries the inline DSN; scrub it from any echo.
		return fmt.Errorf("data-plane migrate %d: %s", resp.StatusCode, shared.RedactDSN(strings.TrimSpace(string(b))))
	}
	return nil
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
	body, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dp.baseURL+"/v1/admin/evict-verify", bytes.NewReader(body))
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
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("data-plane evict-verify %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

// tenantSchema derives the per-tenant schema name for a tenant id, mirroring the
// Rust `DatabaseMount::tenant_schema` sanitization EXACTLY (lowercase, keep
// [a-z0-9_], replace others with '_', trim '_', truncate 50, prefix `tenant_`).
// The two implementations are kept in lockstep by a shared test vector. Returns
// "" if the id sanitizes to empty.
func tenantSchema(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + ('a' - 'A'))
		default:
			b.WriteRune('_')
		}
	}
	frag := strings.Trim(b.String(), "_")
	if frag == "" {
		return ""
	}
	if len(frag) > 50 {
		frag = frag[:50]
	}
	return "tenant_" + frag
}

// Provision reconciles a declarative tenant stack in one idempotent call:
//  1. bootstrap the tenant + first API key + default ABAC role (idempotent);
//  2. register each requested data mount in the adapter-registry, scoped by the
//     tenant SLUG so the api-key query path can resolve it;
//  3. for schema_per_tenant postgres mounts, create the tenant schema.
//
// Re-running is safe: tenant/key/role reuse existing state, mounts report
// "exists", and CREATE SCHEMA IF NOT EXISTS is a no-op. One mount failure does
// not abort the rest — it is reported per-mount.
func (s *Service) Provision(ctx context.Context, req ProvisionRequest) (ProvisionResponse, error) {
	name := req.Name
	if name == "" {
		name = req.Tenant
	}

	bs, err := s.Bootstrap(ctx, req.Tenant, name, BootstrapRequest{
		OwnerUserID:     req.OwnerUserID,
		DefaultRoleName: req.DefaultRoleName,
		DefaultKeyName:  req.DefaultKeyName,
		SeedRoles:       req.SeedRoles,
	})
	if err != nil {
		return ProvisionResponse{}, err
	}

	out := ProvisionResponse{
		Tenant:   bs.Tenant,
		APIKey:   bs.APIKey,
		KeyReuse: bs.KeyReuse,
		Created:  bs.Created,
		Roles:    bs.Roles,
		Mounts:   make([]MountResult, 0, len(req.Mounts)),
	}

	for _, m := range req.Mounts {
		out.Mounts = append(out.Mounts, s.reconcileMount(ctx, req.Tenant, m))
	}
	return out, nil
}

// reconcileMount registers one mount (slug-scoped) and, for schema_per_tenant
// postgres mounts, ensures the tenant schema exists.
func (s *Service) reconcileMount(ctx context.Context, slug string, m MountSpec) MountResult {
	res := MountResult{Engine: m.Engine, Name: m.Name}
	if s.adapter == nil {
		res.Status = "error"
		res.Error = "adapter-registry not configured (set ADAPTER_REGISTRY_URL)"
		return res
	}

	id, status, err := s.adapter.register(ctx, slug, m)
	if err != nil {
		res.Status = "error"
		res.Error = err.Error()
		s.log.Warn("provision mount register failed", "tenant", slug, "engine", m.Engine, "name", m.Name, "err", err)
		return res
	}
	res.Status = status
	res.ID = id

	if !strings.EqualFold(m.Isolation, "schema_per_tenant") {
		return res
	}
	if m.Engine != "postgresql" {
		res.Error = "schema_per_tenant is only supported for postgresql mounts"
		return res
	}
	schema := tenantSchema(slug)
	switch {
	case schema == "":
		res.Error = "tenant slug sanitizes to an empty schema name"
	case s.dataPlane == nil:
		res.Error = "data-plane not configured (set RUST_DATA_PLANE_URL); schema not created"
	default:
		if serr := s.dataPlane.ensureSchema(ctx, slug, schema, m); serr != nil {
			res.Error = "mount registered but schema create failed: " + serr.Error()
			s.log.Warn("provision schema create failed", "tenant", slug, "schema", schema, "err", serr)
		} else {
			res.Schema = schema
		}
	}
	return res
}
