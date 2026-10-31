//! G5 data-plane TLS listener (ADR 0031, devil DT3–DT8, DT15). Certificates are made
//! with openssl at test time, so no key is committed; a missing openssl fails the
//! suite rather than skipping it.

use axum::{routing::get, Router};
use data_plane_server::tls_listener::{self, TlsSettings, CERT_FILE_VAR, KEY_FILE_VAR, PORT_VAR};
use std::{collections::HashMap, net::SocketAddr, path::PathBuf, process::Command, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;

struct Pki {
    dir: PathBuf,
}

impl Pki {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("dp-tls-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let pki = Self { dir };
        std::fs::write(
            pki.path("ca.cnf"),
            "[req]\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n[v3]\n\
             basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n",
        )
        .expect("ca config");
        std::fs::write(
            pki.path("leaf.ext"),
            "basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n\
             subjectAltName=DNS:localhost,DNS:data-plane-router-rust,IP:127.0.0.1\n",
        )
        .expect("leaf ext");
        pki.ca("ca");
        pki.ca("other-ca");
        pki.openssl(&[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            "leaf.key",
            "-out",
            "leaf.csr",
            "-subj",
            "/CN=data-plane",
        ]);
        pki.openssl(&[
            "x509",
            "-req",
            "-in",
            "leaf.csr",
            "-CA",
            "ca.pem",
            "-CAkey",
            "ca.key",
            "-CAcreateserial",
            "-out",
            "leaf.pem",
            "-days",
            "1",
            "-extfile",
            "leaf.ext",
        ]);
        pki.openssl(&["genrsa", "-out", "unrelated.key", "2048"]);
        pki
    }

    fn ca(&self, name: &str) {
        let (key, pem) = (format!("{name}.key"), format!("{name}.pem"));
        self.openssl(&[
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &key,
            "-out",
            &pem,
            "-days",
            "1",
            "-subj",
            "/CN=test-ca",
            "-config",
            "ca.cnf",
        ]);
    }

    fn openssl(&self, args: &[&str]) {
        let output = Command::new("openssl")
            .args(args)
            .current_dir(&self.dir)
            .output()
            .expect("openssl must be installed: the TLS listener tests need it to make their certificates");
        assert!(
            output.status.success(),
            "openssl {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn path(&self, file: &str) -> String {
        self.dir.join(file).to_string_lossy().into_owned()
    }

    fn settings(&self, key: &str) -> TlsSettings {
        TlsSettings {
            cert_file: self.path("leaf.pem"),
            key_file: self.path(key),
            port: 0,
        }
    }

    fn client(&self, ca: &str, addr: SocketAddr) -> reqwest::Client {
        let pem = std::fs::read(self.path(ca)).expect("ca pem");
        reqwest::Client::builder()
            .add_root_certificate(reqwest::Certificate::from_pem(&pem).expect("ca cert"))
            .resolve("localhost", addr)
            .resolve("outside-the-sans", addr)
            .build()
            .expect("client")
    }
}

impl Drop for Pki {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn app() -> Router {
    Router::new()
        .route("/ping", get(|| async { "pong" }))
        .route(
            "/slow",
            get(|| async {
                tokio::time::sleep(Duration::from_millis(400)).await;
                "done"
            }),
        )
}

async fn start(pki: &Pki) -> (SocketAddr, CancellationToken, tokio::task::JoinHandle<()>) {
    let listener = tls_listener::bind("127.0.0.1", &pki.settings("leaf.key"))
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let shutdown = CancellationToken::new();
    let listener = listener.with_handshake_timeout(Duration::from_millis(300));
    let task = tokio::spawn(tls_listener::serve(listener, app(), shutdown.clone()));
    (addr, shutdown, task)
}

fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let map: HashMap<String, String> = pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    move |name| map.get(name).cloned()
}

#[test]
fn no_tls_variables_means_no_second_socket() {
    assert_eq!(
        tls_listener::settings_from(lookup(&[]), 4011).expect("ok"),
        None
    );
    let blank = lookup(&[(CERT_FILE_VAR, ""), (KEY_FILE_VAR, " ")]);
    assert_eq!(tls_listener::settings_from(blank, 4011).expect("ok"), None);
}

#[test]
fn settings_refuse_half_or_colliding_config() {
    let only_cert =
        tls_listener::settings_from(lookup(&[(CERT_FILE_VAR, "/c")]), 4011).unwrap_err();
    assert!(only_cert.to_string().contains(KEY_FILE_VAR), "{only_cert}");
    let only_key = tls_listener::settings_from(lookup(&[(KEY_FILE_VAR, "/k")]), 4011).unwrap_err();
    assert!(only_key.to_string().contains(CERT_FILE_VAR), "{only_key}");
    let both = [(CERT_FILE_VAR, "/c"), (KEY_FILE_VAR, "/k")];
    let same_port =
        tls_listener::settings_from(lookup(&[both[0], both[1], (PORT_VAR, "4011")]), 4011);
    assert!(same_port
        .unwrap_err()
        .to_string()
        .contains("plaintext port"));
    let bad_port =
        tls_listener::settings_from(lookup(&[both[0], both[1], (PORT_VAR, "tls")]), 4011);
    assert!(bad_port.unwrap_err().to_string().contains(PORT_VAR));
    let parsed = tls_listener::settings_from(lookup(&both), 4011)
        .expect("ok")
        .expect("some");
    assert_eq!(parsed.port, tls_listener::DEFAULT_PORT);
}

#[test]
fn a_key_that_does_not_fit_the_certificate_refuses_the_boot() {
    let pki = Pki::new("mismatch");
    let error = tls_listener::load_acceptor(&pki.settings("unrelated.key"))
        .err()
        .expect("refused");
    assert!(error.to_string().contains("does not fit"), "{error}");
}

#[test]
fn an_unreadable_key_names_the_variable_and_never_the_bytes() {
    let pki = Pki::new("unreadable");
    let error = tls_listener::load_acceptor(&pki.settings("missing.key"))
        .err()
        .expect("refused");
    let text = error.to_string();
    assert!(
        text.starts_with(KEY_FILE_VAR) && text.contains("cannot read"),
        "{text}"
    );
    let leaf_key = std::fs::read_to_string(pki.path("leaf.key")).expect("key");
    let not_a_key = TlsSettings {
        key_file: pki.path("leaf.pem"),
        ..pki.settings("leaf.key")
    };
    let text = tls_listener::load_acceptor(&not_a_key)
        .err()
        .expect("refused")
        .to_string();
    assert!(
        text.contains("no private key") && !text.contains("BEGIN"),
        "{text}"
    );
    assert!(!text.contains(leaf_key.lines().nth(1).unwrap_or("-")));
}

#[tokio::test]
async fn serves_http1_over_tls_and_verifies_against_the_ca() {
    let pki = Pki::new("roundtrip");
    let (addr, shutdown, task) = start(&pki).await;
    let response = pki
        .client("ca.pem", addr)
        .get(format!("https://localhost:{}/ping", addr.port()))
        .send()
        .await
        .expect("tls");
    assert_eq!(response.version(), reqwest::Version::HTTP_11);
    assert_eq!(response.text().await.expect("body"), "pong");
    let wrong_ca = pki
        .client("other-ca.pem", addr)
        .get(format!("https://localhost:{}/ping", addr.port()))
        .send()
        .await;
    assert!(
        wrong_ca.is_err(),
        "a client trusting another CA must be refused"
    );
    let outside = pki
        .client("ca.pem", addr)
        .get(format!("https://outside-the-sans:{}/ping", addr.port()))
        .send()
        .await;
    assert!(
        outside.is_err(),
        "a host name outside the SANs must be refused"
    );
    shutdown.cancel();
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .expect("drained")
        .expect("joined");
}

#[tokio::test]
async fn a_request_in_flight_at_shutdown_completes() {
    let pki = Pki::new("drain");
    let (addr, shutdown, task) = start(&pki).await;
    let request = pki
        .client("ca.pem", addr)
        .get(format!("https://localhost:{}/slow", addr.port()))
        .send();
    let pending = tokio::spawn(request);
    tokio::time::sleep(Duration::from_millis(150)).await;
    shutdown.cancel();
    let response = pending
        .await
        .expect("joined")
        .expect("served after the signal");
    assert_eq!(response.text().await.expect("body"), "done");
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .expect("drained")
        .expect("joined");
}

#[tokio::test]
async fn a_silent_client_is_dropped_and_plain_http_gets_no_http_answer() {
    let pki = Pki::new("silent");
    let (addr, shutdown, task) = start(&pki).await;
    let mut silent = tokio::net::TcpStream::connect(addr).await.expect("connect");
    let mut buffer = [0_u8; 64];
    let read = tokio::time::timeout(Duration::from_secs(2), silent.read(&mut buffer)).await;
    assert!(
        matches!(read, Ok(Ok(0)) | Ok(Err(_))),
        "the handshake timeout must close a silent socket"
    );

    let mut plain = tokio::net::TcpStream::connect(addr).await.expect("connect");
    plain
        .write_all(b"GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .expect("write");
    let mut answer = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(2), plain.read_to_end(&mut answer)).await;
    assert!(
        !answer.starts_with(b"HTTP/"),
        "plain HTTP on the TLS port must get no HTTP response"
    );

    let still = pki
        .client("ca.pem", addr)
        .get(format!("https://localhost:{}/ping", addr.port()))
        .send()
        .await;
    assert!(
        still.is_ok(),
        "one bad connection must not stop the listener"
    );
    shutdown.cancel();
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .expect("drained")
        .expect("joined");
}
