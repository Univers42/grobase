package passkeys

import (
	"encoding/base64"
	"errors"
	"strings"

	"github.com/go-webauthn/webauthn/protocol"
)

// wrapProtocol unwraps go-webauthn's verbose protocol.Error into a compact
// message (its DevInfo is internal detail not for the wire).
func wrapProtocol(err error) error {
	var perr *protocol.Error
	if errors.As(err, &perr) {
		return errors.New(strings.TrimSpace(perr.Type + ": " + perr.Details))
	}
	return err
}

func displayOr(display, fallback string) string {
	if strings.TrimSpace(display) != "" {
		return display
	}
	return fallback
}

// resolveEmail returns the user's email if any stored credential row carried it
// (the name column); otherwise the user id. Passkey login does not require an
// email — the session's authority is the verified credential, not the address.
func resolveEmail(stored []storedCredential, userID string) string {
	for _, sc := range stored {
		if strings.Contains(sc.Name, "@") {
			return sc.Name
		}
	}
	return userID
}

// base64urlEncode encodes a credential id the way the store keys it (base64url,
// no padding) so the post-login sign_count bump targets the right row.
func base64urlEncode(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}
