package adapterregistry

import "fmt"

// isAllowedEngine reports whether the control plane will ACCEPT a mount for the
// engine. Honesty rule (Phase 3): this is exactly the engines the Rust data
// plane can actually SERVE — registering a mount for an engine with no Rust pool
// would create a row that 501s on every query. The previously-accepted stubs
// (jdbc, cassandra, neo4j, elasticsearch, qdrant, influx) are quarantined out:
// they were never served, so accepting them was a lie. The DB CHECK constraint
// stays broader (it never rejected these), so existing rows are untouched; only
// NEW registrations of an unserved engine are refused here.
func isAllowedEngine(engine string) bool {
	switch engine {
	case "postgresql", "cockroachdb", "mysql", "mariadb", "mongodb",
		"redis", "sqlite", "mssql", "http":
		return true
	}
	return false
}

// isAllowedIsolation mirrors the tenant isolation strategies the data plane
// understands (see data-plane-core DatabaseMount.isolation).
// tenant_owned: an external client DB wholly owned by one tenant — the data
// plane skips per-row owner_id scoping (tenant gating still happens at
// key→mount resolution, so a foreign tenant's key never resolves the mount).
func isAllowedIsolation(isolation string) bool {
	switch isolation {
	case "shared_rls", "schema_per_tenant", "db_per_tenant", "tenant_owned":
		return true
	}
	return false
}

// CredentialRefInput is the optional Vault-credential reference a tenant may
// register INSTEAD of an inline plaintext connection_string (S2 / G-Vault).
// When present, the row stores provider/reference/version (no encryption) and
// the Rust data plane resolves the real DSN at query time via its
// CredentialProvider registry (credential.rs). `Provider` is the provider name
// the data plane keys on (e.g. "vault"); `Reference` is the provider-scoped
// secret reference (e.g. a Vault KV v2 path); `Version` is an optional pin.
type CredentialRefInput struct {
	Provider  string `json:"provider"`
	Reference string `json:"reference"`
	Version   string `json:"version"`
}

// set reports whether the caller supplied a credential reference at all (any of
// the three fields non-empty). A wholly-empty struct means "no cred-ref" so the
// inline connection_string path is taken (parity).
func (c CredentialRefInput) set() bool {
	return c.Provider != "" || c.Reference != "" || c.Version != ""
}

// RegisterDatabaseRequest is the JSON body for POST /databases.
type RegisterDatabaseRequest struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	// Isolation is optional; empty defaults to "shared_rls" at store time.
	Isolation string `json:"isolation"`
	// CredentialRef is the optional Vault-credential reference (S2 / G-Vault).
	// EXACTLY ONE of {ConnectionString, CredentialRef} must be supplied.
	CredentialRef CredentialRefInput `json:"credential_ref"`
	// KMSKeyID is the optional CMEK / BYOK key id (D4.8). When CMEK_ENABLED is on
	// AND the caller supplies an INLINE connection_string, a non-empty KMSKeyID
	// (or the env default) routes registration through the CMEK envelope: the DSN
	// is sealed under a fresh DEK that is WRAPPED by this external KMS KEK, so the
	// platform stores only the wrapped DEK + ciphertext and cannot decrypt without
	// the KMS. Ignored (parity) when CMEK is disabled or a credential_ref is used.
	KMSKeyID string `json:"kms_key_id"`
}

// Validate enforces the same constraints as the Node DTO + DB check, plus the
// S2 EXACTLY-ONE-OF {connection_string, credential_ref} rule.
func (r RegisterDatabaseRequest) Validate() error {
	if !isAllowedEngine(r.Engine) {
		return fmt.Errorf("unsupported engine %q", r.Engine)
	}
	if l := len(r.Name); l < 1 || l > 64 {
		return fmt.Errorf("name must be 1..64 chars")
	}
	if err := r.validateCredentialSource(); err != nil {
		return err
	}
	if r.Isolation != "" && !isAllowedIsolation(r.Isolation) {
		return fmt.Errorf("unsupported isolation %q", r.Isolation)
	}
	return nil
}

// validateCredentialSource enforces the S2 EXACTLY-ONE-OF {connection_string,
// credential_ref} rule. Both-set and neither-set are rejected so a row is never
// ambiguous (and never silently inline when a ref was intended). The DB CHECK
// (migration 060) mirrors this as a backstop.
func (r RegisterDatabaseRequest) validateCredentialSource() error {
	hasInline := r.ConnectionString != ""
	hasRef := r.CredentialRef.set()
	switch {
	case hasInline && hasRef:
		return fmt.Errorf("provide exactly one of connection_string or credential_ref, not both")
	case !hasInline && !hasRef:
		return fmt.Errorf("connection_string or credential_ref is required")
	}
	if hasRef {
		if r.CredentialRef.Provider == "" {
			return fmt.Errorf("credential_ref.provider is required")
		}
		if r.CredentialRef.Reference == "" {
			return fmt.Errorf("credential_ref.reference is required")
		}
	}
	return nil
}

// TenantDatabase is the public metadata view (no secret material).
type TenantDatabase struct {
	ID            string  `json:"id"`
	TenantID      string  `json:"tenant_id"`
	Engine        string  `json:"engine"`
	Name          string  `json:"name"`
	CreatedAt     string  `json:"created_at"`
	LastHealthyAt *string `json:"last_healthy_at"`
}

// RegisterResult is returned by POST /databases.
type RegisterResult struct {
	ID        string `json:"id"`
	Engine    string `json:"engine"`
	Name      string `json:"name"`
	CreatedAt string `json:"created_at"`
}

// ConnectionResult is the internal decrypt response for the data plane.
type ConnectionResult struct {
	Engine string `json:"engine"`
	// ConnectionString is the resolved inline DSN for an INLINE-credential mount.
	// EMPTY for a cred-ref mount — the data plane must then resolve the DSN itself
	// via its CredentialProvider registry using CredentialRef below (so a
	// Vault-backed DSN never travels back through the control plane in plaintext).
	ConnectionString string `json:"connection_string"`
	// CredentialRef is set ONLY for a cred-ref (Vault-backed) mount (S2). It tells
	// the data plane which provider + reference to resolve the real DSN from at
	// query time. Nil/omitted for an inline mount (parity).
	CredentialRef *CredentialRefInput `json:"credential_ref,omitempty"`
	// Isolation tells the data plane how to scope this mount (shared_rls |
	// schema_per_tenant | db_per_tenant).
	Isolation string `json:"isolation"`
	// Package is the resolved tier name (Phase 4), e.g. "essential"/"pro"/"max".
	// Informational for the query-router / observability.
	Package string `json:"package,omitempty"`
	// CapabilityOverrides is the tenant's tier mask (capability bools + rps/burst)
	// the query-router stamps onto the mount it forwards to Rust, where the
	// planner narrows by it (403 capability_gated) and the token bucket reads
	// rps/burst (429). Nil when tiering is disabled (parity).
	CapabilityOverrides map[string]any `json:"capability_overrides,omitempty"`
}
