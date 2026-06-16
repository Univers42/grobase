// Edge Functions runtime HTTP server.
// REST surface:
//   POST   /v1/functions             — upload {name, code, runtime?}
//   GET    /v1/functions             — list functions for the tenant
//   GET    /v1/functions/:name       — fetch source
//   DELETE /v1/functions/:name       — remove
//   POST   /v1/functions/:name/invoke — execute and return body
//
// Tenant identity is taken from the `X-Baas-Tenant-Id` header (post-M11) with
// fallbacks for compat. Storage lives under FUNCTIONS_DATA_DIR/<tenant>/<name>.ts.

import { dirname, join } from "https://deno.land/std@0.224.0/path/mod.ts";
import { ensureDir } from "https://deno.land/std@0.224.0/fs/ensure_dir.ts";
import { FUNCTION_INVOCATIONS_METRIC, UsageMeter } from "./usage-meter.ts";

const PORT = Number(Deno.env.get("FUNCTIONS_PORT") ?? "3060");
const HOST = Deno.env.get("FUNCTIONS_HOST") ?? "0.0.0.0";
const DATA_DIR = Deno.env.get("FUNCTIONS_DATA_DIR") ?? "/data";
const TIMEOUT_MS = Number(Deno.env.get("FUNCTIONS_INVOKE_TIMEOUT_MS") ?? "5000");

// B1d metering — sub-flag, DEFAULT OFF (byte-parity). When OFF the meter is
// never constructed, so no aggregator, no background flusher (not even an idle
// timer), and the invoke path never records — observably identical to today.
// When ON, each SUCCESSFUL invocation adds 1 to a per-(tenant, metric) windowed
// aggregator; the flusher XADDs the CUMULATIVE window total to the frozen
// `usage.events` stream every FUNCTION_METERING_FLUSH_MS (default 60000).
function envBool(v: string | undefined): boolean {
  return v === "1" || v === "true" || v === "on" ||
    v === "TRUE" || v === "True" || v === "ON";
}
const FUNCTION_METERING = envBool(Deno.env.get("FUNCTION_METERING"));
const FUNCTION_METERING_FLUSH_MS = Number(
  Deno.env.get("FUNCTION_METERING_FLUSH_MS") ?? "60000",
);
// Reuse the established Redis URL convention (the data plane / outbox use the
// same fallbacks); only read when the flag is ON.
const FUNCTION_METERING_REDIS_URL = Deno.env.get("FUNCTION_METERING_REDIS_URL") ??
  Deno.env.get("REDIS_URL") ?? "redis://redis:6379";

const usageMeter: UsageMeter | null = FUNCTION_METERING
  ? new UsageMeter({
    flushMs: FUNCTION_METERING_FLUSH_MS,
    redisUrl: FUNCTION_METERING_REDIS_URL,
  })
  : null;
if (usageMeter) {
  usageMeter.start();
  console.log(
    `[functions] metering ON (flush=${FUNCTION_METERING_FLUSH_MS}ms, metric=${FUNCTION_INVOCATIONS_METRIC})`,
  );
}

// A2 Functions DX — per-function secrets. When FUNCTION_SECRETS_URL is set, the
// runtime resolves the tenant+function's whitelisted secrets from the Go
// secret store at invoke time and injects them into the Deno worker's env
// (spawned with `--allow-env=<keys>` and the values set in the worker's
// Deno.env). Without the URL, no secrets are injected (env stays disabled).
const SECRETS_URL = Deno.env.get("FUNCTION_SECRETS_URL") ?? "";
const SECRETS_TOKEN = Deno.env.get("INTERNAL_SERVICE_TOKEN") ?? "";

