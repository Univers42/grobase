/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   connection.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:20 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:22 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

// GetConnection returns the connection info for the data plane. For an INLINE
// mount it decrypts and returns the DSN (today's path, byte-for-byte). For a
// cred-ref mount (S2) it returns the credential_ref so the data plane resolves
// the real DSN itself via its CredentialProvider registry — no plaintext DSN
// ever travels back through the control plane for a Vault-backed mount.
//
// A cred-ref mount surfaces provider+reference with NO decrypt; the DB XOR
// check guarantees an inline row never has cred_* set. A CMEK / BYOK (D4.8)
// cmek-envelope mount decrypts via the EXTERNAL KMS in resolveConnString; if
// CMEK is disabled/unconfigured it fails closed.
func (s *Service) GetConnection(ctx context.Context, userID, id string) (ConnectionResult, error) {
	row, err := s.loadMountRow(ctx, userID, id)
	if err != nil {
		return ConnectionResult{}, err
	}
	if row.provider != nil && *row.provider != "" {
		result := ConnectionResult{
			Engine:        row.engine,
			Isolation:     row.isolation,
			CredentialRef: row.credentialRef(),
		}
		return s.stampMountOverrides(ctx, userID, result, row), nil
	}
	if len(row.cmekWrap) > 0 && (!s.cmekEnabled || s.kms == nil) {
		return ConnectionResult{}, errors.New("cmek mount stored but CMEK is disabled/unconfigured — cannot decrypt")
	}
	conn, err := s.resolveConnString(ctx, id, row)
	if err != nil {
		return ConnectionResult{}, err
	}
	result := ConnectionResult{Engine: row.engine, ConnectionString: conn, Isolation: row.isolation}
	return s.stampMountOverrides(ctx, userID, result, row), nil
}

// stampMountOverrides applies the tier mask then the per-mount overrides
// (shared_resources, read_scoped) in the one fixed order both GetConnection
// branches share — stampPackage REPLACES CapabilityOverrides, so the per-mount
// merges must run AFTER it. A mount that opted into neither leaves
// CapabilityOverrides exactly as stampPackage left it ⇒ byte-parity.
func (s *Service) stampMountOverrides(ctx context.Context, userID string, result ConnectionResult, row mountRow) ConnectionResult {
	result = mergeSharedResources(s.stampPackage(ctx, userID, result), row.sharedResources)
	return mergeReadScoped(result, row.readScoped)
}

// mergeSharedResources stamps the mount's non-owner-scoped table list onto the
// result's CapabilityOverrides under the reserved key the data plane reads
// (DatabaseMount::shared_resources). It allocates the map when the tier mask is
// nil (PACKAGE_ENFORCEMENT off), so the list survives an otherwise-empty mask. A
// nil/empty list is left untouched ⇒ byte-parity with a mount that never opted in.
func mergeSharedResources(result ConnectionResult, shared []string) ConnectionResult {
	if len(shared) == 0 {
		return result
	}
	if result.CapabilityOverrides == nil {
		result.CapabilityOverrides = map[string]any{}
	}
	result.CapabilityOverrides["shared_resources"] = shared
	return result
}

// mergeReadScoped stamps the mount's read_scoped opt-in onto the result's
// CapabilityOverrides under the reserved key the data plane reads
// (DatabaseMount::read_scoped). false (the column default = no opt-in) is left
// untouched ⇒ byte-parity with a mount that reads under the global flag alone;
// true allocates the map when the tier mask is nil, so the opt-in survives.
func mergeReadScoped(result ConnectionResult, readScoped bool) ConnectionResult {
	if !readScoped {
		return result
	}
	if result.CapabilityOverrides == nil {
		result.CapabilityOverrides = map[string]any{}
	}
	result.CapabilityOverrides["read_scoped"] = true
	return result
}

// credentialRef flattens the nullable cred_* columns into the wire struct for a
// cred-ref mount.
func (m mountRow) credentialRef() *CredentialRefInput {
	return &CredentialRefInput{
		Provider:  *m.provider,
		Reference: pg.DerefStr(m.reference),
		Version:   pg.DerefStr(m.version),
	}
}

// mountRow carries the scanned tenant_databases row through GetConnection's
// branches: inline ciphertext (payload), cred-ref (provider/reference/version),
// or CMEK envelope (cmekWrap + cmekKeyPtr).
type mountRow struct {
	engine          string
	isolation       string
	payload         EncryptedPayload
	provider        *string
	reference       *string
	version         *string
	cmekWrap        []byte
	cmekKeyPtr      *string
	sharedResources []string
	readScoped      bool
}

// loadMountRow reads the mount under EXPLICIT tenant scope (not just RLS): the
// control-plane DB role bypasses RLS, so without `AND tenant_id = $2` a mount
// UUID would be a bearer capability — any valid tenant key + dbId would read
// another tenant's mount. `userID` is the caller tenant (X-Tenant-Id). Also
// stamps last_healthy_at fire-and-forget, matching the Node service.
func (s *Service) loadMountRow(ctx context.Context, userID, id string) (mountRow, error) {
	var m mountRow
	var sharedRaw []byte
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx,
			`SELECT engine, isolation, connection_enc, connection_iv, connection_tag, connection_salt,
			        cred_provider, cred_reference, cred_version,
			        cmek_wrapped_dek, cmek_kms_key_id, shared_resources, read_scoped
			   FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2`, id, userID)
		err := row.Scan(&m.engine, &m.isolation, &m.payload.Encrypted, &m.payload.IV, &m.payload.Tag, &m.payload.Salt,
			&m.provider, &m.reference, &m.version,
			&m.cmekWrap, &m.cmekKeyPtr, &sharedRaw, &m.readScoped)
		if err != nil {
			return mapMountLookupErr(err)
		}
		_, _ = tx.Exec(ctx, `UPDATE public.tenant_databases SET last_healthy_at = now() WHERE id = $1 AND tenant_id = $2`, id, userID)
		return nil
	})
	if err == nil {
		m.sharedResources = decodeSharedResources(sharedRaw)
	}
	return m, err
}

// decodeSharedResources unmarshals the JSONB shared_resources column into a slice
// of table names. NULL/empty (no opt-in) and any malformed value degrade to nil
// ⇒ nothing merged ⇒ byte-parity with a mount that never declared a shared list.
func decodeSharedResources(raw []byte) []string {
	if len(raw) == 0 {
		return nil
	}
	var names []string
	if err := json.Unmarshal(raw, &names); err != nil {
		return nil
	}
	return names
}

// stampPackage adds the tenant's tier mask (Phase 4) so the data plane enforces
// capability gating (403) + rate limiting (429). Resolved from the tenant's
// `plan`; a no-op (returns result unchanged) when PACKAGE_ENFORCEMENT=0.
func (s *Service) stampPackage(ctx context.Context, userID string, result ConnectionResult) ConnectionResult {
	if name, pkg, ok := s.packageForTenant(ctx, userID); ok {
		result.Package = name
		result.CapabilityOverrides = pkg.CapabilityOverrides()
	}
	return result
}
