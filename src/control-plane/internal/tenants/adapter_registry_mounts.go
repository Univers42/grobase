package tenants

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

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

// findMountID resolves an already-registered mount's id by name, tenant-scoped
// (the GET /databases list the same X-Baas-Tenant-Id sees). Best-effort: a
// lookup failure returns "" so the reconcile still reports "exists".
func (ar *AdapterRegistry) findMountID(ctx context.Context, tenantScope, name string) (string, error) {
	req, err := ar.newRequest(ctx, http.MethodGet, "/databases", tenantScope, nil)
	if err != nil {
		return "", err
	}
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

// listMounts GETs /databases scoped to tenantScope (the SAME X-Baas-Tenant-Id the
// query path uses), returning the caller's OWN mounts only. Cross-tenant
// isolation is by construction: the adapter-registry's GET /databases is RLS-
// scoped to the asserted tenant, so a caller can never list another tenant's
// mounts.
func (ar *AdapterRegistry) listMounts(ctx context.Context, tenantScope string) ([]MountView, error) {
	req, err := ar.newRequest(ctx, http.MethodGet, "/databases", tenantScope, nil)
	if err != nil {
		return nil, err
	}
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
	req, err := ar.newRequest(ctx, http.MethodDelete, "/databases/"+id+"/self", tenantScope, nil)
	if err != nil {
		return false, err
	}
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
