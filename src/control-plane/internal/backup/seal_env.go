package backup

import (
	"fmt"
	"os"
	"strings"

	"filippo.io/age"
)

// NewSealerFromEnv builds the artifact sealer from TENANT_BACKUP_AGE_RECIPIENTS
// (age public keys, comma separated), TENANT_BACKUP_AGE_IDENTITY_FILE (a 0600
// file of age private keys; list old ones too so older backups stay restorable)
// and TENANT_BACKUP_ALLOW_PLAINTEXT_RESTORE. All unset = the parity sealer.
// It errors, so boot fails, when recipients are set but no identity matches
// one of them: tenant-control would write backups it cannot restore.
func NewSealerFromEnv() (Sealer, error) {
	var sl Sealer
	var err error
	if v := strings.TrimSpace(os.Getenv("TENANT_BACKUP_AGE_RECIPIENTS")); v != "" {
		if sl.recipients, err = age.ParseRecipients(strings.NewReader(strings.Join(strings.Fields(strings.ReplaceAll(v, ",", " ")), "\n"))); err != nil {
			return Sealer{}, fmt.Errorf("backup: TENANT_BACKUP_AGE_RECIPIENTS: %w", err)
		}
	}
	if path := os.Getenv("TENANT_BACKUP_AGE_IDENTITY_FILE"); path != "" {
		if sl.identities, err = loadIdentities(path); err != nil {
			return Sealer{}, err
		}
	}
	sl.allowPlaintext = os.Getenv("TENANT_BACKUP_ALLOW_PLAINTEXT_RESTORE") == "1"
	if len(sl.recipients) > 0 && !identityMatches(sl.identities, sl.recipients) {
		return Sealer{}, fmt.Errorf("backup: no identity in TENANT_BACKUP_AGE_IDENTITY_FILE matches a TENANT_BACKUP_AGE_RECIPIENTS key — backups could not be restored")
	}
	return sl, nil
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
