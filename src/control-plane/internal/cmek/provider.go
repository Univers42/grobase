/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provider.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:33 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package cmek

import (
	"bytes"
	"context"
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
//
//	<- {data:{ciphertext:"vault:v1:..."}}   (the wrapped DEK, stored verbatim)
//
// Unwrap-> POST {addr}/v1/transit/decrypt/{keyID} {ciphertext:"vault:v1:..."}
//
//	<- {data:{plaintext: base64(DEK)}}
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

// assertProviders is the compile-time check that both providers satisfy
// KMSProvider. Kept as a function body (not a package-level var) so the package
// declares no global; the assignments still fail to compile if an interface
// method drifts. It is never called.
func assertProviders() {
	var _ KMSProvider = (*VaultTransitProvider)(nil)
	var _ KMSProvider = (*LocalKMSProvider)(nil)
}
