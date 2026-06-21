/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   credential.rs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:31:28 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:31:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Pluggable credential providers for the Rust data plane — gap G8.
//!
//! Background: the resolver ([`crate::resolver::EnvMountResolver`]) turns a
//! [`DatabaseMount`] into a concrete DSN. Until G8 the only sources were the
//! caller-supplied `inline_dsn` (the TS query-router proxy's fast path) and a
//! static `DATA_PLANE_MOUNTS` env map. G8 adds *pluggable* providers so a mount
//! can name a runtime credential source via [`DatabaseMount::credential_ref`]'s
//! `provider` field, without baking any address or secret into the binary.
//!
//! Design (matches the standing rules):
//!   * Single dispatch point — [`ProviderRegistry`] is an O(1) `HashMap` keyed
//!     by `provider` name. No scattered per-provider branching in the resolver.
//!   * No hardcoding — every provider is built ONLY from config; an absent
//!     config means the provider is simply not registered (DISABLED), so the
//!     resolver falls through to its existing behaviour. Tokens are env-only and
//!     never defaulted nor logged. The DSN never appears in an error or a log.
//!   * Resource thrift — each provider owns ONE reusable `reqwest::Client`.
//!
//! Parity: providers are disabled by default. The resolver only consults them
//! when `inline_dsn` is absent, so the TS-proxy 201 fast path is byte-unchanged.

use async_trait::async_trait;
use data_plane_core::{DataPlaneError, DataPlaneResult, DatabaseMount};
use reqwest::Client;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// Mirror of the HTTP adapter's outbound timeout (see `http.rs` `REQUEST_TIMEOUT`)
/// so a credential fetch can never hang a request unbounded.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// A pluggable source of a connection string (DSN) for a [`DatabaseMount`].
///
/// Returns the DSN as a `String` (D1 — matches
/// [`crate::resolver::MountResolver::resolve_dsn`]). Implementations MUST NEVER
/// place the DSN (or any secret) into an error or a log line — on any failure
/// they return [`DataPlaneError::CredentialProviderFailed`] carrying only the
/// provider name + mount id.
#[async_trait]
pub trait CredentialProvider: Send + Sync {
    /// The `credential_ref.provider` value this provider answers to. The
    /// registry keys its dispatch map on this string.
    fn name(&self) -> &str;

    /// Resolve `mount` to a DSN, or fail closed.
    async fn resolve_dsn(&self, mount: &DatabaseMount) -> DataPlaneResult<String>;
}

/// Plain, server-owned credential-provider configuration. The server populates
/// this from `ServerConfig` (the single documented home for the env contract)
/// and hands it to [`ProviderRegistry::from_config`], so there is exactly ONE
/// env reader. Every field empty/zero = every provider DISABLED (parity).
#[derive(Clone, Default)]
pub struct ProviderConfig {
    /// adapter-registry origin (reuses the existing `adapter_registry_url`).
    pub adapter_registry_url: String,
    /// adapter-registry service token; empty → provider not registered.
    pub adapter_registry_token: String,
    /// Vault origin; empty → provider not registered.
    pub vault_addr: String,
    /// Vault token (never logged); empty → provider not registered.
    pub vault_token: String,
    /// Vault KV v2 DSN path prefix.
    pub vault_dsn_prefix: String,
    /// Vault secret field holding the DSN.
    pub vault_dsn_field: String,
}

impl std::fmt::Debug for ProviderConfig {
    /// Redact the two plaintext token fields so a stray `{:?}` (a log line, a
    /// panic message, a `#[derive(Debug)]` on an enclosing struct) can never
    /// leak `adapter_registry_token` / `vault_token`. Mirrors the redacting
    /// Debug on [`ProviderRegistry`]. Non-secret fields print normally; a set
    /// token shows `"<redacted>"`, an empty one shows `""` (so "is it
    /// configured?" stays observable without exposing the value).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderConfig")
            .field("adapter_registry_url", &self.adapter_registry_url)
            .field(
                "adapter_registry_token",
                &redact(&self.adapter_registry_token),
            )
            .field("vault_addr", &self.vault_addr)
            .field("vault_token", &redact(&self.vault_token))
            .field("vault_dsn_prefix", &self.vault_dsn_prefix)
            .field("vault_dsn_field", &self.vault_dsn_field)
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

/// O(1) name → provider dispatch table. The single point where a
/// `credential_ref.provider` selects a provider — there is no provider
/// branching anywhere else.
#[derive(Clone, Default)]
pub struct ProviderRegistry {
    by_name: HashMap<String, Arc<dyn CredentialProvider>>,
}

impl std::fmt::Debug for ProviderRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Only the registered provider NAMES — never any token/address state.
        let mut names: Vec<&str> = self.by_name.keys().map(String::as_str).collect();
        names.sort_unstable();
        f.debug_struct("ProviderRegistry")
            .field("providers", &names)
            .finish()
    }
}

