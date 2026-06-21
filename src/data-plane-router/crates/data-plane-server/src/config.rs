/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   config.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:32:57 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:32:58 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

#[derive(Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub product_mode: String,
    pub adapter_registry_url: String,
    pub permission_bundle_url: String,
    /// Inline JSON policy bundle. When set, the in-Rust ABAC evaluator
    /// answers `/v1/permissions/decide` locally; the permission-engine HTTP
    /// roundtrip becomes optional.
    pub permission_bundle_inline: String,
    /// `abac` (default) or `rbac`. Reported via /v1/capabilities.
    pub permission_mode: String,
    /// Max simultaneously-open connection pools the registry keeps (LRU-evicted
    /// beyond this). Bounds memory under N-tenant fan-out (db_per_tenant /
    /// schema_per_tenant). Default 256; from `DATA_PLANE_MAX_POOLS`.
    pub max_pools: usize,
    /// B4-pools: collapse `shared_rls` tenants that share a connection target
    /// onto ONE pool (keyed by DSN/credential, not tenant). Safe ONLY for
    /// shared_rls — RLS scoping is re-applied per checkout from the request
    /// identity, so the pool carries no tenant state. schema_per_tenant pins
    /// `search_path` per pool and db_per_tenant/tenant_owned have distinct DSNs,
    /// so those keep per-tenant pools regardless. Default `false` (per-tenant
    /// pools, byte-parity). From `DATA_PLANE_SHARE_POOLS` (`1`/`true`/`on`).
    /// This is the 100K lever: 10K shared_rls tenants on one DB → 1 pool.
    pub share_pools: bool,
    /// Whether the capability-aware planner (G6) may route a `Federate` verdict
    /// to the analytics plane. Default `false` — until Trino is wired, a
    /// federation plan is lowered to a clean `NotImplemented`. From
    /// `DATA_PLANE_FEDERATION_ENABLED` (`1`/`true`/`on`).
    pub planner_federation_enabled: bool,

    // ---- gap G8: pluggable credential providers (all DISABLED by default) ---
    // These mirror the env vars `EnvMountResolver::from_env` /
    // `ProviderRegistry::from_env` actually read. They live here so the
    // provider contract has ONE documented home (no config drift); the resolver
    // remains the single reader so the empty defaults below keep every provider
    // DISABLED until explicitly configured.
    /// Service token for the adapter-registry credential provider. Empty by
    /// default → the adapter-registry provider is NOT registered. From
    /// `DATA_PLANE_ADAPTER_REGISTRY_TOKEN`. (The URL reuses the existing
    /// `adapter_registry_url` field.)
    pub adapter_registry_token: String,
    /// Vault origin for the Vault credential provider. Empty by default → the
    /// Vault provider is NOT registered. From `DATA_PLANE_VAULT_ADDR`.
    pub vault_addr: String,
    /// Vault token (env-only, never logged). Empty by default. From
    /// `DATA_PLANE_VAULT_TOKEN`. Both addr and token must be set for the Vault
    /// provider to register.
    pub vault_token: String,
    /// KV v2 path prefix for DSN secrets. From `DATA_PLANE_VAULT_DSN_PREFIX`.
    pub vault_dsn_prefix: String,
    /// Secret field that holds the DSN. From `DATA_PLANE_VAULT_DSN_FIELD`.
    pub vault_dsn_field: String,
    /// Resolved-DSN cache TTL in ms. `0` (default) → cache DISABLED. From
    /// `DATA_PLANE_CREDENTIAL_CACHE_TTL_MS`.
    pub credential_cache_ttl_ms: u64,

    /// Security posture (Phase 5/6): `baseline` (default) or `max`. From
    /// `SECURITY_MODE`. In `max`, external engine mounts must present a
    /// verifiable TLS chain (a `require` DSN is upgraded to verify-full instead
    /// of accepting any cert), and credentials are expected to be Vault-backed.
    /// `baseline` keeps libpq `require` semantics (encrypt, don't verify).
    pub security_mode: String,
    /// Optional custom CA bundle (PEM) used to verify external-mount TLS chains
    /// under verify-ca/verify-full. From `DATA_PLANE_TLS_CA_FILE`. Empty → the
    /// system/webpki roots only.
    pub tls_ca_file: String,

    // ---- Phase 7: direct front door (/data/v1), shadow — DISABLED by default ---
    /// tenant-control origin for Rust-native API-key verification. Go remains
    /// the sole identity authority — Rust only CALLS `/v1/keys/verify`. From
    /// `TENANT_CONTROL_URL`.
    pub tenant_control_url: String,
    /// Shared internal service token presented to tenant-control + adapter-
    /// registry on the bypass path (never logged). From `INTERNAL_SERVICE_TOKEN`.
    pub internal_service_token: String,
    /// Mounts the additive `/data/v1` front door (Kong → Rust directly). Default
    /// OFF — the bypass ships dormant; the existing `/query/v1` (→ query-router)
    /// path is untouched, so this is pure shadow until explicitly enabled and
    /// parity-proven. From `DATA_PLANE_BYPASS_ENABLED` (`1`/`true`/`on`).
    pub bypass_enabled: bool,
    /// Phase D — apply ABAC field masks in the Rust data path (cutover prep).
    /// OFF by default (the query-router still masks → byte-parity); flip ON
    /// (`DATA_PLANE_APPLY_MASKS=1`) once the query-router's mask is removed.
    pub apply_masks: bool,
    /// TTL (ms) for the bypass `api-key → identity` cache; default 30 000 to
    /// match the query-router. 0 disables (verify every request).
    pub verify_cache_ttl_ms: u64,
    /// G-ReadAudit (A6) — also audit-log successful READS, not just mutations.
    /// OFF by default (`DATA_PLANE_AUDIT_READS`) → byte-parity: the read path
    /// emits nothing extra and stays off the hot path. Flip ON to get a `read`
    /// audit event (tenant/engine/op/resource/returned_rows) per served read,
    /// at the cost of audit-log volume. Mutations are audited unconditionally.
    pub audit_reads: bool,
    /// Track-B metering (B1a) — per-tenant usage counters in the data plane.
    /// OFF by default → byte-parity: the read/write hot path takes ZERO extra
    /// branches, increments ZERO counters, emits ZERO usage events. Requires
    /// BOTH the master `METERING_ENABLED` AND `DATA_PLANE_METERING` to be truthy
    /// (master + per-emitter sub-flag, mirroring the plan's flag ladder). When
    /// ON, the read arm records `query.count`/`query.rows` and the mutation arm
    /// records `write.rows` into an in-memory aggregate drained by a background
    /// flusher that emits one structured `usage` tracing event per
    /// (tenant, metric) window.
    pub metering: bool,
    /// Track-B metering flush cadence (ms) — how often the background flusher
    /// drains non-zero `(tenant, metric)` aggregates and emits one `usage` event
    /// each. From `DATA_PLANE_METERING_FLUSH_MS` (default 60000); a gate can set
    /// it low to force a fast flush. Only consulted when `metering` is ON.
    pub metering_flush_ms: u64,
    /// Track-B metering (B1b) — the Redis URL the background flusher XADDs the
    /// durable `usage.events` stream entries to, IN ADDITION to the B1a tracing
    /// event. From `DATA_PLANE_METERING_REDIS_URL`, falling back to `REDIS_URL`
    /// (the same fallback the rate limiter's Redis backend uses). Empty → the
    /// XADD is skipped entirely and B1a's tracing event is the only sink, so the
    /// durable path is opt-in via a configured URL on top of the metering flag.
    /// Only consulted when `metering` is ON.
    pub metering_redis_url: String,
    /// Track-B quota enforcement (B2) — honor the control-plane QuotaGuard's
    /// over-quota decision on the request path. OFF by default → byte-parity: the
    /// hot path takes ZERO extra branches (an `Option::is_none` short-circuit
    /// before any quota state is touched), no Redis snapshot is built, and the
    /// refresh tick is never scheduled. Requires BOTH the master `METERING_ENABLED`
    /// AND `DATA_PLANE_QUOTA_ENFORCEMENT` to be truthy (master + per-honor sub-flag,
    /// mirroring the metering flag ladder). When ON, a tenant the QuotaGuard listed
    /// in the `quota:over` Redis set is rejected with 402 (quota exceeded); a tenant
    /// absent from the set is served normally. CONSUMES B1's data (tenant_usage via
    /// the guard) — it never re-meters.
    pub quota_enforcement: bool,
    /// Track-B quota enforcement (B2) — how often the data plane refreshes its
    /// in-memory snapshot of the `quota:over` set from Redis (one `SMEMBERS` per
    /// refresh, NOT per request). From `DATA_PLANE_QUOTA_REFRESH_MS` (default
    /// 15000, matching the reaper cadence); a gate can set it low for a fast
    /// first refresh. Only consulted when `quota_enforcement` is ON.
    pub quota_refresh_ms: u64,
    /// Track-B quota enforcement (B2) — the Redis URL the snapshot refresher reads
    /// `quota:over` from. From `DATA_PLANE_QUOTA_REDIS_URL`, falling back to the
    /// shared `REDIS_URL` (the same convention the rate limiter + metering use).
    /// Empty → the refresher never connects (set stays empty = fail-open). Only
    /// consulted when `quota_enforcement` is ON. REUSED by spend-cap + suspend
    /// (all three honor sets live in the same control-plane Redis), so they add no
    /// new Redis-URL env var.
    pub quota_redis_url: String,
    /// Track-B spend-cap enforcement — honor the control-plane spend-cap guard's
    /// over-spend decision on the request path. OFF by default → byte-parity: the
    /// hot path takes ZERO extra branches (a `bool` short-circuit before any spend
    /// state is touched), no Redis snapshot is built, and the refresh tick is never
    /// scheduled for it. Requires BOTH the master `METERING_ENABLED` AND
    /// `DATA_PLANE_SPEND_CAPS` to be truthy (master + per-honor sub-flag, mirroring
    /// `quota_enforcement`). When ON, a tenant the spend-cap guard listed in the
    /// `spend:over` Redis set is rejected with 402 (`spend_capped`); a tenant absent
    /// from the set is served normally. Reuses `quota_refresh_ms` / `quota_redis_url`.
    pub spend_caps: bool,
    /// Track-B abuse/KYC suspension — honor the control-plane abuse guard's
    /// suspension decision on the request path. OFF by default → byte-parity: the
    /// hot path takes ZERO extra branches (a `bool` short-circuit before any suspend
    /// state is touched), no Redis snapshot is built, and the refresh tick is never
    /// scheduled for it. Requires BOTH the master `METERING_ENABLED` AND
    /// `DATA_PLANE_SUSPEND_READER` to be truthy (master + per-honor sub-flag,
    /// mirroring `quota_enforcement`). When ON, a tenant the abuse guard listed in
    /// the `tenant:suspended` Redis set is rejected with 403 (`tenant_suspended`); a
    /// tenant absent from the set is served normally. Reuses `quota_refresh_ms` /
    /// `quota_redis_url`.
    pub suspend_reader: bool,

    /// B5 per-tenant observability (Pillar 1) — emit `tenant_id` as a STRUCTURED
    /// TRACING/LOG FIELD on the per-request span. OFF by default → byte-parity:
    /// the span is never entered, so the log output carries no `tenant_id` field
    /// and is byte-identical to today. From `DATA_PLANE_TENANT_OBS`
    /// (`1`/`true`/`on`). `tenant_id` is a Loki FIELD (promtail extracts it under
    /// `expressions:` for `| json | tenant_id="X"`), NEVER a Loki label and NEVER a
    /// Prometheus label here — so it adds ZERO label-series cardinality at 10K+
    /// tenants. The handler reads this cheap bool, never the env, per request.
    pub tenant_obs: bool,
    /// B5 per-tenant observability (Pillar 3, OPTIONAL) — additionally emit a
    /// `tenant_id` label on EXACTLY ONE counter (`baas_http_requests_total`),
    /// behind a HARD in-process cap (N=512 distinct tenants + one `_over_cap`
    /// sentinel → ceiling N+1 series, independent of tenant count). OFF by default
    /// EVEN WHEN `tenant_obs` is ON, because the counter path is the only place a
    /// mistake can cost cardinality. Requires BOTH `tenant_obs` AND
    /// `DATA_PLANE_TENANT_OBS_COUNTER` (`1`/`true`/`on`) — only consulted when
    /// `tenant_obs` is also true (the parent log-field flag). NEVER applied to any
    /// histogram or to the cache/pool/outbox counters. OFF → `/metrics` is
    /// byte-identical to today.
    pub tenant_obs_counter: bool,

    /// S8 read-replica routing — serve pure reads (List/Get/Aggregate) on a mount
    /// carrying a `replica_inline_dsn` from the REPLICA's own pool. OFF by default
    /// → byte-parity: the request path takes ZERO extra branches (a `bool`
    /// short-circuit before the mount is even inspected), so `request.mount`
    /// reaches `get_or_create` UNCHANGED and writes/tx/Batch always stay on the
    /// primary. Unlike the metering family this is a routing CAPABILITY, not a
    /// metering feature, so it is STANDALONE (no `METERING_ENABLED` master gate).
    /// From `DATA_PLANE_READ_REPLICA` (`1`/`true`/`on`).
    pub read_replica: bool,
}

