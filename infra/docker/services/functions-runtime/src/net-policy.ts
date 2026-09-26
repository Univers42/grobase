// Tenant Worker `net` permission policy (FUNCTIONS_NET_ALLOWLIST_ENABLED).
//
// OFF (default) keeps today's `net: "inherit"` byte-for-byte. ON turns the
// Worker's network permission into an ALLOWLIST of host[:port] entries taken
// from FUNCTIONS_NET_ALLOW — never a denylist: Deno matches the host STRING, so
// denying "kong" would still admit 172.18.0.5, mini-baas-kong, kong. and any
// tenant DNS name that resolves inside the network. Deno checks every
// redirect hop, raw Deno.connect and WebSocket against the same list. An
// allowlisted hostname is trusted as-is (its DNS answer is not re-checked):
// the compose network jail, not this list, is what keeps internal IPs out.

/**
 * workerNet returns the `net` permission for a tenant Worker.
 * @param enabled FUNCTIONS_NET_ALLOWLIST_ENABLED, parsed.
 * @param allow   FUNCTIONS_NET_ALLOW: comma/space-separated host[:port] entries.
 * @returns "inherit" when OFF; the entries when ON; false (no network) when ON
 *          with no entries. A fresh array per call, never shared between Workers.
 */
export function workerNet(
  enabled: boolean,
  allow: string | undefined,
): "inherit" | false | string[] {
  if (!enabled) return "inherit";
  const hosts = (allow ?? "").split(/[\s,]+/).filter((h) => h !== "");
  return hosts.length > 0 ? hosts : false;
}