// A2 m96 — WARM POOL. DEFAULT OFF (byte-parity): when unset, every invocation
// takes today's exact path — a fresh blob Worker spawned, used once, closed.
// When ON, a small bounded ring of pre-imported workers is reused across
// invocations keyed by (tenant, name): an invoke checks out an idle warm worker
// (or spawns + warms one), runs, and returns it to the pool. A worker is NEVER
// shared across (tenant, name) — the key is the isolation boundary — so no
// secret/heap state leaks across tenants. The reuse signal is surfaced on the
// `X-Function-Warm` response header (`hit` = served by a reused worker, `miss` =
// freshly spawned) so the reuse is observable without timing flakiness.
const WARM_POOL = envBool(Deno.env.get("FUNCTIONS_WARM_POOL"));
const WARM_POOL_MAX = Math.max(
  1,
  Number(Deno.env.get("FUNCTIONS_WARM_POOL_MAX") ?? "8"),
);
const WARM_IDLE_MS = Number(Deno.env.get("FUNCTIONS_WARM_IDLE_MS") ?? "30000");

// A2 m96 — per-invocation RESOURCE LIMIT (memory). DEFAULT OFF (0 => no cap =
// byte-parity): when set, a runtime-controlled watchdog (NOT user code) polls
// the worker's rss every FUNCTIONS_MEM_POLL_MS and self-aborts the invocation
// with `memory_limit_exceeded` if it exceeds the cap, so a runaway function is
// killed rather than starving the box. The coarse CPU/RAM boundary is still the
// container cgroup (compose mem_limit/cpus); this is the per-invoke fine cap.
const MEM_LIMIT_MB = Number(Deno.env.get("FUNCTIONS_MEM_LIMIT_MB") ?? "0");
const MEM_POLL_MS = Math.max(
  5,
  Number(Deno.env.get("FUNCTIONS_MEM_POLL_MS") ?? "25"),
);

await ensureDir(DATA_DIR);

const ROUTES: Array<[string, RegExp, Handler]> = [
  ["POST", /^\/v1\/functions$/, createFn],
  ["GET", /^\/v1\/functions$/, listFns],
  ["GET", /^\/v1\/functions\/([^/]+)$/, readFn],
  ["DELETE", /^\/v1\/functions\/([^/]+)$/, deleteFn],
  ["POST", /^\/v1\/functions\/([^/]+)\/invoke$/, invokeFn],
  ["GET", /^\/health\/live$/, () => json(200, { status: "ok" })],
  ["GET", /^\/health\/ready$/, () => json(200, { status: "ready" })],
];

type Handler = (req: Request, match: RegExpMatchArray) => Promise<Response> | Response;

Deno.serve({ port: PORT, hostname: HOST }, async (req) => {
  try {
    const url = new URL(req.url);
    for (const [method, pattern, handler] of ROUTES) {
      if (req.method !== method) continue;
      const m = pattern.exec(url.pathname);
      if (m) return await handler(req, m);
    }
    return json(404, { error: "not_found", path: url.pathname });
  } catch (err) {
    console.error("[functions] unhandled", err);
    return json(500, { error: "internal_error", message: String(err) });
  }
});

console.log(`[functions] listening on ${HOST}:${PORT}, data=${DATA_DIR}`);

function tenantOf(req: Request): string | null {
  return req.headers.get("x-baas-tenant-id")
      ?? req.headers.get("x-baas-user-id")
      ?? req.headers.get("x-tenant-id")
      ?? req.headers.get("x-user-id");
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function unauthorized(): Response {
  return json(401, { error: "unauthorized", message: "missing X-Baas-Tenant-Id" });
}

function badName(name: string): boolean {
  return !/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/.test(name);
}

function pathFor(tenant: string, name: string): string {
  return join(DATA_DIR, tenant, `${name}.ts`);
}

async function createFn(req: Request): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  let body: { name?: string; code?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "bad_request", message: "invalid JSON" });
  }
  if (!body.name || badName(body.name)) {
    return json(400, { error: "validation_error", message: "name must match [a-zA-Z][a-zA-Z0-9_-]{0,63}" });
  }
  if (!body.code || body.code.length > 256_000) {
    return json(400, { error: "validation_error", message: "code required (max 256KB)" });
  }
  const dest = pathFor(tenant, body.name);
  await ensureDir(dirname(dest));
  await Deno.writeTextFile(dest, body.code);
  return json(201, { name: body.name, bytes: body.code.length });
}

