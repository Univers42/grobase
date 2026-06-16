package tenants

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// selfServe holds the dependencies for the tenant self-service API (B4a).
//
// A caller authenticated AS a tenant — via a tenant API key (X-API-Key /
// `Authorization: Bearer mbk_...`) OR a GoTrue user JWT — operates on its OWN
// tenant through `/v1/tenants/me*`. There is NO path id, so cross-tenant access
// is impossible by construction: every handler resolves the caller's tenant id
// from the credential and binds it into the service call. The slug a key/JWT
// resolves to is the ONLY tenant a request can ever touch.
//
// FLAG-GATED OFF = PARITY: MountSelfServe is called only when
// TENANT_SELFSERVE_ENABLED is truthy. When OFF, none of the /me routes are
// registered, so a request to them 404s exactly as it does today (byte-parity
// with the live baseline — no new path exists).
type selfServe struct {
	svc      *Service
	jwt      *JWTVerifier
	manifest *packages.Manifest
	// billing reports whether BILLING_ENABLED is set; when true a plan PATCH also
	// updates public.tenant_billing.plan. The live Stripe subscription change is a
	// SEPARATE flag-gated step (see PATCH handler TODO) — NOT in B4a.
	billing bool
}

// MountSelfServe registers the six self-service routes onto the shared mux. It is
// the caller's responsibility to invoke this ONLY when TENANT_SELFSERVE_ENABLED
// is truthy (main.go gates it) — when the flag is OFF this function is never
// called and the /me routes do not exist (404 = parity).
//
// jwt may be nil (no GOTRUE_JWT_SECRET): JWT-bearer self-auth then fails 401,
// but API-key self-auth still works. The static "me" paths are registered
// alongside the existing "me/bootstrap" route; net/http's most-specific-pattern
// precedence keeps them disjoint from the parameterised {id} routes.
func MountSelfServe(mux *http.ServeMux, svc *Service, jwt *JWTVerifier, manifest *packages.Manifest, billing bool) {
	ss := &selfServe{svc: svc, jwt: jwt, manifest: manifest, billing: billing}

	mux.HandleFunc("GET /v1/tenants/me", ss.me)
	mux.HandleFunc("GET /v1/tenants/me/usage", ss.meUsage)
	mux.HandleFunc("GET /v1/tenants/me/keys", ss.listKeys)
	mux.HandleFunc("POST /v1/tenants/me/keys", ss.issueKey)
	mux.HandleFunc("DELETE /v1/tenants/me/keys/{keyId}", ss.revokeKey)
	mux.HandleFunc("PATCH /v1/tenants/me", ss.patch)
}

// selfAuth resolves the caller's OWN tenant from its credential. It tries, in
// order:
//  1. a tenant API key — X-API-Key, or `Authorization: Bearer mbk_...` —
//     verified via Service.VerifyKey, yielding {TenantID (slug), Scopes}.
//  2. a GoTrue user JWT — `Authorization: Bearer <jwt>` — verified via
//     JWTVerifier.Verify, then owner_user_id → tenant resolved. A JWT grants
//     full self-management scopes (the user owns the tenant), so writes are
//     allowed; an API key is constrained by its own scopes.
//
// On any failure it writes a 401 and returns ok=false. The returned tenantID is
// the canonical SLUG (what every downstream Service method keys on).
func (ss *selfServe) selfAuth(w http.ResponseWriter, r *http.Request) (tenantID string, scopes []string, ok bool) {
	if raw := apiKeyFromRequest(r); raw != "" {
		out, err := ss.svc.VerifyKey(r.Context(), raw)
		if err != nil {
			shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return "", nil, false
		}
		if !out.Valid {
			shared.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
			return "", nil, false
		}
		return out.TenantID, out.Scopes, true
	}

	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth != "" {
		if ss.jwt == nil {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
				"JWT self-auth not configured (no GOTRUE_JWT_SECRET); use an API key")
			return "", nil, false
		}
		identity, err := ss.jwt.Verify(auth)
		if err != nil {
			shared.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
			return "", nil, false
		}
		// owner_user_id -> tenant, RESOLVE-ONLY. A /me request must never have a
		// write side effect: tenant creation is the explicit job of
		// POST /v1/tenants/me/bootstrap, so a JWT for a user who owns no tenant yet
		// gets a 404 here (not a silently-provisioned tenant). A JWT-authenticated
		// user is the tenant OWNER, so once resolved it gets full self-management
		// scopes.
		t, err := ss.svc.findForUser(r.Context(), identity.UserID)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				shared.WriteError(w, http.StatusNotFound, "no_tenant",
					"no tenant for this user yet — POST /v1/tenants/me/bootstrap to create one")
				return "", nil, false
			}
			shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return "", nil, false
		}
		return t.ID, []string{"read", "write", "admin"}, true
	}

	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"X-API-Key, Authorization: Bearer <api-key>, or Authorization: Bearer <jwt> required")
	return "", nil, false
}

