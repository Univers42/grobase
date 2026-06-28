/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ensure_database.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pg

import (
	"context"
	"fmt"
)

// EnsureDatabase creates a fresh physical database (idempotent) — the strongest provisionable
// isolation boundary for a self-serve app: a foreign app's key can never resolve a mount in
// another app's database. CREATE DATABASE cannot run in a transaction nor take a bound
// parameter, so the identifier is validated here (defense-in-depth) and quoted, never
// interpolated raw. Needs CREATEDB on the control-plane role (true for the single-container
// superuser the fly deploy runs as).
func (p *Postgres) EnsureDatabase(ctx context.Context, name string) error {
	if !validIdentifier(name) {
		return fmt.Errorf("invalid database identifier %q", name)
	}
	var exists bool
	row := p.AdminQueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)`, name)
	if err := row.Scan(&exists); err != nil {
		return err
	}
	if exists {
		return nil
	}
	return p.AdminExec(ctx, `CREATE DATABASE "`+name+`"`)
}

// validIdentifier accepts only a safe, bounded Postgres identifier: 1–63 chars, first a lowercase
// letter, the rest lowercase alphanumerics or underscores. This is what makes the quoted
// interpolation in EnsureDatabase injection-proof.
func validIdentifier(s string) bool {
	if len(s) == 0 || len(s) > 63 {
		return false
	}
	for i, r := range s {
		switch {
		case r >= 'a' && r <= 'z':
		case i > 0 && (r >= '0' && r <= '9' || r == '_'):
		default:
			return false
		}
	}
	return true
}
