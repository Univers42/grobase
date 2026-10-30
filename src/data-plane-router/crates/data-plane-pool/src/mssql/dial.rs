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

//! G2 dial guard for SQL Server (ADR 0019, devil C10). bb8-tiberius dials
//! `config.get_addr()` itself and follows one TDS Routing redirect to whatever
//! host the server names, so this manager owns `connect`: under enforce each
//! hop (the DSN host, then at most one Routing host) is resolved, vetted and
//! dialled by IP. tiberius takes the TLS server name from `config.host`, which
//! keeps the name, so certificate checks are unchanged. A named instance needs
//! SQL Browser (UDP 1434; the `sql-browser` feature is off) and is refused.
//! Caveat: each hop pins its first vetted record, so a host with several A
//! records loses failover across them, as pgwire does. A refusal at checkout
//! (the name moved after open) surfaces as bb8's checkout timeout; the
//! `dial_guard deny` line names the class.

use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::{DialScope, Refusal};
use async_trait::async_trait;
use bb8_tiberius::rt::Client;
use bb8_tiberius::{ConnectionManager, Error};
use data_plane_core::DataPlaneResult;
use futures::future::BoxFuture;
use std::future::Future;
use std::io;
use std::net::SocketAddr;
use tiberius::Config;
use tokio::net::TcpStream;
use tokio_util::compat::TokioAsyncWriteCompatExt;

pub(super) type TcpDial = fn(SocketAddr) -> BoxFuture<'static, io::Result<TcpStream>>;

/// `guard: None` (off, or a Platform DSN) is bb8-tiberius, untouched.
pub(super) struct DialManager {
    inner: ConnectionManager,
    config: Config,
    guard: Option<Guard>,
}

pub(super) struct Guard {
    scope: DialScope,
    dial: TcpDial,
}

impl DialManager {
    pub(super) fn new(config: Config, scope: Option<DialScope>) -> Self {
        Self {
            inner: ConnectionManager::new(config.clone()),
            config,
            guard: scope.map(|scope| Guard {
                scope,
                dial: tcp_connect,
            }),
        }
    }

    /// Enforce refuses a denied DSN host before the pool exists; bb8 builds
    /// the pool without dialling, so nothing else would say so at open.
    pub(super) async fn precheck(&self) -> DataPlaneResult<()> {
        match &self.guard {
            Some(guard) if guard.scope.enforcing() => match guard.pin(&self.config).await {
                Ok(_) => Ok(()),
                Err(refusal) => Err(guard.scope.refused(&refusal)),
            },
            _ => Ok(()),
        }
    }
}

#[async_trait]
impl bb8::ManageConnection for DialManager {
    type Connection = Client;
    type Error = Error;

    async fn connect(&self) -> Result<Client, Error> {
        match &self.guard {
            None => self.inner.connect().await,
            Some(guard) => guard.connect(self.config.clone(), tds_connect).await,
        }
    }

    async fn is_valid(&self, conn: &mut Client) -> Result<(), Error> {
        self.inner.is_valid(conn).await
    }

    fn has_broken(&self, conn: &mut Client) -> bool {
        self.inner.has_broken(conn)
    }
}

impl Guard {
    #[cfg(test)]
    pub(super) fn with_dial(scope: DialScope, dial: TcpDial) -> Self {
        Self { scope, dial }
    }

    /// The DSN host, then at most one Routing host, each through `tcp`. A
    /// second redirect comes back as tiberius's `Routing` error.
    pub(super) async fn connect<T, F, Fut>(&self, config: Config, tds: F) -> Result<T, Error>
    where
        F: Fn(Config, TcpStream) -> Fut + Send + Sync,
        Fut: Future<Output = tiberius::Result<T>> + Send,
        T: Send,
    {
        let tcp = self.tcp(&config).await?;
        match tds(config.clone(), tcp).await {
            Err(tiberius::error::Error::Routing { host, port }) => {
                let mut routed = config;
                routed.host(&host);
                routed.port(port);
                let tcp = self.tcp(&routed).await?;
                Ok(tds(routed, tcp).await?)
            }
            other => Ok(other?),
        }
    }

    /// Enforce dials the vetted IP; shadow logs and dials the name, as off would.
    async fn tcp(&self, config: &Config) -> Result<TcpStream, Error> {
        let pinned = self.pin(config).await;
        if !self.scope.enforcing() {
            return Ok(TcpStream::connect(config.get_addr()).await?);
        }
        match pinned {
            Ok(addr) => Ok((self.dial)(addr).await?),
            Err(refusal) => Err(refused_io(self.scope.refused(&refusal).to_string())),
        }
    }

    /// Vets the hop's host and returns its first vetted address; every
    /// refusal is reported (shadow logs, enforce logs and refuses).
    async fn pin(&self, config: &Config) -> Result<SocketAddr, Refusal> {
        let (host, port) = host_port(config);
        let vetted = if host.contains('\\') {
            Err(Refusal::new(DenyClass::NamedInstance, None, &host, port))
        } else {
            self.scope.vet_first(&host, port).await
        };
        if let Err(refusal) = &vetted {
            self.scope.report(refusal);
        }
        vetted.map(|ip| SocketAddr::new(ip, port))
    }
}

/// tiberius keeps host and port crate-private; `get_addr` is `host:port`.
fn host_port(config: &Config) -> (String, u16) {
    let addr = config.get_addr();
    match addr.rsplit_once(':') {
        Some((host, port)) => (host.to_string(), port.parse().unwrap_or(1433)),
        None => (addr, 1433),
    }
}

fn refused_io(message: String) -> Error {
    Error::Io(io::Error::new(io::ErrorKind::PermissionDenied, message))
}

fn tcp_connect(addr: SocketAddr) -> BoxFuture<'static, io::Result<TcpStream>> {
    Box::pin(TcpStream::connect(addr))
}

/// What bb8-tiberius does once it has a socket.
async fn tds_connect(config: Config, tcp: TcpStream) -> tiberius::Result<Client> {
    tcp.set_nodelay(true)?;
    tiberius::Client::connect(config, tcp.compat_write()).await
}
