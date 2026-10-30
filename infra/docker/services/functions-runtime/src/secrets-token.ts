// Which token the runtime sends on the secret-resolve call (ADR 0023 F1, devil 2026-10-30).
// Compose renders an unset key as "" and `??` keeps "", so an empty value counts as
// unset here. Otherwise a legacy .env without FUNCTION_SECRETS_TOKEN would send no
// header, get a 401, and run every function without its secrets.

/** SecretsToken is the value to send and the name of the variable it came from. */
export interface SecretsToken {
  value: string;
  source: "FUNCTION_SECRETS_TOKEN" | "INTERNAL_SERVICE_TOKEN" | "none";
}

/**
 * secretsToken prefers the scoped FUNCTION_SECRETS_TOKEN (trimmed, as the Go side
 * trims it) and falls back to the shared INTERNAL_SERVICE_TOKEN, sent as is.
 * @param get reads one environment variable (Deno.env.get in the runtime).
 */
export function secretsToken(
  get: (key: string) => string | undefined,
): SecretsToken {
  const scoped = (get("FUNCTION_SECRETS_TOKEN") ?? "").trim();
  if (scoped !== "") return { value: scoped, source: "FUNCTION_SECRETS_TOKEN" };
  const shared = get("INTERNAL_SERVICE_TOKEN") ?? "";
  if (shared !== "") return { value: shared, source: "INTERNAL_SERVICE_TOKEN" };
  return { value: "", source: "none" };
}
