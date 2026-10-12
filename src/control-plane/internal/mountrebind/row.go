package mountrebind

import (
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
)

// cipherColumn names the four bytea columns in EncryptedPayload field order.
func cipherColumn(i int) string {
	switch i {
	case 0:
		return "connection_enc"
	case 1:
		return "connection_iv"
	case 2:
		return "connection_tag"
	}
	return "connection_salt"
}

// row re-seals one COPY row under the target key when the source key opens it, with the
// DSN RewriteDSN returns; a row without ciphertext, one the source key cannot open and a
// Refused one are returned byte for byte.
func (rw *rewriter) row(line string, cols map[string]int) (string, error) {
	fields := strings.Split(strings.TrimSuffix(line, "\n"), "\t")
	rec := Row{ID: field(fields, cols, "id"), Engine: field(fields, cols, "engine"), Outcome: NoCiphertext}
	defer func() { rw.stats.Rows = append(rw.stats.Rows, rec) }()
	payload, ok := payloadOf(fields, cols)
	if !ok {
		return line, nil
	}
	dsn, err := rw.source.Decrypt(payload)
	if err != nil {
		rec.Outcome = Undecryptable
		return line, nil
	}
	next, outcome := RewriteDSN(rec.Engine, dsn, rw.targets)
	rec.Outcome = outcome
	if outcome == Refused {
		return line, nil
	}
	if err := rw.seal(fields, cols, next); err != nil {
		return "", fmt.Errorf("row %s: %w", rec.ID, err)
	}
	rec.Resealed = true
	return strings.Join(fields, "\t") + "\n", nil
}

// seal encrypts dsn under the target key and opens it again with the same production
// Encryptor before anything is written, so a row the control plane could not read never lands.
func (rw *rewriter) seal(fields []string, cols map[string]int, dsn string) error {
	p, err := rw.target.Encrypt(dsn)
	if err != nil {
		return err
	}
	back, err := rw.target.Decrypt(p)
	if err != nil || back != dsn {
		return fmt.Errorf("re-encrypted DSN does not decrypt back to itself")
	}
	for i, b := range [4][]byte{p.Encrypted, p.IV, p.Tag, p.Salt} {
		fields[cols[cipherColumn(i)]] = `\\x` + hex.EncodeToString(b)
	}
	return nil
}

// payloadOf reads the four bytea columns, which COPY text writes as \\x<hex>; a \N or
// malformed value means the row carries no ciphertext to rebind.
func payloadOf(fields []string, cols map[string]int) (adapterregistry.EncryptedPayload, bool) {
	var raw [4][]byte
	for i := range raw {
		v := field(fields, cols, cipherColumn(i))
		b, err := hex.DecodeString(strings.TrimPrefix(v, `\\x`))
		if !strings.HasPrefix(v, `\\x`) || err != nil {
			return adapterregistry.EncryptedPayload{}, false
		}
		raw[i] = b
	}
	return adapterregistry.EncryptedPayload{Encrypted: raw[0], IV: raw[1], Tag: raw[2], Salt: raw[3]}, true
}

// field returns the named column of a row, or "" when the header lacks it or the row is short.
func field(fields []string, cols map[string]int, name string) string {
	i, ok := cols[name]
	if !ok || i >= len(fields) {
		return ""
	}
	return fields[i]
}
