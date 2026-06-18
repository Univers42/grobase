# Parity route-sets (G10)

`make parity` (→ [`scripts/verify/parity.sh`](../parity.sh)) is the reusable layer-swap
gate: **"prove plane B matches plane A for route set R, and emit a verdict."** It is the
generic successor to the one-shot `parity-probe.sh` (the historical TS↔Rust full-suite probe,
still available as `make parity-suite`).

The gate is **data-driven**: the request battery lives in a route-set file here, never in the
script — so every future plane promotion reuses the same gate by authoring a route-set.

## Modes

| Invocation | Mode | Meaning |
|---|---|---|
| `make parity NEW=<url> ROUTES=<set> RECORD=1` | record | capture a golden contract snapshot from the live plane |
| `make parity NEW=<url> ROUTES=<set>` | contract | assert the live plane still matches its golden (regression gate; the single-plane / post-cutover case) |
| `make parity OLD=<url> NEW=<url> ROUTES=<set>` | diff | assert two reachable planes return the same contract |

Each non-record run writes a machine-readable verdict to `.parity/verdict-<set>-<ts>.json`
(`{verdict: pass|fail, total, matched, mismatched, cases:[…]}`) and exits non-zero on any
divergence — so `cutover-<plane>` and CI can gate on it.

## Authoring a route-set

`scripts/verify/parity/<name>.routes.json`:

```json
{
  "name": "my-swap",
  "description": "what this proves",
  "normalize": "<jq program applied to every response body>",
  "requests": [
    { "name": "case-id", "method": "GET", "path": "/v1/thing",
      "headers": {"X-Service-Token": "${INTERNAL_SERVICE_TOKEN}"},
      "body": null,
      "normalize": "<optional per-request jq override>" }
  ]
}
```

- **`normalize`** — a jq program run over each response body before comparison. Use it to drop
  volatile fields (request ids, timestamps, generated row ids) and to canonicalize order
  (`sort_by`) so structural equality is meaningful and not flaky. Non-JSON bodies are compared
  verbatim. The shipped [`data-plane-contract`](data-plane-contract.routes.json) reduces the
  Rust router's `/v1/capabilities` to just the sorted `engines[]` matrix — the
  engine-agnosticism contract a data-plane swap must preserve, minus deployment-specific
  runtime fields.
- **`${VAR}`** in `path` / `headers` / `body` is expanded from the environment, so secrets and
  tokens are passed at run time and never committed into the route-set.
- Keep route-sets **auth-light where possible** (introspection/health/capability endpoints)
  so they run before a gateway key is provisioned. Hit the service directly (e.g.
  `NEW=http://localhost:4011`) for the data-plane contract.

## Goldens

`<name>.golden.json` is the recorded contract. It is **tracked** (it pins the contract a swap
must reproduce); re-record it deliberately with `RECORD=1` when the contract legitimately
changes, and review the diff. Per-run verdicts under `.parity/` are git-ignored.

The self-test gate [`m20-parity-harness.sh`](../m20-parity-harness.sh) exercises the harness
(record → compare → tamper → fail → restore) so the gate itself is verified.
