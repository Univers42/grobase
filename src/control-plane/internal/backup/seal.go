package backup

import (
	"bufio"
	"errors"
	"fmt"
	"io"

	"filippo.io/age"
)

// ageHeader opens every age v1 file; restore sniffs it to tell a sealed artifact
// from a legacy plaintext one.
const ageHeader = "age-encryption.org/v1\n"

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

// writeTo runs fill against dst, through an age stream when recipients are set.
// On a fill error the age stream is deliberately NOT closed: closing writes the
// final chunk, which would authenticate a truncated artifact.
func (sl Sealer) writeTo(dst io.Writer, fill func(io.Writer) error) error {
	if len(sl.recipients) == 0 {
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
// plaintext, decrypting a sealed artifact.
// Ponytail: sealed-vs-plain is sniffed from the age header — a plaintext artifact
// whose first COPY row starts with that header fails to decrypt, so it is refused
// (fail-closed), never mis-restored.
func (sl Sealer) open(src io.Reader) ([]byte, error) {
	br := bufio.NewReader(src)
	r, err := sl.reader(br)
	if err != nil {
		return nil, err
	}
	plain, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("backup: read artifact: %w", err)
	}
	return plain, nil
}

// reader returns the plaintext view of br: an age decryptor for a sealed
// artifact, br itself for a plaintext one the policy accepts.
func (sl Sealer) reader(br *bufio.Reader) (io.Reader, error) {
	head, err := br.Peek(len(ageHeader))
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("backup: read artifact: %w", err)
	}
	if string(head) != ageHeader {
		if len(sl.recipients) > 0 && !sl.allowPlaintext {
			return nil, ErrPlaintextArtifact
		}
		return br, nil
	}
	if len(sl.identities) == 0 {
		return nil, ErrArtifactSealed
	}
	r, err := age.Decrypt(br, sl.identities...)
	if err != nil {
		return nil, fmt.Errorf("backup: decrypt artifact: %w", err)
	}
	return r, nil
}