async function listFns(req: Request): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const dir = join(DATA_DIR, tenant);
  const out: Array<{ name: string; bytes: number; updated_at: string }> = [];
  try {
    for await (const entry of Deno.readDir(dir)) {
      if (!entry.isFile || !entry.name.endsWith(".ts")) continue;
      const stat = await Deno.stat(join(dir, entry.name));
      out.push({
        name: entry.name.replace(/\.ts$/, ""),
        bytes: stat.size,
        updated_at: (stat.mtime ?? new Date(0)).toISOString(),
      });
    }
  } catch (err) {
    if (!(err instanceof Deno.errors.NotFound)) throw err;
  }
  return json(200, out);
}

async function readFn(req: Request, m: RegExpMatchArray): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const name = m[1];
  if (badName(name)) return json(400, { error: "validation_error" });
  try {
    const code = await Deno.readTextFile(pathFor(tenant, name));
    return json(200, { name, code });
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) return json(404, { error: "not_found" });
    throw err;
  }
}

async function deleteFn(req: Request, m: RegExpMatchArray): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const name = m[1];
  if (badName(name)) return json(400, { error: "validation_error" });
  try {
    await Deno.remove(pathFor(tenant, name));
    return json(200, { deleted: true });
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) return json(404, { error: "not_found" });
    throw err;
  }
}

async function invokeFn(req: Request, m: RegExpMatchArray): Promise<Response> {
  const tenant = tenantOf(req);
  if (!tenant) return unauthorized();
  const name = m[1];
  if (badName(name)) return json(400, { error: "validation_error" });

  const codePath = pathFor(tenant, name);
  try {
    await Deno.stat(codePath);
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) return json(404, { error: "not_found" });
    throw err;
  }

  let inputBody: unknown = null;
  const ctype = req.headers.get("content-type") ?? "";
  if (ctype.includes("application/json")) {
    try {
      inputBody = await req.json();
    } catch {
      inputBody = null;
    }
  } else {
    inputBody = await req.text();
  }

  const headers: Record<string, string> = {};
  req.headers.forEach((v, k) => { headers[k] = v; });

  const secrets = await resolveSecrets(tenant, name);

  const input: InvokeInput = {
    tenant_id: tenant,
    method: req.method,
    headers,
    body: inputBody,
  };
  // WARM POOL: flag-gated. OFF => the byte-parity worker-per-invocation path.
  const result = WARM_POOL
    ? await pool.invoke(tenant, name, codePath, input, secrets)
    : await invokeInWorker(codePath, input, secrets);
  if (result.error) {
    // A runaway invocation killed by the memory watchdog maps to 429 (the caller
    // exceeded a resource limit, not a bug in our runtime); everything else is a
    // 500 function error — same status the cold path returns today.
    if (result.error.startsWith("memory_limit_exceeded")) {
      const r = json(429, { error: "resource_limit", message: result.error });
      r.headers.set("X-Function-Warm", result.warm ? "hit" : "miss");
      return r;
    }
    return json(500, { error: "function_error", message: result.error });
  }
  // B1d metering — count this SUCCESSFUL invocation (qty 1) for the caller's
  // authenticated tenant. `tenant` is taken from the same identity the rest of
  // the handler used (X-Baas-Tenant-Id, post-M11; the runtime's caller). The
  // record is a cheap non-blocking += into the windowed aggregator; the flusher
  // emits the cumulative window total. Guarded on the flag so OFF == parity.
  usageMeter?.record(tenant, FUNCTION_INVOCATIONS_METRIC, 1);
  const headersOut: Record<string, string> = {
    "content-type": result.contentType ?? "application/json",
  };
  // Surface the warm-pool reuse signal only when the pool is engaged so the OFF
  // path response is byte-identical to today (no extra header).
  if (WARM_POOL) headersOut["X-Function-Warm"] = result.warm ? "hit" : "miss";
  return new Response(typeof result.body === "string" ? result.body : JSON.stringify(result.body), {
    status: result.status ?? 200,
    headers: headersOut,
  });
}

