//! EngineAdapter for SQL Server: pool construction + the tiberius `Config`/TLS
//! posture that backs it.

use super::pool::MssqlPool;
use super::*;

pub struct MssqlEngineAdapter {
    resolver: Arc<dyn MountResolver>,
}

impl MssqlEngineAdapter {
    #[must_use]
    pub fn new(resolver: Arc<dyn MountResolver>) -> Self {
        Self { resolver }
    }
}

#[async_trait]
impl EngineAdapter for MssqlEngineAdapter {
    fn engine(&self) -> &str {
        "mssql"
    }

    fn capabilities(&self) -> EngineCapabilities {
        EngineCapabilities::mssql()
    }

    fn supported_ops(&self) -> &'static [DataOperationKind] {
        SUPPORTED_OPS
    }

    // ponytail: linear pool-construction sequence (DSN → config → bb8 build) —
    //   one straight-line setup, nothing to factor.
    async fn open_pool(&self, mount: DatabaseMount) -> DataPlaneResult<Box<dyn EnginePool>> {
        let dsn = self.resolver.resolve_dsn(&mount).await?;
        let config = mssql_config(&dsn)?;
        let manager = ConnectionManager::new(config);
        let pool = Pool::builder()
            .max_size(mount.pool_policy.max.max(1))
            .build(manager)
            .await
            .map_err(|e| DataPlaneError::Backend {
                message: format!("mssql pool build failed: {e}"),
            })?;
        Ok(Box::new(MssqlPool {
            mount_id: mount.id.clone(),
            tenant_id: mount.tenant_id.clone(),
            owner_scoped: mount.isolation().owner_scoped(),
            shared_pool: crate::pools_shared(&mount),
            pool,
        }))
    }

    async fn health_check(&self, pool: &dyn EnginePool) -> DataPlaneResult<EngineHealth> {
        Ok(EngineHealth::unknown("mssql", pool.mount_id()))
    }
}

/// Build a tiberius `Config` from a `mssql://user:pass@host:port/db` DSN. The
/// TLS posture is decided by [`apply_mssql_tls`] — tiberius verifies the server
/// cert by default; we only relax that deliberately (never silently).
fn mssql_config(dsn: &str) -> DataPlaneResult<Config> {
    let rest = dsn
        .strip_prefix("mssql://")
        .or_else(|| dsn.strip_prefix("sqlserver://"))
        .ok_or_else(|| DataPlaneError::Backend {
            message: "mssql DSN must start with mssql:// or sqlserver://".to_string(),
        })?;
    // user:pass@host:port/db
    let (creds, hostpart) = rest
        .split_once('@')
        .ok_or_else(|| DataPlaneError::Backend {
            message: "mssql DSN missing '@' (user:pass@host:port/db)".to_string(),
        })?;
    let (user, pass) = creds.split_once(':').unwrap_or((creds, ""));
    let (host_port, db) = hostpart.split_once('/').unwrap_or((hostpart, "master"));
    let (host, port) = host_port.split_once(':').unwrap_or((host_port, "1433"));
    let port: u16 = port.parse().unwrap_or(1433);

    let mut config = Config::new();
    config.host(host);
    config.port(port);
    config.database(if db.is_empty() { "master" } else { db });
    config.authentication(AuthMethod::sql_server(user, pass));
    apply_mssql_tls(&mut config);
    Ok(config)
}

/// Phase B — the MSSQL TLS posture (closes the unconditional `trust_cert()`
/// hole, which accepted ANY server certificate even under `SECURITY_MODE=max`).
/// tiberius encrypts the connection and, by DEFAULT, verifies the certificate
/// against the native root store. We only override that explicitly:
///
///   * `SECURITY_MODE=max` → never blind-trust. Pin a custom CA when
///     `DATA_PLANE_TLS_CA_FILE` is set, otherwise verify against the native
///     roots. The insecure dev escape is ignored (a self-signed mount fails).
///   * baseline/dev        → a self-signed local SQL Server is accepted ONLY via
///     the explicit `DATA_PLANE_TLS_INSECURE=1` escape (or a pinned CA); without
///     it the chain is still verified.
fn apply_mssql_tls(config: &mut Config) {
    let max_security = std::env::var("SECURITY_MODE")
        .map(|v| v.eq_ignore_ascii_case("max"))
        .unwrap_or(false);
    let ca_file = std::env::var("DATA_PLANE_TLS_CA_FILE").unwrap_or_default();
    let insecure =
        !max_security && std::env::var("DATA_PLANE_TLS_INSECURE").ok().as_deref() == Some("1");
    if insecure {
        config.trust_cert();
    } else if !ca_file.is_empty() {
        config.trust_cert_ca(&ca_file);
    }
    // else: default tiberius behaviour — verify against the native root store.
}
