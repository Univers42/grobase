package backup

import (
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"unicode"

	"filippo.io/age"
)

// NewSealerFromEnv builds the artifact sealer from TENANT_BACKUP_AGE_RECIPIENTS
// (age public keys, comma or whitespace separated), TENANT_BACKUP_AGE_IDENTITY_FILE
// (a 0600 file of age private keys; list old ones too so older backups stay
// restorable) and TENANT_BACKUP_ALLOW_PLAINTEXT_RESTORE. All unset = the parity
// sealer. It errors, so boot fails, on a configuration usable() refuses.
func NewSealerFromEnv() (Sealer, error) {
	sl, err := sealerFromEnv()
	if err == nil {
		err = sl.usable(os.Getenv("BACKUP_AGE_RECIPIENTS"))
	}
	if err != nil {
		return Sealer{}, err
	}
	return sl, nil
}

// sealerFromEnv parses the TENANT_BACKUP_AGE_* variables.
func sealerFromEnv() (Sealer, error) {
	var sl Sealer
	var err error
	if keys := keyList(os.Getenv("TENANT_BACKUP_AGE_RECIPIENTS")); len(keys) > 0 {
		if sl.recipients, err = age.ParseRecipients(strings.NewReader(strings.Join(keys, "\n"))); err != nil {
			return Sealer{}, fmt.Errorf("backup: TENANT_BACKUP_AGE_RECIPIENTS: %w", err)
		}
	}
	if path := os.Getenv("TENANT_BACKUP_AGE_IDENTITY_FILE"); path != "" {
		if sl.identities, err = loadIdentities(path); err != nil {
			return Sealer{}, err
		}
	}
	sl.allowPlaintext = os.Getenv("TENANT_BACKUP_ALLOW_PLAINTEXT_RESTORE") == "1"
	return sl, nil
}

// usable refuses a sealer that holds a key to the whole-cluster backups (cluster
// is BACKUP_AGE_RECIPIENTS), that could not restore what it writes (no identity
// matches a recipient), or whose recipients age cannot seal to together (a
// post-quantum key mixed with a classic one).
func (sl Sealer) usable(cluster string) error {
	if opensAny(sl.identities, keyList(cluster)) {
		return fmt.Errorf("backup: an identity in TENANT_BACKUP_AGE_IDENTITY_FILE opens BACKUP_AGE_RECIPIENTS (whole-cluster backups) — give per-tenant backups their own key")
	}
	if !sl.sealing() {
		return nil
	}
	if !identityMatches(sl.identities, sl.recipients) {
		return fmt.Errorf("backup: no identity in TENANT_BACKUP_AGE_IDENTITY_FILE matches a TENANT_BACKUP_AGE_RECIPIENTS key — backups could not be restored")
	}
	if _, err := age.Encrypt(io.Discard, sl.recipients...); err != nil {
		return fmt.Errorf("backup: TENANT_BACKUP_AGE_RECIPIENTS cannot be sealed to together: %w", err)
	}
	return nil
}

// keyList splits an age key list on commas and whitespace.
func keyList(v string) []string {
	return strings.FieldsFunc(v, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
}

// opensAny reports whether some identity's public key is one of keys.
func opensAny(ids []age.Identity, keys []string) bool {
	for _, id := range ids {
		if pub := publicKeyOf(id); pub != "" && slices.Contains(keys, pub) {
			return true
		}
	}
	return false
}

// loadIdentities parses the age identity file at path, refusing one that group
// or others can read (it holds private keys).
func loadIdentities(path string) ([]age.Identity, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("backup: TENANT_BACKUP_AGE_IDENTITY_FILE: %w", err)
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("backup: TENANT_BACKUP_AGE_IDENTITY_FILE: %w", err)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("backup: TENANT_BACKUP_AGE_IDENTITY_FILE %s is mode %04o, want 0600 (it holds private keys)", path, fi.Mode().Perm())
	}
	ids, err := age.ParseIdentities(f)
	if err != nil {
		return nil, fmt.Errorf("backup: TENANT_BACKUP_AGE_IDENTITY_FILE: %w", err)
	}
	return ids, nil
}

// identityMatches reports whether some identity's public key is among recipients.
func identityMatches(ids []age.Identity, recipients []age.Recipient) bool {
	for _, id := range ids {
		pub := publicKeyOf(id)
		for _, r := range recipients {
			if s, ok := r.(fmt.Stringer); ok && pub != "" && s.String() == pub {
				return true
			}
		}
	}
	return false
}

// publicKeyOf returns the recipient string of an X25519 or hybrid identity, ""
// for any other kind.
func publicKeyOf(id age.Identity) string {
	switch v := id.(type) {
	case *age.X25519Identity:
		return v.Recipient().String()
	case *age.HybridIdentity:
		return v.Recipient().String()
	default:
		return ""
	}
}
