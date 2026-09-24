// Unit tests for the tenant Worker `net` permission policy
// (FUNCTIONS_NET_ALLOWLIST_ENABLED). Run in a container:
//   docker run --rm -v "$PWD/src:/app" -w /app denoland/deno:alpine-2.1.4 \
//     deno test --allow-net --unstable-worker-options net-policy.test.ts
// The Worker tests spawn real Deno Workers against two loopback listeners, so
// they pin what Deno 2.1.4 actually enforces, not just the value we pass it.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { workerNet } from "./net-policy.ts";

/** probeFromWorker runs `connect(host, port)` inside a Worker built with `net` and resolves "open" or the error name. */
function probeFromWorker(
  net: ReturnType<typeof workerNet>,
  host: string,
  port: number,
): Promise<string> {
  const src = `self.onmessage = async (ev) => {
    try { const c = await Deno.connect(ev.data); c.close(); self.postMessage("open"); }
    catch (e) { self.postMessage(e.name); }
  };`;
  const url = URL.createObjectURL(
    new Blob([src], { type: "application/javascript" }),
  );
  const worker = new Worker(url, {
    type: "module",
    deno: {
      permissions: {
        read: false,
        env: false,
        run: false,
        write: false,
        ffi: false,
        sys: false,
        net,
      },
    },
  } as WorkerOptions);
  return new Promise((resolve) => {
    worker.onmessage = (ev) => {
      worker.terminate();
      URL.revokeObjectURL(url);
      resolve(String(ev.data));
    };
    worker.postMessage({ hostname: host, port });
  });
}

Deno.test("flag OFF inherits the runtime's net permission (byte-parity), whatever the list says", () => {
  assertEquals(workerNet(false, undefined), "inherit");
  assertEquals(workerNet(false, "api.example.com"), "inherit");
});

Deno.test("flag ON turns the comma/space list into host[:port] entries, blanks dropped", () => {
  assertEquals(workerNet(true, "functions-relay:8000,api.example.com"), [
    "functions-relay:8000",
    "api.example.com",
  ]);
  assertEquals(
    workerNet(true, " functions-relay:8000 , api.example.com:443 "),
    ["functions-relay:8000", "api.example.com:443"],
  );
  assertEquals(workerNet(true, "functions-relay:8000,"), [
    "functions-relay:8000",
  ]);
});

Deno.test("flag ON with an empty list revokes net entirely (deny all, never inherit)", () => {
  assertEquals(workerNet(true, undefined), false);
  assertEquals(workerNet(true, ""), false);
  assertEquals(workerNet(true, " , ,"), false);
});

Deno.test("each call returns a fresh array (no shared mutable state across Workers)", () => {
  const a = workerNet(true, "a:1") as string[];
  a.push("b:2");
  assertEquals(workerNet(true, "a:1"), ["a:1"]);
});

Deno.test("a Worker under the ON policy reaches only the listed host:port — not another port, IP alias or name", async () => {
  const allowed = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const other = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const allowedPort = allowed.addr.port;
  const otherPort = other.addr.port;
  const accept = (l: Deno.Listener) =>
    l.accept().then((c) => c.close()).catch(() => {});
  accept(allowed);
  accept(other);
  try {
    const net = workerNet(true, `127.0.0.1:${allowedPort}`);
    assertEquals(await probeFromWorker(net, "127.0.0.1", allowedPort), "open");
    assertEquals(
      await probeFromWorker(net, "127.0.0.1", otherPort),
      "NotCapable",
    );
    assertEquals(
      await probeFromWorker(net, "localhost", allowedPort),
      "NotCapable",
    );
    assertEquals(
      await probeFromWorker(workerNet(true, ""), "127.0.0.1", allowedPort),
      "NotCapable",
    );
  } finally {
    allowed.close();
    other.close();
  }
});

Deno.test("a Worker under the OFF policy reaches what the runtime reaches (today's behaviour)", async () => {
  const l = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  l.accept().then((c) => c.close()).catch(() => {});
  try {
    assertEquals(
      await probeFromWorker(workerNet(false, ""), "127.0.0.1", l.addr.port),
      "open",
    );
  } finally {
    l.close();
  }
});
