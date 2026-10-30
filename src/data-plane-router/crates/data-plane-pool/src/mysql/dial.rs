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

//! G2 dial guard for the MySQL wire (ADR 0019). mysql_async builds its pool
//! from one `Opts` with no per-connection hook, so the guard owns the pool:
//! it vets the driver-parsed host (C9), and under enforce rebuilds the pool
//! with `resolved_ips(vetted)` and `prefer_socket(false)` whenever the vetted
//! set changes (C4). A `socket=` option is refused.
//!
//! Caveat: the host is re-vetted at a checkout at most every `REVET_AFTER`,
//! not at each physical connect. Every connection still goes only to a vetted
//! address; a DNS change is picked up late (up to `REVET_AFTER`), and under
//! shadow a refused host logs once per interval while the pool is in use.

use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::{DialScope, Refusal};
use data_plane_core::DataPlaneResult;
use mysql_async::{Conn, Opts, OptsBuilder, Pool};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const REVET_AFTER: Duration = Duration::from_secs(30);

/// The mount's pool, behind the guard when one applies.
pub(super) struct DialPool {
    pool: Mutex<Pool>,
    guard: Option<Guard>,
}

struct Guard {
    scope: DialScope,
    opts: Opts,
    revet_after: Duration,
    pinned: Mutex<Pinned>,
}

struct Pinned {
    ips: Vec<IpAddr>,
    vetted_at: Instant,
}

impl DialPool {
    /// `scope: None` (off, or a Platform DSN) is the pre-G2 pool, untouched.
    pub(super) async fn open(opts: Opts, scope: Option<DialScope>) -> DataPlaneResult<Self> {
        Self::open_with(opts, scope, REVET_AFTER).await
    }

    pub(super) async fn open_with(
        opts: Opts,
        scope: Option<DialScope>,
        revet_after: Duration,
    ) -> DataPlaneResult<Self> {
        let Some(scope) = scope else {
            return Ok(Self::plain(Pool::new(opts), None));
        };
        let ips = match vet(&scope, &opts).await {
            Ok(ips) => ips,
            Err(refusal) if scope.enforcing() => return Err(scope.refused(&refusal)),
            Err(_) => Vec::new(),
        };
        let pool = if scope.enforcing() {
            Pool::new(pinned_opts(&opts, &ips))
        } else {
            Pool::new(opts.clone())
        };
        let guard = Guard {
            scope,
            opts,
            revet_after,
            pinned: Mutex::new(Pinned {
                ips,
                vetted_at: Instant::now(),
            }),
        };
        Ok(Self::plain(pool, Some(guard)))
    }

    fn plain(pool: Pool, guard: Option<Guard>) -> Self {
        Self {
            pool: Mutex::new(pool),
            guard,
        }
    }

    fn current(&self) -> Pool {
        self.pool.lock().expect("mysql dial pool").clone()
    }

    /// The driver's checkout, after a re-vet when one is due.
    pub(super) async fn get_conn(&self) -> mysql_async::Result<Conn> {
        if let Some(guard) = &self.guard {
            if guard.due() {
                self.revet(guard).await?;
            }
        }
        self.current().get_conn().await
    }

    pub(super) async fn disconnect(&self) -> mysql_async::Result<()> {
        self.current().disconnect().await
    }

    async fn revet(&self, guard: &Guard) -> mysql_async::Result<()> {
        let vetted = vet(&guard.scope, &guard.opts).await;
        let mut pinned = guard.pinned.lock().expect("mysql dial pin");
        pinned.vetted_at = Instant::now();
        let ips = match vetted {
            Ok(ips) => ips,
            Err(refusal) if guard.scope.enforcing() => {
                let message = guard.scope.refused(&refusal).to_string();
                return Err(mysql_async::Error::Other(message.into()));
            }
            Err(_) => return Ok(()),
        };
        if !guard.scope.enforcing() || ips == pinned.ips {
            return Ok(());
        }
        let fresh = Pool::new(pinned_opts(&guard.opts, &ips));
        pinned.ips = ips;
        let retired = std::mem::replace(&mut *self.pool.lock().expect("mysql dial pool"), fresh);
        tokio::spawn(async move {
            if let Err(e) = retired.disconnect().await {
                tracing::debug!(error = %e, "dial_guard: retired mysql pool disconnect failed");
            }
        });
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn pinned_ips(&self) -> Vec<IpAddr> {
        let guard = self.guard.as_ref().expect("guarded pool");
        guard.pinned.lock().expect("mysql dial pin").ips.clone()
    }

    #[cfg(test)]
    pub(super) async fn revet_now(&self) -> mysql_async::Result<()> {
        self.revet(self.guard.as_ref().expect("guarded pool")).await
    }
}

impl Guard {
    fn due(&self) -> bool {
        let pinned = self.pinned.lock().expect("mysql dial pin");
        pinned.vetted_at.elapsed() >= self.revet_after
    }
}

/// Refuse `socket=`, then resolve and classify the driver-parsed host; every
/// refusal is reported (shadow logs, enforce logs and refuses).
async fn vet(scope: &DialScope, opts: &Opts) -> Result<Vec<IpAddr>, Refusal> {
    let port = opts.tcp_port();
    let vetted = match opts.socket() {
        Some(socket) => Err(Refusal::new(DenyClass::UnixSocket, None, socket, port)),
        None => scope.vet_host(opts.ip_or_hostname(), port).await,
    };
    if let Err(refusal) = &vetted {
        scope.report(refusal);
    }
    vetted
}

/// The dial options under enforce: only the vetted addresses, never a socket.
pub(super) fn pinned_opts(opts: &Opts, ips: &[IpAddr]) -> Opts {
    OptsBuilder::from_opts(opts.clone())
        .resolved_ips(Some(ips.to_vec()))
        .prefer_socket(false)
        .into()
}
