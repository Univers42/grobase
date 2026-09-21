# Handoff prompt — grobase hardening

Paste everything below the line into the next agent's first message. It is
written to be read cold, by someone who has never seen the repo.

---

You are working on **grobase** (`github.com/Univers42/grobase`), a
self-hosted BaaS platform: ~66 containerised services behind a WAF and a Kong
gateway, organised into planes (data, control, adapter, background, analytics,
storage, realtime, functions, observability, engines) and packaged into tiers
(`basic` / `essential` / `pro` / `max`) that resolve to compose profiles.

It is **already deployed and in daily use** as a private cloud on a single
server. That is the operating constraint: it is not a greenfield project and it
is not a toy. Your job is not to redesign it. Your job is to close the gap
between what it claims and what it provably does, without breaking the running
deployment.

## Prime directive

**A green test is a claim, not a fact.** The single most valuable thing found
in the previous engagement was that five of grobase's own quality gates were
green while proving nothing:

- `mc_cmd` in the storage phase ended in `return 0` — every MinIO assertion
  passed unconditionally.
- The offers Postman collection seeded an empty `authEmail`, got a 422, and
  accepted it.
- `TEST_ORIGIN` defaulted to an origin Kong is configured to reject; CI
  exported the right one, hiding the default from everyone who ran it locally.
- `waf-test` curled a port nothing listened on and ended in `echo`, so it was
  structurally incapable of a non-zero exit. A security gate that can only pass
  is worse than no gate.
- `phase9-storage-operations-test.sh` never touched the storage plane it is
  named after — it passed with that plane stopped.

Assume more of these exist. Before you trust any suite, break the thing it
claims to test and confirm the suite goes red.

## The tool that enforces that: the mutation runner

`scripts/test/mutants/run.sh` (+ `mutants.tsv`) is a small, hand-written
mutation harness in the spirit of how Google runs mutation testing: a few
meaningful, reversible mutants rather than thousands of generated ones.

- Two mutant kinds: `env` (override one variable for one suite) and `svc`
  (stop one container; an EXIT trap restores it).
- Verdicts: `KILLED`, `SURVIVED`, `BASELINE` (the suite was already red — never
  credited as a kill), `SKIPPED`, `INVALID`, `STALE`.
- Run it: `bash scripts/test/mutants/run.sh [mutant-id]`. Report:
  `artifacts/test/mutants.md`.

**Extend it.** It currently covers 9 behaviours and reports 9/9 killed. That is
a claim about nine behaviours, not about the platform. Every time you fix a bug,
add the mutant that would have caught it. Every time you add a gate, add the
mutant that proves the gate can fail. A `SURVIVED` verdict is a bug report about
the test suite; a `STALE` verdict means the mutant's patch no longer applies and
must be regenerated, not deleted.

## Running the suites

From the deployment root:

- `make test-scripts` — phases 1–16. This is the **right** entry point: it
  discovers Kong's host port and exports `TEST_ORIGIN=https://localhost:3000`.
  Plain `make test-smoke` relies on script defaults, which is exactly how the
  `TEST_ORIGIN` hole stayed hidden.
- `make test-postman` — builds the htmlextra newman image, then runs offers +
  edge. `make test-edge` alone assumes that image already exists.
- `make waf-test`, `make test-unit`, `make test-lint`, `make verify-all`.

## Non-negotiable operational invariants

These were learned the hard way. Violating any of them costs an afternoon.

1. **Never run `make up` on a live stack.** `resolve-ports.sh` counts
   grobase's *own* running containers as "port in use", so `make up` silently
   relocates the WAF and Kong. Every test that hardcodes `:8000` then fails for
   an unrelated-looking reason. To restart one service, recreate it from its
   compose labels instead.
2. **Everything binds loopback except the WAF.** The WAF is the only door.
   Any service that publishes `0.0.0.0` is a bug, including in an overlay.
3. **Realtime holds a Postgres `LISTEN` that does not reattach** when Postgres
   is recreated. Every container reports healthy, subscribers connect, and no
   row change is ever delivered. This is the platform's worst failure mode —
   healthy-but-wrong — and it is currently papered over by restarting realtime
   after the stack is up. Fix it properly: reconnect-and-relisten with backoff,
   and add a mutant that recreates Postgres and asserts a change still arrives.
4. **Published images drift from source.** `grobase-realtime:latest` once
   lagged the commit being configured, so the deployment ran a binary that
   ignored the origin list it was handed. Never assume `:latest` matches the
   tree; verify (e.g. `docker create` + `docker cp` the binary out and grep it —
   distroless images have no shell).