impl ServerConfig {
    /// Whether the router is running in the max-hardening security posture.
    #[must_use]
    pub fn is_max_security(&self) -> bool {
        self.security_mode.eq_ignore_ascii_case("max")
    }
}

impl ServerConfig {
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            host: read_env("DATA_PLANE_ROUTER_HOST", "0.0.0.0"),
            port: read_env("DATA_PLANE_ROUTER_PORT", "4011")
                .parse()
                .unwrap_or(4011),
            product_mode: read_env("DATA_PLANE_ROUTER_PRODUCT_MODE", "shadow"),
            adapter_registry_url: read_env(
                "DATA_PLANE_ADAPTER_REGISTRY_URL",
                "http://adapter-registry-go:3021",
            ),
            permission_bundle_url: read_env(
                "DATA_PLANE_PERMISSION_BUNDLE_URL",
                "http://permission-engine:3050/permissions/bundles/latest",
            ),
            permission_bundle_inline: read_env("DATA_PLANE_PERMISSION_BUNDLE", ""),
            permission_mode: read_env("DATA_PLANE_PERMISSION_MODE", "abac"),
            max_pools: read_env("DATA_PLANE_MAX_POOLS", "256")
                .parse()
                .unwrap_or(256),
            share_pools: matches!(
                read_env("DATA_PLANE_SHARE_POOLS", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            planner_federation_enabled: matches!(
                read_env("DATA_PLANE_FEDERATION_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // gap G8: every provider knob defaults to empty/disabled.
            adapter_registry_token: read_env("DATA_PLANE_ADAPTER_REGISTRY_TOKEN", ""),
            vault_addr: read_env("DATA_PLANE_VAULT_ADDR", ""),
            vault_token: read_env("DATA_PLANE_VAULT_TOKEN", ""),
            vault_dsn_prefix: read_env("DATA_PLANE_VAULT_DSN_PREFIX", "data-plane/dsn"),
            vault_dsn_field: read_env("DATA_PLANE_VAULT_DSN_FIELD", "dsn"),
            credential_cache_ttl_ms: read_env("DATA_PLANE_CREDENTIAL_CACHE_TTL_MS", "0")
                .parse()
                .unwrap_or(0),
            security_mode: read_env("SECURITY_MODE", "baseline"),
            tls_ca_file: read_env("DATA_PLANE_TLS_CA_FILE", ""),
            tenant_control_url: read_env("TENANT_CONTROL_URL", "http://tenant-control:3022"),
            internal_service_token: read_env("INTERNAL_SERVICE_TOKEN", ""),
            bypass_enabled: matches!(
                read_env("DATA_PLANE_BYPASS_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            apply_masks: matches!(
                read_env("DATA_PLANE_APPLY_MASKS", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            verify_cache_ttl_ms: read_env("DATA_PLANE_VERIFY_CACHE_TTL_MS", "30000")
                .parse()
                .unwrap_or(30000),
            audit_reads: matches!(
                read_env("DATA_PLANE_AUDIT_READS", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // Track-B metering (B1a): ON only when BOTH the master flag AND the
            // per-emitter sub-flag are truthy — so the master can gate the whole
            // pipeline while the data-plane emitter is still independently
            // toggleable for an isolated gate. BOTH default `false` → byte-parity.
            metering: matches!(
                read_env("METERING_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ) && matches!(
                read_env("DATA_PLANE_METERING", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            metering_flush_ms: read_env("DATA_PLANE_METERING_FLUSH_MS", "60000")
                .parse()
                .unwrap_or(60000),
            // Track-B metering (B1b): the durable sink URL. Falls back to the
            // shared `REDIS_URL` so the standard stack needs no extra var; empty
            // → no XADD (B1a tracing-only). Mirrors the ratelimit-redis URL
            // resolution (its own var, then `REDIS_URL`).
            metering_redis_url: {
                let url = read_env("DATA_PLANE_METERING_REDIS_URL", "");
                if url.trim().is_empty() {
                    read_env("REDIS_URL", "")
                } else {
                    url
                }
            },
            // Track-B quota enforcement (B2): ON only when BOTH the master flag
            // AND the per-honor sub-flag are truthy — so the master gates the whole
            // pipeline while the data-plane honor is independently toggleable for an
            // isolated gate. BOTH default `false` → byte-parity.
            quota_enforcement: matches!(
                read_env("METERING_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ) && matches!(
                read_env("DATA_PLANE_QUOTA_ENFORCEMENT", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            quota_refresh_ms: read_env("DATA_PLANE_QUOTA_REFRESH_MS", "15000")
                .parse()
                .unwrap_or(15000),
            // Track-B quota enforcement (B2): the snapshot source URL. Own var,
            // then the shared `REDIS_URL` — mirrors metering_redis_url exactly.
            // REUSED by spend-cap + suspend (same control-plane Redis).
            quota_redis_url: {
                let url = read_env("DATA_PLANE_QUOTA_REDIS_URL", "");
                if url.trim().is_empty() {
                    read_env("REDIS_URL", "")
                } else {
                    url
                }
            },
            // Track-B spend-cap enforcement: ON only when BOTH the master flag
            // AND the per-honor sub-flag are truthy — EXACTLY like quota_enforcement.
            // BOTH default `false` → byte-parity.
            spend_caps: matches!(
                read_env("METERING_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ) && matches!(
                read_env("DATA_PLANE_SPEND_CAPS", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // Track-B abuse/KYC suspension: ON only when BOTH the master flag AND
            // the per-honor sub-flag are truthy — EXACTLY like quota_enforcement.
            // BOTH default `false` → byte-parity.
            suspend_reader: matches!(
                read_env("METERING_ENABLED", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ) && matches!(
                read_env("DATA_PLANE_SUSPEND_READER", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // B5 per-tenant observability (Pillar 1): the parent log-field flag.
            // Default `false` → byte-parity (the request span is never entered).
            tenant_obs: matches!(
                read_env("DATA_PLANE_TENANT_OBS", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // B5 per-tenant observability (Pillar 3): the optional bounded counter
            // sub-flag. AND-gated with `tenant_obs` so the counter path can NEVER
            // be on without the parent — read once here, never the env per request.
            // BOTH default `false` → `/metrics` byte-identical to today.
            tenant_obs_counter: matches!(
                read_env("DATA_PLANE_TENANT_OBS", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ) && matches!(
                read_env("DATA_PLANE_TENANT_OBS_COUNTER", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
            // S8 read-replica routing: a STANDALONE routing capability (no
            // METERING_ENABLED master gate), so it is a single-flag bool just like
            // share_pools / bypass_enabled. Default `false` → byte-parity (reads
            // stay on the primary, request.mount reaches get_or_create unchanged).
            read_replica: matches!(
                read_env("DATA_PLANE_READ_REPLICA", "false")
                    .to_lowercase()
                    .as_str(),
                "1" | "true" | "on"
            ),
        }
    }
}

impl std::fmt::Debug for ServerConfig {
    /// Redact the two plaintext token fields (`adapter_registry_token`,
    /// `vault_token`) so a stray `{:?}` of the whole config can never leak a
    /// secret. Mirrors the redacting Debug on `ProviderConfig`/`ProviderRegistry`
    /// in the pool crate. A set token shows `"<redacted>"`, an empty one shows
    /// `""` (so "is the provider configured?" stays observable); every other
    /// field prints normally.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServerConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("product_mode", &self.product_mode)
            .field("adapter_registry_url", &self.adapter_registry_url)
            .field("permission_bundle_url", &self.permission_bundle_url)
            .field("permission_bundle_inline", &self.permission_bundle_inline)
            .field("permission_mode", &self.permission_mode)
            .field("max_pools", &self.max_pools)
            .field(
                "planner_federation_enabled",
                &self.planner_federation_enabled,
            )
            .field(
                "adapter_registry_token",
                &redact(&self.adapter_registry_token),
            )
            .field("vault_addr", &self.vault_addr)
            .field("vault_token", &redact(&self.vault_token))
            .field("vault_dsn_prefix", &self.vault_dsn_prefix)
            .field("vault_dsn_field", &self.vault_dsn_field)
            .field("credential_cache_ttl_ms", &self.credential_cache_ttl_ms)
            .field("security_mode", &self.security_mode)
            .field("tls_ca_file", &self.tls_ca_file)
            .field("tenant_control_url", &self.tenant_control_url)
            .field(
                "internal_service_token",
                &redact(&self.internal_service_token),
            )
            .field("bypass_enabled", &self.bypass_enabled)
            .field("metering", &self.metering)
            .field("metering_flush_ms", &self.metering_flush_ms)
            // A Redis URL can embed credentials (redis://user:pass@host) — redact
            // it like the other secret-bearing fields (presence stays observable).
            .field("metering_redis_url", &redact(&self.metering_redis_url))
            .field("quota_enforcement", &self.quota_enforcement)
            .field("quota_refresh_ms", &self.quota_refresh_ms)
            .field("quota_redis_url", &redact(&self.quota_redis_url))
            .field("spend_caps", &self.spend_caps)
            .field("suspend_reader", &self.suspend_reader)
            .field("tenant_obs", &self.tenant_obs)
            .field("tenant_obs_counter", &self.tenant_obs_counter)
            .field("read_replica", &self.read_replica)
            .finish()
    }
}

/// Map a secret to a Debug-safe placeholder: `""` when empty (so config
/// presence stays observable), `"<redacted>"` otherwise. Never echoes the value.
fn redact(secret: &str) -> &'static str {
    if secret.is_empty() {
        ""
    } else {
        "<redacted>"
    }
}

fn read_env(key: &str, default_value: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default_value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // N1 — `{:?}` of ServerConfig must NOT leak a set token value, but MUST
    // still render the field (redacted) so the struct stays diagnosable.
    #[test]
    fn debug_redacts_tokens() {
        let mut cfg = ServerConfig::from_env();
        cfg.vault_token = "s.SUPERSECRET-vault-token".to_string();
        cfg.adapter_registry_token = "svc-SECRET-registry-token".to_string();
        cfg.vault_dsn_prefix = "data-plane/dsn".to_string(); // pin a non-secret field
        let dbg = format!("{cfg:?}");
        assert!(
            !dbg.contains("SUPERSECRET-vault-token"),
            "vault_token value leaked into Debug: {dbg}"
        );
        assert!(
            !dbg.contains("SECRET-registry-token"),
            "adapter_registry_token value leaked into Debug: {dbg}"
        );
        assert!(
            dbg.contains("<redacted>"),
            "redacted placeholder present: {dbg}"
        );
        // A non-secret field still renders normally.
        assert!(
            dbg.contains("data-plane/dsn"),
            "non-secret field still printed: {dbg}"
        );
    }

    // An empty token renders as "" (so "is it configured?" stays observable),
    // never the redaction placeholder.
    #[test]
    fn debug_empty_token_not_redacted() {
        let mut cfg = ServerConfig::from_env();
        cfg.vault_token = String::new();
        cfg.adapter_registry_token = String::new();
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("vault_token: \"\""),
            "empty vault_token shows empty: {dbg}"
        );
    }

    // S8 — DATA_PLANE_READ_REPLICA is a standalone routing-capability flag: unset
    // ⇒ false (byte-parity, reads stay on the primary); "1" ⇒ true.
    #[test]
    fn read_replica_flag_defaults_off_and_parses_on() {
        std::env::remove_var("DATA_PLANE_READ_REPLICA");
        assert!(
            !ServerConfig::from_env().read_replica,
            "unset DATA_PLANE_READ_REPLICA must default OFF (byte-parity)"
        );
        std::env::set_var("DATA_PLANE_READ_REPLICA", "1");
        assert!(
            ServerConfig::from_env().read_replica,
            "DATA_PLANE_READ_REPLICA=1 must enable read-replica routing"
        );
        std::env::remove_var("DATA_PLANE_READ_REPLICA");
    }
}