// resolveSecrets fetches the tenant+function's decrypted secrets from the Go
// secret store. Failures are non-fatal — the function just runs without the
// secrets injected (logged). Returns {} when no store is configured.
async function resolveSecrets(tenant: string, name: string): Promise<Record<string, string>> {
  if (!SECRETS_URL) return {};
  try {
    const u = new URL(SECRETS_URL);
    u.searchParams.set("tenant", tenant);
    u.searchParams.set("function", name);
    const resp = await fetch(u.toString(), {
      headers: SECRETS_TOKEN ? { "X-Internal-Service-Token": SECRETS_TOKEN } : {},
    });
    if (!resp.ok) {
      console.error(`[functions] secret resolve failed: HTTP ${resp.status}`);
      return {};
    }
    const data = await resp.json();
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(data ?? {})) {
      if (typeof v === "string") out[k] = v;
    }
    return out;
  } catch (err) {
    console.error("[functions] secret resolve error", err);
    return {};
  }
}

interface InvokeInput {
  tenant_id: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

interface InvokeResult {
  status?: number;
  body?: unknown;
  contentType?: string;
  error?: string;
  // m96: set when the invocation was served by a reused warm worker.
  warm?: boolean;
}

// Runtime-controlled memory watchdog preamble, injected into the worker ONLY
// when a per-invoke cap is configured. It is EMPTY when MEM_LIMIT_MB == 0, so
// the OFF path worker source is byte-identical to today. The watchdog polls the
// worker's OWN rss (not user code) and self-aborts with `memory_limit_exceeded`
// if it exceeds the cap, leaving the runtime process untouched.
function memWatchdogPreamble(): string {
  if (MEM_LIMIT_MB <= 0) return "";
  const cap = MEM_LIMIT_MB * 1024 * 1024;
  return `
      let __wd = setInterval(() => {
        try {
          if (Deno.memoryUsage().rss > ${cap}) {
            clearInterval(__wd);
            self.postMessage({ ok: false, error: "memory_limit_exceeded: rss over ${MEM_LIMIT_MB}MB cap" });
            self.close();
          }
        } catch (_) { /* ignore */ }
      }, ${MEM_POLL_MS});
  `;
}

function invokeInWorker(
  codePath: string,
  input: InvokeInput,
  secrets: Record<string, string> = {},
): Promise<InvokeResult> {
  return new Promise((resolve) => {
    const secretKeys = Object.keys(secrets);
    // The worker imports the handler dynamically AFTER seeding Deno.env so the
    // handler reads its secrets via the normal Deno.env.get(...) API. env
    // permission is scoped to exactly the whitelisted keys (least privilege);
    // when there are no secrets, env stays disabled.
    const workerSource = `${memWatchdogPreamble()}
      const __secrets = ${JSON.stringify(secrets)};
      for (const [k, v] of Object.entries(__secrets)) {
        try { Deno.env.set(k, v); } catch (_) { /* env not permitted */ }
      }
      const { default: handler } = await import("file://${codePath}");
      self.onmessage = async (ev) => {
        try {
          const out = await handler(ev.data);
          self.postMessage({ ok: true, out });
        } catch (e) {
          self.postMessage({ ok: false, error: (e && e.stack) || String(e) });
        } finally {
          self.close();
        }
      };
    `;
    const blob = new Blob([workerSource], { type: "application/typescript" });
    const url = URL.createObjectURL(blob);
    const worker = new Worker(url, {
      type: "module",
      deno: {
        permissions: {
          read: [codePath],
          net: "inherit",
          // Scope env to exactly the whitelisted secret keys, else disable.
          env: secretKeys.length > 0 ? secretKeys : false,
          run: false,
          write: false,
          ffi: false,
          sys: false,
        },
      },
    } as WorkerOptions);

    const timeout = setTimeout(() => {
      worker.terminate();
      URL.revokeObjectURL(url);
      resolve({ error: `timeout after ${TIMEOUT_MS}ms` });
    }, TIMEOUT_MS);

    worker.onmessage = (ev) => {
      clearTimeout(timeout);
      URL.revokeObjectURL(url);
      const msg = ev.data as { ok: boolean; out?: InvokeResult; error?: string };
      resolve(msg.ok ? (msg.out ?? {}) : { error: msg.error });
    };
    worker.onerror = (ev) => {
      clearTimeout(timeout);
      URL.revokeObjectURL(url);
      resolve({ error: ev.message });
    };
    worker.postMessage(input);
  });
}

// ─── WARM POOL (m96, flag-gated) ─────────────────────────────────────────────
// A bounded ring of persistent Deno workers, keyed by `${tenant} ${name}`.
// A persistent warm worker imports the handler ONCE and then loops on messages
// (it does NOT self.close() after a single invoke), so the second+ invocation of
// the same function skips the per-invoke module import + isolate spin-up. The key
// is the isolation boundary: a worker is NEVER reused across a different
// (tenant, name), so no secret/heap state can leak between tenants. The pool is
// only ever constructed/used when FUNCTIONS_WARM_POOL is ON.

interface WarmWorker {
  key: string;
  worker: Worker;
  url: string;
  busy: boolean;
  ready: Promise<void>;
  idleTimer: number | null;
  pending: Map<number, (r: InvokeResult) => void>;
  seq: number;
}

class WarmPool {
  private byKey = new Map<string, WarmWorker>();