impl ProviderRegistry {
    /// Build a registry from a list of providers, keyed by `name()`. A later
    /// entry with a duplicate name replaces an earlier one.
    #[must_use]
    pub fn with(providers: Vec<Arc<dyn CredentialProvider>>) -> Self {
        let by_name = providers
            .into_iter()
            .map(|p| (p.name().to_string(), p))
            .collect();
        Self { by_name }
    }

    /// Build the registry from explicit [`ProviderConfig`], registering a
    /// provider ONLY when its required fields are present. With empty config
    /// nothing is registered and the registry is empty — providers stay disabled
    /// (parity). This is the single construction path; [`from_env`] just reads
    /// the env into a [`ProviderConfig`] first.
    ///
    /// [`from_env`]: ProviderRegistry::from_env
    #[must_use]
    pub fn from_config(cfg: &ProviderConfig) -> Self {
        let mut providers: Vec<Arc<dyn CredentialProvider>> = Vec::new();

        // adapter-registry: registered only when a service token is configured.
        if !cfg.adapter_registry_token.trim().is_empty() {
            let base_url = if cfg.adapter_registry_url.trim().is_empty() {
                "http://adapter-registry-go:3021".to_string()
            } else {
                cfg.adapter_registry_url.clone()
            };
            if let Ok(p) =
                AdapterRegistryProvider::new(base_url, cfg.adapter_registry_token.clone())
            {
                providers.push(Arc::new(p));
            }
        }

        // vault: registered only when BOTH addr and token are configured.
        if !cfg.vault_addr.trim().is_empty() && !cfg.vault_token.trim().is_empty() {
            let prefix = if cfg.vault_dsn_prefix.trim().is_empty() {
                "data-plane/dsn".to_string()
            } else {
                cfg.vault_dsn_prefix.clone()
            };
            let field = if cfg.vault_dsn_field.trim().is_empty() {
                "dsn".to_string()
            } else {
                cfg.vault_dsn_field.clone()
            };
            if let Ok(p) = VaultProvider::new(
                cfg.vault_addr.clone(),
                cfg.vault_token.clone(),
                prefix,
                field,
            ) {
                providers.push(Arc::new(p));
            }
        }

        Self::with(providers)
    }

    /// Build the registry from environment (reads into a [`ProviderConfig`] then
    /// delegates to [`from_config`]). With no provider env set the registry is
    /// empty — providers stay disabled (parity).
    ///
    /// [`from_config`]: ProviderRegistry::from_config
    #[must_use]
    pub fn from_env() -> Self {
        let cfg = ProviderConfig {
            adapter_registry_url: env_nonempty("DATA_PLANE_ADAPTER_REGISTRY_URL")
                .unwrap_or_default(),
            adapter_registry_token: env_nonempty("DATA_PLANE_ADAPTER_REGISTRY_TOKEN")
                .unwrap_or_default(),
            vault_addr: env_nonempty("DATA_PLANE_VAULT_ADDR").unwrap_or_default(),
            vault_token: env_nonempty("DATA_PLANE_VAULT_TOKEN").unwrap_or_default(),
            vault_dsn_prefix: env_nonempty("DATA_PLANE_VAULT_DSN_PREFIX").unwrap_or_default(),
            vault_dsn_field: env_nonempty("DATA_PLANE_VAULT_DSN_FIELD").unwrap_or_default(),
        };
        Self::from_config(&cfg)
    }

    /// Look up the provider for a `credential_ref.provider` name, if registered.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<&Arc<dyn CredentialProvider>> {
        self.by_name.get(name)
    }
}

