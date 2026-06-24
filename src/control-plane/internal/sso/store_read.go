/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_read.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:56:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:56:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package sso

import "context"

// GetByID fetches a connection by its uuid. tenant scoping is NOT applied here
// (the begin path resolves a connection the caller already named); the WHERE on
// id is unique. The decrypted secret is loaded into Connection.ClientSecret.
func (s *Store) GetByID(ctx context.Context, id string) (Connection, error) {
	rows, err := s.db.AdminQuery(ctx, selectConn+` WHERE id::text = $1`, id)
	if err != nil {
		return Connection{}, err
	}
	return s.scanOne(rows)
}

// GetByTenant lists a tenant's connections (tenant_id bound in WHERE). Secrets
// are decrypted back into memory for each row.
func (s *Store) GetByTenant(ctx context.Context, tenantID string) ([]Connection, error) {
	rows, err := s.db.AdminQuery(ctx, selectConn+` WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT 500`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Connection, 0)
	for rows.Next() {
		c, err := s.scanRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetByIssuer fetches a connection by (tenant_id, issuer) — the UNIQUE pair. Used
// to verify an id_token's iss resolves to exactly one registered connection.
func (s *Store) GetByIssuer(ctx context.Context, tenantID, issuer string) (Connection, error) {
	rows, err := s.db.AdminQuery(ctx, selectConn+` WHERE tenant_id = $1 AND issuer = $2`, tenantID, issuer)
	if err != nil {
		return Connection{}, err
	}
	return s.scanOne(rows)
}

// GetByEmailDomain resolves a connection by (tenant_id, email_domain) — the
// BeginLogin-by-email path. tenant_id is mandatory (no cross-tenant scan).
func (s *Store) GetByEmailDomain(ctx context.Context, tenantID, domain string) (Connection, error) {
	rows, err := s.db.AdminQuery(ctx,
		selectConn+` WHERE tenant_id = $1 AND email_domain = $2 ORDER BY created_at DESC LIMIT 1`,
		tenantID, domain)
	if err != nil {
		return Connection{}, err
	}
	return s.scanOne(rows)
}
