// Unit tests for the secret-resolve token choice (ADR 0023 F1). Run in a container:
//   docker run --rm -v "$PWD/src:/app" -w /app denoland/deno:alpine-2.1.4 \
//     deno test secrets-token.test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { secretsToken } from "./secrets-token.ts";

const env = (vars: Record<string, string>) => (key: string) => vars[key];

Deno.test("the scoped token wins when set", () => {
  assertEquals(
    secretsToken(
      env({
        FUNCTION_SECRETS_TOKEN: "scoped",
        INTERNAL_SERVICE_TOKEN: "shared",
      }),
    ),
    {
      value: "scoped",
      source: "FUNCTION_SECRETS_TOKEN",
    },
  );
});

Deno.test('an empty scoped token falls back to the shared one (compose renders unset as "")', () => {
  assertEquals(
    secretsToken(
      env({ FUNCTION_SECRETS_TOKEN: "", INTERNAL_SERVICE_TOKEN: "shared" }),
    ),
    {
      value: "shared",
      source: "INTERNAL_SERVICE_TOKEN",
    },
  );
});

Deno.test("a whitespace-only scoped token is unset, as Go trims it", () => {
  assertEquals(
    secretsToken(
      env({ FUNCTION_SECRETS_TOKEN: "  ", INTERNAL_SERVICE_TOKEN: "shared" }),
    ).source,
    "INTERNAL_SERVICE_TOKEN",
  );
});

Deno.test("a legacy env with only the shared token sends it", () => {
  assertEquals(
    secretsToken(env({ INTERNAL_SERVICE_TOKEN: "shared" })).value,
    "shared",
  );
});

Deno.test("nothing set sends nothing", () => {
  assertEquals(
    secretsToken(
      env({ FUNCTION_SECRETS_TOKEN: "", INTERNAL_SERVICE_TOKEN: "" }),
    ),
    { value: "", source: "none" },
  );
});