/// Read an env var, returning `Some(value)` only when set AND non-empty (after
/// trim). Used so a config var present-but-blank keeps the provider disabled.
fn env_nonempty(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Reject any caller-controlled path segment that could pivot the request off
/// its intended secret/resource. A `credential_ref.reference` (and `version`)
/// arrives deserialized straight from the request body and is interpolated into
/// an upstream URL path; without this gate a caller could set
/// `reference = "../other-tenant/dsn"` (or embed a `/`) to read a different
/// secret (cross-secret/cross-tenant credential confusion). We REJECT rather
/// than percent-encode so the failure is explicit and fail-closed: a segment
/// must be non-empty and contain no `/`, `\`, `..`, control char, or whitespace.
/// `provider`/`mount_id` are the caller's only error breadcrumb — the rejected
/// value is never echoed (no secret-adjacent input in errors/logs).
fn validate_ref_segment(s: &str) -> Result<(), ()> {
    if s.is_empty()
        || s.contains('/')
        || s.contains('\\')
        || s.contains("..")
        || s.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return Err(());
    }
    Ok(())
}

/// Precondition for building a Vault KV path from a credential_ref. The
/// `reference` is mandatory and must be a single safe path segment. The
/// `version` is OPTIONAL — an empty string means "use the latest secret version"
/// (version is not required in the credential_ref DTO), so it must pass; a
/// NON-empty version is validated as a safe segment (fail-closed on a hostile
/// pinned value). Extracted as a pure fn so the empty-version-allowed contract is
/// unit-pinned without standing up a live Vault. `version` is expected trimmed.
fn credential_path_ok(reference: &str, version: &str) -> bool {
    validate_ref_segment(reference).is_ok()
        && (version.is_empty() || validate_ref_segment(version).is_ok())
}

/// Build the shared outbound client. One per provider (object-pool); reused for
/// every resolve so we never spin a fresh TCP/TLS stack per request.
fn build_client() -> DataPlaneResult<Client> {
    Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .user_agent("mini-baas-data-plane-router/0.1")
        .build()
        .map_err(|e| DataPlaneError::Backend {
            message: format!("credential provider client init failed: {e}"),
        })
}

// ---------------------------------------------------------------------------
// AdapterRegistryProvider (D4) — name() == "adapter-registry"
// ---------------------------------------------------------------------------

/// Resolves a DSN from the Go control-plane `adapter-registry` service via its
/// internal `GET /databases/{id}/connect` endpoint. Scoped per-tenant by the
/// `X-Baas-Tenant-Id` header (D4) and authenticated with the service token.
pub struct AdapterRegistryProvider {
    client: Client,
    base_url: String,
    service_token: String,
}

/// The relevant slice of the Go `ConnectionResult`
/// (control-plane/internal/adapterregistry/models.go) — we only read
/// `connection_string`; other fields are ignored.
#[derive(Deserialize)]
struct ConnectionResult {
    connection_string: String,
}

impl AdapterRegistryProvider {
    /// `base_url` is the adapter-registry origin (no trailing path);
    /// `service_token` authenticates the internal `/connect` route.
    pub fn new(base_url: String, service_token: String) -> DataPlaneResult<Self> {
        Ok(Self {
            client: build_client()?,
            base_url: base_url.trim_end_matches('/').to_string(),
            service_token,
        })
    }

    fn fail(mount_id: &str) -> DataPlaneError {
        DataPlaneError::CredentialProviderFailed {
            provider: "adapter-registry".to_string(),
            mount_id: mount_id.to_string(),
        }
    }
}

#[async_trait]
impl CredentialProvider for AdapterRegistryProvider {
    fn name(&self) -> &str {
        "adapter-registry"
    }

    async fn resolve_dsn(&self, mount: &DatabaseMount) -> DataPlaneResult<String> {
        // Defense in depth: `mount.id` is interpolated into the path. The Go
        // /connect handler already scopes by service token + tenant header, so
        // this is server-defended, but the same fail-closed gate is cheap and
        // stops a `/`-bearing or `..` id from ever reshaping the upstream path.
        if validate_ref_segment(&mount.id).is_err() {
            return Err(Self::fail(&mount.id));
        }
        let path = format!("/databases/{}/connect", mount.id);
        let url = format!("{}{path}", self.base_url);
        let req = self
            .client
            .get(&url)
            .header("X-Baas-Tenant-Id", &mount.tenant_id);
        let req = if crate::service_auth::hmac_mode() {
            req.header(
                "X-Service-Auth",
                crate::service_auth::compute_service_auth(&self.service_token, "GET", &path, b""),
            )
        } else {
            req.header("X-Service-Token", &self.service_token)
        };
        let resp = req.send().await.map_err(|_| Self::fail(&mount.id))?;
        if !resp.status().is_success() {
            return Err(Self::fail(&mount.id));
        }
        let parsed: ConnectionResult = resp.json().await.map_err(|_| Self::fail(&mount.id))?;
        if parsed.connection_string.trim().is_empty() {
            return Err(Self::fail(&mount.id));
        }
        Ok(parsed.connection_string)
    }
}

