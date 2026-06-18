package provision

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// recordDB captures every SQL/args pair. AdminQuery returns an error so the
// query-path methods short-circuit BEFORE scanning (we assert the emitted SQL
// contract — the scan path is exercised against a real DB live). AdminExec
// records the call and succeeds.
type recordDB struct {
	queries  [][]any // [sql, args...]
	execs    [][]any
	queryErr error
}

func (r *recordDB) AdminQuery(_ context.Context, sql string, args ...any) (pgx.Rows, error) {
	r.queries = append(r.queries, append([]any{sql}, args...))
	if r.queryErr != nil {
		return nil, r.queryErr
	}
	return nil, errStopBeforeScan
}

func (r *recordDB) AdminExec(_ context.Context, sql string, args ...any) error {
	r.execs = append(r.execs, append([]any{sql}, args...))
	return nil
}

type sentinelErr string

func (s sentinelErr) Error() string { return string(s) }

const errStopBeforeScan = sentinelErr("stop-before-scan")

func TestEnsureRoleNamespacesAndUpserts(t *testing.T) {
	db := &recordDB{}
	be := NewSQLBackend(db, "", "")
	_, _, _ = be.EnsureRole(context.Background(), "acme", RoleSpec{Name: "editor", Description: "d"})

	if len(db.queries) != 1 {
		t.Fatalf("expected 1 query, got %d", len(db.queries))
	}
	sql, _ := db.queries[0][0].(string)
	if !strings.Contains(sql, "ON CONFLICT (name) DO NOTHING") {
		t.Error("EnsureRole must use ON CONFLICT (name) DO NOTHING for idempotency")
	}
	// First arg must be the slug-namespaced role name.
	if got := db.queries[0][1]; got != "acme:editor" {
		t.Errorf("role name arg = %v, want slug-namespaced acme:editor", got)
	}
}

func TestEnsurePolicyContentKeyedGuard(t *testing.T) {
	db := &recordDB{}
	be := NewSQLBackend(db, "", "")
	_, _ = be.EnsurePolicy(context.Background(), "role-1", PolicySpec{
		ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow", Priority: 0,
	})
	if len(db.queries) != 1 {
		t.Fatalf("expected 1 query, got %d", len(db.queries))
	}
	sql, _ := db.queries[0][0].(string)
	if !strings.Contains(sql, "NOT EXISTS") {
		t.Error("EnsurePolicy must guard with NOT EXISTS (content-keyed upsert)")
	}
	if !strings.Contains(sql, "rp.conditions = $5::jsonb") {
		t.Error("EnsurePolicy must compare conditions as canonical jsonb")
	}
}

// TestEnsurePolicyBindsSortedActions pins the fix for the action-reorder
// idempotency bug: the NOT EXISTS guard compares `rp.actions = $4::text[]`, which
// is ORDER-SENSITIVE in Postgres. Before the fix, EnsurePolicy bound the raw
// (possibly reordered) actions while the dedup hash sorted them — so a re-run
// with reordered actions inserted a DUPLICATE row. The $4 arg must therefore be
// the canonical SORTED slice, identical no matter how the caller ordered it.
func TestEnsurePolicyBindsSortedActions(t *testing.T) {
	run := func(actions []string) []string {
		db := &recordDB{}
		be := NewSQLBackend(db, "", "")
		_, _ = be.EnsurePolicy(context.Background(), "role-1", PolicySpec{
			ResourceType: "*", ResourceName: "*",
			Actions: actions, Effect: "allow", Priority: 0,
		})
		// args layout: [sql, $1 roleID, $2 type, $3 name, $4 actions, $5 cond, ...]
		got, ok := db.queries[0][4].([]string)
		if !ok {
			t.Fatalf("$4 actions arg is %T, want []string", db.queries[0][4])
		}
		return got
	}

	want := []string{"delete", "insert", "select", "update"}
	forward := run([]string{"select", "insert", "update", "delete"})
	reordered := run([]string{"delete", "update", "select", "insert"})

	for _, got := range [][]string{forward, reordered} {
		if len(got) != len(want) {
			t.Fatalf("bound actions = %v, want %v", got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("bound actions = %v, want canonical sorted %v", got, want)
			}
		}
	}
	// Same bytes regardless of input order → the SQL guard now matches the row a
	// prior run inserted → zero duplicate rows on re-run with reordered actions.
}

func TestEnsurePolicyDefaultsNilConditionsToEmptyJSON(t *testing.T) {
	db := &recordDB{}
	be := NewSQLBackend(db, "", "")
	_, _ = be.EnsurePolicy(context.Background(), "role-1", PolicySpec{
		ResourceType: "*", ResourceName: "*", Actions: []string{"select"}, Effect: "allow",
		Conditions: nil,
	})
	// $5 is the conditions JSON arg (sql, $1..$7 => index 5 in args slice).
	condArg := db.queries[0][5]
	if condArg != "{}" {
		t.Errorf("nil conditions = %v, want \"{}\"", condArg)
	}
}

func TestAssignRoleIdempotentSQL(t *testing.T) {
	db := &recordDB{}
	be := NewSQLBackend(db, "", "")
	if err := be.AssignRole(context.Background(), "00000000-0000-4000-8000-000000000001", "acme:editor"); err != nil {
		t.Fatalf("AssignRole error: %v", err)
	}
	if len(db.execs) != 1 {
		t.Fatalf("expected 1 exec, got %d", len(db.execs))
	}
	sql, _ := db.execs[0][0].(string)
	if !strings.Contains(sql, "ON CONFLICT (user_id, role_id) DO NOTHING") {
		t.Error("AssignRole must be idempotent via ON CONFLICT (user_id, role_id)")
	}
	if db.execs[0][2] != "acme:editor" {
		t.Errorf("role name arg = %v, want acme:editor", db.execs[0][2])
	}
}

func TestDecideViaHTTP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/permissions/decide" {
			t.Errorf("path = %s, want /permissions/decide", r.URL.Path)
		}
		if r.Header.Get("X-Service-Token") != "tok" {
			t.Errorf("missing service token")
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"allow":true,"reason":"ok","mode":"abac"}`))
	}))
	defer srv.Close()

	be := NewSQLBackend(&recordDB{}, srv.URL, "tok")
	allow, err := be.Decide(context.Background(), "u1", "postgresql", "contacts", "insert")
	if err != nil {
		t.Fatalf("Decide error: %v", err)
	}
	if !allow {
		t.Error("Decide should return allow=true")
	}
}

func TestDecideDisabledWithoutURL(t *testing.T) {
	be := NewSQLBackend(&recordDB{}, "", "tok")
	if _, err := be.Decide(context.Background(), "u1", "t", "n", "insert"); err == nil {
		t.Error("Decide must error when permission-engine URL is not configured")
	}
}

func TestNamespacedHelper(t *testing.T) {
	if namespaced("acme", "user") != "acme:user" {
		t.Errorf("namespaced mismatch: %q", namespaced("acme", "user"))
	}
}

func TestNullableHelper(t *testing.T) {
	if nullable("  ") != nil {
		t.Error("blank string should be SQL NULL")
	}
	if nullable("x") != "x" {
		t.Error("non-blank string should pass through")
	}
}
