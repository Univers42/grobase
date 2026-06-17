package tenants

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

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

// ── helpers ─────────────────────────────────────────────────────────────────

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

// loadOrEmpty returns the stored entitlement record, or a zero record (empty
// entitlement, active) when none exists yet.
func (b *builderAPI) loadOrEmpty(ctx context.Context, slug string) ent.Record {
	rec, err := b.store.Load(ctx, slug)
	if err != nil {
		return ent.Record{TenantID: slug, Status: "active"}
	}
	return rec
}

// validServiceToken gates the operator routes (constant-time compare).
func (b *builderAPI) validServiceToken(r *http.Request) bool {
	return shared.VerifyServiceRequest(r, b.svcToken)
}

// ── TENANT: mounts ────────────────────────────────────────────────────────────

// createMount registers a mount for the CALLER's own tenant via the adapter-
// registry. The engine allowlist + max_mounts cap are enforced DOWNSTREAM by the
// adapter-registry against the EFFECTIVE (resolved+clamped) package — the SAME
// gate /connect uses — so the builder does not re-implement the tier check; it
// just forwards the caller-scoped registration. [scope: write]
func (b *builderAPI) createMount(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !b.ss.requireScope(w, scopes, "write") {
		return
	}
	if b.adapter == nil {
		shared.WriteError(w, http.StatusServiceUnavailable, "adapter_unavailable",
			"mount registration unavailable (ADAPTER_REGISTRY_URL not set)")
		return
	}
	var req MountSpec
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if strings.TrimSpace(req.Engine) == "" || strings.TrimSpace(req.Name) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "engine and name are required")
		return
	}
	id, status, err := b.adapter.register(r.Context(), tenantID, req)
	if err != nil {
		// The adapter-registry maps an over-tier engine / mount-quota to 403; surface
		// its message. A transport/5xx surfaces as 502.
		msg := err.Error()
		if strings.Contains(msg, "403") {
			shared.WriteError(w, http.StatusForbidden, "mount_denied", msg)
			return
		}
		shared.WriteError(w, http.StatusBadGateway, "adapter_error", msg)
		return
	}
	code := http.StatusCreated
	if status == "exists" {
		code = http.StatusOK
	}
	shared.WriteJSON(w, code, map[string]any{"id": id, "status": status, "engine": req.Engine, "name": req.Name})
}