// ---------------------------------------------------------------------------
// VaultProvider (D3) — name() == "vault", KV v2
// ---------------------------------------------------------------------------

/// Resolves a DSN from HashiCorp Vault KV v2:
/// `GET {addr}/v1/secret/data/{prefix}/{reference}?version={n}` with the
/// `X-Vault-Token` header, reading `.data.data.{field}` from the response.
///
/// The token is supplied via env only (`DATA_PLANE_VAULT_TOKEN`); it is never
/// defaulted and never logged. The DSN value read from the secret is likewise
/// never logged.
pub struct VaultProvider {
    client: Client,
    addr: String,
    token: String,
    prefix: String,
    field: String,
}

/// The KV v2 read response shape — outer `.data` wraps an inner `.data` map of
/// the secret's key/value pairs.
#[derive(Deserialize)]
struct VaultRead {
    data: VaultDataEnvelope,
}

#[derive(Deserialize)]
struct VaultDataEnvelope {
    data: HashMap<String, serde_json::Value>,
}

impl VaultProvider {
    pub fn new(
        addr: String,
        token: String,
        prefix: String,
        field: String,
    ) -> DataPlaneResult<Self> {
        Ok(Self {
            client: build_client()?,
            addr: addr.trim_end_matches('/').to_string(),
            token,
            // Normalise the prefix so we never emit a double slash.
            prefix: prefix.trim_matches('/').to_string(),
            field,
        })
    }

    fn fail(mount_id: &str) -> DataPlaneError {
        DataPlaneError::CredentialProviderFailed {
            provider: "vault".to_string(),
            mount_id: mount_id.to_string(),
        }
    }
}

#[async_trait]
impl CredentialProvider for VaultProvider {
    fn name(&self) -> &str {
        "vault"
    }

    async fn resolve_dsn(&self, mount: &DatabaseMount) -> DataPlaneResult<String> {
        let reference = &mount.credential_ref.reference;
        let version = mount.credential_ref.version.trim();
        // S1 fail-closed gate: `reference` (and a PINNED `version`) come straight
        // from the request body and are interpolated into the Vault KV path.
        // Validate BEFORE building the URL so a `../other-tenant/dsn` reference can
        // never pivot to a different secret. See `credential_path_ok`.
        if !credential_path_ok(reference, version) {
            return Err(Self::fail(&mount.id));
        }
        let mut url = format!("{}/v1/secret/data/{}/{}", self.addr, self.prefix, reference);
        // `credential_ref.version` is a free-form String. If it parses as a
        // positive integer we request that exact KV v2 version; otherwise we
        // omit `?version` and Vault returns the latest version. (Our pool_key
        // already includes the raw version string, so rotation still keys a
        // distinct pool regardless of whether Vault pinned a numeric version.)
        // The validated version is appended as a pure integer, so no
        // caller-controlled raw text reaches the query string either.
        if let Ok(v) = version.parse::<u64>() {
            url.push_str(&format!("?version={v}"));
        }
        let resp = self
            .client
            .get(&url)
            .header("X-Vault-Token", &self.token)
            .send()
            .await
            .map_err(|_| Self::fail(&mount.id))?;
        if !resp.status().is_success() {
            return Err(Self::fail(&mount.id));
        }
        let parsed: VaultRead = resp.json().await.map_err(|_| Self::fail(&mount.id))?;
        let dsn = parsed
            .data
            .data
            .get(&self.field)
            .and_then(serde_json::Value::as_str)
            .map(str::to_string)
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| Self::fail(&mount.id))?;
        Ok(dsn)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use data_plane_core::{CredentialRef, PoolPolicy};

    fn mount(provider: &str) -> DatabaseMount {
        DatabaseMount {
            id: "db1".into(),
            tenant_id: "t-1".into(),
            project_id: None,
            engine: "postgresql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: provider.into(),
                reference: "r".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: None,
            isolation: None,
            replica_inline_dsn: None,
            read_replica_route: false,
        }
    }

    /// A no-network fake provider answering to a configurable name, used to
    /// prove registry dispatch + error pass-through without any HTTP.
    struct FakeProvider {
        name: String,
        result: fn(&DatabaseMount) -> DataPlaneResult<String>,
    }

