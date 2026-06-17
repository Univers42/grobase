// Package ipguard (Track-D D2e) is the control-plane TENANT-CONFIGURABLE IP
// ALLOWLIST for the API edge. A tenant restricts which source IPs/CIDRs may call
// its API; a request whose client IP (taken from X-Forwarded-For at the edge, or
// the direct peer) is not in the tenant's allowlist is rejected with 403.
//
// It provides two surfaces, ALL flag-gated OFF by default
// (TENANT_IP_ALLOWLIST_ENABLED):
//
//  1. EDGE CHECK — POST /v1/ipguard/check {tenant_id, ip} (service-token only):
//     the decision an edge auth-request plugin (Kong) calls before forwarding a
//     request. It answers "may client IP X reach tenant T's API?". A tenant with
//     NO allowlist rule is UNRESTRICTED (allow=true) — the feature is OPT-IN; a
//     tenant WITH ≥1 rule is restricted to the union of its CIDRs (allow=true iff
//     the IP is contained in some rule, else allow=false → the edge returns 403).
//  2. CRUD — admin /v1/tenants/{id}/ip-allowlist + self-serve
//     /v1/tenants/me/ip-allowlist: a tenant manages its OWN allowlist (list, add,
//     remove a CIDR rule).
//
// THE LOAD-BEARING CONSTRAINT: enforcement lives ENTIRELY here in the control
// plane (an edge decision), never in RequestIdentity, the RLS GUCs, or the data
// plane — so per-request isolation + SHARE_POOLS stay byte-untouched, exactly as
// D1 org-scoping does.
//
// FLAG-GATED OFF = PARITY: Mount is called ONLY when TENANT_IP_ALLOWLIST_ENABLED
// is truthy. When OFF (the default) Mount is never called, none of the routes
// exist (404), and no allowlist is ever consulted — byte-identical to today (the
// same discipline as TENANT_SELFSERVE_ENABLED / TENANT_AUDIT_ENABLED in
// cmd/tenant-control). The CIDR containment match runs IN GO (net.ParseCIDR +
// Contains), engine-agnostic and independent of any DB inet operator.
package ipguard

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
)

// idb is the minimal Postgres surface the service needs. *pg.Postgres
// satisfies it (the guard runs as the BYPASSRLS control-plane role); a fake
// satisfies it in unit tests so the decision + CRUD contracts are provable
// without a live database.
type idb interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

var (
	// ErrEmptyTenant guards every path — an allowlist op with no tenant is
	// meaningless (and a "" tenant would scan/mutate nothing or, worse, leak).
	ErrEmptyTenant = errors.New("ipguard: tenant_id required")
	// ErrBadCIDR is returned when a caller submits a rule that does not parse as
	// an IP or CIDR network (defence in depth atop the native CIDR column).
	ErrBadCIDR = errors.New("ipguard: invalid CIDR or IP")
	// ErrBadIP is returned when the edge check is asked about an unparseable IP.
	ErrBadIP = errors.New("ipguard: invalid client IP")
)

// Service reads + mutates the per-tenant allowlist and renders the edge decision.
type Service struct {
	db idb
	// listFn is a test seam: when non-nil, List() delegates to it instead of the
	// DB, so the pure-Go decision logic (CIDR containment, opt-in default) is
	// provable WITHOUT a live database. Production never sets it (nil ⇒ real DB).
	listFn func(ctx context.Context, tenantID string) ([]Rule, error)
}

// NewService wraps the privileged Postgres handle.
func NewService(db idb) *Service { return &Service{db: db} }

// Rule is one allowlist entry (a CIDR network or a single host).
type Rule struct {
	ID        string `json:"id"`
	TenantID  string `json:"tenant_id"`
	CIDR      string `json:"cidr"`
	Note      string `json:"note,omitempty"`
	CreatedBy string `json:"created_by,omitempty"`
	CreatedAt string `json:"created_at,omitempty"`
}

// Decision is the edge-check answer.
type Decision struct {
	TenantID   string `json:"tenant_id"`
	IP         string `json:"ip"`
	Allow      bool   `json:"allow"`
	Restricted bool   `json:"restricted"` // true iff the tenant has ≥1 allowlist rule
	Reason     string `json:"reason,omitempty"`
}

// AddInput is one rule to add.
type AddInput struct {
	TenantID  string
	CIDR      string
	Note      string
	CreatedBy string
}

