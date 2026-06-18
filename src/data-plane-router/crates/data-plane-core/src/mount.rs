use crate::identity::{IdentitySource, RequestIdentity};
use crate::isolation::{safe_schema, Isolation, ScopeDirective};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PoolPolicy {
    pub min: u32,
    pub max: u32,
    pub idle_ttl_ms: u64,
    pub max_lifetime_ms: u64,
}

impl Default for PoolPolicy {
    fn default() -> Self {
        Self {
            min: 0,
            max: 10,
            idle_ttl_ms: 30_000,
            max_lifetime_ms: 1_800_000,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CredentialRef {
    pub provider: String,
    pub reference: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DatabaseMount {
    pub id: String,
    pub tenant_id: String,
    pub project_id: Option<String>,
    pub engine: String,
    pub name: String,
    pub credential_ref: CredentialRef,
    #[serde(default)]
    pub pool_policy: PoolPolicy,
    pub capability_overrides: Option<Value>,
    /// Optional inline DSN supplied by the caller (e.g. the TS query-router
    /// proxy after it already fetched `connection_string` from the
    /// adapter-registry). When present the resolver uses this directly and
    /// the static `DATA_PLANE_MOUNTS` env-backed map becomes a fallback for
    /// purely server-side flows.
    #[serde(default)]
    pub inline_dsn: Option<String>,
    /// Tenant isolation strategy for this mount (wiki/02-layer-edition-model.md §5):
    ///   * `shared_rls` / absent — one schema, RLS + owner_id (the default);
    ///   * `schema_per_tenant`   — pin `search_path` to `tenant_<id>`;
    ///   * `db_per_tenant`       — a distinct DSN; no execution change.
    #[serde(default)]
    pub isolation: Option<String>,
    /// S8 read-replica: optional read-replica DSN for this mount. When set AND
    /// DATA_PLANE_READ_REPLICA is ON, pure reads (List/Get/Aggregate) are served
    /// from the replica's own pool; writes/tx/Batch stay on the primary. Absent
    /// (the default) ⇒ reads use the primary = byte-parity.
    #[serde(default)]
    pub replica_inline_dsn: Option<String>,
    /// Internal routing marker — NEVER serialized. Set ONLY on the read-replica
    /// VARIANT of a mount (see read_replica_variant) so its pool keys distinctly
    /// from the primary. Always false on a deserialized request ⇒ wire parity.
    #[serde(skip)]
    pub read_replica_route: bool,
}

impl DatabaseMount {
    #[must_use]
    pub fn pool_key(&self) -> String {
        format!(
            "{}/{}/{}/{}/{}",
            self.tenant_id,
            self.project_id.as_deref().unwrap_or("default"),
            self.id,
            self.engine,
            self.credential_ref.version,
        )
    }

    /// Derive the read-replica VARIANT of this mount: inline_dsn ← the replica DSN,
    /// route marker set so the pool keys distinctly. Returns None when no replica
    /// DSN is configured (caller then uses the primary mount unchanged = parity).
    #[must_use]
    pub fn read_replica_variant(self) -> Option<DatabaseMount> {
        let replica = self
            .replica_inline_dsn
            .as_deref()
            .filter(|d| !d.trim().is_empty())?
            .to_string();
        Some(DatabaseMount {
            inline_dsn: Some(replica),
            read_replica_route: true,
            ..self
        })
    }

    /// B4-pools: the pool key to actually use, honoring the registry's
    /// pool-sharing policy. When `share_shared_rls` is on AND this mount is
    /// `shared_rls`, the key is the connection TARGET (inline DSN hash, else the
    /// credential reference) — NOT the tenant — so every tenant pointing at the
    /// same physical database shares ONE pool. This is correct only for
    /// shared_rls: its tenant scoping (`app.current_tenant_id`) is re-applied
    /// per checkout from the request identity, so the pool holds no tenant
    /// state. `schema_per_tenant` pins `search_path` into the pool and
    /// `db_per_tenant` / `tenant_owned` use distinct DSNs, so all three keep the
    /// per-tenant [`pool_key`]. With sharing off, this is byte-identical to
    /// `pool_key()`.
    ///
    /// The cred `version` stays in the shared key so a rotation forks a fresh
    /// pool (parity with `pool_key`'s rotation behavior).
    #[must_use]
    pub fn effective_pool_key(&self, share_shared_rls: bool) -> String {
        let base = if share_shared_rls && matches!(self.isolation(), Isolation::SharedRls) {
            let target = match self.inline_dsn.as_deref() {
                Some(dsn) if !dsn.is_empty() => format!("dsn:{:016x}", stable_hash(dsn)),
                _ => format!(
                    "cred:{}/{}/{}",
                    self.credential_ref.provider,
                    self.credential_ref.reference,
                    self.credential_ref.version
                ),
            };
            format!("shared/{}/{}", self.engine, target)
        } else {
            self.pool_key()
        };
        // S8 read-replica: the replica VARIANT (read_replica_route set) keys to a
        // distinct `/ro` pool so it NEVER collides with the primary pool — in BOTH
        // the share and non-share branches. On a deserialized request the marker
        // is always false (`#[serde(skip)]`), so the key is byte-parity with today.
        if self.read_replica_route {
            format!("{base}/ro")
        } else {
            base
        }
    }

    /// The parsed [`Isolation`] strategy for this mount. The wire `isolation`
    /// string is parsed exactly once here; every consumer matches the enum.
    /// Absent / empty / unknown degrades to [`Isolation::SharedRls`] (parity).
    #[must_use]
    pub fn isolation(&self) -> Isolation {
        Isolation::from_mount(self.isolation.as_deref())
    }

    /// The per-tenant schema name for a `schema_per_tenant` mount, or `None`
    /// for any other isolation strategy (shared / db-per-tenant need no
    /// `search_path` change).
    ///
    /// Thin delegator to [`crate::isolation::safe_schema`] — the single source
    /// of truth for the `tenant_` prefix + `[a-z0-9_]` sanitization shared by
    /// the PG `search_path` lowering and provisioning DDL. The result is a
    /// fixed, safe identifier callers may interpolate into `SET search_path`
    /// (which cannot bind parameters) without injection risk. `None` when the
    /// strategy isn't `schema_per_tenant` or the id sanitizes to empty.
    ///
    /// ```
    /// use data_plane_core::{CredentialRef, DatabaseMount, PoolPolicy};
    ///
    /// let mut mount = DatabaseMount {
    ///     id: "db1".into(),
    ///     tenant_id: "acme".into(),
    ///     project_id: None,
    ///     engine: "postgresql".into(),
    ///     name: "n".into(),
    ///     credential_ref: CredentialRef {
    ///         provider: "adapter-registry".into(),
    ///         reference: "r".into(),
    ///         version: "1".into(),
    ///     },
    ///     pool_policy: PoolPolicy::default(),
    ///     capability_overrides: None,
    ///     inline_dsn: None,
    ///     isolation: Some("schema_per_tenant".into()),
    ///     replica_inline_dsn: None,
    ///     read_replica_route: false,
    /// };
    ///
    /// // schema_per_tenant → a sanitized `tenant_<id>_<hash>` schema.
    /// assert!(mount.tenant_schema().unwrap().starts_with("tenant_acme_"));
    ///
    /// // The shared default needs no search_path change → None.
    /// mount.isolation = Some("shared_rls".into());
    /// assert_eq!(mount.tenant_schema(), None);
    /// ```
    #[must_use]
    pub fn tenant_schema(&self) -> Option<String> {
        match self.isolation() {
            Isolation::SchemaPerTenant => safe_schema(&self.tenant_id),
            Isolation::SharedRls | Isolation::DbPerTenant | Isolation::TenantOwned => None,
        }
    }

    /// The per-tenant namespace for a `schema_per_tenant` mount (the MySQL/Mongo
    /// database, the Redis/Dynamo key segment), or `None` for any other strategy
    /// (→ the engine's DSN-default / historical shape, parity). The isolation
    /// policy is defined once in [`Isolation::scope`]; the namespace is per-mount,
    /// so the mount's own `tenant_id` is the scoping identity. Single source of
    /// truth — was reimplemented byte-for-byte in the mysql/mongo/redis/dynamodb
    /// adapters.
    #[must_use]
    pub fn resolve_namespace(&self) -> Option<String> {
        let identity = RequestIdentity {
            tenant_id: self.tenant_id.clone(),
            project_id: self.project_id.clone(),
            app_id: None,
            user_id: None,
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::ServiceToken,
        };
        match self.isolation().scope(self, &identity) {
            ScopeDirective::UseNamespace { namespace } => Some(namespace),
            ScopeDirective::None | ScopeDirective::SetSearchPath { .. } => None,
        }
    }
}

/// A stable, non-reversible digest of a DSN for use inside a pool key — so two
/// mounts with the same inline DSN collapse to the same pool WITHOUT the DSN (a
/// secret) appearing in the key, logs, or `/metrics`. `DefaultHasher` is
/// fixed-seed (deterministic within and across process runs), which is all a
/// pool key needs; it is NOT a cryptographic guarantee, but the input is never
/// recovered from the digest and the digest is never security-load-bearing.
#[must_use]
fn stable_hash(s: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mount(tenant: &str, isolation: Option<&str>) -> DatabaseMount {
        DatabaseMount {
            id: "db1".into(),
            tenant_id: tenant.into(),
            project_id: None,
            engine: "postgresql".into(),
            name: "n".into(),
            credential_ref: CredentialRef {
                provider: "adapter-registry".into(),
                reference: "r".into(),
                version: "1".into(),
            },
            pool_policy: PoolPolicy::default(),
            capability_overrides: None,
            inline_dsn: None,
            isolation: isolation.map(str::to_string),
            replica_inline_dsn: None,
            read_replica_route: false,
        }
    }

    #[test]
    fn shared_and_absent_have_no_schema() {
        assert_eq!(mount("acme", None).tenant_schema(), None);
        assert_eq!(mount("acme", Some("shared_rls")).tenant_schema(), None);
        assert_eq!(mount("acme", Some("db_per_tenant")).tenant_schema(), None);
    }

    #[test]
    fn effective_pool_key_off_is_byte_identical_to_pool_key() {
        for iso in [
            None,
            Some("shared_rls"),
            Some("schema_per_tenant"),
            Some("db_per_tenant"),
        ] {
            let m = mount("acme", iso);
            assert_eq!(m.effective_pool_key(false), m.pool_key());
        }
    }

    #[test]
    fn shared_rls_tenants_on_same_credential_collapse_to_one_pool() {
        // Same engine + same credential_ref, different tenants → SAME shared key.
        let a = mount("tenant-a", Some("shared_rls"));
        let b = mount("tenant-b", Some("shared_rls"));
        assert_ne!(a.pool_key(), b.pool_key(), "per-tenant keys must differ");
        assert_eq!(
            a.effective_pool_key(true),
            b.effective_pool_key(true),
            "shared_rls on one DB must share a pool"
        );
        assert!(!a.effective_pool_key(true).contains("tenant-a"));
    }

    #[test]
    fn shared_rls_inline_dsn_collapses_by_target_not_tenant() {
        let mut a = mount("tenant-a", Some("shared_rls"));
        let mut b = mount("tenant-b", Some("shared_rls"));
        a.inline_dsn = Some("postgres://shared/db".into());
        b.inline_dsn = Some("postgres://shared/db".into());
        assert_eq!(a.effective_pool_key(true), b.effective_pool_key(true));
        // The DSN itself must never appear in the key (it's a secret).
        assert!(!a.effective_pool_key(true).contains("postgres://"));
        // A different DSN forks a different pool.
        b.inline_dsn = Some("postgres://other/db".into());
        assert_ne!(a.effective_pool_key(true), b.effective_pool_key(true));
    }

    #[test]
    fn non_shared_rls_never_shares_even_when_enabled() {
        // schema_per_tenant and db_per_tenant keep per-tenant pools regardless.
        for iso in [
            Some("schema_per_tenant"),
            Some("db_per_tenant"),
            Some("tenant_owned"),
        ] {
            let a = mount("tenant-a", iso);
            let b = mount("tenant-b", iso);
            assert_ne!(
                a.effective_pool_key(true),
                b.effective_pool_key(true),
                "{iso:?} must not share a pool"
            );
            assert_eq!(a.effective_pool_key(true), a.pool_key());
        }
    }

    #[test]
    fn shared_rls_cred_version_still_forks_on_rotation() {
        let a = mount("tenant-a", Some("shared_rls"));
        let mut b = mount("tenant-b", Some("shared_rls"));
        b.credential_ref.version = "2".into();
        assert_ne!(
            a.effective_pool_key(true),
            b.effective_pool_key(true),
            "a rotated credential must fork a fresh pool"
        );
    }

    #[test]
    fn schema_per_tenant_derives_safe_name() {
        // Delegates to `safe_schema` (the single source of truth), so the derived
        // name carries the collision-free `_<hash8>` suffix. Assert it equals
        // `safe_schema` and keeps the human-readable prefix, not a brittle literal.
        assert_eq!(
            mount("acme", Some("schema_per_tenant")).tenant_schema(),
            safe_schema("acme")
        );
        // slugs / uuids with separators sanitize to underscores
        let s = mount("t-Acme_2", Some("schema_per_tenant"))
            .tenant_schema()
            .unwrap();
        assert!(s.starts_with("tenant_t_acme_2_"), "{s}");
        let s = mount(
            "00000000-0000-4000-8000-000000000003",
            Some("schema_per_tenant"),
        )
        .tenant_schema()
        .unwrap();
        assert!(
            s.starts_with("tenant_00000000_0000_4000_8000_000000000003_"),
            "{s}"
        );
    }

    #[test]
    fn injection_chars_are_neutralised() {
        let s = mount("a; DROP SCHEMA public; --", Some("schema_per_tenant"))
            .tenant_schema()
            .unwrap();
        assert!(s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
        assert!(s.starts_with("tenant_a"));
    }

    #[test]
    fn empty_after_sanitize_is_none() {
        assert_eq!(
            mount("---", Some("schema_per_tenant")).tenant_schema(),
            None
        );
    }

    #[test]
    fn distinct_tenants_get_distinct_pool_keys_and_schemas() {
        // The cross-tenant-leak guard: two DISTINCT raw tenant ids must NEVER
        // share a pool_key NOR a schema. pool_key keys on the raw id, so two ids
        // that previously sanitized to the SAME schema (`t-acme` / `t.acme`) got
        // separate pools pointing at one schema — a leak. Both axes must differ.
        let a = mount("t-acme", Some("schema_per_tenant"));
        let b = mount("t.acme", Some("schema_per_tenant"));
        assert_ne!(
            a.pool_key(),
            b.pool_key(),
            "distinct tenants → distinct pool_key"
        );
        assert_ne!(
            a.tenant_schema(),
            b.tenant_schema(),
            "distinct tenants → distinct schema (collision-free)"
        );
        // Both still resolve to a schema (neither sanitizes to empty).
        assert!(a.tenant_schema().is_some() && b.tenant_schema().is_some());
    }

    // ---- S8 read-replica routing (gate m122) -------------------------------

    #[test]
    fn read_replica_variant_none_when_no_replica_dsn() {
        // (a) No replica DSN configured ⇒ no variant; the caller uses the primary
        // mount unchanged = parity. Whitespace-only is treated as absent too.
        assert_eq!(
            mount("acme", Some("shared_rls")).read_replica_variant(),
            None
        );
        let mut blank = mount("acme", Some("shared_rls"));
        blank.replica_inline_dsn = Some("   ".into());
        assert_eq!(blank.read_replica_variant(), None);
    }

    #[test]
    fn read_replica_variant_sets_inline_dsn_and_route_marker() {
        // (b) A configured replica DSN ⇒ the variant routes inline_dsn ← replica
        // and flips the route marker on.
        let mut m = mount("acme", Some("shared_rls"));
        m.replica_inline_dsn = Some("postgres://replica/db".into());
        let v = m.read_replica_variant().expect("variant present");
        assert_eq!(v.inline_dsn.as_deref(), Some("postgres://replica/db"));
        assert!(v.read_replica_route);
    }

    #[test]
    fn read_replica_variant_pool_key_distinct_in_both_share_modes() {
        // (c) The variant's effective_pool_key ENDS WITH "/ro" and DIFFERS from
        // the primary's effective_pool_key in BOTH share=true and share=false, so
        // the replica pool can never collide with the primary pool.
        for share in [true, false] {
            let mut primary = mount("acme", Some("shared_rls"));
            primary.inline_dsn = Some("postgres://primary/db".into());
            primary.replica_inline_dsn = Some("postgres://replica/db".into());
            let variant = primary
                .clone()
                .read_replica_variant()
                .expect("variant present");
            let pk = variant.effective_pool_key(share);
            assert!(
                pk.ends_with("/ro"),
                "share={share}: replica key must end with /ro: {pk}"
            );
            assert_ne!(
                primary.effective_pool_key(share),
                pk,
                "share={share}: replica pool key must differ from the primary"
            );
        }
    }

    #[test]
    fn replica_dsn_round_trips_and_route_marker_never_serializes() {
        // (d) serde: replica_inline_dsn round-trips; read_replica_route is NEVER
        // serialized (the variant's JSON has no "read_replica_route" key) and
        // defaults false on deserialize ⇒ wire parity for an arriving request.
        let mut m = mount("acme", Some("shared_rls"));
        m.replica_inline_dsn = Some("postgres://replica/db".into());
        // clone for the variant so the ORIGINAL `m` survives for the round-trip
        // assertion below (read_replica_variant consumes self).
        let variant = m.clone().read_replica_variant().expect("variant present");
        assert!(
            variant.read_replica_route,
            "the variant carries the marker in-memory"
        );
        let json = serde_json::to_string(&variant).unwrap();
        assert!(
            !json.contains("read_replica_route"),
            "the internal route marker must never serialize: {json}"
        );
        // replica_inline_dsn round-trips and the deserialized marker defaults false.
        let back: DatabaseMount = serde_json::from_str(&json).unwrap();
        assert!(
            !back.read_replica_route,
            "marker defaults false on the wire"
        );
        let primary_json = serde_json::to_string(&m).unwrap();
        let back2: DatabaseMount = serde_json::from_str(&primary_json).unwrap();
        assert_eq!(
            back2.replica_inline_dsn.as_deref(),
            Some("postgres://replica/db"),
            "replica_inline_dsn round-trips on the wire"
        );
        assert!(!back2.read_replica_route);
    }
}