    #[async_trait]
    impl CredentialProvider for FakeProvider {
        fn name(&self) -> &str {
            &self.name
        }
        async fn resolve_dsn(&self, m: &DatabaseMount) -> DataPlaneResult<String> {
            (self.result)(m)
        }
    }

    fn ok_dsn(_m: &DatabaseMount) -> DataPlaneResult<String> {
        Ok("postgres://fake".into())
    }

    // t1 — provider selection is keyed purely by credential_ref.provider name.
    #[test]
    fn t1_provider_selection_by_ref_provider() {
        let reg = ProviderRegistry::with(vec![
            Arc::new(FakeProvider {
                name: "adapter-registry".into(),
                result: ok_dsn,
            }),
            Arc::new(FakeProvider {
                name: "vault".into(),
                result: ok_dsn,
            }),
        ]);
        assert_eq!(
            reg.get("adapter-registry").map(|p| p.name()),
            Some("adapter-registry")
        );
        assert_eq!(reg.get("vault").map(|p| p.name()), Some("vault"));
        assert!(reg.get("nope").is_none(), "unknown provider name -> None");
    }

    // t3 — a provider error surfaces unchanged as CredentialProviderFailed.
    #[tokio::test]
    async fn t3_provider_error_is_provider_failed() {
        fn boom(m: &DatabaseMount) -> DataPlaneResult<String> {
            Err(DataPlaneError::CredentialProviderFailed {
                provider: "vault".into(),
                mount_id: m.id.clone(),
            })
        }
        let reg = ProviderRegistry::with(vec![Arc::new(FakeProvider {
            name: "vault".into(),
            result: boom,
        })]);
        let m = mount("vault");
        let p = reg.get("vault").expect("registered");
        let err = p.resolve_dsn(&m).await.unwrap_err();
        match err {
            DataPlaneError::CredentialProviderFailed { provider, mount_id } => {
                assert_eq!(provider, "vault");
                assert_eq!(mount_id, "db1");
            }
            other => panic!("expected CredentialProviderFailed, got {other:?}"),
        }
    }

    // from_env stays disabled (empty registry) when no provider config is set.
    #[test]
    fn from_env_without_config_is_empty() {
        // Defensive: clear any provider env that might leak from the host.
        for k in [
            "DATA_PLANE_ADAPTER_REGISTRY_TOKEN",
            "DATA_PLANE_VAULT_ADDR",
            "DATA_PLANE_VAULT_TOKEN",
        ] {
            std::env::remove_var(k);
        }
        let reg = ProviderRegistry::from_env();
        assert!(reg.get("adapter-registry").is_none());
        assert!(reg.get("vault").is_none());
    }

    // S1 — a reference carrying a path-traversal/separator must FAIL CLOSED at
    // the VaultProvider before any URL is built (no cross-secret pivot). We
    // assert the validator rejects the hostile segments AND accepts a clean one,
    // proving the gate is what stands between the caller and the Vault path.
    #[test]
    fn s1_validate_ref_segment_rejects_traversal_and_separators() {
        for bad in [
            "",                    // empty
            "../other-tenant/dsn", // traversal
            "a/b",                 // forward slash
            "a\\b",                // backslash
            "..",                  // bare parent
            "a b",                 // whitespace
            "a\tb",                // tab
            "a\nb",                // newline / control
            "a\u{0}b",             // NUL
        ] {
            assert!(
                validate_ref_segment(bad).is_err(),
                "validator must reject hostile segment {bad:?}"
            );
        }
        for ok in ["dsn", "tenant_42-dsn", "abc123", "v.2"] {
            assert!(
                validate_ref_segment(ok).is_ok(),
                "validator must accept clean segment {ok:?}"
            );
        }
    }

    // S2 — the credential-path precondition: an EMPTY version is the common
    // "use latest" case and MUST pass (regression for the m121 502 where an
    // unpinned credential_ref could never resolve); a pinned version is still
    // validated, and the reference is always validated.
    #[test]
    fn s2_credential_path_allows_empty_version_rejects_hostile_inputs() {
        // clean reference + unpinned version (the common case) is allowed
        assert!(credential_path_ok("m121-tenant-max-dsn", ""));
        // clean reference + clean pinned version is allowed
        assert!(credential_path_ok("dsn", "5"));
        // hostile reference is rejected regardless of version
        assert!(!credential_path_ok("../other-tenant/dsn", ""));
        assert!(!credential_path_ok("a/b", ""));
        // empty reference is rejected (reference is mandatory)
        assert!(!credential_path_ok("", ""));
        // a NON-empty malformed version is rejected even with a clean reference
        assert!(!credential_path_ok("dsn", "../9"));
        assert!(!credential_path_ok("dsn", "a/b"));
    }

