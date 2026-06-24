/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models_test.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:42 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:43 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import "testing"

// TestValidateCredentialXOR pins the S2 (G-Vault) EXACTLY-ONE-OF
// {connection_string, credential_ref} contract on RegisterDatabaseRequest.
// The DB CHECK (migration 060) mirrors this as a backstop, but the DTO is the
// first gate — this table makes the four-quadrant truth table a regression pin
// independent of the live m121 gate.
func TestValidateCredentialXOR(t *testing.T) {
	const (
		eng = "postgresql"
		nm  = "tenantdb"
		dsn = "postgres://u:p@h:5432/db"
	)
	ref := func(provider, reference, version string) CredentialRefInput {
		return CredentialRefInput{Provider: provider, Reference: reference, Version: version}
	}
	cases := []struct {
		name    string
		req     RegisterDatabaseRequest
		wantErr bool
	}{
		{
			"inline only accepted",
			RegisterDatabaseRequest{Engine: eng, Name: nm, ConnectionString: dsn},
			false,
		},
		{
			"ref only (provider+reference) accepted",
			RegisterDatabaseRequest{Engine: eng, Name: nm, CredentialRef: ref("vault", "data-plane/dsn/x", "")},
			false,
		},
		{
			"ref only with version accepted",
			RegisterDatabaseRequest{Engine: eng, Name: nm, CredentialRef: ref("vault", "data-plane/dsn/x", "3")},
			false,
		},
		{
			"both set rejected",
			RegisterDatabaseRequest{Engine: eng, Name: nm, ConnectionString: dsn, CredentialRef: ref("vault", "data-plane/dsn/x", "")},
			true,
		},
		{
			"neither set rejected",
			RegisterDatabaseRequest{Engine: eng, Name: nm},
			true,
		},
		{
			"ref missing provider rejected",
			RegisterDatabaseRequest{Engine: eng, Name: nm, CredentialRef: ref("", "data-plane/dsn/x", "")},
			true,
		},
		{
			"ref missing reference rejected",
			RegisterDatabaseRequest{Engine: eng, Name: nm, CredentialRef: ref("vault", "", "")},
			true,
		},
		{
			"version-only ref rejected (provider+reference missing)",
			RegisterDatabaseRequest{Engine: eng, Name: nm, CredentialRef: ref("", "", "7")},
			true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.req.Validate()
			if tc.wantErr && err == nil {
				t.Fatalf("Validate() = nil, want error")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("Validate() = %v, want nil", err)
			}
		})
	}
}

// TestValidateBaselineUnchanged guards the pre-S2 contract: a plain inline
// registration with a valid engine/name still validates, and the existing
// engine/name guards still fire (so the XOR additions did not loosen them).
func TestValidateBaselineUnchanged(t *testing.T) {
	ok := RegisterDatabaseRequest{Engine: "mysql", Name: "db", ConnectionString: "mysql://h/db"}
	if err := ok.Validate(); err != nil {
		t.Fatalf("valid inline request rejected: %v", err)
	}
	badEngine := RegisterDatabaseRequest{Engine: "nope", Name: "db", ConnectionString: "x"}
	if badEngine.Validate() == nil {
		t.Fatalf("unsupported engine accepted")
	}
	badName := RegisterDatabaseRequest{Engine: "postgresql", Name: "", ConnectionString: "x"}
	if badName.Validate() == nil {
		t.Fatalf("empty name accepted")
	}
}
