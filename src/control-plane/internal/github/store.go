/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:19 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:20 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package github

import (
	"context"
	"encoding/json"
	"time"
)

// store.go — persistence for the four linkage tables (admin pool). NO token columns
// exist; nothing here ever stores a GitHub token.

// upsertInstallation records (or refreshes) a GitHub App installation's identity.
func (s *Service) upsertInstallation(ctx context.Context, in Installation) error {
	perms, _ := json.Marshal(in.Permissions)
	return s.db.AdminExec(ctx, `
		INSERT INTO public.github_installations
		  (installation_id, github_org_login, github_org_id, app_slug, permissions, updated_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, now())
		ON CONFLICT (installation_id) DO UPDATE SET
		  github_org_login = EXCLUDED.github_org_login, github_org_id = EXCLUDED.github_org_id,
		  app_slug = EXCLUDED.app_slug, permissions = EXCLUDED.permissions, updated_at = now()`,
		in.InstallationID, in.OrgLogin, in.OrgID, in.AppSlug, string(perms))
}

// putPending inserts a fresh pending-connect nonce (TTL 10 min).
func (s *Service) putPending(ctx context.Context, nonce, orgID, initiatedBy string) error {
	expires := s.now().UTC().Add(10 * time.Minute)
	return s.db.AdminExec(ctx, `
		INSERT INTO public.github_connect_pending (nonce, org_id, initiated_by, status, expires_at)
		VALUES ($1, NULLIF($2,'')::uuid, $3, 'pending', $4)`,
		nonce, orgID, initiatedBy, expires)
}

// takePendingForCallback consumes a nonce on the relay callback: it must be pending
// and unexpired; marks it ready with the installation. ErrNotFound otherwise (single-use).
func (s *Service) markPendingReady(ctx context.Context, nonce string, installID int64) error {
	tag, err := s.execTag(ctx, `
		UPDATE public.github_connect_pending SET status='ready', installation_id=$2
		 WHERE nonce=$1 AND status='pending' AND expires_at > now()`, nonce, installID)
	if err != nil {
		return err
	}
	if tag == 0 {
		return ErrNotFound
	}
	return nil
}

// pendingStatus reads a nonce's status + resolved installation for the CLI poll.
func (s *Service) pendingStatus(ctx context.Context, nonce string) (ConnectStatus, error) {
	rows, err := s.db.AdminQuery(ctx, `
		SELECT p.status, COALESCE(p.installation_id,0), COALESCE(i.github_org_login,'')
		  FROM public.github_connect_pending p
		  LEFT JOIN public.github_installations i ON i.installation_id = p.installation_id
		 WHERE p.nonce=$1`, nonce)
	if err != nil {
		return ConnectStatus{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return ConnectStatus{}, ErrNotFound
	}
	var st ConnectStatus
	if err := rows.Scan(&st.Status, &st.InstallationID, &st.OrgLogin); err != nil {
		return ConnectStatus{}, err
	}
	return st, nil
}

// installationForOrgLogin resolves a recorded installation by GitHub org login.
func (s *Service) installationForOrgLogin(ctx context.Context, login string) (int64, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT installation_id FROM public.github_installations WHERE lower(github_org_login)=lower($1)`, login)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	if !rows.Next() {
		return 0, ErrNotFound
	}
	var id int64
	if err := rows.Scan(&id); err != nil {
		return 0, err
	}
	return id, nil
}

// upsertLink links a vault42 org to an installation (idempotent).
func (s *Service) upsertLink(ctx context.Context, orgID string, installID int64, linkedBy string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.github_links (org_id, installation_id, linked_by)
		VALUES ($1::uuid, $2, $3)
		ON CONFLICT (org_id, installation_id) DO UPDATE SET linked_by = EXCLUDED.linked_by`,
		orgID, installID, linkedBy)
}

// linkInstallation resolves the installation linked to a vault42 org.
func (s *Service) linkInstallation(ctx context.Context, orgID string) (int64, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT installation_id FROM public.github_links WHERE org_id::text=$1 LIMIT 1`, orgID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	if !rows.Next() {
		return 0, ErrNotFound
	}
	var id int64
	if err := rows.Scan(&id); err != nil {
		return 0, err
	}
	return id, nil
}

// upsertUserLink records the GitHub user → GoTrue subject mapping after a login.
func (s *Service) upsertUserLink(ctx context.Context, githubUserID int64, login, userID string) error {
	return s.db.AdminExec(ctx, `
		INSERT INTO public.github_user_links (github_user_id, github_login, user_id)
		VALUES ($1, $2, $3)
		ON CONFLICT (github_user_id) DO UPDATE SET github_login = EXCLUDED.github_login`,
		githubUserID, login, userID)
}

// execTag runs a write and returns the affected-row count (drains the empty result).
func (s *Service) execTag(ctx context.Context, sql string, args ...any) (int64, error) {
	rows, err := s.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return 0, err
	}
	for rows.Next() {
	}
	return rows.CommandTag().RowsAffected(), rows.Err()
}
