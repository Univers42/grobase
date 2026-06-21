/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   user.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package passkeys

import (
	"github.com/go-webauthn/webauthn/webauthn"
)

// webauthnUser adapts our durable user+credentials to the webauthn.User
// interface the library's Begin/Finish ceremonies consume. The library reads
// WebAuthnCredentials() to build allowCredentials on login and to verify the
// asserted credential id belongs to this user — so binding the right
// credentials here is the per-user authentication boundary (user U2 cannot
// finish a login as U1, because U1's credentials are not on U2's user object).
type webauthnUser struct {
	id          []byte // WebAuthn user handle (the GoTrue user UUID bytes)
	name        string // login name (email)
	displayName string
	creds       []webauthn.Credential
}

func (u *webauthnUser) WebAuthnID() []byte                         { return u.id }
func (u *webauthnUser) WebAuthnName() string                       { return u.name }
func (u *webauthnUser) WebAuthnDisplayName() string                { return u.displayName }
func (u *webauthnUser) WebAuthnIcon() string                       { return "" }
func (u *webauthnUser) WebAuthnCredentials() []webauthn.Credential { return u.creds }

// Credential <-> stored-row codec (newUser / decodeCredential / encodeCredential
// / withAllowCredentials) lives in credential_codec.go.
