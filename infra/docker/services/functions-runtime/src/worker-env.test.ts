// Unit tests for how a tenant Worker receives its function secrets (N-26).
// Run in a container:
//   docker run --rm -v "$PWD/src:/app" -w /app denoland/deno:alpine-2.1.4 \
//     deno test --allow-env --unstable-worker-options worker-env.test.ts
// They spawn real Deno Workers, so they pin what Deno 2.1.4 does with a
// Worker's environment, not just the source we generate.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { workerEnv } from "./worker-env.ts";

/** runInWorker runs `body` after workerEnv(secrets) in a Worker and resolves what it posts. */
function runInWorker(secrets: Record<string, string>, body: string): Promise<string> {
  const env = workerEnv(secrets);
  const url = URL.createObjectURL(
    new Blob([`${env.preamble}\n${body}`], { type: "application/javascript" }),
  );
  const worker = new Worker(url, {
    type: "module",
    deno: {
      permissions: {
        env: env.permission,
        read: false,
        net: false,
        run: false,
        write: false,
        ffi: false,
        sys: false,
      },
    },
  } as WorkerOptions);
  return new Promise((resolve) => {
    worker.onmessage = (ev) => {
      worker.terminate();
      URL.revokeObjectURL(url);
      resolve(String(ev.data));
    };
  });
}

/** tryRead is Worker source that posts Deno.env.get(key), or the error's name. */
function tryRead(key: string): string {
  return `try { self.postMessage(String(Deno.env.get(${JSON.stringify(key)}))); }
    catch (e) { self.postMessage(e.name); }`;
}

Deno.test("a handler reads its own secret with Deno.env.get", async () => {
  assertEquals(await runInWorker({ API_KEY: "k-1" }, tryRead("API_KEY")), "k-1");
});

Deno.test("a key the function was not given is refused, as Deno's permission did", async () => {
  assertEquals(await runInWorker({ API_KEY: "k-1" }, tryRead("HOME")), "NotCapable");
  assertEquals(await runInWorker({}, tryRead("HOME")), "NotCapable");
});

Deno.test("a secret never reaches the runtime's process environment", async () => {
  Deno.env.delete("N26_SHARED");
  await runInWorker({ N26_SHARED: "tenant-a" }, `self.postMessage("ran")`);
  assertEquals(Deno.env.get("N26_SHARED"), undefined);
});

Deno.test("one tenant's secret is invisible to another tenant's Worker with the same key", async () => {
  Deno.env.delete("N26_SHARED");
  const reader = runInWorker(
    { N26_SHARED: "tenant-b" },
    `Deno.env.delete("N26_SHARED");
     setTimeout(() => {
       try { self.postMessage(String(Deno.env.get("N26_SHARED"))); }
       catch (e) { self.postMessage(e.name); }
     }, 300);`,
  );
  await runInWorker({ N26_SHARED: "tenant-a" }, `self.postMessage("ran")`);
  assert((await reader) !== "tenant-a", "tenant B read tenant A's secret");
});

Deno.test("a secret value Deno.env.set would reject does not expose the runtime's own variable", async () => {
  Deno.env.set("N26_PLATFORM_TOKEN", "real-platform-value");
  try {
    const seen = await runInWorker({ N26_PLATFORM_TOKEN: "x\u0000y" }, tryRead("N26_PLATFORM_TOKEN"));
    assert(seen !== "real-platform-value", "the Worker read the runtime's real value");
    assertEquals(seen, "x\u0000y");
  } finally {
    Deno.env.delete("N26_PLATFORM_TOKEN");
  }
});

Deno.test("the runtime's environment stays unreachable past the Deno.env replacement", async () => {
  Deno.env.set("N26_PLATFORM_TOKEN", "real-platform-value");
  try {
    const seen = await runInWorker(
      { N26_PLATFORM_TOKEN: "tenant-value" },
      `try { self.postMessage(String(Deno[Deno.internal].core.ops.op_get_env("N26_PLATFORM_TOKEN"))); }
       catch (e) { self.postMessage(e.name); }`,
    );
    assertEquals(seen, "NotCapable");
  } finally {
    Deno.env.delete("N26_PLATFORM_TOKEN");
  }
});