  private buildPersistentSource(codePath: string, secrets: Record<string, string>): string {
    // Persistent variant of invokeInWorker's source: import once, then serve a
    // stream of {id, input} messages, replying {id, ok, out|error}. The memory
    // watchdog (if a cap is set) aborts the CURRENT invocation by replying an
    // error AND closing the worker, so a poisoned warm worker is discarded.
    const wd = MEM_LIMIT_MB > 0
      ? `
      let __wd = setInterval(() => {
        try {
          if (Deno.memoryUsage().rss > ${MEM_LIMIT_MB * 1024 * 1024}) {
            clearInterval(__wd);
            if (__cur !== null) self.postMessage({ id: __cur, ok: false, error: "memory_limit_exceeded: rss over ${MEM_LIMIT_MB}MB cap" });
            self.close();
          }
        } catch (_) { /* ignore */ }
      }, ${MEM_POLL_MS});`
      : "";
    return `
      let __cur = null;${wd}
      const __secrets = ${JSON.stringify(secrets)};
      for (const [k, v] of Object.entries(__secrets)) {
        try { Deno.env.set(k, v); } catch (_) { /* env not permitted */ }
      }
      const { default: handler } = await import("file://${codePath}");
      self.onmessage = async (ev) => {
        const { id, input } = ev.data;
        __cur = id;
        try {
          const out = await handler(input);
          self.postMessage({ id, ok: true, out });
        } catch (e) {
          self.postMessage({ id, ok: false, error: (e && e.stack) || String(e) });
        } finally {
          __cur = null;
        }
      };
      // Signal the parent the handler is imported and onmessage is wired, so the
      // very first invoke is never posted into a not-yet-ready worker.
      self.postMessage({ __ready: true });
    `;
  }

