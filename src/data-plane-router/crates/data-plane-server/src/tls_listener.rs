//! The data plane's TLS listener (G5, ADR 0031): the same router as the plaintext
//! port, served over TLS on DATA_PLANE_ROUTER_TLS_PORT when both
//! DATA_PLANE_ROUTER_TLS_CERT_FILE and DATA_PLANE_ROUTER_TLS_KEY_FILE are set.
//!
//! Accept mode, like G5a: the plaintext listener is unchanged, and with neither
//! variable set no second socket exists. HTTP/1.1 only, matching the plaintext port
//! (axum is built without http2), so ALPN offers `http/1.1` alone. A bad cert, key
//! or port refuses the boot rather than falling back to plaintext.

use axum::Router;
use hyper::server::conn::http1;
use hyper_util::{rt::TokioIo, service::TowerToHyperService};
use std::{io, net::SocketAddr, path::Path, sync::Arc, time::Duration};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::{
    rustls::{
        self,
        pki_types::{CertificateDer, PrivateKeyDer},
        ServerConfig,
    },
    TlsAcceptor,
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};

pub const CERT_FILE_VAR: &str = "DATA_PLANE_ROUTER_TLS_CERT_FILE";
pub const KEY_FILE_VAR: &str = "DATA_PLANE_ROUTER_TLS_KEY_FILE";
pub const PORT_VAR: &str = "DATA_PLANE_ROUTER_TLS_PORT";
pub const DEFAULT_PORT: u16 = 4012;

// Caveat: a client that opens a socket and then stays silent holds a task for this
// long; a handshake slower than 10 s (a very lossy link) is dropped as if silent.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TlsSettings {
    pub cert_file: String,
    pub key_file: String,
    pub port: u16,
}

pub struct TlsListener {
    listener: TcpListener,
    acceptor: TlsAcceptor,
    handshake_timeout: Duration,
}

/// Reads the TLS settings through `lookup` (an empty value counts as unset).
/// `None` when neither file variable is set; an error when only one is, or when
/// the port is not a number or collides with the plaintext port.
pub fn settings_from(
    lookup: impl Fn(&str) -> Option<String>,
    plain_port: u16,
) -> anyhow::Result<Option<TlsSettings>> {
    let read = |name: &str| lookup(name).filter(|value| !value.trim().is_empty());
    let (cert_file, key_file) = match (read(CERT_FILE_VAR), read(KEY_FILE_VAR)) {
        (None, None) => return Ok(None),
        (Some(cert), Some(key)) => (cert, key),
        (Some(_), None) => {
            anyhow::bail!("{CERT_FILE_VAR} is set but {KEY_FILE_VAR} is not: set both or neither")
        }
        (None, Some(_)) => {
            anyhow::bail!("{KEY_FILE_VAR} is set but {CERT_FILE_VAR} is not: set both or neither")
        }
    };
    let port = match read(PORT_VAR) {
        None => DEFAULT_PORT,
        Some(raw) => raw
            .trim()
            .parse()
            .map_err(|_| anyhow::anyhow!("{PORT_VAR}={raw} is not a port number"))?,
    };
    if port == plain_port {
        anyhow::bail!("{PORT_VAR} {port} is the plaintext port too: pick another one");
    }
    Ok(Some(TlsSettings {
        cert_file,
        key_file,
        port,
    }))
}

pub fn settings_from_env(plain_port: u16) -> anyhow::Result<Option<TlsSettings>> {
    settings_from(|name| std::env::var(name).ok(), plain_port)
}

/// Loads the cert and key and binds the TLS port, or `None` with no TLS variables set.
pub async fn bind_from_env(host: &str, plain_port: u16) -> anyhow::Result<Option<TlsListener>> {
    match settings_from_env(plain_port)? {
        Some(settings) => Ok(Some(bind(host, &settings).await?)),
        None => Ok(None),
    }
}

pub async fn bind(host: &str, settings: &TlsSettings) -> anyhow::Result<TlsListener> {
    let acceptor = load_acceptor(settings)?;
    let address = format!("{host}:{}", settings.port);
    let listener = TcpListener::bind(&address)
        .await
        .map_err(|error| anyhow::anyhow!("{PORT_VAR}: cannot bind {address}: {error}"))?;
    tracing::info!(%address, "Rust data-plane-router listening (TLS)");
    Ok(TlsListener {
        listener,
        acceptor,
        handshake_timeout: HANDSHAKE_TIMEOUT,
    })
}

impl TlsListener {
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    /// Test seam: a shorter handshake timeout than the 10 s default.
    pub fn with_handshake_timeout(mut self, timeout: Duration) -> Self {
        self.handshake_timeout = timeout;
        self
    }
}