    // S1 — end-to-end at the provider: a "../"-bearing reference yields
    // CredentialProviderFailed (NOT a successful fetch / silent latest-read).
    // No network is reached because validation runs before the URL is built, so
    // a bogus addr proves the rejection is the validator, not a transport error
    // that happens to look the same.
    #[tokio::test]
    async fn s1_vault_rejects_traversal_reference_before_fetch() {
        let p = VaultProvider::new(
            "http://127.0.0.1:1".into(), // unroutable; must never be dialed
            "t".into(),
            "data-plane/dsn".into(),
            "dsn".into(),
        )
        .expect("provider");
        let mut m = mount("vault");
        m.credential_ref.reference = "../other-tenant/dsn".into();
        let err = p.resolve_dsn(&m).await.unwrap_err();
        match err {
            DataPlaneError::CredentialProviderFailed { provider, mount_id } => {
                assert_eq!(provider, "vault");
                assert_eq!(mount_id, "db1");
            }
            other => panic!("expected CredentialProviderFailed (validation), got {other:?}"),
        }
        // A bare "/" in the reference is rejected the same way.
        m.credential_ref.reference = "a/b".into();
        assert!(matches!(
            p.resolve_dsn(&m).await.unwrap_err(),
            DataPlaneError::CredentialProviderFailed { .. }
        ));
        // A malformed (non-numeric, separator-bearing) version is also rejected.
        m.credential_ref.reference = "dsn".into();
        m.credential_ref.version = "../9".into();
        assert!(matches!(
            p.resolve_dsn(&m).await.unwrap_err(),
            DataPlaneError::CredentialProviderFailed { .. }
        ));
    }

    // N1 — `{:?}` of ProviderConfig must NOT leak a set token, but MUST still
    // render the (redacted) field so the struct stays diagnosable.
    #[test]
    fn n1_provider_config_debug_redacts_tokens() {
        let cfg = ProviderConfig {
            adapter_registry_url: "http://adapter-registry-go:3021".into(),
            adapter_registry_token: "svc-SECRET-registry-token".into(),
            vault_addr: "http://vault:8200".into(),
            vault_token: "s.SUPERSECRET-vault-token".into(),
            vault_dsn_prefix: "data-plane/dsn".into(),
            vault_dsn_field: "dsn".into(),
        };
        let dbg = format!("{cfg:?}");
        assert!(
            !dbg.contains("SUPERSECRET-vault-token"),
            "vault_token leaked: {dbg}"
        );
        assert!(
            !dbg.contains("SECRET-registry-token"),
            "registry token leaked: {dbg}"
        );
        assert!(
            dbg.contains("<redacted>"),
            "redaction placeholder present: {dbg}"
        );
        // Non-secret fields still render.
        assert!(
            dbg.contains("data-plane/dsn"),
            "non-secret field still printed: {dbg}"
        );
        // An empty token renders as "" (config presence stays observable).
        let empty = ProviderConfig::default();
        let dbg_empty = format!("{empty:?}");
        assert!(
            dbg_empty.contains("vault_token: \"\""),
            "empty token shows empty: {dbg_empty}"
        );
    }

    // t11 — live Vault read, gated on real Vault env. #[ignore] by default.
    #[tokio::test]
    #[ignore = "requires a live Vault: set DATA_PLANE_VAULT_ADDR + DATA_PLANE_VAULT_TOKEN"]
    async fn t11_vault_live_read() {
        let addr = std::env::var("DATA_PLANE_VAULT_ADDR").expect("DATA_PLANE_VAULT_ADDR");
        let token = std::env::var("DATA_PLANE_VAULT_TOKEN").expect("DATA_PLANE_VAULT_TOKEN");
        let prefix = std::env::var("DATA_PLANE_VAULT_DSN_PREFIX")
            .unwrap_or_else(|_| "data-plane/dsn".into());
        let field = std::env::var("DATA_PLANE_VAULT_DSN_FIELD").unwrap_or_else(|_| "dsn".into());
        let p = VaultProvider::new(addr, token, prefix, field).expect("provider");
        let dsn = p.resolve_dsn(&mount("vault")).await.expect("vault read");
        assert!(!dsn.is_empty());
    }
}
