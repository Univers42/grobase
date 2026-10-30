/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dial.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 10:57:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 10:57:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial guard for pgwire (ADR 0019). A guarded pool dials through
//! [`GuardedConnect`]: at EVERY physical connect it reads the driver's own
//! parsed `tokio_postgres::Config` (C1), classifies every host and every tenant
//! `hostaddr` (C2), refuses a unix socket, and under enforce connects with one
//! vetted `hostaddr` per host while `host` stays the TLS name (C4).
//!
//! Caveat: a host that resolves to several addresses is pinned to the first
//! one; the others are vetted but never tried, so a dead first address fails
//! the dial where the driver alone would fall through to the next record.

use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::{DialScope, Refusal};
use crate::dial_guard::DialGuardMode;
use crate::resolver::Provenance;
use data_plane_core::{DataPlaneResult, DatabaseMount};
use deadpool_postgres::{
    Config as DeadpoolConfig, ConfigConnectImpl, Connect, Manager, Pool, Runtime,
};
use futures::future::BoxFuture;
use std::net::IpAddr;
use std::str::FromStr;
use std::sync::Arc;
use tokio::task::JoinHandle;
use tokio_postgres::config::Host;
use tokio_postgres::tls::{MakeTlsConnect, TlsConnect};
use tokio_postgres::{Client, Config as PgConfig, NoTls, Socket};

const DEFAULT_PORT: u16 = 5432;

/// The per-pool guard: the scope plus the exact pooler endpoints that are
/// resolved but not classified (C3: only `DATA_PLANE_POOLER_URL`'s host:port).
pub(super) struct PgDialGuard {
    pub(super) scope: DialScope,
    exempt: Vec<(String, u16)>,
}

/// `None` (dial unchanged) when the guard is off or the DSN is Platform.
pub(super) fn guard_for(
    mode: DialGuardMode,
    engine: &'static str,
    mount: &DatabaseMount,
    provenance: Provenance,
    pooler_url: Option<&str>,
) -> Option<Arc<PgDialGuard>> {
    let scope = DialScope::for_mount(mode, engine, mount, provenance)?;
    Some(Arc::new(PgDialGuard::new(scope, pooler_url)))
}

impl PgDialGuard {
    pub(super) fn new(scope: DialScope, pooler_url: Option<&str>) -> Self {
        let parsed = pooler_url.and_then(|url| PgConfig::from_str(url).ok());
        let exempt = parsed.map_or_else(Vec::new, |cfg| {
            let ports = cfg.get_ports();
            let hosts = cfg.get_hosts().iter().enumerate();
            hosts
                .filter_map(|(i, host)| match host {
                    Host::Tcp(name) => Some((name.to_ascii_lowercase(), port_at(ports, i))),
                    Host::Unix(_) => None,
                })
                .collect()
        });
        Self { scope, exempt }
    }

    /// The config this dial may use and every refusal found. The vetted
    /// config is the tenant's when it names `hostaddr`s (all classified), else
    /// a clone with exactly one vetted `hostaddr` pushed per host.
    pub(super) async fn plan(&self, cfg: &PgConfig) -> (PgConfig, Vec<Refusal>) {
        let mut vetted = cfg.clone();
        let mut refusals = Vec::new();
        let ports = cfg.get_ports();
        let addrs = cfg.get_hostaddrs();
        for (i, host) in cfg.get_hosts().iter().enumerate() {
            let port = port_at(ports, i);
            match host {
                Host::Unix(path) => refusals.push(Refusal::new(
                    DenyClass::UnixSocket,
                    None,
                    &path.display().to_string(),
                    port,
                )),
                Host::Tcp(name) if addrs.is_empty() => match self.pin(name, port).await {
                    Ok(ip) => {
                        vetted.hostaddr(ip);
                    }
                    Err(refusal) => refusals.push(refusal),
                },
                Host::Tcp(_) => {}
            }
        }
        for (i, ip) in addrs.iter().enumerate() {
            let vet = self.scope.vet_ip(*ip, &ip.to_string(), port_at(ports, i));
            refusals.extend(vet.err());
        }
        (vetted, refusals)
    }

