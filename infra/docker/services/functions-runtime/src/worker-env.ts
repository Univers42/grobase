// How a tenant Worker receives its function secrets (N-26).
//
// A handler reads its secrets with the normal Deno.env.get(KEY) API, but that
// Deno.env is a private in-memory map built inside the Worker. The Worker's
// real `env` permission is off, so it can never read or write the runtime's
// process environment. Deno.env is process-wide: seeding secrets with
// Deno.env.set left them there for any other tenant's Worker granted the same
// key, and a value set() rejected (a NUL byte) was swallowed, leaving the
// runtime's own variable of that name readable.

/** WorkerEnv is the source prefix and the `env` permission for one tenant Worker. */
export interface WorkerEnv {
  preamble: string;
  permission: false;
}

/**
 * workerEnv builds the Worker source prefix that replaces Deno.env with a
 * private map of `secrets`. Keys outside the map throw Deno.errors.NotCapable,
 * the error Deno's own scoped permission gave, so handlers see the same API.
 * @param secrets the tenant function's resolved KEY → value map.
 */
export function workerEnv(secrets: Record<string, string>): WorkerEnv {
  return {
    preamble: `
      {
        const granted = new Map(Object.entries(${JSON.stringify(secrets)}));
        const keys = new Set(granted.keys());
        const refuse = (k) => {
          throw new Deno.errors.NotCapable('Requires env access to "' + k + '", run again with the --allow-env flag');
        };
        const check = (k) => { if (!keys.has(String(k))) refuse(String(k)); return String(k); };
        const env = {
          get: (k) => granted.get(check(k)),
          has: (k) => granted.has(check(k)),
          set: (k, v) => { granted.set(check(k), String(v)); },
          delete: (k) => { granted.delete(check(k)); },
          toObject: () => refuse("*"),
        };
        Object.defineProperty(Deno, "env", { value: Object.freeze(env), configurable: false, writable: false });
      }`,
    permission: false,
  };
}
