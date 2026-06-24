/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 07:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 07:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package pubkeys — the member X25519 public-key registry + the grant-fulfilment seam between
// the control plane (WHO may access) and the vault42 zero-knowledge crypto plane (WHO CAN
// decrypt). NO PRIVATE KEYS are stored. The control plane owns the QUESTION ("is this grant
// provisioned to its members?", GET .../fulfilled); vault42 (or the admin's sync-keys) records
// the ANSWER (POST .../wraps) after it wraps an environment scope key to a member.
// CONTROL-PLANE ONLY; flag-gated by USER_PUBKEYS_ENABLED.
package pubkeys

// pubErr is the package's const-error type (errors.Is works, no package-level var).
type pubErr string

func (e pubErr) Error() string { return string(e) }

const (
	// ErrNotFound — a pubkey / grant row does not exist (404).
	ErrNotFound pubErr = "not found"
	// ErrBadReq — a missing required field (400).
	ErrBadReq pubErr = "x25519_pub, v42_address and pubkey_sig are required"
)

// Pubkey is the public projection of public.user_pubkeys (all PUBLIC material).
type Pubkey struct {
	UserID     string `json:"user_id"`
	OrgID      string `json:"org_id"`
	Ed25519Pub string `json:"ed25519_pub"`
	X25519Pub  string `json:"x25519_pub"`
	V42Address string `json:"v42_address"`
	PubkeySig  string `json:"pubkey_sig"`
	CreatedAt  string `json:"created_at"`
	RotatedAt  string `json:"rotated_at,omitempty"`
}

// RegisterPubkeyRequest is the PUT /v1/orgs/{orgId}/pubkey body. The caller registers their
// OWN keys (user_id comes from the JWT, never the body). pubkey_sig is the member's Ed25519
// self-signature over (user_id||org_id||x25519_pub) — proof-of-possession.
type RegisterPubkeyRequest struct {
	Ed25519Pub string `json:"ed25519_pub"`
	X25519Pub  string `json:"x25519_pub"`
	V42Address string `json:"v42_address"`
	PubkeySig  string `json:"pubkey_sig"`
}

// FulfilledResponse reports whether a grant's scope key has been wrapped to every effective
// member; Missing lists the user ids still awaiting provisioning (pending-provision).
type FulfilledResponse struct {
	Fulfilled bool     `json:"fulfilled"`
	Missing   []string `json:"missing"`
}
