/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   credential_codec.go                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:09 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package passkeys

import (
	"encoding/base64"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

// newUser builds the WebAuthn user object from the identity + its stored
// credentials. userID is used as the stable user handle (decoded to bytes); the
// stored rows are decoded back into webauthn.Credential so the library can
// enforce ownership + verify the assertion against the right public key.
func newUser(userID, name, display string, stored []storedCredential) (*webauthnUser, error) {
	creds := make([]webauthn.Credential, 0, len(stored))
	for _, sc := range stored {
		c, err := decodeCredential(sc)
		if err != nil {
			return nil, err
		}
		creds = append(creds, c)
	}
	return &webauthnUser{
		id:          []byte(userID),
		name:        name,
		displayName: display,
		creds:       creds,
	}, nil
}

// decodeCredential rebuilds a webauthn.Credential from its stored text columns.
// credential_id is base64url; public_key + aaguid are base64-std (the verbatim
// byte slices go-webauthn produced at registration). The sign_count is carried
// so the library's clone-detection compares the asserted counter against it.
func decodeCredential(sc storedCredential) (webauthn.Credential, error) {
	cid, err := base64.RawURLEncoding.DecodeString(sc.CredentialID)
	if err != nil {
		return webauthn.Credential{}, err
	}
	pub, err := base64.StdEncoding.DecodeString(sc.PublicKey)
	if err != nil {
		return webauthn.Credential{}, err
	}
	var aaguid []byte
	if sc.AAGUID != "" {
		if aaguid, err = base64.StdEncoding.DecodeString(sc.AAGUID); err != nil {
			return webauthn.Credential{}, err
		}
	}
	return webauthn.Credential{
		ID:        cid,
		PublicKey: pub,
		Authenticator: webauthn.Authenticator{
			AAGUID:    aaguid,
			SignCount: sc.SignCount,
		},
	}, nil
}

// encodeCredential serializes a freshly verified webauthn.Credential into the
// durable text columns. credential_id stays base64url (the form the login
// lookup + allowCredentials use); public_key + aaguid are base64-std.
func encodeCredential(c *webauthn.Credential, tenantID, userID, name string) storedCredential {
	transports := make([]string, 0, len(c.Transport))
	for _, t := range c.Transport {
		transports = append(transports, string(t))
	}
	return storedCredential{
		TenantID:     tenantID,
		UserID:       userID,
		Name:         name,
		CredentialID: base64.RawURLEncoding.EncodeToString(c.ID),
		PublicKey:    base64.StdEncoding.EncodeToString(c.PublicKey),
		SignCount:    c.Authenticator.SignCount,
		AAGUID:       base64.StdEncoding.EncodeToString(c.Authenticator.AAGUID),
		Transports:   transportsCSV(transports),
	}
}

// withAllowCredentials narrows a login ceremony to a known user's credentials.
// Passed to BeginLogin so the assertion options carry allowCredentials, which
// also means a login/begin for a user with no passkey produces no offer (the
// store returns ErrNoCredentials before we get here).
func withAllowCredentials(stored []storedCredential) []protocol.CredentialDescriptor {
	out := make([]protocol.CredentialDescriptor, 0, len(stored))
	for _, sc := range stored {
		if cid, err := base64.RawURLEncoding.DecodeString(sc.CredentialID); err == nil {
			out = append(out, protocol.CredentialDescriptor{
				Type:         protocol.PublicKeyCredentialType,
				CredentialID: cid,
			})
		}
	}
	return out
}