// listMounts returns the caller's OWN mounts (cross-tenant isolation by
// construction — the adapter-registry GET is RLS-scoped to the asserted tenant).
// [scope: read]
func (b *builderAPI) listMounts(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !b.ss.requireScope(w, scopes, "read") {
		return
	}
	if b.adapter == nil {
		shared.WriteError(w, http.StatusServiceUnavailable, "adapter_unavailable",
			"mount listing unavailable (ADAPTER_REGISTRY_URL not set)")
		return
	}
	out, err := b.adapter.listMounts(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusBadGateway, "adapter_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// deleteMount deletes one of the caller's OWN mounts by id, CALLER-SCOPED. The
// adapter-registry's caller-scoped delete binds `AND tenant_id = $caller`, so a
// mount UUID is NEVER a bearer capability — a tenant can never delete another
// tenant's mount even by guessing the uuid. [scope: write]
func (b *builderAPI) deleteMount(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !b.ss.requireScope(w, scopes, "write") {
		return
	}
	if b.adapter == nil {
		shared.WriteError(w, http.StatusServiceUnavailable, "adapter_unavailable",
			"mount deletion unavailable (ADAPTER_REGISTRY_URL not set)")
		return
	}
	deleted, err := b.adapter.deleteMount(r.Context(), tenantID, r.PathValue("mountId"))
	if err != nil {
		shared.WriteError(w, http.StatusBadGateway, "adapter_error", err.Error())
		return
	}
	if !deleted {
		shared.WriteError(w, http.StatusNotFound, "not_found", "no such mount for this tenant")
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

// ── TENANT: entitlements ──────────────────────────────────────────────────────

// entitlementsResponse is the GET /me/entitlements body: the stored custom
// entitlement (or empty), the ceiling, and the effective package preview.
type entitlementsResponse struct {
	TenantID    string                `json:"tenant_id"`
	Plan        string                `json:"plan"`
	CeilingPlan string                `json:"ceiling_plan"`
	Status      string                `json:"status"`
	Custom      ent.CustomEntitlement `json:"custom"`
	Effective   effectiveView         `json:"effective"`
}

// effectiveView is the clamped EFFECTIVE package projected for the tenant — the
// same shape the data plane is stamped with, plus the raw capability_overrides
// mask (the load-bearing artifact a tenant/operator can diff against the tier).
type effectiveView struct {
	Package             string          `json:"package"`
	Engines             []string        `json:"engines"`
	Capabilities        map[string]bool `json:"capabilities"`
	Limits              packages.Limits `json:"limits"`
	MaxMounts           int             `json:"max_mounts"`
	Addons              []string        `json:"addons"`
	SecurityMode        string          `json:"security_mode"`
	CapabilityOverrides map[string]any  `json:"capability_overrides"`
}

// effectiveFor clamps the custom entitlement to the ceiling and projects the
// effective view (the SAME Clamp the resolver applies at /connect time).
func (b *builderAPI) effectiveFor(custom ent.CustomEntitlement, ceiling packages.Package, ceilingName string) effectiveView {
	eff := packages.Clamp(custom.ToPackage(), ceiling)
	return effectiveView{
		Package:             ceilingName,
		Engines:             eff.Engines,
		Capabilities:        eff.Capabilities,
		Limits:              eff.Limits,
		MaxMounts:           eff.PoolPolicy.MaxMounts,
		Addons:              eff.Addons,
		SecurityMode:        eff.SecurityMode,
		CapabilityOverrides: eff.CapabilityOverrides(),
	}
}

// getEntitlements returns the caller's stored custom entitlement + the effective
// (clamped) package. [scope: read]
func (b *builderAPI) getEntitlements(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !b.ss.requireScope(w, scopes, "read") {
		return
	}
	t, err := b.ss.svc.FindOne(r.Context(), tenantID)
	if b.ss.handleLookup(w, err) {
		return
	}
	rec := b.loadOrEmpty(r.Context(), tenantID)
	ceiling, ceilingName := b.ceilingFor(r.Context(), tenantID, t.Plan)
	shared.WriteJSON(w, http.StatusOK, entitlementsResponse{
		TenantID:    tenantID,
		Plan:        t.Plan,
		CeilingPlan: rec.CeilingPlan,
		Status:      rec.Status,
		Custom:      rec.Entitlement,
		Effective:   b.effectiveFor(rec.Entitlement, ceiling, ceilingName),
	})
}

// patchEntitlements is the COMPOSE-time gate. A tenant submits a custom
// entitlement; ValidateWithin checks it against the ceiling and rejects an
// over-ceiling request with 403 entitlement_exceeds_ceiling BEFORE persisting.
// Within-ceiling requests are UPSERT'd. The resolve-time Clamp is still the
// backstop — but this gives the tenant a clean, immediate error. [scope: admin]
func (b *builderAPI) patchEntitlements(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return
	}
	// admin scope: composing the backend is an account-admin action (like PATCH
	// /me {plan}), so a read/write-only key cannot widen the entitlement.
	if !b.ss.requireScope(w, scopes, "admin") {
		return
	}
	var custom ent.CustomEntitlement
	if err := json.NewDecoder(r.Body).Decode(&custom); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	t, err := b.ss.svc.FindOne(r.Context(), tenantID)
	if b.ss.handleLookup(w, err) {
		return
	}
	ceiling, ceilingName := b.ceilingFor(r.Context(), tenantID, t.Plan)

	// COMPOSE-time privilege-boundary gate: a clean 403 naming the offending axis.
	if vErr := packages.ValidateWithin(custom.ToPackage(), ceiling); vErr != nil {
		shared.WriteError(w, http.StatusForbidden, "entitlement_exceeds_ceiling", vErr.Error())
		return
	}

	rec := b.loadOrEmpty(r.Context(), tenantID)
	rec.TenantID = tenantID
	rec.Entitlement = custom
	rec.Status = "active"
	// NOTE: a tenant may NEVER set its own ceiling_plan — that is operator-only.
	// We preserve the operator's ceiling_plan from the loaded row (loadOrEmpty
	// keeps it), and never read a ceiling_plan from the tenant's request body.
	if err := b.store.Upsert(r.Context(), rec); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, entitlementsResponse{
		TenantID:    tenantID,
		Plan:        t.Plan,
		CeilingPlan: rec.CeilingPlan,
		Status:      rec.Status,
		Custom:      rec.Entitlement,
		Effective:   b.effectiveFor(rec.Entitlement, ceiling, ceilingName),
	})
}

// ── TENANT: preview ───────────────────────────────────────────────────────────

// previewRequest is the POST /me/builder body: a hypothetical custom entitlement
// the tenant wants to preview WITHOUT persisting.
type previewRequest struct {
	Entitlement ent.CustomEntitlement `json:"entitlement"`
}

// previewResponse returns the effective (clamped) package + any compose-time
// violations + the mount budget (max_mounts vs how many the tenant already has).
type previewResponse struct {
	TenantID    string        `json:"tenant_id"`
	Plan        string        `json:"plan"`
	CeilingPlan string        `json:"ceiling_plan"`
	Effective   effectiveView `json:"effective"`
	Violations  []string      `json:"violations"`
	MountBudget mountBudget   `json:"mount_budget"`
}

// mountBudget is the registered-vs-allowed mount count for the effective package.
type mountBudget struct {
	Used      int `json:"used"`
	Allowed   int `json:"allowed"`
	Remaining int `json:"remaining"`
}

// preview is a DRY-RUN: it clamps the submitted entitlement to the ceiling and
// returns the effective package, the compose-time violations (what ValidateWithin
// would reject), and the mount budget — WITHOUT writing anything. [scope: read]
func (b *builderAPI) preview(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := b.ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !b.ss.requireScope(w, scopes, "read") {
		return
	}
	var req previewRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	t, err := b.ss.svc.FindOne(r.Context(), tenantID)
	if b.ss.handleLookup(w, err) {
		return
	}
	ceiling, ceilingName := b.ceilingFor(r.Context(), tenantID, t.Plan)
	eff := b.effectiveFor(req.Entitlement, ceiling, ceilingName)

	violations := []string{}
	if vErr := packages.ValidateWithin(req.Entitlement.ToPackage(), ceiling); vErr != nil {
		violations = append(violations, vErr.Error())
	}

	// Mount budget: the effective max_mounts vs how many the tenant already has
	// registered. Best-effort — an adapter outage leaves used=-1 (unknown).
	budget := mountBudget{Allowed: eff.MaxMounts, Used: -1}
	if b.adapter != nil {
		if mounts, lErr := b.adapter.listMounts(r.Context(), tenantID); lErr == nil {
			budget.Used = len(mounts)
			budget.Remaining = eff.MaxMounts - len(mounts)
			if budget.Remaining < 0 {
				budget.Remaining = 0
			}
		}
	}

	shared.WriteJSON(w, http.StatusOK, previewResponse{
		TenantID:    tenantID,
		Plan:        t.Plan,
		CeilingPlan: ceilingName,
		Effective:   eff,
		Violations:  violations,
		MountBudget: budget,
	})
}

// ── OPERATOR: ceiling + entitlement (service-token; ceiling authority) ─────────

// operatorCeilingRequest sets a per-tenant ceiling_plan (a sales deal). The
// operator IS the ceiling authority, so this is NOT clamped to the tenant's plan.
type operatorCeilingRequest struct {
	CeilingPlan string `json:"ceiling_plan"`
}

// operatorSetCeiling raises/sets a tenant's ceiling_plan above its named tier
// (a custom deal). Service-token gated; the operator bypasses the self-serve
// clamp on WRITE. The resolve-time Clamp still applies on READ (so the EFFECTIVE
// package is clamped to THIS ceiling, never higher). [auth: service token]
func (b *builderAPI) operatorSetCeiling(w http.ResponseWriter, r *http.Request) {
	if !b.validServiceToken(r) {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	slug := r.PathValue("id")
	var req operatorCeilingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	ceiling := strings.TrimSpace(req.CeilingPlan)
	if ceiling == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "ceiling_plan is required")
		return
	}
	if !b.knownPlan(ceiling) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error",
			"unknown ceiling_plan "+ceiling+" (not in package manifest)")
		return
	}
	// The tenant must exist (a ceiling on a missing tenant is a no-op trap).
	if _, err := b.ss.svc.FindOne(r.Context(), slug); err != nil {
		if errors.Is(err, ErrNotFound) {
			shared.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
			return
		}
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if err := b.store.SetCeiling(r.Context(), slug, ceiling); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"tenant_id": slug, "ceiling_plan": ceiling})
}

