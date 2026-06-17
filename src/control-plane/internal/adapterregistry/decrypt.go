package adapterregistry

import (
	"context"

	"github.com/dlesieur/mini-baas/control-plane/internal/cmek"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// resolveConnString returns the decrypted DSN, decrypting only when the
// ciphertext changed since the last call (the auth tag is a cryptographic digest
// of payload+key — equal tag ⇒ equal plaintext). Concurrent misses for one mount
// coalesce (sf); distinct cold inline mounts queue on the Encryptor's
// scryptSlots. See connCache.
func (s *Service) resolveConnString(ctx context.Context, id string, row mountRow) (string, error) {
	tag := string(row.payload.Tag)
	if v, ok := s.connCache.Load(id); ok {
		if e, ok := v.(connCacheEntry); ok && e.tag == tag {
			return e.conn, nil
		}
	}
	v, derr, _ := s.sf.Do(id+"\x00"+tag, func() (any, error) {
		if v, ok := s.connCache.Load(id); ok {
			if e, ok := v.(connCacheEntry); ok && e.tag == tag {
				return e.conn, nil
			}
		}
		c, err := s.decryptMount(ctx, row)
		if err != nil {
			return nil, err
		}
		s.connCache.Store(id, connCacheEntry{tag: tag, conn: c})
		return c, nil
	})
	if derr != nil {
		return "", derr
	}
	conn, _ := v.(string)
	return conn, nil
}

// decryptMount opens the ciphertext: a CMEK-envelope mount unwraps the DEK via
// the KMS (one round-trip per ciphertext) then AES-GCM-opens the DSN; an inline
// mount uses the platform master key. If the KMS cannot unwrap (key revoked),
// cmek.Open returns ErrShredded — crypto-shred by construction.
func (s *Service) decryptMount(ctx context.Context, row mountRow) (string, error) {
	if len(row.cmekWrap) > 0 {
		ct := cmek.JoinCiphertext(row.payload.Encrypted, row.payload.Tag)
		plain, err := cmek.Open(ctx, s.kms, shared.DerefStr(row.cmekKeyPtr), row.cmekWrap, row.payload.IV, ct)
		if err != nil {
			return "", err
		}
		return string(plain), nil
	}
	return s.enc.Decrypt(row.payload)
}