// apiKeyFromRequest extracts a tenant API key from X-API-Key or from an
// `Authorization: Bearer mbk_...` header (the project key prefix). A JWT Bearer
// (no mbk_ prefix) is left for the JWT path, so the two credential types never
// collide on the same header.
func apiKeyFromRequest(r *http.Request) string {
	if k := strings.TrimSpace(r.Header.Get("X-API-Key")); k != "" {
		return k
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if rest, ok := cutBearer(auth); ok && strings.HasPrefix(rest, "mbk_") {
		return rest
	}
	return ""
}

// cutBearer strips a case-insensitive "Bearer " prefix, returning the remainder
// and whether the prefix was present.
func cutBearer(auth string) (string, bool) {
	const p = "bearer "
	if len(auth) >= len(p) && strings.EqualFold(auth[:len(p)], p) {
		return strings.TrimSpace(auth[len(p):]), true
	}
	return "", false
}

// hasScope reports whether the credential carries the named scope, treating
// "admin" as a superset (an admin key may do anything a write/read key may).
func hasScope(scopes []string, want string) bool {
	for _, s := range scopes {
		if s == want || s == "admin" {
			return true
		}
	}
	return false
}

// scopesWithinCaller resolves the EFFECTIVE scopes a caller is asking to grant a
// new key (an empty request defaults to the service's {read,write}) and reports
// whether every one is a scope the caller itself holds (admin is a superset). It
// is the scope-containment guard that prevents a within-tenant privilege
// escalation — a write-only key requesting {admin}. Returns the effective scope
// set so the handler can pass it explicitly (no re-defaulting in the service).
func scopesWithinCaller(requested, held []string) ([]string, bool) {
	eff := requested
	if len(eff) == 0 {
		eff = []string{"read", "write"}
	}
	for _, s := range eff {
		if !hasScope(held, s) {
			return nil, false
		}
	}
	return eff, true
}

// requireScope enforces a write/admin scope, writing 403 and returning false on
// a read-only credential.
func (ss *selfServe) requireScope(w http.ResponseWriter, scopes []string, want string) bool {
	if hasScope(scopes, want) {
		return true
	}
	shared.WriteError(w, http.StatusForbidden, "forbidden",
		"this credential lacks the required scope: "+want)
	return false
}

// MeResponse is the GET /v1/tenants/me body: the caller's tenant summary plus
// the resolved tier entitlements (engines / capabilities / limits / quota).
type MeResponse struct {
	Tenant       meTenant     `json:"tenant"`
	Entitlements entitlements `json:"entitlements"`
}

type meTenant struct {
	// ID is the slug — the identifier every service method keys on, matching the
	// existing /v1/tenants/{id} JSON convention (id=slug). The internal UUID is
	// surfaced separately as uuid (also matching the existing Tenant projection).
	ID     string `json:"id"`
	UUID   string `json:"uuid"`
	Slug   string `json:"slug"`
	Name   string `json:"name"`
	Plan   string `json:"plan"`
	Status string `json:"status"`
}

// entitlements is the tier's resolved offer surface, derived from the package
// manifest (config/packages/packages.json) — the single source of truth.
type entitlements struct {
	Package      string          `json:"package"`
	Engines      []string        `json:"engines"`
	Capabilities map[string]bool `json:"capabilities"`
	Limits       packages.Limits `json:"limits"`
	Quota        *packages.Quota `json:"quota,omitempty"`
}

// me returns the caller's own tenant + entitlements.
func (ss *selfServe) me(w http.ResponseWriter, r *http.Request) {
	tenantID, _, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	t, err := ss.svc.FindOne(r.Context(), tenantID)
	if ss.handleLookup(w, err) {
		return
	}
	pkgName, pkg := ss.manifest.For(t.Plan)
	resp := MeResponse{
		Tenant: meTenant{ID: t.ID, UUID: t.UUID, Slug: t.ID, Name: t.Name, Plan: t.Plan, Status: t.Status},
		Entitlements: entitlements{
			Package:      pkgName,
			Engines:      pkg.Engines,
			Capabilities: pkg.Capabilities,
			Limits:       pkg.Limits,
			Quota:        pkg.Limits.Quota,
		},
	}
	shared.WriteJSON(w, http.StatusOK, resp)
}

// meUsage sums the caller's own tenant_usage over an optional [from,to) window.
// It runs the SAME aggregation SQL as the B1c read-back endpoint
// (GET /v1/tenants/{id}/usage) so the numbers are byte-identical — the metering
// Reader has no exported constructor (unexported db field), so the query is
// replicated here over Service's admin pool rather than reaching into the other
// package. Isolation is enforced TWICE: the tenant id comes from the credential
// (never the request), and the SQL always binds tenant_id (defense-in-depth atop
// the RLS policy on public.tenant_usage).
func (ss *selfServe) meUsage(w http.ResponseWriter, r *http.Request) {
	tenantID, _, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	metric := strings.TrimSpace(q.Get("metric"))
	from, fok := parseTimeParam(w, q.Get("from"), "from")
	if !fok {
		return
	}
	to, tok := parseTimeParam(w, q.Get("to"), "to")
	if !tok {
		return
	}
	out, err := ss.svc.aggregateUsage(r.Context(), tenantID, metric, from, to)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// listKeys returns the caller's own keys, redacted (no secret). [scope: read]
func (ss *selfServe) listKeys(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "read") {
		return
	}
	out, err := ss.svc.ListKeys(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// issueKey mints a new key for the caller's own tenant; the full secret is
// returned ONCE. [scope: write or admin]
func (ss *selfServe) issueKey(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "write") {
		return
	}
	var req IssueKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	// Scope containment: a caller may never mint a key broader than its own
	// credential. Without this a `write`-only key could issue an `admin` key (the
	// write gate above is satisfied) and thereby reach admin-only operations like
	// PATCH /me {plan} — a within-tenant privilege escalation. We resolve the
	// effective scopes (mirroring the service's empty->{read,write} default) and
	// reject any the caller does not hold (admin is a superset).
	eff, ok := scopesWithinCaller(req.Scopes, scopes)
	if !ok {
		shared.WriteError(w, http.StatusForbidden, "forbidden",
			"cannot issue a key with scopes broader than your own credential")
		return
	}
	req.Scopes = eff
	out, err := ss.svc.IssueKey(r.Context(), tenantID, req)
	if err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, out)
}

// revokeKey revokes one of the caller's own keys by id. The RevokeKey SQL binds
// BOTH the key id AND the tenant slug, so a caller can never revoke another
// tenant's key even if it guessed the uuid. [scope: write or admin]
func (ss *selfServe) revokeKey(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "write") {
		return
	}
	if ss.handleLookup(w, ss.svc.RevokeKey(r.Context(), tenantID, r.PathValue("keyId"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

// patchRequest is the PATCH /v1/tenants/me body. Only `plan` is self-service;
// name/status/metadata are admin-only and deliberately NOT exposed here.
type patchRequest struct {
	Plan string `json:"plan"`
}

// patch changes the caller's own plan to another manifest tier. [scope: admin]
//
// The new plan must exist in the package manifest (a direct package key OR a
// legacy alias) — an unknown plan is a 400 rather than a silent downgrade. When
// BILLING_ENABLED is set we also reflect the new plan into
// public.tenant_billing.plan so the billing map stays consistent.
func (ss *selfServe) patch(w http.ResponseWriter, r *http.Request) {
	tenantID, scopes, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	if !ss.requireScope(w, scopes, "admin") {
		return
	}
	var req patchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	plan := strings.TrimSpace(req.Plan)
	if plan == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "plan is required")
		return
	}
	// Validate against the manifest. For() falls back to the default package for
	// an unknown plan, so we must check membership EXPLICITLY (direct key or a
	// legacy alias) instead of trusting For() to reject — otherwise "garbage"
	// would silently resolve to the default tier.
	if !ss.knownPlan(plan) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error",
			"unknown plan "+plan+" (not in package manifest)")
		return
	}

	t, err := ss.svc.Update(r.Context(), tenantID, UpdateTenantRequest{Plan: &plan})
	if ss.handleLookup(w, err) {
		return
	}

	if ss.billing {
		// Keep the billing map's plan column in sync. Best-effort: a failure here
		// does not roll back the tenant plan change (the tenants row is the source
		// of truth for entitlements); it is logged via the service logger.
		//
		// TODO(B4b): the LIVE Stripe subscription update (swapping the customer's
		// subscription item to the new price) is a SEPARATE flag-gated step and is
		// intentionally NOT performed here in B4a — this only updates the local
		// tenant->plan map; no external Stripe call is made.
		if err := ss.svc.updateBillingPlan(r.Context(), tenantID, plan); err != nil {
			ss.svc.log.Warn("tenant_billing plan sync failed (continuing)", "tenant", tenantID, "err", err)
		}
	}

	pkgName, _ := ss.manifest.For(t.Plan)
	shared.WriteJSON(w, http.StatusOK, map[string]any{
		"tenant":  meTenant{ID: t.ID, UUID: t.UUID, Slug: t.ID, Name: t.Name, Plan: t.Plan, Status: t.Status},
		"package": pkgName,
	})
}

