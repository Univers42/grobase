# 0008 — `/admin/v1/{migrate,rotate}`: Kong forwards to tenant-control, which signs

Status: ruled PROCEED-WITH-CONDITIONS (2026-10-29, C1–C14), code in G1f. The VM rollout runs
#72 → G1f → VM Kong edit (backup + `kong config parse`) → shadow with zero `would_deny` →
enforce. Each step needs a human go.

## Problem

Kong's `admin-migrate` and `admin-rotate` services proxied straight to
`data-plane-router-rust:4011/v1/admin/{migrate,rotate}` (`kong.yml`, before this change). The
body is the caller's own: `{identity, mount, name, statements}` (`sdks/js/src/types.ts:686-725`).
The data plane authorizes on that self-declared `identity` (`routes/admin.rs:89-96, 151-158`).

G1a's inbound auth (ADR 0007) covers every data-plane `/v1/*` route. Kong cannot sign:
- its Lua sandbox allows only `cjson.safe`;
- a Kong signer would sign client bodies, which is the thing the signature is meant to prevent.

Under `DATA_PLANE_INBOUND_AUTH=enforce`, both routes would answer 401. The SDK
(`sdks/js/src/domains/admin.ts:114-122`) holds only the service_role key, not a service token.

## Decision

Kong keeps every plugin on both routes (key-auth with `hide_credentials: false`, ip-restriction,
ACL `baas-admin`, 256 KiB, 30/min). It now forwards to
`tenant-control:3022/v1/admin/{migrate,rotate}` (`kong.yml:693-730`).

tenant-control (`internal/tenants/admin_relay.go`):

1. **Body cap first.** It reads at most 256 KiB, returning 413 above that, before auth.
   `rotation.Accept` reads the whole body, so the cap has to come before it.
2. **Two credentials, nothing else:**
   - a valid service token (`rotation.Accept`, the rule every other admin route uses);
   - an `apikey` header equal to `KONG_SERVICE_API_KEY` (`serviceauth.SecureCompare`).

   This arm is off when the var is unset, and exists only on these two routes. There is no
   Bearer arm, and a consumer header proves nothing.
3. **Identity overwritten, everything else untouched.** The body is decoded as
   `map[string]json.RawMessage`. Only `identity` is replaced with
   `{tenant_id: mount.tenant_id, user_id: "admin-api:<arm>", source: "service_token", roles: ["service_role"]}`.
   Decoding the mount through a Go struct would drop `isolation`, `pool_policy` and
   `replica_inline_dsn`. DDL would then silently land in `public`, and rotate would drain 0 pools.
4. **Signed forward on its own client.** The request is a v1 HMAC POST (`postSigned`) on a 65 s
   client (`adminRelayTimeout`, `dataplane.go:42`), which is longer than Kong's 60 s upstream
   read timeout. The 8 s provisioning client would cut long migrations. The data plane's
   response is read up to 1 MiB.
5. **Relay, redacted.** The data plane's status and body pass through `httpx.RedactDSN`. That
   now covers libpq keyword DSNs (`host=db password=…`) as well as URLs.
   - Data plane unset → 503.
   - Data plane unreachable → 502, without the address.
6. **Audit.** Each call logs one line with route, arm, tenant, migration name and status. It
   never logs statements, DSNs or keys.

## Alternatives considered

- **Kong Lua signer.** Rejected for the reasons in the Problem section: the sandbox and signing
  client bodies.
- **Accept `Authorization: Bearer <service_role key>`.** Rejected because the SDK already sends
  the key as `apikey`. A second header arm would add surface for no caller.
- **Decode into the Go `Mount` struct.** Rejected because it loses the mount fields listed in
  Decision 3.
- **Give the SDK a service token.** Rejected because it would put a token that signs any
  identity (ADR 0007, residual 1) into client code.

## Consequences

- **A second credential.** The service_role key becomes a credential that tenant-control
  accepts, on these two routes only. `TestKongServiceKeyDoesNotOpenOtherAdminRoutes` fails if
  it ever opens another route. That key already reached the same data-plane endpoints through
  Kong before this change.
- **Every authenticated caller is admin for the mount's tenant.** Only service_role and
  service-token holders can authenticate, and both are platform-wide. `mount.tenant_id` stays
  caller-chosen, as it was.
- **Rotation must reach tenant-control.** `rotate_kong` now restarts tenant-control as well as
  Kong. However, `restart_services` uses `docker compose restart`, which does not reload `.env`.
  This is pre-existing and affects every rotation, so the old key keeps working until the
  service is recreated. Tracked in [#75](https://github.com/Univers42/grobase/issues/75).
- **Probes.** m227 probes the new path for `..` and `%2F` traversal from `/admin/v1/migrate`
  into `/v1/provision`, and a SQL body sent to `/admin/v1/rotate`. All three must get a 403, because the WAF SQL exemption is `@streq /admin/v1/migrate` (`waf/conf/exclusions.conf:98`).

## Reopen when

- A caller needs these routes without platform-wide rights. In that case, scope the identity by
  key or kid (ADR 0007, "Reopen when") instead of trusting `mount.tenant_id`.
- Kong gains a signing plugin that signs its own envelope instead of the client body.
