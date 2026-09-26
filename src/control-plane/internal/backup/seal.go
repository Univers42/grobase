package backup

import (
	"fmt"
	"io"

	"filippo.io/age"
)

// sealedSuffix ends the store key (and so the ledger location) of an
// age-sealed artifact. Restore reads the seal state from the ledger, never from
// the artifact's bytes, which tenant data can shape.
const sealedSuffix = ".age"

// ErrPlaintextArtifact refuses a plaintext artifact on a deployment that seals
// its backups: a swapped-in clear artifact must not restore silently.
const ErrPlaintextArtifact backupErr = "backup: artifact is not encrypted but TENANT_BACKUP_AGE_RECIPIENTS is set — restore refused (TENANT_BACKUP_ALLOW_PLAINTEXT_RESTORE=1 allows it)"

// ErrArtifactSealed means the artifact is encrypted and no identity is configured.
const ErrArtifactSealed backupErr = "backup: artifact is encrypted and TENANT_BACKUP_AGE_IDENTITY_FILE is not set"

// Sealer holds the age keys of per-tenant backup artifacts. No recipients =
// artifacts are written in clear (parity); no identities = a sealed artifact
// cannot be opened. The zero value is the parity sealer.
type Sealer struct {
	recipients     []age.Recipient
	identities     []age.Identity
	allowPlaintext bool
}

// sealing reports whether new artifacts are sealed.
func (sl Sealer) sealing() bool { return len(sl.recipients) > 0 }

// artifactKey is the store key of a backup; a sealed artifact carries sealedSuffix.
func artifactKey(tenantID, backupID string, sealed bool) string {
	if sealed {
		return tenantID + "/" + backupID + sealedSuffix
	}
	return tenantID + "/" + backupID
}

// writeTo runs fill against dst, through an age stream when recipients are set.
// On a fill error the age stream is deliberately NOT closed: closing writes the
// final chunk, which would authenticate a truncated artifact.
func (sl Sealer) writeTo(dst io.Writer, fill func(io.Writer) error) error {
	if !sl.sealing() {
		return fill(dst)
	}
	w, err := age.Encrypt(dst, sl.recipients...)
	if err != nil {
		return fmt.Errorf("backup: start artifact encryption: %w", err)
	}
	if err := fill(w); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("backup: finish artifact encryption: %w", err)
	}
	return nil
}

// open reads src to EOF (so a caller hashing src sees every stored byte; age
// itself refuses bytes after its final chunk) and returns the artifact's
// plaintext. sealed is the ledger's record of how the artifact was written.
func (sl Sealer) open(src io.Reader, sealed bool) ([]byte, error) {
	r, err := sl.reader(src, sealed)
	if err != nil {
		return nil, err
	}
	plain, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("backup: read artifact: %w", err)
	}
	return plain, nil
}

// reader returns the plaintext view of src: an age decryptor for a sealed
// artifact, src itself for a plaintext one the policy accepts.
func (sl Sealer) reader(src io.Reader, sealed bool) (io.Reader, error) {
	if !sealed {
		if sl.sealing() && !sl.allowPlaintext {
			return nil, ErrPlaintextArtifact
		}
		return src, nil
	}
	if len(sl.identities) == 0 {
		return nil, ErrArtifactSealed
	}
	r, err := age.Decrypt(src, sl.identities...)
	if err != nil {
		return nil, fmt.Errorf("backup: decrypt artifact: %w", err)
	}
	return r, nil
}