    async fn pin(&self, name: &str, port: u16) -> Result<IpAddr, Refusal> {
        let lower = name.to_ascii_lowercase();
        let ips = if self.exempt.iter().any(|(h, p)| *h == lower && *p == port) {
            self.scope.resolve(name, port).await?
        } else {
            self.scope.vet_host(name, port).await?
        };
        Ok(ips[0])
    }

    /// Under enforce, refuse at pool open so the caller gets the class rather
    /// than the driver's generic connect error. Shadow and a clean plan pass.
    pub(super) async fn precheck(&self, cfg: &DeadpoolConfig) -> DataPlaneResult<()> {
        if !self.scope.enforcing() {
            return Ok(());
        }
        // An unparsable config is left to create_pool, which reports it.
        let Ok(pg_config) = cfg.get_pg_config() else {
            return Ok(());
        };
        let (_, refusals) = self.plan(&pg_config).await;
        refusals.iter().for_each(|r| self.scope.report(r));
        match refusals.first() {
            Some(first) => Err(self.scope.refused(first)),
            None => Ok(()),
        }
    }
}

/// The driver's own rule: port `i`, else the first port, else 5432.
fn port_at(ports: &[u16], i: usize) -> u16 {
    ports
        .get(i)
        .or(ports.first())
        .copied()
        .unwrap_or(DEFAULT_PORT)
}

/// deadpool's connect, preceded by the plan at every physical dial.
pub(super) struct GuardedConnect<T>
where
    T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
    T::Stream: Sync + Send,
    T::TlsConnect: Sync + Send,
    <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
{
    pub(super) inner: ConfigConnectImpl<T>,
    pub(super) guard: Arc<PgDialGuard>,
}

impl<T> Connect for GuardedConnect<T>
where
    T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
    T::Stream: Sync + Send,
    T::TlsConnect: Sync + Send,
    <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
{
    fn connect(
        &self,
        pg_config: &PgConfig,
    ) -> BoxFuture<'_, Result<(Client, JoinHandle<()>), tokio_postgres::Error>> {
        let pg_config = pg_config.clone();
        Box::pin(async move {
            let (vetted, refusals) = self.guard.plan(&pg_config).await;
            refusals.iter().for_each(|r| self.guard.scope.report(r));
            if !self.guard.scope.enforcing() {
                return self.inner.connect(&pg_config).await;
            }
            if !refusals.is_empty() {
                return Err(refused_error().await);
            }
            self.inner.connect(&vetted).await
        })
    }
}

/// tokio-postgres has no public error constructor; an empty config fails
/// with a config error before any I/O. The reason is in the deny log line.
async fn refused_error() -> tokio_postgres::Error {
    match PgConfig::new().connect(NoTls).await {
        Err(e) => e,
        Ok(_) => unreachable!("a config with no host cannot connect"),
    }
}

/// The pool for `cfg`: deadpool's own `create_pool` when unguarded (byte-for-
/// byte the pre-G2 path), else the same config behind [`GuardedConnect`].
pub(super) fn build_pool<T>(
    cfg: &DeadpoolConfig,
    tls: T,
    guard: Option<Arc<PgDialGuard>>,
) -> Result<Pool, String>
where
    T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
    T::Stream: Sync + Send,
    T::TlsConnect: Sync + Send,
    <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
{
    let Some(guard) = guard else {
        return cfg
            .create_pool(Some(Runtime::Tokio1), tls)
            .map_err(|e| e.to_string());
    };
    let pg_config = cfg.get_pg_config().map_err(|e| e.to_string())?;
    let connect = GuardedConnect {
        inner: ConfigConnectImpl { tls },
        guard,
    };
    let manager = Manager::from_connect(pg_config, connect, cfg.get_manager_config());
    Pool::builder(manager)
        .config(cfg.get_pool_config())
        .runtime(Runtime::Tokio1)
        .build()
        .map_err(|e| e.to_string())
}
