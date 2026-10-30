# A third IDENTITY_HEADER_MODE value (`shadow`) is out of scope

- Decided: 2026-10-30 · by devil (D1 enforce precondition 2, strict-shadow ruling, ADR 0023)
- Holds while: `identityHeaderMode()` maps an unknown value to the NODE_ENV default

## The concept

Measure strict before flipping it with `IDENTITY_HEADER_MODE=shadow`: run compat but log what
strict would have refused.

## Why not

- `src/libs/common/src/identity/request-identity.ts:360-365` reads only `strict` and `compat`.
  Any other value falls back to `NODE_ENV`, which is `production` on the VM, so the result is strict.
- An image built before the shadow code, or rolled back to one, that reads `shadow` therefore
  runs strict: it 401s every raw-header caller. That is the outage the measurement exists to prevent.
- A separate boolean, `IDENTITY_STRICT_SHADOW`, is a no-op on an old image. That failure is safe.

## Prior requests

- 2026-10-30 (d1-relay, plan line 167): rejected by the plan's author, and the devil agreed.

## Reopen when

Every deployed image refuses to boot on an unknown `IDENTITY_HEADER_MODE`, or maps it to compat.
