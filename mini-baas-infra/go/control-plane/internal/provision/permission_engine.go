package provision

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// PermissionEngine is the ABAC seam the reconciler (and tenant Bootstrap) talk
// to. It is an interface so the reconciler can be unit-tested with a fake and so
// the SQL implementation can later be swapped for a pure-HTTP one without
// touching reconcile logic.
type PermissionEngine interface {
	// EnsureRole idempotently ensures a slug-namespaced role exists and returns
	// its DB role_id. created reports whether this call inserted the row.
	EnsureRole(ctx context.Context, slug string, r RoleSpec) (roleID string, created bool, err error)
	// EnsurePolicy idempotently ensures one resource_policies row under roleID.
	// created reports whether this call inserted the row.
	EnsurePolicy(ctx context.Context, roleID string, p PolicySpec) (created bool, err error)
	// AssignRole idempotently grants a slug-namespaced role to a user (UUID).
	AssignRole(ctx context.Context, userID, roleName string) error
	// Decide self-verifies a permission via the permission-engine HTTP API.
	Decide(ctx context.Context, userID, resourceType, resourceName, op string) (bool, error)
}

// DB is the minimal Postgres surface sqlBackend needs. *shared.Postgres
// satisfies it; tests provide a fake.
type DB interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// sqlBackend is the direct-SQL PermissionEngine. It speaks to the same Postgres
// that backs permission-engine (migration 007: roles / user_roles /
// resource_policies). All writes are idempotent.
//
// CORRECTNESS KEY: role names are slug-namespaced (`<slug>:<role>`) so two
// tenants asking for the same logical role do NOT collide on the global
// UNIQUE(roles.name) constraint.
type sqlBackend struct {
	db           DB
	decideURL    string // permission-engine base URL (optional; "" disables Decide)
	serviceToken string
	http         *http.Client
}

// NewSQLBackend builds the SQL-backed PermissionEngine. decideURL/serviceToken
// may be empty — Decide then returns an error rather than a false negative.
func NewSQLBackend(db DB, decideURL, serviceToken string) PermissionEngine {
	return &sqlBackend{
		db:           db,
		decideURL:    strings.TrimRight(decideURL, "/"),
		serviceToken: serviceToken,
		http:         &http.Client{Timeout: 5 * time.Second},
	}
}

// EnsureRole upserts `<slug>:<role>` and returns its id. ON CONFLICT DO NOTHING
// keeps it idempotent; we then read the id back regardless of insert/no-op.
func (b *sqlBackend) EnsureRole(ctx context.Context, slug string, r RoleSpec) (string, bool, error) {
	name := namespaced(slug, r.Name)
	row, err := b.queryOne(ctx, `
		WITH ins AS (
		  INSERT INTO public.roles (name, description, is_system)
		  VALUES ($1, $2, false)
		  ON CONFLICT (name) DO NOTHING
		  RETURNING id::text
		)
		SELECT id, true  FROM ins
		UNION ALL
		SELECT id::text, false FROM public.roles WHERE name = $1
		LIMIT 1`, name, nullable(r.Description))
	if err != nil {
		return "", false, err
	}
	var id string
	var created bool
	if err := row.Scan(&id, &created); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", false, fmt.Errorf("role %q not found after upsert", name)
		}
		return "", false, err
	}
	return id, created, nil
}

