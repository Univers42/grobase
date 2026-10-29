/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   descriptor.go                                      :+:      :+:    :+:   */
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
	"regexp"

	"github.com/jackc/pgx/v5"
)

// MountDescriptor says where a mount's data lives (G4) so the UI can name the DBMS, host or
// file a database is bound to. It is built from the decrypted DSN but carries no
// credential: never the password, the user, the raw DSN or a vault reference.
type MountDescriptor struct {
	ID             string  `json:"id"`
	Name           string  `json:"name"`
	Engine         string  `json:"engine"`
	Isolation      string  `json:"isolation"`
	CredentialMode string  `json:"credential_mode"`
	Location       string  `json:"location"`
	Host           string  `json:"host,omitempty"`
	Port           int     `json:"port,omitempty"`
	File           string  `json:"file,omitempty"`
	Database       string  `json:"database,omitempty"`
	TLS            string  `json:"tls"`
	CreatedAt      string  `json:"created_at"`
	LastHealthyAt  *string `json:"last_healthy_at"`
}

var providerName = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)

// Describe returns the mount's descriptor, tenant-scoped like FindOne. Unlike GetConnection
// it does not stamp last_healthy_at (reading the label is not a connection) and never calls
// an external KMS: a CMEK or vault mount reports its credential mode and no location.
func (s *Service) Describe(ctx context.Context, userID, id string) (MountDescriptor, error) {
	meta, err := s.FindOne(ctx, userID, id)
	if err != nil {
		return MountDescriptor{}, err
	}
	var row mountRow
	err = s.db.TenantTx(ctx, userID, func(tx pgx.Tx) error {
		row, err = scanMountRow(ctx, tx, userID, id)
		return err
	})
	if err != nil {
		return MountDescriptor{}, err
	}
	d := MountDescriptor{
		ID: meta.ID, Name: meta.Name, Engine: row.engine, Isolation: row.isolation,
		CreatedAt: meta.CreatedAt, LastHealthyAt: meta.LastHealthyAt,
		CredentialMode: "inline", Location: locationUnknown, TLS: tlsUnknown,
	}
	switch {
	case row.provider != nil && *row.provider != "":
		d.CredentialMode = "external"
		if providerName.MatchString(*row.provider) {
			d.CredentialMode = *row.provider
		}
		return d, nil
	case len(row.cmekWrap) > 0:
		d.CredentialMode = "cmek"
		return d, nil
	}
	dsn, err := s.resolveConnString(ctx, id, row)
	if err != nil {
		return MountDescriptor{}, err
	}
	return d.withFacts(describeDSN(row.engine, dsn)), nil
}

func (d MountDescriptor) withFacts(f dsnFacts) MountDescriptor {
	d.Location, d.Host, d.Port, d.File, d.Database, d.TLS = f.location, f.host, f.port, f.file, f.database, f.tls
	return d
}