// knownPlan reports whether plan is a real manifest tier (direct package key or
// a legacy alias) — used to reject an unknown plan instead of letting For()
// silently fall back to the default package.
func (ss *selfServe) knownPlan(plan string) bool {
	if _, ok := ss.manifest.Packages[plan]; ok {
		return true
	}
	if alias, ok := ss.manifest.Aliases[plan]; ok {
		if _, ok := ss.manifest.Packages[alias]; ok {
			return true
		}
	}
	return false
}

// handleLookup maps a service lookup error to the right status, mirroring
// routes.handleLookup so the /me surface returns the same error shapes.
func (ss *selfServe) handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "tenant not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}

// parseTimeParam parses an optional ?from / ?to window bound. Empty = the zero
// time (an unbounded side). A present value is accepted as RFC3339 OR a unix-ms
// integer; anything else is a 400 — mirrors metering.parseWindowBound so the
// /me/usage filter behaves identically to the B1c {id}/usage filter.
func parseTimeParam(w http.ResponseWriter, raw, field string) (time.Time, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}, true
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t.UTC(), true
	}
	if ms, err := strconv.ParseInt(raw, 10, 64); err == nil && ms >= 0 {
		return time.UnixMilli(ms).UTC(), true
	}
	shared.WriteError(w, http.StatusBadRequest, "validation_error",
		"invalid "+field+": want RFC3339 or unix-ms")
	return time.Time{}, false
}