// operatorEntitlementRequest mints a custom entitlement for a tenant WITHOUT the
// self-serve clamp (the operator is the ceiling authority). It may also set the
// ceiling_plan in the same call (the deal + its envelope together).
type operatorEntitlementRequest struct {
	CeilingPlan string                `json:"ceiling_plan"`
	Status      string                `json:"status"`
	Entitlement ent.CustomEntitlement `json:"entitlement"`
}

// operatorUpsertEntitlement mints/replaces a tenant's custom entitlement (+
// optional ceiling_plan) WITHOUT ValidateWithin — the operator may write a row
// the tenant could not. The resolve-time Clamp still bounds the EFFECTIVE package
// to the (operator-set) ceiling, so even the operator's row can never make the
// stamp exceed the ceiling it itself declares. [auth: service token]
func (b *builderAPI) operatorUpsertEntitlement(w http.ResponseWriter, r *http.Request) {
	if !b.validServiceToken(r) {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	slug := r.PathValue("id")
	var req operatorEntitlementRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if _, err := b.ss.svc.FindOne(r.Context(), slug); err != nil {
		if errors.Is(err, ErrNotFound) {
			shared.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
			return
		}
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	ceiling := strings.TrimSpace(req.CeilingPlan)
	if ceiling != "" && !b.knownPlan(ceiling) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error",
			"unknown ceiling_plan "+ceiling+" (not in package manifest)")
		return
	}
	status := strings.TrimSpace(req.Status)
	if status == "" {
		status = "active"
	}
	if status != "active" && status != "draft" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "status must be active or draft")
		return
	}
	rec := ent.Record{
		TenantID:    slug,
		Entitlement: req.Entitlement,
		CeilingPlan: ceiling,
		Status:      status,
	}
	if err := b.store.Upsert(r.Context(), rec); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{
		"tenant_id":    slug,
		"ceiling_plan": ceiling,
		"status":       status,
		"entitlement":  req.Entitlement,
	})
}

// knownPlan reports whether plan is a real manifest tier (direct key or alias),
// mirroring selfServe.knownPlan so an unknown ceiling_plan is rejected rather
// than silently resolving to the default tier.
func (b *builderAPI) knownPlan(plan string) bool {
	if _, ok := b.manifest.Packages[plan]; ok {
		return true
	}
	if alias, ok := b.manifest.Aliases[plan]; ok {
		if _, ok := b.manifest.Packages[alias]; ok {
			return true
		}
	}
	return false
}
