// Package funcsecrets implements the per-function secret store (A2 Functions
// DX). Values are sealed with AES-256-GCM (scrypt-derived key) reusing the
// adapter-registry Encryptor so the same VAULT_ENC_KEY decrypts both.
//
// Surface (tenant-scoped via forwarded envelope headers):
//
//	POST   /v1/function-secrets            set {key, value, function_name?}
//	GET    /v1/function-secrets            list (NEVER returns plaintext)
//	DELETE /v1/function-secrets/{key}      delete (optional ?function_name=)
//
// Plus an internal, service-token-only resolve used by functions-runtime at
// invoke time:
//
//	GET /internal/v1/function-secrets/resolve?tenant=&function=
//	    -> {"KEY":"value", ...}   (function-scoped secrets override tenant-wide)
package funcsecrets

import (
	"context"
	"errors"
	"log/slog"
	"regexp"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// ErrNotFound is returned when a secret key does not exist for the tenant.
var ErrNotFound = errors.New("function secret not found")

var keyRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

// Service owns CRUD + resolve on function_secrets.
type Service struct {
	db  *pg.Postgres
	enc *adapterregistry.Encryptor
	log *slog.Logger
}

// NewService wires the DB pool + AES encryptor.
func NewService(db *pg.Postgres, enc *adapterregistry.Encryptor, log *slog.Logger) *Service {
	return &Service{db: db, enc: enc, log: log}
}

// EnsureSchema verifies the table exists (real DDL in migration 037).
func (s *Service) EnsureSchema(ctx context.Context) error {
	const q = `SELECT 1 FROM information_schema.tables
	            WHERE table_schema = 'public' AND table_name = 'function_secrets'`
	rows, err := s.db.AdminQuery(ctx, q)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return errors.New("public.function_secrets missing — run migration 037_function_secrets.sql")
	}
	return nil
}

// SecretMeta is the public (plaintext-free) metadata view.
type SecretMeta struct {
	Key          string `json:"key"`
	FunctionName string `json:"function_name"`
	UpdatedAt    string `json:"updated_at"`
}

// SetRequest is the body for POST /v1/function-secrets.
type SetRequest struct {
	Key          string `json:"key"`
	Value        string `json:"value"`
	FunctionName string `json:"function_name"`
}

// Validate enforces the key grammar.
func (r SetRequest) Validate() error {
	if !keyRe.MatchString(r.Key) {
		return errors.New("key must match [A-Za-z_][A-Za-z0-9_]{0,127}")
	}
	return nil
}
