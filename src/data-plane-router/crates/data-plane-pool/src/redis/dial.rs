/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dial.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 11:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 11:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial guard for Redis (ADR 0019). redis 0.27.6 has no TLS feature, so
//! `rediss://` fails at parse and there is no SNI concern. Under a scope a unix
//! socket (C11) or `TcpTls` address is refused; a TCP host is resolved, vetted,
//! then dialled as `ConnectionAddr::Tcp(<vetted ip>, port)` with parsed db,
//! username, password and protocol unchanged. There is no per-connection hook,
//! so the guard re-vets at checkout at most every `REVET_AFTER` and rebuilds on
//! a changed IP.
//! Caveat: a reconnect reuses the pinned IP; a DNS change is up to `REVET_AFTER`
//! late, and under shadow a refused host logs once per interval.

use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::{DialScope, Refusal};
use data_plane_core::{DataPlaneError, DataPlaneResult};
use redis::aio::{ConnectionManager, ConnectionManagerConfig};
use redis::{Client, ConnectionAddr, ConnectionInfo, IntoConnectionInfo};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::sync::Mutex as AsyncMutex;

const REVET_AFTER: Duration = Duration::from_secs(30);

/// The mount's manager, swapped by the guard when the vetted address moves.
pub(super) struct DialManager {
    manager: Mutex<ConnectionManager>,
    guard: Option<Guard>,
}

struct Guard {
    scope: DialScope,
    info: ConnectionInfo,
    revet_after: Duration,
    pinned: Mutex<Pinned>,
    // ConnectionManager connects eagerly: one re-vet at a time, so a burst of
    // checkouts after the interval builds one manager, not one per caller.
    serial: AsyncMutex<()>,
}

struct Pinned {
    ip: Option<IpAddr>,
    vetted_at: Instant,
}

impl DialManager {
    /// `scope: None` (off, or a Platform DSN) is the pre-G2 dial, untouched.
    pub(super) async fn open(dsn: &str, scope: Option<DialScope>) -> DataPlaneResult<Self> {
        Self::open_with(dsn, scope, REVET_AFTER).await
    }

    pub(super) async fn open_with(
        dsn: &str,
        scope: Option<DialScope>,
        revet_after: Duration,
    ) -> DataPlaneResult<Self> {
        let Some(scope) = scope else {
            return Ok(Self::plain(connect_dsn(dsn).await?, None));
        };
        let info = parse_info(dsn)?;
        let ip = match vet(&scope, &info).await {
            Ok(ip) => Some(ip),
            Err(refusal) if scope.enforcing() => return Err(scope.refused(&refusal)),
            Err(_) => None,
        };
        let manager = match ip.filter(|_| scope.enforcing()) {
            Some(ip) => connect_info(pinned_info(&info, ip)).await?,
            None => connect_dsn(dsn).await?,
        };
        let guard = Guard::new(scope, info, ip, revet_after);
        Ok(Self::plain(manager, Some(guard)))
    }

    fn plain(manager: ConnectionManager, guard: Option<Guard>) -> Self {
        Self {
            manager: Mutex::new(manager),
            guard,
        }
    }

    fn current(&self) -> ConnectionManager {
        self.manager.lock().expect("redis dial manager").clone()
    }

    /// The current manager, after a re-vet when one is due.
    pub(super) async fn checkout(&self) -> DataPlaneResult<ConnectionManager> {
        if let Some(guard) = &self.guard {
            if guard.due() {
                self.revet(guard).await?;
            }
        }
        Ok(self.current())
    }

    async fn revet(&self, guard: &Guard) -> DataPlaneResult<()> {
        let _serial = guard.serial.lock().await;
        if !guard.due() {
            return Ok(());
        }
        let Some(ip) = guard.next_pin().await? else {
            return Ok(());
        };
        let fresh = connect_info(pinned_info(&guard.info, ip)).await?;
        *self.manager.lock().expect("redis dial manager") = fresh;
        guard.pinned.lock().expect("redis dial pin").ip = Some(ip);
        Ok(())
    }
}

/// A guarded manager over an already-open connection, so the re-vet path runs
/// without a reachable public address.
#[cfg(test)]
pub(super) struct Fixture {
    pub scope: DialScope,
    pub info: ConnectionInfo,
    pub ip: IpAddr,
    pub revet_after: Duration,
}

#[cfg(test)]
impl DialManager {
    pub(super) fn for_test(manager: ConnectionManager, fixture: Fixture) -> Self {
        let guard = Guard::new(
            fixture.scope,
            fixture.info,
            Some(fixture.ip),
            fixture.revet_after,
        );
        Self::plain(manager, Some(guard))
    }

    pub(super) fn pinned_ip(&self) -> Option<IpAddr> {
        let guard = self.guard.as_ref().expect("guarded manager");
        guard.pinned.lock().expect("redis dial pin").ip
    }

