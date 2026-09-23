// Unit tests for the functions-jail relay (relay.ts). Run in a container:
//   docker run --rm -v "$PWD/src:/app" -w /app denoland/deno:alpine-2.1.4 \
//     deno test --allow-net relay.test.ts
// Every socket is loopback and ephemeral; each test closes what it opens.

import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  exactPathHandler,
  parseForwards,
  relayTcp,
  splitHostPort,
} from "./relay.ts";

type Seen = { method: string; path: string; headers: Record<string, string> };

/** recordingUpstream serves 200 "upstream" on an ephemeral loopback port and records each request it sees. */
function recordingUpstream(): {
  server: Deno.HttpServer<Deno.NetAddr>;
  seen: Seen[];
} {
  const seen: Seen[] = [];
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: 0, onListen() {} },
    (req) => {
      const u = new URL(req.url);
      seen.push({
        method: req.method,
        path: u.pathname + u.search,
        headers: Object.fromEntries(req.headers),
      });
      return new Response("upstream");
    },
  );
  return { server, seen };
}

/** status sends one request to the handler and returns its HTTP status, draining the body. */
async function status(
  handler: (req: Request) => Response | Promise<Response>,
  method: string,
  url: string,
): Promise<number> {
  const res = await handler(
    new Request(url, {
      method,
      headers: {
        "x-internal-service-token": "tok",
        "x-baas-tenant-id": "victim",
      },
    }),
  );
  await res.body?.cancel();
  return res.status;
}

Deno.test("parseForwards reads port=target entries and skips blanks", () => {
  assertEquals(parseForwards("3060=functions-sandbox:3060, 8000=kong:8000,"), [
    { port: 3060, target: "functions-sandbox:3060" },
    { port: 8000, target: "kong:8000" },
  ]);
  assertEquals(parseForwards(undefined), []);
  assertEquals(parseForwards(" , "), []);
});

Deno.test("parseForwards fails fast on a malformed entry", () => {
  for (
    const bad of [
      "kong:8000",
      "=kong:8000",
      "x=kong:8000",
      "3060=",
      "0=kong:8000",
      "70000=kong:8000",
    ]
  ) {
    assertThrows(() => parseForwards(bad), Error, "bad relay forward");
  }
});

Deno.test("splitHostPort parses host:port and rejects anything else", () => {
  assertEquals(splitHostPort("kong:8000"), { hostname: "kong", port: 8000 });
  for (const bad of ["kong", ":8000", "kong:", "kong:http", "kong:99999"]) {
    assertThrows(() => splitHostPort(bad), Error, "bad relay target");
  }
});

Deno.test("exactPathHandler forwards only GET <path>?query, carrying only the service token", async () => {
  const up = recordingUpstream();
  try {
    const target =
      `http://127.0.0.1:${up.server.addr.port}/internal/v1/function-secrets/resolve`;
    const h = exactPathHandler(target);
    assertEquals(
      await status(
        h,
        "GET",
        "http://relay:3025/internal/v1/function-secrets/resolve?tenant=t&function=f",
      ),
      200,
    );
    assertEquals(up.seen.length, 1);
    assertEquals(up.seen[0].method, "GET");
    assertEquals(
      up.seen[0].path,
      "/internal/v1/function-secrets/resolve?tenant=t&function=f",
    );
    assertEquals(up.seen[0].headers["x-internal-service-token"], "tok");
    assertEquals(up.seen[0].headers["x-baas-tenant-id"], undefined);
  } finally {
    await up.server.shutdown();
  }
});

Deno.test("exactPathHandler answers 404 for any other method or path, without calling upstream", async () => {
  const up = recordingUpstream();
  try {
    const h = exactPathHandler(
      `http://127.0.0.1:${up.server.addr.port}/internal/v1/function-secrets/resolve`,
    );
    assertEquals(
      await status(
        h,
        "POST",
        "http://relay:3025/internal/v1/function-secrets/resolve",
      ),
      404,
    );
    assertEquals(await status(h, "GET", "http://relay:3025/v1/webhooks"), 404);
    assertEquals(
      await status(h, "GET", "http://relay:3025/v1/function-secrets"),
      404,
    );
    assertEquals(
      await status(
        h,
        "GET",
        "http://relay:3025/internal/v1/function-secrets/resolve/../../../../v1/webhooks",
      ),
      404,
    );
    assertEquals(
      await status(
        h,
        "GET",
        "http://relay:3025/internal/v1/function-secrets/resolve/%2e%2e/%2e%2e/%2e%2e/%2e%2e/v1/webhooks",
      ),
      404,
    );
    assertEquals(
      await status(
        h,
        "GET",
        "http://relay:3025/internal/v1/function-secrets/resolve/",
      ),
      404,
    );
    assertEquals(up.seen.length, 0);
  } finally {
    await up.server.shutdown();
  }
});

Deno.test("exactPathHandler answers 502 when the upstream is down", async () => {
  const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = l.addr.port;
  l.close();
  const h = exactPathHandler(
    `http://127.0.0.1:${port}/internal/v1/function-secrets/resolve`,
  );
  assertEquals(
    await status(
      h,
      "GET",
      "http://relay:3025/internal/v1/function-secrets/resolve",
    ),
    502,
  );
});

Deno.test("relayTcp bridges a connection byte-for-byte to its target, then stops when the listener closes", async () => {
  const up = recordingUpstream();
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const done = relayTcp(listener, {
    hostname: "127.0.0.1",
    port: up.server.addr.port,
  });
  try {
    const res = await fetch(
      `http://127.0.0.1:${listener.addr.port}/via/relay?x=1`,
      { headers: { connection: "close" } },
    );
    assertEquals(res.status, 200);
    assertEquals(await res.text(), "upstream");
    assertEquals(up.seen[0].path, "/via/relay?x=1");
  } finally {
    listener.close();
    await done;
    await up.server.shutdown();
  }
});

Deno.test("relayTcp closes the client when the target refuses", async () => {
  const dead = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const deadPort = dead.addr.port;
  dead.close();
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const done = relayTcp(listener, { hostname: "127.0.0.1", port: deadPort });
  try {
    const conn = await Deno.connect({
      hostname: "127.0.0.1",
      port: listener.addr.port,
    });
    const n = await conn.read(new Uint8Array(1));
    conn.close();
    assertEquals(n, null);
  } finally {
    listener.close();
    await done;
  }
});
