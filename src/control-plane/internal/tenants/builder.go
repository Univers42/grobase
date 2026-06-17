package tenants

import (
	"context"
	"net/http"

	ent "github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// builderAPI is the DYNAMIC BUILDER control surface (BUILDER_ENABLED). It gives a
// TENANT a self-serve way to COMPOSE its own backend — N mounts of any allowed
// engine, a narrowed custom entitlement, a preview of the effective package — all
// WITHIN a CEILING, and gives an OPERATOR an admin way to mint a custom
// entitlement + raise a per-tenant ceiling (a sales deal) without a rebuild.
//
// CEILING = PRIVILEGE BOUNDARY, enforced at TWO points:
//   - ValidateWithin at COMPOSE time (PATCH /me/entitlements → clean 403).
//   - Clamp at RESOLVE time (every adapter-registry /connect + quota evaluation),
//     the BACKSTOP that a stale over-ceiling row is clamped DOWN, never trusted.
//
// SELF-SERVE has NO path id — the tenant is resolved from the caller credential
// (reusing selfServe.selfAuth), so cross-tenant access is impossible by
// construction. The OPERATOR routes carry an {id} but require the control-plane
// SERVICE TOKEN (the operator is the ceiling authority and bypasses the
// self-serve clamp on WRITE — the resolve-time Clamp still applies on READ).
//
// FLAG-GATED OFF = PARITY: MountBuilder is called ONLY when BUILDER_ENABLED is
// truthy (main.go gates it, AND it requires TENANT_SELFSERVE_ENABLED for the
// self-auth surface). When OFF the routes do not exist (404), the
// tenant_entitlements table is empty/unread, and resolution is manifest.For
// verbatim — byte-identical to today.
type builderAPI struct {
	ss       *selfServe         // reuses selfAuth / requireScope / handleLookup
	store    *ent.Store         // writes/reads public.tenant_entitlements
	manifest *packages.Manifest // ceiling lookup + plan validation
	adapter  *AdapterRegistry   // mount CRUD client (wraps the adapter-registry)
	svcToken string             // operator routes require the service token
}

// MountBuilder registers the dynamic-builder routes. tenant-control invokes this
// ONLY under BUILDER_ENABLED (+ TENANT_SELFSERVE_ENABLED for selfAuth). The
// self-serve struct is built the same way MountSelfServe builds it (so selfAuth
// behaves identically); the operator routes are service-token gated.
//
// adapter may be nil (ADAPTER_REGISTRY_URL unset): the entitlement routes still
// work, but the mount routes return a clean 503 (the builder cannot register a
// mount without the adapter-registry).
func MountBuilder(mux *http.ServeMux, svc *Service, jwt *JWTVerifier, store *ent.Store,
	manifest *packages.Manifest, adapter *AdapterRegistry, serviceToken string) {
	b := &builderAPI{
		ss:       &selfServe{svc: svc, jwt: jwt, manifest: manifest},
		store:    store,
		manifest: manifest,
		adapter:  adapter,
		svcToken: serviceToken,
	}

	// ── TENANT self-serve (no path id; tenant from credential) ──────────────────
	mux.HandleFunc("POST /v1/tenants/me/mounts", b.createMount)
	mux.HandleFunc("GET /v1/tenants/me/mounts", b.listMounts)
	mux.HandleFunc("DELETE /v1/tenants/me/mounts/{mountId}", b.deleteMount)
	mux.HandleFunc("GET /v1/tenants/me/entitlements", b.getEntitlements)
	mux.HandleFunc("PATCH /v1/tenants/me/entitlements", b.patchEntitlements)
	mux.HandleFunc("POST /v1/tenants/me/builder", b.preview)

	// ── OPERATOR admin (path id; service-token; ceiling authority) ──────────────
	mux.HandleFunc("PATCH /v1/tenants/{id}/ceiling", b.operatorSetCeiling)
	mux.HandleFunc("PUT /v1/tenants/{id}/entitlement", b.operatorUpsertEntitlement)
}

// ceilingFor resolves a tenant's CEILING package: the operator ceiling_plan when
// set on the stored row, else the tenant's own plan. Returns the ceiling package
// + the ceiling plan name. A missing row uses the tenant's plan (the parity
// ceiling). The manifest's For() applies the alias/default chain.
func (b *builderAPI) ceilingFor(ctx context.Context, slug, plan string) (packages.Package, string) {
	ceilingPlan := plan
	if rec, err := b.store.Load(ctx, slug); err == nil && rec.CeilingPlan != "" {
		ceilingPlan = rec.CeilingPlan
	}
	name, pkg := b.manifest.For(ceilingPlan)
	return pkg, name
}

// validServiceToken gates the operator routes (constant-time compare).
func (b *builderAPI) validServiceToken(r *http.Request) bool {
	return shared.VerifyServiceRequest(r, b.svcToken)
}

// selfAuthScope resolves the caller's tenant and enforces the named scope in one
// step. ok=false means a 401/403 was already written.
func (b *builderAPI) selfAuthScope(w http.ResponseWriter, r *http.Request, scope string) (string, bool) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return "", false
	}
	if !b.ss.requireScope(w, scopes, scope) {
		return "", false
	}
	return tenantID, true
}
