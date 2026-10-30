# A MinIO TLS listener beside plaintext :9000 is out of scope

- Decided: 2026-10-30 · by devil (G5 MinIO HTTPS re-rule, ADR 0030)
- Holds while: MinIO has no setting to serve HTTP and HTTPS at once

## The concept

Keep plaintext `http://minio:9000` for every existing client, and add an HTTPS port
beside it. Clients would then migrate one at a time and nobody has to cut over at once.

## Why not

- MinIO with `--certs-dir` answers plain HTTP with 400 on both 9000 and 9001.
  Measured on RELEASE.2025-09-07, and again in `wiki/architecture/minio-https-trust-matrix.md` (k1b, Go 400).
  A second listener is therefore not a MinIO flag. It is a new TLS-terminator
  container (rung 6/7) that has to be maintained, patched and health-checked.
- It keeps the plaintext hop the G5 item exists to remove, so the goal is met only for
  clients that have migrated.
- m195 asserts that prod publishes exactly `9000->9000` (`scripts/verify/m195-prod-overlay-hardening.sh:128`).
- Every client trust knob was measured to work and to fail loudly
  (same doc, L1), so a staged migration buys nothing a single overlay does not already give.

## Prior requests

- 2026-10-30 (spike/minio-https-trust): listed as L2 option B.

## Reopen when

A MinIO release serves HTTP and HTTPS at the same time on one process, or a client that
cannot trust a private CA has to stay on the in-network path.
