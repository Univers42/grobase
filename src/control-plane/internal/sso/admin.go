package sso

import (
	"context"
	"errors"
	"strings"
)

// RegisterConnection seals + persists a new IdP connection (admin path). A
// duplicate (tenant, issuer) is ErrConflict; missing required fields ErrValidation.
func (s *Service) RegisterConnection(ctx context.Context, in RegisterInput) (Connection, error) {
	if err := validateRegister(in); err != nil {
		return Connection{}, err
	}
	return s.store.Insert(ctx, in)
}

// ListConnections returns a tenant's connections (admin path), tenant_id bound.
func (s *Service) ListConnections(ctx context.Context, tenantID string) ([]Connection, error) {
	return s.store.GetByTenant(ctx, tenantID)
}

func validateRegister(in RegisterInput) error {
	missing := strings.TrimSpace(in.TenantID) == "" ||
		strings.TrimSpace(in.Issuer) == "" ||
		strings.TrimSpace(in.ClientID) == "" ||
		strings.TrimSpace(in.AuthorizeURL) == "" ||
		strings.TrimSpace(in.TokenURL) == "" ||
		strings.TrimSpace(in.RedirectURI) == ""
	if missing {
		return errors.Join(ErrValidation,
			errors.New("issuer, client_id, authorize_url, token_url, redirect_uri are required"))
	}
	return nil
}
