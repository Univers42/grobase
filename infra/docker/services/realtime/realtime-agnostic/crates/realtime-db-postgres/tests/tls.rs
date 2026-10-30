/* ************************************************************************** */
/*                                                                            */
/*   tls.rs — the producer's LISTEN rides TLS when the DSN asks for it        */
/*                                                                            */
/*   Needs a REAL TLS server. Run it through                                  */
/*   scripts/verify/m258-realtime-pg-tls.sh, which starts a throwaway one     */
/*   behind the G5a engine-TLS entrypoint and exports the DSNs and the CA.    */
/*                                                                            */
/* ************************************************************************** */

// Same allowance the workspace's other integration tests carry: a test that
// cannot panic cannot assert.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::time::Duration;

use realtime_core::DatabaseProducer;
use realtime_db_postgres::{PostgresConfig, PostgresProducer};
use tokio_postgres::NoTls;

const CHANNEL: &str = "realtime_tls_test";
const PAYLOAD: &str = r#"{"table":"probe","schema":"public","operation":"INSERT","data":{"id":1}}"#;

/// A required env var. Absent, the test PANICS: a TLS proof that skips itself
/// and still reports green is the failure this gate exists to prevent.
fn env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{name} is unset — run scripts/verify/m258-realtime-pg-tls.sh"))
}

fn producer(dsn: &str) -> PostgresProducer {
    let config: PostgresConfig = serde_json::from_value(serde_json::json!({
        "connection_string": dsn,
        "channel": CHANNEL,
    }))
    .expect("config");
    PostgresProducer::new(config)
}

/// A plaintext side channel to the same server, to NOTIFY and to read
/// `pg_stat_ssl` for the producer's own backend.
async fn observer() -> tokio_postgres::Client {
    let dsn = format!("{} sslmode=disable", env("REALTIME_PG_TLS_TEST_DSN"));
    let (client, connection) = tokio_postgres::connect(&dsn, NoTls)
        .await
        .expect("observer connect");
    tokio::spawn(async move {
        let _ = connection.await;
    });
    client
}

/// `(ssl, version)` of every backend tagged `application_name`.
async fn backends(observer: &tokio_postgres::Client, app: &str) -> Vec<(bool, Option<String>)> {
    observer
        .query(
            "SELECT s.ssl, s.version FROM pg_stat_ssl s \
             JOIN pg_stat_activity a USING (pid) WHERE a.application_name = $1",
            &[&app],
        )
        .await
        .expect("pg_stat_ssl")
        .iter()
        .map(|row| (row.get(0), row.get(1)))
        .collect()
}

async fn assert_listen_over_tls(sslmode: &str, app: &str) {
    let dsn = format!(
        "{} sslmode={sslmode} application_name={app}",
        env("REALTIME_PG_TLS_TEST_DSN")
    );
    let producer = producer(&dsn);
    let mut stream = producer.start().await.expect("attach over TLS");
    producer
        .health_check()
        .await
        .expect("health check over TLS");

    let observer = observer().await;
    let seen = backends(&observer, app).await;
    assert!(!seen.is_empty(), "{sslmode}: no backend tagged {app}");
    for (ssl, version) in &seen {
        assert!(*ssl, "{sslmode}: a producer backend is NOT encrypted");
        println!("{sslmode}: backend ssl=true version={version:?}");
    }

    observer
        .batch_execute(&format!("NOTIFY {CHANNEL}, '{PAYLOAD}'"))
        .await
        .expect("notify");
    let event = tokio::time::timeout(Duration::from_secs(5), stream.next_event())
        .await
        .expect("timed out waiting for the event over TLS");
    assert!(event.is_some(), "{sslmode}: no event delivered over TLS");
    producer.stop().await.expect("stop");
}

#[tokio::test]
#[ignore = "needs a TLS PostgreSQL — run scripts/verify/m258-realtime-pg-tls.sh"]
async fn require_listens_over_tls() {
    assert_listen_over_tls("require", "rt_tls_require").await;
}

#[tokio::test]
#[ignore = "needs a TLS PostgreSQL — run scripts/verify/m258-realtime-pg-tls.sh"]
async fn verify_full_with_the_ca_listens_over_tls() {
    env("REALTIME_PG_TLS_CA_FILE");
    assert_listen_over_tls("verify-full", "rt_tls_verify").await;
}

/// The host name is not in the certificate: verify-full must refuse it, and
/// must NOT fall back to a plaintext session — no backend may carry the tag.
#[tokio::test]
#[ignore = "needs a TLS PostgreSQL — run scripts/verify/m258-realtime-pg-tls.sh"]
async fn verify_full_refuses_a_host_outside_the_certificate() {
    let app = "rt_tls_bad_san";
    let dsn = format!(
        "{} sslmode=verify-full application_name={app}",
        env("REALTIME_PG_TLS_TEST_UNLISTED_HOST_DSN")
    );
    let producer = producer(&dsn);
    let err = producer
        .start()
        .await
        .err()
        .expect("verify-full accepted a host outside the SAN");
    println!("refused as expected: {err}");
    assert!(
        producer.health_check().await.is_err(),
        "health check passed on a bad SAN"
    );
    assert!(
        !producer.is_connected(),
        "producer reports connected after a refused dial"
    );
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        backends(&observer().await, app).await.is_empty(),
        "a backend tagged {app} exists — the refused dial fell back to plaintext"
    );
}