// MetricAgg is one metric's summed usage over the selected window (mirrors
// metering.MetricAgg so the /me/usage body is shape-identical to {id}/usage).
type MetricAgg struct {
	Metric      string `json:"metric"`
	Qty         int64  `json:"qty"`
	WindowCount int64  `json:"window_count"`
}

// UsageWindow echoes the resolved [from,to) bounds (RFC3339, "" = unbounded).
type UsageWindow struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// UsageResponse is the body of GET /v1/tenants/me/usage (shape-identical to
// metering.UsageResponse).
type UsageResponse struct {
	TenantID string      `json:"tenant_id"`
	Window   UsageWindow `json:"window"`
	Metrics  []MetricAgg `json:"metrics"`
	TotalQty int64       `json:"total_qty"`
}

// usageAggregateSQL is byte-identical to metering.aggregateSQL: $1 tenant_id is
// ALWAYS bound (defense-in-depth atop RLS); metric/from/to are nullable filters
// over a half-open [from,to) window.
const usageAggregateSQL = `
SELECT metric, COALESCE(SUM(qty), 0)::bigint AS qty, COUNT(*)::bigint AS window_count
  FROM public.tenant_usage
 WHERE tenant_id = $1
   AND ($2::text        IS NULL OR metric       =  $2)
   AND ($3::timestamptz IS NULL OR window_start >= $3)
   AND ($4::timestamptz IS NULL OR window_start <  $4)
 GROUP BY metric
 ORDER BY metric`

// aggregateUsage sums one tenant's public.tenant_usage rows over an optional
// window, replicating the B1c metering Reader's query over the admin pool (the
// Reader has no exported constructor). metric=="" / zero from / zero to disable
// that filter (passed as SQL NULL).
func (s *Service) aggregateUsage(ctx context.Context, tenantID, metric string, from, to time.Time) (UsageResponse, error) {
	resp := UsageResponse{
		TenantID: tenantID,
		Window:   UsageWindow{From: rfc3339OrEmpty(from), To: rfc3339OrEmpty(to)},
		Metrics:  make([]MetricAgg, 0),
	}
	rows, err := s.db.AdminQuery(ctx, usageAggregateSQL,
		tenantID, nullableStr(metric), nullableTime(from), nullableTime(to))
	if err != nil {
		return resp, err
	}
	defer rows.Close()
	for rows.Next() {
		var m MetricAgg
		if err := rows.Scan(&m.Metric, &m.Qty, &m.WindowCount); err != nil {
			return resp, err
		}
		resp.Metrics = append(resp.Metrics, m)
		resp.TotalQty += m.Qty
	}
	return resp, rows.Err()
}

// updateBillingPlan reflects a plan change into public.tenant_billing.plan when
// BILLING_ENABLED. Best-effort sync of the local tenant->plan map — it does NOT
// touch Stripe (the live subscription swap is the separate B4b step). Idempotent
// UPSERT keyed by tenant_id; a missing row (tenant never billed) is created so
// the plan column is consistent for when billing is later configured.
func (s *Service) updateBillingPlan(ctx context.Context, tenantID, plan string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.tenant_billing (tenant_id, plan, updated_at)
		VALUES ($1, $2, now())
		ON CONFLICT (tenant_id)
		DO UPDATE SET plan = EXCLUDED.plan, updated_at = now()`,
		tenantID, plan)
}

// nullableStr maps an empty filter to SQL NULL (no filter).
func nullableStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// nullableTime maps a zero time to SQL NULL (unbounded side).
func nullableTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

// rfc3339OrEmpty renders a bound for the echoed window ("" when unbounded).
func rfc3339OrEmpty(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
