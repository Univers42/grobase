/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   patch.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 20:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 20:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"context"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5"
)

const maxPatchBodyBytes = 64 << 10

// Patch sentinels; writePatchError maps each to its status.
const (
	// ErrCredentialModeMismatch rejects a credential mode or provider switch.
	ErrCredentialModeMismatch adapterregistryErr = "credential mode mismatch"
	// ErrPlatformMount protects the control plane's own mount from rotation.
	ErrPlatformMount adapterregistryErr = "platform mount credential cannot be changed"
	// ErrCMEKUnavailable prevents a CMEK mount from downgrading to inline storage.
	ErrCMEKUnavailable adapterregistryErr = "cmek is disabled or unconfigured"
	// ErrRevisionConflict reports a credential change since the optimistic read.
	ErrRevisionConflict adapterregistryErr = "database revision conflict"
)

// PatchDatabaseRequest leaves nil fields unchanged and preserves credential mode.
type PatchDatabaseRequest struct {
	Name             *string             `json:"name"`
	ConnectionString *string             `json:"connection_string"`
	CredentialRef    *CredentialRefInput `json:"credential_ref"`
}

// Validate distinguishes absent fields from explicitly empty values.
func (r PatchDatabaseRequest) Validate() error {
	if r.Name == nil && r.ConnectionString == nil && r.CredentialRef == nil {
		return fmt.Errorf("nothing to change")
	}
	if r.ConnectionString != nil && r.CredentialRef != nil {
		return fmt.Errorf("provide only one of connection_string or credential_ref")
	}
	if r.Name != nil && (len(*r.Name) < 1 || len(*r.Name) > 64) {
		return fmt.Errorf("name must be 1..64 chars")
	}
	if r.ConnectionString != nil && *r.ConnectionString == "" {
		return fmt.Errorf("connection_string must be non-empty")
	}
	if r.CredentialRef != nil && (r.CredentialRef.Provider == "" || r.CredentialRef.Reference == "") {
		return fmt.Errorf("credential_ref.provider and credential_ref.reference are required")
	}
	return nil
}

func (r PatchDatabaseRequest) credentialChange() bool {
	return r.ConnectionString != nil || r.CredentialRef != nil
}

func (r PatchDatabaseRequest) changedFields() []string {
	fields := make([]string, 0, 3)
	if r.Name != nil {
		fields = append(fields, "name")
	}
	if r.ConnectionString != nil {
		fields = append(fields, "connection_string")
	}
	if r.CredentialRef != nil {
		fields = append(fields, "credential_ref")
	}
	return fields
}

type patchMutation struct {
	id, userID string
	req        PatchDatabaseRequest
	row        mountRow
	plan       mountPlan
}

// Patch seals between transactions and guards the mode-preserving update by revision.
func (s *Service) Patch(ctx context.Context, userID, id string, req PatchDatabaseRequest) (MountDescriptor, error) {
	row, err := s.loadPatchRow(ctx, userID, id)
	if err != nil {
		return MountDescriptor{}, err
	}
	if err := validatePatchMode(row, req); err != nil {
		return MountDescriptor{}, err
	}
	var plan mountPlan
	if req.ConnectionString != nil {
		if err := s.guardPlatformPatch(ctx, id, row); err != nil {
			return MountDescriptor{}, err
		}
		plan, err = s.sealPatchCredential(ctx, userID, row, *req.ConnectionString)
		if err != nil {
			return MountDescriptor{}, err
		}
	}
	mutation := patchMutation{id: id, userID: userID, req: req, row: row, plan: plan}
	if err := s.updatePatch(ctx, mutation); err != nil {
		return MountDescriptor{}, err
	}
	if req.credentialChange() {
		s.connCache.Delete(id)
	}
	descriptor, err := s.Describe(ctx, userID, id)
	if err != nil {
		return MountDescriptor{}, err
	}
	s.log.Info("database mount patched", "tenant", userID, "mount", id, "old_revision", row.revision, "fields", req.changedFields())
	return descriptor, nil
}

func (s *Service) loadPatchRow(ctx context.Context, userID, id string) (mountRow, error) {
	var row mountRow
	err := s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		var err error
		row, err = scanMountRow(ctx, tx, userID, id)
		return err
	})
	return row, err
}

