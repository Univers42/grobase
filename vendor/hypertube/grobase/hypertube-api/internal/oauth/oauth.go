// Package oauth implements the subject-mandated OAuth2 client_credentials grant:
// it mints short-lived HS256 bearer tokens and guards routes with a bearer
// middleware. The JWT secret and client credentials are env-injected (never global).
package oauth

import (
	"crypto/subtle"
	"time"
)

// Audience is the required aud claim on every token this service issues/accepts.
const Audience = "hypertube-api"

// tokenTTL bounds a minted token's lifetime (short, per the contract).
const tokenTTL = 15 * time.Minute

// Issuer mints and verifies HS256 tokens and validates client credentials. It
// holds only secrets passed in at construction — no package-level state.
type Issuer struct {
	jwtSecret    []byte
	clientID     string
	clientSecret string
}

// New returns an Issuer bound to the JWT signing secret and the one accepted
// client credential pair.
func New(jwtSecret, clientID, clientSecret string) *Issuer {
	return &Issuer{jwtSecret: []byte(jwtSecret), clientID: clientID, clientSecret: clientSecret}
}

// ValidClient compares the supplied credentials constant-time against the
// configured pair, returning true only when both match.
func (i *Issuer) ValidClient(id, secret string) bool {
	idOK := subtle.ConstantTimeCompare([]byte(id), []byte(i.clientID)) == 1
	secretOK := subtle.ConstantTimeCompare([]byte(secret), []byte(i.clientSecret)) == 1
	return idOK && secretOK
}
