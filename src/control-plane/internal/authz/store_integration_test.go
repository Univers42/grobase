//go:build authz_integration

package authz

// Runs against a real postgres that already has the authz schema (testdata/contract_schema.sql,
// or migration 091). Run:
//
//	AUTHZ_TEST_DSN=postgres://u:p@host:5432/db go test -tags authz_integration ./internal/authz/ -run Integration
//
// scripts/verify/m231-authz-tuples.sh does this against a throwaway container.

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

const itModel = `{"types":{
 "workspace":{"relations":{"member":{"types":["user"]}}},
 "page":{"relations":{"owner":{"types":["user"]},"viewer":{"types":["user","workspace#member"]}},
  "permissions":{"read":{"union":[{"relation":"owner"},{"relation":"viewer"}]}}}}}`

func integrationStore(t *testing.T) *Store {
	t.Helper()
	dsn := os.Getenv("AUTHZ_TEST_DSN")
	if dsn == "" {
		t.Skip("AUTHZ_TEST_DSN not set")
	}
	db, err := pg.NewPostgres(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if err := db.AdminExec(context.Background(), `TRUNCATE authz.tuples, authz.models`); err != nil {
		t.Fatal(err)
	}
	return NewStore(db, slog.New(slog.NewTextHandler(io.Discard, nil)), DefaultConfig())
}

func allowed(t *testing.T, s *Store, app, user, object string) bool {
	t.Helper()
	ref, _ := ParseRef(object)
	ds, err := s.Check(context.Background(), Query{App: app, UserID: user, Name: "read", Objects: []Ref{ref}})
	if err != nil {
		t.Fatal(err)
	}
	return ds[0].Allowed
}

func put(t *testing.T, s *Store, app, object, source string, tuples ...TupleIn) {
	t.Helper()
	if _, err := s.ReplaceTuples(context.Background(), app, TuplesRequest{Source: source, Object: object, Tuples: tuples}); err != nil {
		t.Fatal(err)
	}
}

func TestIntegrationCrossAppIsolationAndRevocation(t *testing.T) {
	s := integrationStore(t)
	ctx := context.Background()
	for _, app := range []string{"a", "b"} {
		if err := s.PutModel(ctx, app, []byte(itModel)); err != nil {
			t.Fatal(err)
		}
	}
	put(t, s, "a", "page:1", "src", TupleIn{"owner", "user:alice"})
	if !allowed(t, s, "a", "alice", "page:1") {
		t.Fatal("alice must read page:1 in app a")
	}
	if allowed(t, s, "b", "alice", "page:1") {
		t.Fatal("app b sees app a's tuple")
	}
	put(t, s, "a", "page:1", "src")
	if allowed(t, s, "a", "alice", "page:1") {
		t.Fatal("revocation not immediate: the next check still allows")
	}
}

func TestIntegrationUserset(t *testing.T) {
	s := integrationStore(t)
	if err := s.PutModel(context.Background(), "a", []byte(itModel)); err != nil {
		t.Fatal(err)
	}
	put(t, s, "a", "workspace:w", "src", TupleIn{"member", "user:bob"})
	put(t, s, "a", "page:2", "src", TupleIn{"viewer", "workspace:w#member"})
	if !allowed(t, s, "a", "bob", "page:2") || allowed(t, s, "a", "eve", "page:2") {
		t.Fatal("userset grant must reach bob only")
	}
}

func TestIntegrationModelChangeThatOrphansTuplesIs409(t *testing.T) {
	s := integrationStore(t)
	ctx := context.Background()
	if err := s.PutModel(ctx, "a", []byte(itModel)); err != nil {
		t.Fatal(err)
	}
	put(t, s, "a", "page:1", "src", TupleIn{"viewer", "user:carol"})
	slim := `{"types":{"page":{"relations":{"owner":{"types":["user"]}},"permissions":{"read":{"relation":"owner"}}}}}`
	var dropped *DroppedError
	if err := s.PutModel(ctx, "a", []byte(slim)); !errors.As(err, &dropped) {
		t.Fatalf("want DroppedError, got %v", err)
	}
	put(t, s, "a", "page:1", "src")
	if err := s.PutModel(ctx, "a", []byte(slim)); err != nil {
		t.Fatalf("model change after the tuples are gone: %v", err)
	}
}
