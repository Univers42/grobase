/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:32 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package scim

import (
	"context"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// memberProvisioner is the seam onto internal/orgs membership lifecycle. SCIM
// provisioning REUSES the existing org membership API — it never reinvents
// membership. *orgs.Service satisfies it; a fake satisfies it in unit tests.
// AddMember(orgID, userID, role, invitedBy) upserts; RemoveMember(orgID, userID)
// deletes. The soft-deactivate (active:false) is a column flip handled by the
// store (org_members.active), NOT a membership add/remove.
type memberProvisioner interface {
	AddMember(ctx context.Context, orgID, userID, role, invitedBy string) error
	RemoveMember(ctx context.Context, orgID, userID string) error
}

// Service drives the SCIM User lifecycle: it binds a bearer token to a tenant
// (+org), maps SCIM Users onto org members via the existing memberProvisioner,
// and persists the SCIM resource mapping (scim_users). It is the layer the HTTP
// handler calls; the store owns SQL, orgs owns membership.
type Service struct {
	store   *store
	members memberProvisioner
	log     *slog.Logger
}

// NewService wires the DB-backed store + the org membership provisioner + logger.
func NewService(db *pg.Postgres, members memberProvisioner, log *slog.Logger) *Service {
	return &Service{store: newStore(db), members: members, log: log}
}

// Authorize resolves a cleartext SCIM bearer to its tenant/org binding and stamps
// last_used_at. ErrTokenInvalid for a missing/unknown/revoked token (the wall).
func (s *Service) Authorize(ctx context.Context, bearer string) (TokenBinding, error) {
	b, err := s.store.VerifyToken(ctx, bearer)
	if err != nil {
		return TokenBinding{}, err
	}
	s.store.Touch(ctx, b.TokenID)
	return b, nil
}

// IssueToken creates a SCIM bearer for (tenantID, orgID) and returns the
// cleartext ONCE. Admin-only (service token) at the handler layer.
func (s *Service) IssueToken(ctx context.Context, tenantID, orgID, description string) (cleartext, tokenID string, err error) {
	return s.store.IssueToken(ctx, tenantID, orgID, description)
}

// RevokeToken revokes a SCIM bearer (admin path). Scoped to the tenant.
func (s *Service) RevokeToken(ctx context.Context, tenantID, tokenID string) error {
	return s.store.Revoke(ctx, tenantID, tokenID)
}
