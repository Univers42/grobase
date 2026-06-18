# Infrastructure Contracts

Contracts describe non-negotiable runtime policies shared by all services. They are not secrets and should be safe to read in CI, docs, and reviews.

- `transport-security.md`: CA-backed HTTPS, redirects, HSTS, and localhost-only HTTP exceptions.
- `secrets.md`: secret ownership, allowed secret injection paths, and forbidden storage locations.