// EnsurePolicy content-keyed-upserts one resource_policies row. resource_policies
// has no natural unique constraint, so idempotency is enforced by a NOT EXISTS
// guard on the same semantic content the diff hashes (type+name+actions+effect+
// priority). conditions is compared as canonical JSONB.
func (b *sqlBackend) EnsurePolicy(ctx context.Context, roleID string, p PolicySpec) (bool, error) {
	// conditions JSON is the SAME canonical form policyContentHash folds into the
	// identity key, so the stored `$5::jsonb` value and the dedup hash can never
	// disagree (no float-vs-int / nested-value drift).
	condJSON := canonicalConditionsJSON(p.Conditions)
	// Bind actions in the SAME canonical (sorted) order policyContentHash uses.
	// The identity diff treats {select,insert} == {insert,select}, but the SQL
	// guard compares `rp.actions = $4::text[]` which IS order-sensitive in
	// Postgres — so binding the raw (possibly reordered) slice would let a re-run
	// with reordered actions insert a DUPLICATE row. Sorting here keeps the stored
	// row and the identity key derived from one canonical form.
	sortedActions := append([]string(nil), p.Actions...)
	sort.Strings(sortedActions)
	row, err := b.queryOne(ctx, `
		WITH ins AS (
		  INSERT INTO public.resource_policies
		         (role_id, resource_type, resource_name, actions, conditions, effect, priority)
		  SELECT $1::uuid, $2, $3, $4::text[], $5::jsonb, $6, $7
		  WHERE NOT EXISTS (
		    SELECT 1 FROM public.resource_policies rp
		     WHERE rp.role_id = $1::uuid
		       AND rp.resource_type = $2
		       AND rp.resource_name = $3
		       AND rp.actions = $4::text[]
		       AND rp.effect = $6
		       AND rp.priority = $7
		       AND rp.conditions = $5::jsonb
		  )
		  RETURNING 1
		)
		SELECT count(*) FROM ins`,
		roleID, p.ResourceType, p.ResourceName, sortedActions, string(condJSON), p.Effect, p.Priority)
	if err != nil {
		return false, err
	}
	var n int
	if err := row.Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// AssignRole grants `roleName` (already slug-namespaced by the caller) to a
// user. Idempotent via UNIQUE(user_id, role_id).
func (b *sqlBackend) AssignRole(ctx context.Context, userID, roleName string) error {
	return b.db.AdminExec(ctx, `
		INSERT INTO public.user_roles (user_id, role_id)
		SELECT $1::uuid, r.id FROM public.roles r WHERE r.name = $2
		ON CONFLICT (user_id, role_id) DO NOTHING`, userID, roleName)
}

// Decide self-verifies via POST /permissions/decide using the internal service
// token (ServiceTokenGuard). The endpoint speaks `op`, not raw action, so we
// pass the op straight through.
func (b *sqlBackend) Decide(ctx context.Context, userID, resourceType, resourceName, op string) (bool, error) {
	if b.decideURL == "" {
		return false, errors.New("permission-engine URL not configured")
	}
	body, _ := json.Marshal(map[string]any{
		"user":          map[string]string{"id": userID},
		"resource_type": resourceType,
		"resource_name": resourceName,
		"op":            op,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.decideURL+"/permissions/decide", bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	if b.serviceToken != "" {
		req.Header.Set("X-Service-Token", b.serviceToken)
	}
	shared.PropagateHeaders(ctx, req)
	resp, err := b.http.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		// Defense-in-depth: scrub any DSN-shaped substring from the echoed body.
		return false, fmt.Errorf("permission-engine %d: %s", resp.StatusCode, shared.RedactDSN(strings.TrimSpace(string(msg))))
	}
	var out struct {
		Allow bool `json:"allow"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return false, err
	}
	return out.Allow, nil
}

// queryOne reduces a multi-row result to a single-row scanner returning
// pgx.ErrNoRows when empty (mirrors tenants.singleRow).
func (b *sqlBackend) queryOne(ctx context.Context, sql string, args ...any) (interface{ Scan(...any) error }, error) {
	rows, err := b.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return &singleRow{rows: rows}, nil
}

type singleRow struct{ rows pgx.Rows }

func (s *singleRow) Scan(dest ...any) error {
	defer s.rows.Close()
	if !s.rows.Next() {
		if err := s.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return s.rows.Scan(dest...)
}

// namespaced builds the slug-scoped DB role name. Centralized so the format
// lives in exactly one place (mirrors NamespacedRoleName / RoleKey).
func namespaced(slug, role string) string { return slug + ":" + role }

func nullable(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}