  private spawn(key: string, codePath: string, secrets: Record<string, string>): WarmWorker {
    const secretKeys = Object.keys(secrets);
    const source = this.buildPersistentSource(codePath, secrets);
    const blob = new Blob([source], { type: "application/typescript" });
    const url = URL.createObjectURL(blob);
    const worker = new Worker(url, {
      type: "module",
      deno: {
        permissions: {
          read: [codePath],
          net: "inherit",
          env: secretKeys.length > 0 ? secretKeys : false,
          run: false,
          write: false,
          ffi: false,
          sys: false,
        },
      },
    } as WorkerOptions);
    let resolveReady: () => void = () => {};
    const ready = new Promise<void>((res) => { resolveReady = res; });
    const ww: WarmWorker = {
      key,
      worker,
      url,
      busy: false,
      idleTimer: null,
      pending: new Map(),
      seq: 0,
      ready,
    };
    worker.onmessage = (ev) => {
      const msg = ev.data as { __ready?: boolean; id: number; ok: boolean; out?: InvokeResult; error?: string };
      if (msg.__ready) { resolveReady(); return; }
      const cb = ww.pending.get(msg.id);
      if (cb) {
        ww.pending.delete(msg.id);
        cb(msg.ok ? (msg.out ?? {}) : { error: msg.error });
      }
    };
    worker.onerror = (ev) => {
      // A worker-level error poisons the worker: fail all pending + drop it.
      for (const [, cb] of ww.pending) cb({ error: ev.message });
      ww.pending.clear();
      this.discard(ww);
    };
    // Evict the pool's oldest if we are at capacity (simple bound).
    if (this.byKey.size >= WARM_POOL_MAX) {
      const first = this.byKey.values().next().value as WarmWorker | undefined;
      if (first && !first.busy) this.discard(first);
    }
    this.byKey.set(key, ww);
    return ww;
  }

  private discard(ww: WarmWorker): void {
    if (ww.idleTimer !== null) clearTimeout(ww.idleTimer);
    try { ww.worker.terminate(); } catch (_) { /* ignore */ }
    try { URL.revokeObjectURL(ww.url); } catch (_) { /* ignore */ }
    if (this.byKey.get(ww.key) === ww) this.byKey.delete(ww.key);
  }

  private armIdle(ww: WarmWorker): void {
    if (ww.idleTimer !== null) clearTimeout(ww.idleTimer);
    ww.idleTimer = setTimeout(() => this.discard(ww), WARM_IDLE_MS);
  }

  async invoke(
    tenant: string,
    name: string,
    codePath: string,
    input: InvokeInput,
    secrets: Record<string, string>,
  ): Promise<InvokeResult> {
    const key = `${tenant} ${name}`;
    let ww = this.byKey.get(key);
    let warmHit = true;
    if (!ww || ww.busy) {
      // No idle warm worker for this (tenant, name): spawn a fresh one (miss).
      ww = this.spawn(key, codePath, secrets);
      warmHit = false;
    }
    if (ww.idleTimer !== null) { clearTimeout(ww.idleTimer); ww.idleTimer = null; }
    ww.busy = true;
    const id = ++ww.seq;
    const target = ww;
    // Wait for the worker to have imported the handler + wired onmessage so the
    // first message is never dropped into a not-yet-ready isolate.
    await target.ready;
    const result = await new Promise<InvokeResult>((resolve) => {
      const timeout = setTimeout(() => {
        target.pending.delete(id);
        // A timed-out warm worker is poisoned (it may still be running) — drop it.
        this.discard(target);
        resolve({ error: `timeout after ${TIMEOUT_MS}ms` });
      }, TIMEOUT_MS);
      target.pending.set(id, (r) => { clearTimeout(timeout); resolve(r); });
      target.worker.postMessage({ id, input });
    });
    // If the worker self-closed (memory cap) discard it so it is never reused.
    if (result.error && result.error.startsWith("memory_limit_exceeded")) {
      this.discard(target);
    } else if (this.byKey.get(key) === target) {
      target.busy = false;
      this.armIdle(target);
    }
    result.warm = warmHit;
    return result;
  }
}

const pool = new WarmPool();
