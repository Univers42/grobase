package adapterregistry

import "context"

// Remove deletes a database by id (admin scope, bypasses RLS).
func (s *Service) Remove(ctx context.Context, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 RETURNING id`, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	return nil
}

// RemoveScoped deletes a mount by id, CALLER-SCOPED — the SQL binds BOTH the id
// AND the caller's tenant_id, so a mount UUID is NEVER a bearer capability: a
// caller can only ever delete its OWN mount, even if it guessed another tenant's
// uuid. This is the self-serve builder's delete (DELETE /databases/{id}/self),
// distinct from the admin Remove (DELETE /databases/{id}) which bypasses RLS for
// operator teardown. `userID` is the caller tenant the query-router forwards as
// X-Baas-Tenant-Id (the same scope GetConnection/List use). The connCache entry
// for the id is invalidated so a stale decrypted DSN cannot survive the delete.
func (s *Service) RemoveScoped(ctx context.Context, userID, id string) error {
	rows, err := s.db.AdminQuery(ctx,
		`DELETE FROM public.tenant_databases WHERE id = $1 AND tenant_id = $2 RETURNING id`, id, userID)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		return ErrNotFound
	}
	s.connCache.Delete(id)
	return nil
}