// Allowed is the CORE edge decision. It is the SAME logic an edge plugin would
// run: load the tenant's rules; if it has NONE the tenant is unrestricted
// (allow=true, restricted=false) — the feature is OPT-IN; otherwise allow=true
// iff the client IP is contained in at least one rule's CIDR, else 403.
//
// The containment match is done IN GO (net.ParseCIDR + Contains), so it is
// engine-agnostic and a single IPv4/IPv6 host is handled identically to a /32 or
// /128. tenant_id is ALWAYS bound in the rule load (the cross-tenant wall, atop
// RLS): a check for tenant T can never read tenant U's rules.
func (s *Service) Allowed(ctx context.Context, tenantID, clientIP string) (Decision, error) {
	tenantID = strings.TrimSpace(tenantID)
	if tenantID == "" {
		return Decision{}, ErrEmptyTenant
	}
	ip := parseIP(clientIP)
	if ip == nil {
		return Decision{}, ErrBadIP
	}
	rules, err := s.List(ctx, tenantID)
	if err != nil {
		return Decision{}, err
	}
	// OPT-IN default: no rule ⇒ unrestricted ⇒ allow. This is what keeps the
	// feature additive — a tenant that never configured an allowlist is exactly
	// as open as today even with the flag ON.
	if len(rules) == 0 {
		return Decision{TenantID: tenantID, IP: ip.String(), Allow: true, Restricted: false, Reason: "no_allowlist"}, nil
	}
	return matchRules(tenantID, ip, rules), nil
}

// List returns a tenant's allowlist rules (newest first). tenant_id is ALWAYS
// bound — a tenant can never list another tenant's rules.
func (s *Service) List(ctx context.Context, tenantID string) ([]Rule, error) {
	tenantID = strings.TrimSpace(tenantID)
	if tenantID == "" {
		return nil, ErrEmptyTenant
	}
	if s.listFn != nil { // test seam — never set in production
		return s.listFn(ctx, tenantID)
	}
	rows, err := s.db.AdminQuery(ctx, `
		SELECT id::text, tenant_id, host(cidr) ||
		         CASE WHEN family(cidr)=4 AND masklen(cidr)=32 THEN ''
		              WHEN family(cidr)=6 AND masklen(cidr)=128 THEN ''
		              ELSE '/' || masklen(cidr)::text END AS cidr,
		       note, created_by, created_at::text
		  FROM public.tenant_ip_allowlist
		 WHERE tenant_id = $1
		 ORDER BY created_at DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanRules(rows)
}

// Add inserts (idempotently) one allowlist rule. The CIDR is normalized in Go
// BEFORE the insert so a bare host ("203.0.113.5") becomes a /32 (or /128 for
// IPv6) and a malformed value is rejected with ErrBadCIDR (defence in depth atop
// the native CIDR column). A re-add of the same rule is a no-op upsert
// (ON CONFLICT on the (tenant_id, cidr) unique key).
func (s *Service) Add(ctx context.Context, in AddInput) (Rule, error) {
	tenantID := strings.TrimSpace(in.TenantID)
	if tenantID == "" {
		return Rule{}, ErrEmptyTenant
	}
	norm, err := normalizeCIDR(in.CIDR)
	if err != nil {
		return Rule{}, err
	}
	var r Rule
	row := s.queryRow(ctx, `
		INSERT INTO public.tenant_ip_allowlist (tenant_id, cidr, note, created_by)
		VALUES ($1, $2::cidr, $3, $4)
		ON CONFLICT (tenant_id, cidr)
		  DO UPDATE SET note = EXCLUDED.note
		RETURNING id::text, tenant_id,
		          host(cidr) ||
		            CASE WHEN family(cidr)=4 AND masklen(cidr)=32 THEN ''
		                 WHEN family(cidr)=6 AND masklen(cidr)=128 THEN ''
		                 ELSE '/' || masklen(cidr)::text END,
		          note, created_by, created_at::text`,
		tenantID, norm, in.Note, in.CreatedBy)
	if err := row.Scan(&r.ID, &r.TenantID, &r.CIDR, &r.Note, &r.CreatedBy, &r.CreatedAt); err != nil {
		return Rule{}, err
	}
	return r, nil
}

// Remove deletes one rule by id, ALWAYS bound to the tenant — a tenant can never
// delete another tenant's rule even by guessing its id. Reports whether a row
// was removed (false ⇒ 404 to the caller).
func (s *Service) Remove(ctx context.Context, tenantID, ruleID string) (bool, error) {
	tenantID = strings.TrimSpace(tenantID)
	ruleID = strings.TrimSpace(ruleID)
	if tenantID == "" {
		return false, ErrEmptyTenant
	}
	if ruleID == "" {
		return false, nil
	}
	found, err := s.ruleExists(ctx, tenantID, ruleID)
	if err != nil || !found {
		return false, err
	}
	if err := s.db.AdminExec(ctx,
		`DELETE FROM public.tenant_ip_allowlist WHERE tenant_id=$1 AND id::text=$2`, tenantID, ruleID); err != nil {
		return false, err
	}
	return true, nil
}
