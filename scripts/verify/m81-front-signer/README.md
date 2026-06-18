# m81 front-signer — minimal REAL RS256 issuer (gate-only)

`signer.mjs` is a tiny, zero-dependency (node:22-alpine, `node:crypto` only) service that
plays the role of a **real RS256 issuer** for the `m81-rs256-issuer.sh` gate — the half
`m64` skipped. m64 proved only the tenant-control *verifier* against a stub; m81 proves an
*issuer* end-to-end through **Kong (RS256)** and then tenant-control (RS256/JWKS).

It:

- generates one real RSA-2048 keypair (`kid=m81-key-1`) — the issuing key;
- serves a real `GET /.well-known/jwks.json` (n,e of the public half) — for tenant-control's `JWKS_URL`;
- serves the public key as SPKI **PEM** at `GET /pem` — for Kong's `rsa_public_key`;
- mints RS256 tokens (`alg=RS256`, `kid` present, `iss=<ISSUER>`) at `GET /token/valid`;
- mints attack tokens at `GET /token/{hsforge,wrongkey,unknownkid,none}` that MUST be rejected.

This is the runbook's documented **option 2** ("put a small JWKS-publishing signer in
front") for when the vendored `supabase/gotrue:v2.188.1` (HS256-only) cannot itself issue
RS256. It is a **gate fixture only** — it never runs in the live stack. The live cutover
either bumps gotrue to an asymmetric-signing image (≥ the July-2025 signing-keys release,
`GOTRUE_JWT_KEYS` JWK set) or fronts it with an equivalent signer; see
[`wiki/security-residuals-runbook.md` §G-RS256](../../../../wiki/security-residuals-runbook.md).
