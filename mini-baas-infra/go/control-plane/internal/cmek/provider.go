package cmek

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// VaultTransitProvider is the REAL KMS: it wraps/unwraps the DEK via the
// HashiCorp Vault Transit secrets engine over its HTTP API. Transit is
// "encryption-as-a-service" — the KEK material never leaves Vault; the platform
// only sends the DEK to be encrypted (wrap) and the wrapped blob to be decrypted
// (unwrap). When the customer runs `vault delete transit/keys/<keyID>` (after
// enabling deletion), every decrypt for that key fails forever — crypto-shred.
//
// Wrap  -> POST {addr}/v1/transit/encrypt/{keyID} {plaintext: base64(DEK)}
//          <- {data:{ciphertext:"vault:v1:..."}}   (the wrapped DEK, stored verbatim)
// Unwrap-> POST {addr}/v1/transit/decrypt/{keyID} {ciphertext:"vault:v1:..."}
//          <- {data:{plaintext: base64(DEK)}}
//
// The "vault:v1:..." string is stored as-is in cmek_wrapped_dek (it embeds the
// key VERSION, so a rotated key still decrypts old ciphertexts; a DELETED key
// decrypts nothing). Auth is the X-Vault-Token header (VAULT_TOKEN), same env S2
// uses. Mount path defaults to "transit" (override via VAULT_TRANSIT_MOUNT).
type VaultTransitProvider struct {
	addr  string // e.g. http://vault:8200 (no trailing slash)
	token string
	mount string // transit engine mount path, default "transit"
	http  *http.Client
}

// VaultTransitConfig configures a VaultTransitProvider.
type VaultTransitConfig struct {
	Addr    string        // VAULT_ADDR
	Token   string        // VAULT_TOKEN
	Mount   string        // transit mount path; "" -> "transit"
	Timeout time.Duration // per-request timeout; 0 -> 10s
}

// NewVaultTransitProvider builds the real Vault Transit KMS provider.
func NewVaultTransitProvider(cfg VaultTransitConfig) (*VaultTransitProvider, error) {
	if cfg.Addr == "" {
		return nil, fmt.Errorf("cmek: VAULT_ADDR is required for the vault-transit KMS provider")
	}
	if cfg.Token == "" {
		return nil, fmt.Errorf("cmek: VAULT_TOKEN is required for the vault-transit KMS provider")
	}
	mount := cfg.Mount
	if mount == "" {
		mount = "transit"
	}
	to := cfg.Timeout
	if to == 0 {
		to = 10 * time.Second
	}
	return &VaultTransitProvider{
		addr:  strings.TrimRight(cfg.Addr, "/"),
		token: cfg.Token,
		mount: strings.Trim(mount, "/"),
		http:  &http.Client{Timeout: to},
	}, nil
}

// WrapDEK posts the base64 DEK to transit/encrypt/{keyID} and returns the
// "vault:v1:..." ciphertext bytes verbatim (the wrapped DEK).
func (p *VaultTransitProvider) WrapDEK(ctx context.Context, keyID string, plaintextDEK []byte) ([]byte, error) {
	body := map[string]string{"plaintext": base64.StdEncoding.EncodeToString(plaintextDEK)}
	var out struct {
		Data struct {
			Ciphertext string `json:"ciphertext"`
		} `json:"data"`
	}
	if err := p.call(ctx, "encrypt", keyID, body, &out); err != nil {
		return nil, err
	}
	if out.Data.Ciphertext == "" {
		return nil, fmt.Errorf("cmek: vault transit encrypt returned no ciphertext for key %q", keyID)
	}
	return []byte(out.Data.Ciphertext), nil
}

// UnwrapDEK posts the "vault:v1:..." wrapped DEK to transit/decrypt/{keyID} and
// returns the decoded plaintext DEK. A non-2xx (e.g. key deleted -> 400/403)
// surfaces as an error, which Open maps to ErrShredded.
func (p *VaultTransitProvider) UnwrapDEK(ctx context.Context, keyID string, wrappedDEK []byte) ([]byte, error) {
	body := map[string]string{"ciphertext": string(wrappedDEK)}
	var out struct {
		Data struct {
			Plaintext string `json:"plaintext"`
		} `json:"data"`
	}
	if err := p.call(ctx, "decrypt", keyID, body, &out); err != nil {
		return nil, err
	}
	dek, err := base64.StdEncoding.DecodeString(out.Data.Plaintext)
	if err != nil {
		return nil, fmt.Errorf("cmek: vault transit decrypt returned a non-base64 plaintext: %w", err)
	}
	return dek, nil
}