    pub(super) async fn next_pin_now(&self) -> DataPlaneResult<Option<IpAddr>> {
        self.guard
            .as_ref()
            .expect("guarded manager")
            .next_pin()
            .await
    }
}

impl Guard {
    fn new(
        scope: DialScope,
        info: ConnectionInfo,
        ip: Option<IpAddr>,
        revet_after: Duration,
    ) -> Self {
        Self {
            scope,
            info,
            revet_after,
            pinned: Mutex::new(Pinned {
                ip,
                vetted_at: Instant::now(),
            }),
            serial: AsyncMutex::new(()),
        }
    }

    fn due(&self) -> bool {
        let pinned = self.pinned.lock().expect("redis dial pin");
        pinned.vetted_at.elapsed() >= self.revet_after
    }

    /// Re-vets and returns the address to move to; `None` keeps the manager.
    /// The pin itself moves only once the new manager is up (`revet`), so a
    /// failed connect leaves the old, still-vetted manager in place.
    async fn next_pin(&self) -> DataPlaneResult<Option<IpAddr>> {
        let vetted = vet(&self.scope, &self.info).await;
        let mut pinned = self.pinned.lock().expect("redis dial pin");
        pinned.vetted_at = Instant::now();
        match vetted {
            Ok(ip) if self.scope.enforcing() && pinned.ip != Some(ip) => Ok(Some(ip)),
            Ok(_) => Ok(None),
            Err(refusal) if self.scope.enforcing() => Err(self.scope.refused(&refusal)),
            Err(_) => Ok(None),
        }
    }
}

/// Refuse unix and TLS addresses, then resolve and vet every TCP record; the
/// first vetted record is the pin. Every refusal is reported (shadow logs,
/// enforce logs and refuses).
async fn vet(scope: &DialScope, info: &ConnectionInfo) -> Result<IpAddr, Refusal> {
    let vetted = match &info.addr {
        ConnectionAddr::Unix(path) => Err(Refusal::new(
            DenyClass::UnixSocket,
            None,
            &path.display().to_string(),
            0,
        )),
        ConnectionAddr::TcpTls { host, port, .. } => {
            Err(Refusal::new(DenyClass::Tls, None, host, *port))
        }
        ConnectionAddr::Tcp(host, port) => scope.vet_first(host, *port).await,
    };
    if let Err(refusal) = &vetted {
        scope.report(refusal);
    }
    vetted
}

/// The parsed settings (db, username, password, protocol) with the address
/// replaced by the vetted IP: the driver never resolves the name again.
pub(super) fn pinned_info(info: &ConnectionInfo, ip: IpAddr) -> ConnectionInfo {
    let port = match &info.addr {
        ConnectionAddr::Tcp(_, port) | ConnectionAddr::TcpTls { port, .. } => *port,
        ConnectionAddr::Unix(_) => 0,
    };
    ConnectionInfo {
        addr: ConnectionAddr::Tcp(ip.to_string(), port),
        redis: info.redis.clone(),
    }
}

#[cfg(test)]
pub(super) async fn plan(
    scope: &DialScope,
    info: &ConnectionInfo,
) -> Result<ConnectionInfo, Refusal> {
    vet(scope, info).await.map(|ip| pinned_info(info, ip))
}

fn parse_info(dsn: &str) -> DataPlaneResult<ConnectionInfo> {
    dsn.into_connection_info()
        .map_err(|e| DataPlaneError::Backend {
            message: format!("invalid redis URL: {e}"),
        })
}

pub(super) async fn connect_dsn(dsn: &str) -> DataPlaneResult<ConnectionManager> {
    let client = Client::open(dsn).map_err(|e| DataPlaneError::Backend {
        message: format!("invalid redis URL: {e}"),
    })?;
    connect_client(client).await
}

async fn connect_info(info: ConnectionInfo) -> DataPlaneResult<ConnectionManager> {
    let client = Client::open(info).map_err(|e| DataPlaneError::Backend {
        message: format!("invalid redis URL: {e}"),
    })?;
    connect_client(client).await
}

async fn connect_client(client: Client) -> DataPlaneResult<ConnectionManager> {
    ConnectionManager::new_with_config(client, manager_config())
        .await
        .map_err(|e| DataPlaneError::Backend {
            message: format!("redis connection manager init failed: {e}"),
        })
}

/// redis-rs 0.27 hands `factor` (100) to backon as a multiplier on its 1 s base, so
/// the default retry delays climb to backon's 60 s cap: a refused port held
/// `open_pool` over 120 s (measured, `canary.rs`). Bounded to 3 retries of ≤ 0.5 s.
///
/// Caveat: a host that accepts TCP and never answers still holds `open_pool` for
/// about 4 × 5 s; the same bound applies to background reconnects after a drop.
fn manager_config() -> ConnectionManagerConfig {
    ConnectionManagerConfig::new()
        .set_connection_timeout(Duration::from_secs(5))
        .set_max_delay(500)
        .set_number_of_retries(3)
}
