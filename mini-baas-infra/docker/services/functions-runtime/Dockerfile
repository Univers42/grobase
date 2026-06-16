# Edge Functions runtime (Deno worker-per-invocation MVP).
#
# Tenants POST TypeScript/JavaScript source to /v1/functions. Code is persisted
# to /data/<tenant_id>/<name>.ts. Invocation spawns a fresh Deno Worker with a
# minimal permission set (no FS, no env, network only to allow-listed hosts).
#
# Limitations (documented honestly in wiki/back/08):
#   - per-invocation worker startup is ~20-40ms (no warm pool yet)
#   - no resource caps beyond Deno's V8 isolate; for hard CPU/RAM caps you need
#     cgroups around a separate child process (planned, not MVP)
#   - no streaming response support (request/response only)
#
# A2 status:
#   - Per-function SECRETS are injected at invoke time (see server.ts
#     resolveSecrets + invokeInWorker: the worker is spawned with env scoped to
#     exactly the whitelisted keys, values seeded via Deno.env.set). DONE.
#   - WARM POOL + hard cgroup caps: DEFERRED (not cleanly unit-testable in this
#     slot). Design when picked up:
#       * Container-level cgroup caps already apply (compose mem_limit/cpus on
#         the functions-runtime service) — that is the coarse RAM/CPU boundary.
#       * Warm pool: keep a small ring of pre-imported Worker handles keyed by
#         (tenant,name); on invoke check out an idle worker (or spawn one), run,
#         then RESET it (terminate + respawn) before returning it so no isolate
#         state leaks across invocations — reuse the module-graph cache, not the
#         JS heap. Cross-tenant reuse of the SAME worker is forbidden. This needs
#         a worker-lifecycle harness + leak tests before it can ship, so it is
#         intentionally NOT faked here.
#       * Hard per-invoke CPU/RAM: run the worker as a separate `deno run` child
#         under its own cgroup (memory.max / cpu.max) instead of an in-process
#         Worker; gated on the warm-pool refactor.
FROM denoland/deno:alpine-2.1.4

ENV FUNCTIONS_HOST=0.0.0.0 \
    FUNCTIONS_PORT=3060 \
    FUNCTIONS_DATA_DIR=/data \
    FUNCTIONS_INVOKE_TIMEOUT_MS=5000

WORKDIR /app
COPY src/ /app/

# Pre-cache deps for offline starts.
RUN deno cache server.ts || true

VOLUME ["/data"]
EXPOSE 3060

HEALTHCHECK --interval=10s --timeout=3s --start-period=8s --retries=5 \
  CMD wget -qO- http://127.0.0.1:${FUNCTIONS_PORT}/health/live || exit 1

ENTRYPOINT ["deno", "run", \
            "--allow-net", "--allow-read", "--allow-write=/data", \
            "--allow-env", "--unstable-worker-options", \
            "/app/server.ts"]