// call POSTs {addr}/v1/{mount}/{op}/{keyID} with the X-Vault-Token header and
// decodes the JSON response into out. A non-2xx status is an error (the body is
// included so a deleted-key 400/403 is legible in logs/gates).
func (p *VaultTransitProvider) call(ctx context.Context, op, keyID string, body any, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	url := fmt.Sprintf("%s/v1/%s/%s/%s", p.addr, p.mount, op, keyID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", p.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.http.Do(req)
	if err != nil {
		return fmt.Errorf("cmek: vault transit %s request failed: %w", op, err)
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("cmek: vault transit %s key=%q -> HTTP %d: %s", op, keyID, resp.StatusCode, strings.TrimSpace(string(rb)))
	}
	if err := json.Unmarshal(rb, out); err != nil {
		return fmt.Errorf("cmek: vault transit %s: decode response: %w", op, err)
	}
	return nil
}

// LocalKMSProvider is a TEST-ONLY KMS: it wraps/unwraps the DEK with a fixed
// in-process AES-256 KEK. It exists so the cmek unit tests can prove the
// envelope round-trip and crypto-shred semantics WITHOUT a running Vault. It is
// NOT a real KMS — the KEK lives in this process's memory, which defeats the
// whole "we never hold your unwrap key" property. Never construct it outside
// tests / local development; production must use VaultTransitProvider (or another
// external KMSProvider).
//
// Wrap  = AES-256-GCM(KEK, DEK) with a random nonce; wrapped = nonce||ct.
// Unwrap inverts it; a wrong/zeroed KEK fails GCM auth (the crypto-shred analog).
type LocalKMSProvider struct {
	keks map[string][]byte // keyID -> 32-byte KEK (test only)
}

// NewLocalKMSProvider derives a deterministic 256-bit KEK per keyID from a test
// seed (sha256(seed||keyID)), so a test can wrap under one keyID and prove that
// unwrapping under a DIFFERENT keyID (or a revoked one) fails. TEST-ONLY.
func NewLocalKMSProvider(seed string, keyIDs ...string) *LocalKMSProvider {
	p := &LocalKMSProvider{keks: map[string][]byte{}}
	for _, id := range keyIDs {
		p.keks[id] = deriveTestKEK(seed, id)
	}
	return p
}

// RevokeKey deletes a keyID's KEK from this test provider, so subsequent
// UnwrapDEK calls fail — the in-process analog of `vault delete transit/keys/x`
// (crypto-shred). TEST-ONLY.
func (p *LocalKMSProvider) RevokeKey(keyID string) { delete(p.keks, keyID) }

func deriveTestKEK(seed, keyID string) []byte {
	h := sha256.Sum256([]byte("cmek-local-test-kek\x00" + seed + "\x00" + keyID))
	return h[:]
}

// WrapDEK AES-256-GCM-encrypts the DEK under the keyID's KEK; wrapped = nonce||ct.
func (p *LocalKMSProvider) WrapDEK(_ context.Context, keyID string, plaintextDEK []byte) ([]byte, error) {
	kek, ok := p.keks[keyID]
	if !ok {
		return nil, fmt.Errorf("cmek/local: unknown keyID %q (test KEK not registered)", keyID)
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	ct := gcm.Seal(nil, nonce, plaintextDEK, nil)
	return append(nonce, ct...), nil
}

// UnwrapDEK reverses WrapDEK. A missing keyID (revoked) or a wrong KEK fails —
// the test crypto-shred path.
func (p *LocalKMSProvider) UnwrapDEK(_ context.Context, keyID string, wrappedDEK []byte) ([]byte, error) {
	kek, ok := p.keks[keyID]
	if !ok {
		return nil, fmt.Errorf("cmek/local: keyID %q revoked/unknown — cannot unwrap (crypto-shred)", keyID)
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(wrappedDEK) < ns {
		return nil, fmt.Errorf("cmek/local: wrapped DEK too short")
	}
	nonce, ct := wrappedDEK[:ns], wrappedDEK[ns:]
	dek, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("cmek/local: unwrap GCM open failed (wrong KEK / tampered): %w", err)
	}
	return dek, nil
}

// compile-time assertions that both providers satisfy KMSProvider.
var (
	_ KMSProvider = (*VaultTransitProvider)(nil)
	_ KMSProvider = (*LocalKMSProvider)(nil)
)