5. **External artifacts rot.** `minio/mc` was withdrawn from Docker Hub;
   Trino 467's tarball was pruned from its GitHub release while the directory
   listing still advertised it. Pin and mirror every external input.

## Known open work, highest value first

1. **Node services are not cgroup-aware.** `mongo-api` declares
   `mem_limit: 128m`, but node sizes its default heap from *host* RAM, not the
   container limit — measured 259 MB heap limit inside that 128 MB container on
   a 7.5 GB host, and proportionally worse on a 16 GB CI runner. This is a
   latent trap, not a currently-firing bug (the service sits at 68 MB and has
   never been OOM-killed), but the two numbers disagree by construction and the
   failure mode when it does fire is a silent kill with no log line. Audit every
   Node service and make them agree deliberately:
   `NODE_OPTIONS=--max-old-space-size=<~75% of mem_limit>`, or drop the limit.
2. **Health checks must assert what dependents need, not what is convenient.**
   A worked example, and the bug that kept CI red for three days: mongo's probe
   ran `mongosh` against *localhost inside the container*. On a fresh volume the
   official entrypoint runs a temporary mongod bound to 127.0.0.1 for its initdb
   steps — so the probe passed against that temporary instance, compose released
   `depends_on: service_healthy`, and `mongo-init` (a `restart: "no"` one-shot)
   dialled `mongo:27017` over the network, got ECONNREFUSED, exited 1 and never
   retried. `rs.initiate()` never ran, mongo stayed `RSGhost`, and mongo-api
   crash-looped 16 times. Every container reported healthy. Audit the other
   probes for the same shape: does the probe exercise the same path the
   dependents use? And no one-shot should treat a single refused dial as final.
3. **CI cannot see the services it starts by name.** Services carrying
   `profiles:` that are started by name (`compose up -d <svc>`) bypass the
   profile without activating it, so every later `docker compose ps/logs` omits
   them. The failing integration run above printed nine healthy services and
   zero lines from the one that was down — which is why it went undiagnosed for
   three days. Use
   `docker ps --filter label=com.docker.compose.project=mini-baas`.
3. **Backups do not cover what the platform advertises.** Mongo's image has no
   `mongodump`; CockroachDB and MSSQL are not dumped at all. A multi-engine BaaS
   whose backup story covers one engine is mis-sold. Restore-test whatever you
   add — an untested backup is a claim, see the prime directive.
4. **Reproducibility of images.** Establish that a deployed image provably
   corresponds to a commit (digest pinning, a build-info label, or both), and
   make the deployment refuse to start on a mismatch.
5. **CI coverage holes.** Phases 9 and 11–13 were skipped in CI — exactly where
   the broken gates were. That is not a coincidence. Get them running.
6. **One known-flaky gate:** `Cloud gates` → `m94-cloud-funnel`, assertion B3
   ("events grew 1→2 after re-ticks — the billing_reported ledger must suppress
   re-sends"). It failed once and passed on a clean re-run with no code change.
   A flaky gate is corrosive: it trains everyone to re-run instead of read. Make
   it deterministic — most likely the re-tick races the ledger write, so the
   gate should wait for the ledger row rather than for wall-clock time.

## How to work

- **Repair grobase in grobase.** If a fault shows up in a deployment, fix it
  upstream on a branch, not by patching the deployed tree. A deployed tree that
  differs from `main` is how a test recipe was once "passing" locally and broken
  for everyone else.
- **Measure before you claim.** Do not report a fix as working because the build
  succeeded. Start the thing and observe it. (A Trino version bump compiled
  fine and would have died at runtime on a Java flag removed in that release.)
- **Comments explain the why, with the measurement that motivated them.** This
  repo's existing comments set a high bar — several Dockerfiles explain the
  image-size measurement behind a choice. Match it. Do not write comments that
  restate the code.
- **Small, reviewable commits**, Conventional Commits, no AI attribution lines
  and no `Co-Authored-By` trailers.
- **Never install packages on the deployment host.** Every platform change is
  Docker/compose.
- When a capability is genuinely blocked (no credentials, no log access), say so
  and ask, rather than guessing and pushing a speculative fix to `main`.

## Definition of done, per change

1. The failing behaviour is reproduced and understood, not inferred.
2. The fix is applied upstream on a branch.
3. A mutant exists that fails without the fix and passes with it.
4. The full phase suite plus the mutation runner are green, and you state the
   numbers.
5. CI is green on the PR before merge — and if a job was already red before your
   branch, say so explicitly rather than absorbing the blame or the credit.