/// Builds the rustls config: TLS 1.2+ (rustls has no older), ring, ALPN `http/1.1`.
/// rustls refuses a key that does not match the certificate (the spec proves it).
pub fn load_acceptor(settings: &TlsSettings) -> anyhow::Result<TlsAcceptor> {
    let certs = read_certs(&settings.cert_file)?;
    let key = read_key(&settings.key_file)?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|error| anyhow::anyhow!("{KEY_FILE_VAR} does not fit {CERT_FILE_VAR}: {error}"))?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(TlsAcceptor::from(Arc::new(config)))
}

fn read_certs(path: &str) -> anyhow::Result<Vec<CertificateDer<'static>>> {
    let pem = read_pem(CERT_FILE_VAR, path)?;
    let certs = rustls_pemfile::certs(&mut pem.as_slice())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| anyhow::anyhow!("{CERT_FILE_VAR}={path}: not PEM: {error}"))?;
    if certs.is_empty() {
        anyhow::bail!("{CERT_FILE_VAR}={path}: no certificate in the file");
    }
    Ok(certs)
}

fn read_key(path: &str) -> anyhow::Result<PrivateKeyDer<'static>> {
    let pem = read_pem(KEY_FILE_VAR, path)?;
    rustls_pemfile::private_key(&mut pem.as_slice())
        .map_err(|error| anyhow::anyhow!("{KEY_FILE_VAR}={path}: not PEM: {error}"))?
        .ok_or_else(|| anyhow::anyhow!("{KEY_FILE_VAR}={path}: no private key in the file"))
}

fn read_pem(var: &str, path: &str) -> anyhow::Result<Vec<u8>> {
    std::fs::read(Path::new(path))
        .map_err(|error| anyhow::anyhow!("{var}={path}: cannot read: {error}"))
}

/// Serves `app` until `shutdown` fires, then lets every open connection finish its
/// request (hyper's graceful shutdown) before returning.
pub async fn serve(tls: TlsListener, app: Router, shutdown: CancellationToken) {
    let connections = TaskTracker::new();
    loop {
        let accepted = tokio::select! {
            accepted = tls.listener.accept() => accepted,
            () = shutdown.cancelled() => break,
        };
        match accepted {
            Ok((stream, peer)) => {
                let connection = Connection {
                    acceptor: tls.acceptor.clone(),
                    peer,
                    timeout: tls.handshake_timeout,
                };
                connections.spawn(connection.serve(stream, app.clone(), shutdown.clone()));
            }
            Err(error) => accept_backoff(error).await,
        }
    }
    connections.close();
    connections.wait().await;
}

/// An accept error never ends the loop. A per-connection error is retried at once;
/// anything else (EMFILE) waits a second, as axum::serve does.
async fn accept_backoff(error: io::Error) {
    use io::ErrorKind::{ConnectionAborted, ConnectionRefused, ConnectionReset};
    if matches!(
        error.kind(),
        ConnectionAborted | ConnectionRefused | ConnectionReset
    ) {
        return;
    }
    tracing::error!(%error, "data-plane TLS accept failed; retrying in 1 s");
    tokio::time::sleep(Duration::from_secs(1)).await;
}

struct Connection {
    acceptor: TlsAcceptor,
    peer: SocketAddr,
    timeout: Duration,
}

impl Connection {
    async fn serve(self, stream: TcpStream, app: Router, shutdown: CancellationToken) {
        let Some(tls) = self.handshake(stream).await else {
            return;
        };
        let service = TowerToHyperService::new(app);
        let connection = http1::Builder::new()
            .serve_connection(TokioIo::new(tls), service)
            .with_upgrades();
        tokio::pin!(connection);
        let result = tokio::select! {
            result = connection.as_mut() => result,
            () = shutdown.cancelled() => {
                connection.as_mut().graceful_shutdown();
                connection.await
            }
        };
        if let Err(error) = result {
            tracing::debug!(peer = %self.peer, %error, "data-plane TLS connection ended with an error");
        }
    }

    async fn handshake(
        &self,
        stream: TcpStream,
    ) -> Option<tokio_rustls::server::TlsStream<TcpStream>> {
        match tokio::time::timeout(self.timeout, self.acceptor.accept(stream)).await {
            Ok(Ok(tls)) => {
                let version = tls.get_ref().1.protocol_version();
                tracing::debug!(peer = %self.peer, ?version, "data-plane TLS handshake accepted");
                Some(tls)
            }
            Ok(Err(error)) => {
                tracing::debug!(peer = %self.peer, %error, "data-plane TLS handshake refused");
                None
            }
            Err(_) => {
                tracing::debug!(peer = %self.peer, "data-plane TLS handshake timed out");
                None
            }
        }
    }
}
