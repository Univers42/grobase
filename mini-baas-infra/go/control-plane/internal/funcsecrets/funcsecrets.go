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
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// ErrNotFound is returned when a secret key does not exist for the tenant.
var ErrNotFound = errors.New("function secret not found")

var keyRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

// Service owns CRUD + resolve on function_secrets.
type Service struct {
	db  *shared.Postgres
	enc *adapterregistry.Encryptor
	log *slog.Logger
}

// NewService wires the DB pool + AES encryptor.
func NewService(db *shared.Postgres, enc *adapterregistry.Encryptor, log *slog.Logger) *Service {
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

// Set upserts an encrypted secret under the caller's tenant scope.
func (s *Service) Set(ctx context.Context, tenantID string, req SetRequest) (SecretMeta, error) {
	payload, err := s.enc.Encrypt(req.Value)
	if err != nil {
		return SecretMeta{}, err
	}
	var meta SecretMeta
	err = s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			INSERT INTO public.function_secrets
			       (tenant_id, function_name, key, encrypted, iv, tag, salt)
			VALUES ($1,$2,$3,$4,$5,$6,$7)
			ON CONFLICT (tenant_id, function_name, key) DO UPDATE
			   SET encrypted = EXCLUDED.encrypted, iv = EXCLUDED.iv,
			       tag = EXCLUDED.tag, salt = EXCLUDED.salt, updated_at = now()
			RETURNING key, function_name, updated_at::text`,
			tenantID, req.FunctionName, req.Key,
			payload.Encrypted, payload.IV, payload.Tag, payload.Salt)
		return row.Scan(&meta.Key, &meta.FunctionName, &meta.UpdatedAt)
	})
	return meta, err
}

// List returns secret metadata (no plaintext) for the caller's tenant.
func (s *Service) List(ctx context.Context, tenantID string) ([]SecretMeta, error) {
	out := make([]SecretMeta, 0)
	err := s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT key, function_name, updated_at::text
			  FROM public.function_secrets
			 ORDER BY function_name, key`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var m SecretMeta
			if err := rows.Scan(&m.Key, &m.FunctionName, &m.UpdatedAt); err != nil {
				return err
			}
			out = append(out, m)
		}
		return rows.Err()
	})
	return out, err
}

// Delete removes a secret by key (and optional function scope).
func (s *Service) Delete(ctx context.Context, tenantID, functionName, key string) error {
	return s.db.TenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx,
			`DELETE FROM public.function_secrets WHERE key = $1 AND function_name = $2`,
			key, functionName)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
}

// Resolve returns the decrypted key/value map for a tenant + function.
// Function-scoped secrets override tenant-wide ones (function_name = '').
// Uses the admin pool because the runtime authenticates with the service token,
// not a tenant session.
func (s *Service) Resolve(ctx context.Context, tenantID, functionName string) (map[string]string, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT function_name, key, encrypted, iv, tag, salt
		  FROM public.function_secrets
		 WHERE tenant_id = $1 AND (function_name = '' OR function_name = $2)
		 ORDER BY function_name ASC`, tenantID, functionName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]string)
	for rows.Next() {
		var (
			fn  string
			key string
			p   adapterregistry.EncryptedPayload
		)
		if err := rows.Scan(&fn, &key, &p.Encrypted, &p.IV, &p.Tag, &p.Salt); err != nil {
			return nil, err
		}
		plain, derr := s.enc.Decrypt(p)
		if derr != nil {
			s.log.Warn("secret decrypt failed", "tenant", tenantID, "key", key, "err", derr)
			continue
		}
		// ORDER BY function_name ASC puts '' (tenant-wide) first; the
		// function-scoped row (if any) overwrites it.
		out[key] = plain
	}
	return out, rows.Err()
}

// Mount registers the tenant-facing CRUD routes.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/function-secrets", rt.set)
	mux.HandleFunc("GET /v1/function-secrets", rt.list)
	mux.HandleFunc("DELETE /v1/function-secrets/{key}", rt.remove)
	mux.HandleFunc("GET /internal/v1/function-secrets/resolve", rt.resolve)
}

type routes struct {
	svc          *Service
	serviceToken string
}

func (rt *routes) set(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	var req SetRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	meta, err := rt.svc.Set(r.Context(), tenantID, req)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, meta)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.List(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) remove(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := requireTenant(w, r)
	if !ok {
		return
	}
	fn := r.URL.Query().Get("function_name")
	err := rt.svc.Delete(r.Context(), tenantID, fn, r.PathValue("key"))
	switch {
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "function secret not found")
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
	}
}

// resolve is internal-only: it returns DECRYPTED secrets and must be protected
// by the service token (the gateway also keeps /internal off the public router).
func (rt *routes) resolve(w http.ResponseWriter, r *http.Request) {
	if rt.serviceToken != "" && r.Header.Get("X-Internal-Service-Token") != rt.serviceToken {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "invalid service token")
		return
	}
	tenant := r.URL.Query().Get("tenant")
	if tenant == "" {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "tenant required")
		return
	}
	fn := r.URL.Query().Get("function")
	secrets, err := rt.svc.Resolve(r.Context(), tenant, fn)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, secrets)
}

func requireTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Baas-User-Id", "X-Tenant-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing tenant header (X-Baas-Tenant-Id, X-Baas-User-Id, X-Tenant-Id or X-User-Id)")
	return "", false
}