func validatePatchMode(row mountRow, req PatchDatabaseRequest) error {
	provider := pg.DerefStr(row.provider)
	if req.ConnectionString != nil && provider != "" {
		return ErrCredentialModeMismatch
	}
	if req.CredentialRef != nil && req.CredentialRef.Provider != provider {
		return ErrCredentialModeMismatch
	}
	return nil
}

// guardPlatformPatch protects the control plane's own mount. Caveat: the host
// check is text-only (no DNS, first host only), not an SSRF guard; the real
// guard is the shared dial guard (plan item G1), not this function.
func (s *Service) guardPlatformPatch(ctx context.Context, id string, row mountRow) error {
	if len(row.cmekWrap) > 0 && (!s.cmekEnabled || s.kms == nil) {
		return ErrCMEKUnavailable
	}
	current, err := s.resolveConnString(ctx, id, row)
	if err != nil {
		return err
	}
	if describeDSN(row.engine, current).location == locationPlatform {
		return ErrPlatformMount
	}
	return nil
}

// sealPatchCredential avoids sealCredential's mode-switching default-key fallback.
func (s *Service) sealPatchCredential(ctx context.Context, userID string, row mountRow, dsn string) (mountPlan, error) {
	if len(row.cmekWrap) > 0 {
		if !s.cmekEnabled || s.kms == nil {
			return mountPlan{}, ErrCMEKUnavailable
		}
		req := RegisterDatabaseRequest{Engine: row.engine, ConnectionString: dsn}
		return s.sealCMEK(ctx, req, mountPlan{usingCMEK: true, cmekKeyID: pg.DerefStr(row.cmekKeyPtr)})
	}
	_, pkg, tiered := s.packageForTenant(ctx, userID)
	if tiered && pkg.SecurityMode == "max" {
		return mountPlan{}, ErrPlaintextDsnForbidden
	}
	payload, err := s.enc.Encrypt(dsn)
	if err != nil {
		return mountPlan{}, err
	}
	return mountPlan{payload: payload}, nil
}

func (s *Service) updatePatch(ctx context.Context, mutation patchMutation) error {
	var affected int64
	err := s.db.TenantTx(ctx, mutation.userID, func(tx pgx.Tx) error {
		query, args := patchUpdate(mutation)
		tag, err := tx.Exec(ctx, query, args...)
		if err != nil {
			return err
		}
		affected = tag.RowsAffected()
		return nil
	})
	if err != nil {
		return mapRegisterError(err)
	}
	if affected == 0 {
		return ErrRevisionConflict
	}
	return nil
}

// patchUpdate keeps revision out of the SET list: the database trigger owns it.
func patchUpdate(mutation patchMutation) (string, []any) {
	args := []any{mutation.id, mutation.userID, mutation.req.Name, mutation.row.revision}
	if !mutation.req.credentialChange() {
		return `UPDATE public.tenant_databases SET name = COALESCE($3, name)
		 WHERE id = $1 AND tenant_id = $2 AND revision = $4`, args
	}
	switch {
	case pg.DerefStr(mutation.row.provider) != "":
		var version any
		if mutation.req.CredentialRef.Version != "" {
			version = mutation.req.CredentialRef.Version
		}
		return `UPDATE public.tenant_databases SET name = COALESCE($3, name),
		 cred_provider = $5, cred_reference = $6, cred_version = $7
		 WHERE id = $1 AND tenant_id = $2 AND revision = $4`,
			append(args, mutation.req.CredentialRef.Provider, mutation.req.CredentialRef.Reference, version)
	case len(mutation.row.cmekWrap) > 0:
		return `UPDATE public.tenant_databases SET name = COALESCE($3, name),
		 connection_enc = $5, connection_iv = $6, connection_tag = $7,
		 cmek_wrapped_dek = $8, cmek_kms_key_id = $9
		 WHERE id = $1 AND tenant_id = $2 AND revision = $4`,
			append(args, mutation.plan.payload.Encrypted, mutation.plan.payload.IV, mutation.plan.payload.Tag,
				mutation.plan.cmekWrap, mutation.plan.cmekKeyID)
	default:
		return `UPDATE public.tenant_databases SET name = COALESCE($3, name),
		 connection_enc = $5, connection_iv = $6, connection_tag = $7, connection_salt = $8
		 WHERE id = $1 AND tenant_id = $2 AND revision = $4`,
			append(args, mutation.plan.payload.Encrypted, mutation.plan.payload.IV, mutation.plan.payload.Tag, mutation.plan.payload.Salt)
	}
}
