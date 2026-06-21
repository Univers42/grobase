/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package environments — per-project environments (dev/staging/prod): the key-bearing scope
// vault42 derives a per-environment keypair from. CONTROL-PLANE ONLY (never enters the RLS
// GUCs / data plane); flag-gated by ENVIRONMENTS_ENABLED (requires RBAC_HIERARCHY_ENABLED).
// Mirrors the teams package shape.
package environments

import "regexp"

// envErr is the package's const-error type (errors.Is works, no package-level var).
type envErr string

func (e envErr) Error() string { return string(e) }

const (
	// ErrNotFound — an environment row does not exist (404).
	ErrNotFound envErr = "not found"
	// ErrConflict — a duplicate (project, name) environment (409).
	ErrConflict envErr = "already exists"
	// ErrBadName — the name violates the slug charset (400).
	ErrBadName envErr = "name must match ^[a-z0-9][a-z0-9_-]{0,62}$"
)

// namePattern mirrors the DB CHECK on environments.name.
const namePattern = `^[a-z0-9][a-z0-9_-]{0,62}$`

// Environment is the public projection of public.environments.
type Environment struct {
	ID        string  `json:"id"`
	ProjectID string  `json:"project_id"`
	Name      string  `json:"name"`
	CreatedBy *string `json:"created_by,omitempty"`
	CreatedAt string  `json:"created_at"`
}

// CreateEnvironmentRequest is the POST /v1/projects/{id}/environments body.
type CreateEnvironmentRequest struct {
	Name string `json:"name"`
}

// Validate enforces the same charset as the DB CHECK.
func (r CreateEnvironmentRequest) Validate() error {
	if !regexp.MustCompile(namePattern).MatchString(r.Name) {
		return ErrBadName
	}
	return nil
}
