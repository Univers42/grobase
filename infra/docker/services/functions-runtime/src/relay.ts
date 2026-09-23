// Functions-jail relay. In the docker-compose.prod/cloud overlays the runtime
// lives on its own `functions-jail` network, and this relay is the ONE
// container on both that network and `mini-baas` (gate m192). Tenant code can
// therefore reach exactly what is relayed here, nothing else on mini-baas:
//   FUNCTIONS_RELAY_TCP  "port=host:port,…"  raw TCP forwards — ingress to the
//     jailed runtime (the relay answers as `functions-runtime` on mini-baas, so
//     Kong, webhook-dispatcher and function-scheduler need no change) and
//     egress to Kong's PROXY port (callbacks pass Kong key-auth/JWT like any
//     client; the admin/status port is never relayed).
//   FUNCTIONS_RELAY_HTTP "port=http://host:port/path,…"  ONE exact path, GET
//     only, carrying only X-Internal-Service-Token — the runtime's secrets
//     resolve, without opening the rest of webhook-dispatcher (its /v1/* routes
//     trust raw identity headers) to the jail.
// Every listener binds 0.0.0.0 at boot; a malformed spec or busy port exits.

type Forward = { port: number; target: string };
type Target = { hostname: string; port: number };

/** portOf returns s as a TCP port, or NaN unless s is a decimal integer in 1..65535. */
function portOf(s: string): number {
  const n = /^\d+$/.test(s) ? Number(s) : Number.NaN;
  return n >= 1 && n <= 65535 ? n : Number.NaN;
}

/**
 * parseForwards splits "port=target,…" (comma/space separated) into forwards.
 * @throws Error "bad relay forward" on an entry without a valid port or target.
 */
export function parseForwards(spec: string | undefined): Forward[] {
  return (spec ?? "").split(/[\s,]+/).filter((e) => e !== "").map((entry) => {
    const eq = entry.indexOf("=");
    const port = portOf(entry.slice(0, eq));
    const target = entry.slice(eq + 1);
    if (eq < 1 || Number.isNaN(port) || target === "") {
      throw new Error(`bad relay forward "${entry}" (want port=target)`);
    }
    return { port, target };
  });
}

/**
 * splitHostPort parses a "host:port" TCP target.
 * @throws Error "bad relay target" when the host is empty or the port invalid.
 */
export function splitHostPort(target: string): Target {
  const i = target.lastIndexOf(":");
  const port = portOf(target.slice(i + 1));
  if (i < 1 || Number.isNaN(port)) {
    throw new Error(`bad relay target "${target}" (want host:port)`);
  }
  return { hostname: target.slice(0, i), port };
}

/** closeQuietly closes a connection the other direction may already have closed. */
function closeQuietly(conn: Deno.Conn): void {
  try {
    conn.close();
  } catch {
    return;
  }
}

/** bridge pipes client and target both ways and closes both once either direction ends; a refused target closes the client. */
async function bridge(client: Deno.Conn, to: Target): Promise<void> {
  let upstream: Deno.Conn;
  try {
    upstream = await Deno.connect(to);
  } catch {
    closeQuietly(client);
    return;
  }
  // ponytail: no half-close — HTTP never half-closes; allSettled + closeWrite() if a relayed protocol does
  await Promise.race([
    client.readable.pipeTo(upstream.writable, { preventClose: true }).catch(
      () => {},
    ),
    upstream.readable.pipeTo(client.writable, { preventClose: true }).catch(
      () => {},
    ),
  ]);
  closeQuietly(client);
  closeQuietly(upstream);
}

/** relayTcp bridges every connection accepted on listener to target; it resolves once the listener is closed and every bridge has ended. */
export async function relayTcp(
  listener: Deno.Listener,
  to: Target,
): Promise<void> {
  const open = new Set<Promise<void>>();
  for await (const client of listener) {
    const b: Promise<void> = bridge(client, to).finally(() => open.delete(b));
    open.add(b);
  }
  await Promise.all(open);
}

/**
 * exactPathHandler forwards `GET <target path>?<query>` to target carrying only
 * the X-Internal-Service-Token header. Any other method or path answers 404
 * without touching upstream (the URL is normalised first, so `..` and `%2e%2e`
 * cannot walk out of the path); an unreachable upstream answers 502.
 */
export function exactPathHandler(
  target: string,
): (req: Request) => Promise<Response> {
  const base = new URL(target);
  return async (req) => {
    const url = new URL(req.url);
    if (req.method !== "GET" || url.pathname !== base.pathname) {
      return new Response(null, { status: 404 });
    }
    const token = req.headers.get("x-internal-service-token");
    try {
      return await fetch(new URL(url.search, base), {
        headers: token === null ? {} : { "x-internal-service-token": token },
      });
    } catch {
      return new Response(null, { status: 502 });
    }
  };
}

/** main validates both specs, then binds every listener; an empty or malformed spec, or a busy port, throws and exits. */
function main(): void {
  const tcp = parseForwards(Deno.env.get("FUNCTIONS_RELAY_TCP"));
  const http = parseForwards(Deno.env.get("FUNCTIONS_RELAY_HTTP"));
  if (tcp.length + http.length === 0) {
    throw new Error(
      "functions relay: FUNCTIONS_RELAY_TCP and FUNCTIONS_RELAY_HTTP are both empty",
    );
  }
  const routes = tcp.map((f) => ({
    port: f.port,
    to: splitHostPort(f.target),
  }));
  const handlers = http.map((f) => ({
    port: f.port,
    handler: exactPathHandler(f.target),
  }));
  for (const r of routes) {
    relayTcp(Deno.listen({ hostname: "0.0.0.0", port: r.port }), r.to);
  }
  for (const h of handlers) {
    Deno.serve({ hostname: "0.0.0.0", port: h.port, onListen() {} }, h.handler);
  }
  console.log(
    `[functions-relay] tcp ${JSON.stringify(tcp)} http ${JSON.stringify(http)}`,
  );
}

if (import.meta.main) main();
