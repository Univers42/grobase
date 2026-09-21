/* ************************************************************************** */
/*                                                                            */
/*   reconnect.rs — the LISTEN must survive PostgreSQL going away             */
/*                                                                            */
/*   Needs a REAL server. Run it through                                      */
/*   scripts/verify/m184-realtime-listen-reconnect.sh, which starts a         */
/*   throwaway one and exports REALTIME_PG_TEST_DSN.                          */
/*                                                                            */
/* ************************************************************************** */

// Same allowance the workspace's other integration test carries: a test that
// cannot panic cannot assert.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::time::Duration;

use realtime_core::DatabaseProducer;
use realtime_db_postgres::{PostgresConfig, PostgresProducer};
use tokio_postgres::NoTls;

const CHANNEL: &str = "realtime_reconnect_test";
const PAYLOAD: &str = r#"{"table":"probe","schema":"public","operation":"INSERT","data":{"id":1}}"#;

/// The DSN of a `PostgreSQL` this test may terminate backends on.
///
/// Absent, the test PANICS rather than returning early. A proof that skips
/// itself and still reports green is the exact failure this repo keeps finding.
fn dsn() -> String {
    std::env::var("REALTIME_PG_TEST_DSN").expect(
        "REALTIME_PG_TEST_DSN is unset — this proof needs a real PostgreSQL it is \
         allowed to terminate backends on. Run scripts/verify/m184-realtime-listen-reconnect.sh.",
    )
}

/// A second client, used to NOTIFY and to kill the producer's backend.
async fn client(dsn: &str) -> tokio_postgres::Client {
    let (client, connection) = tokio_postgres::connect(dsn, NoTls)
        .await
        .expect("notifier connect");
    tokio::spawn(async move {
        let _ = connection.await;
    });
    client
}

/// Killing every other backend is what recreating the container does to the
/// LISTEN — the connection ends server-side, with no chance to say goodbye.
async fn kill_other_backends(client: &tokio_postgres::Client) {
    let _ = client
        .batch_execute(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
             WHERE pid <> pg_backend_pid() AND datname = current_database()",
        )
        .await;
}

// #[ignore], so `cargo test --workspace` stays runnable without a database —
// but NOT skipped-and-forgotten: m184 runs it with --ignored and then asserts
// that exactly one test ran, so a filtered-out case is a gate failure, not a
// silent green.
#[tokio::test]
#[ignore = "needs a real PostgreSQL — run scripts/verify/m184-realtime-listen-reconnect.sh"]
async fn listen_reattaches_after_the_connection_dies() {
    let dsn = dsn();
    let config: PostgresConfig = serde_json::from_value(serde_json::json!({
        "connection_string": dsn,
        "channel": CHANNEL,
    }))
    .expect("config");

    let producer = PostgresProducer::new(config);
    let mut stream = producer.start().await.expect("first attach");
    assert!(
        producer.is_connected(),
        "producer reports disconnected at start"
    );

    let notifier = client(&dsn).await;
    let notify = format!("NOTIFY {CHANNEL}, '{PAYLOAD}'");

    notifier.batch_execute(&notify).await.expect("first notify");
    let before = tokio::time::timeout(Duration::from_secs(5), stream.next_event())
        .await
        .expect("timed out waiting for the first event");
    assert!(before.is_some(), "no event delivered before the kill");

    kill_other_backends(&notifier).await;

    // Re-NOTIFY until the re-attached LISTEN delivers, or give up. Against the
    // old one-shot producer the sender is dropped the moment the connection
    // dies, so next_event() returns None immediately and this loop exhausts.
    let mut after = None;
    for _ in 0..50 {
        let _ = notifier.batch_execute(&notify).await;
        if let Ok(Some(event)) =
            tokio::time::timeout(Duration::from_millis(500), stream.next_event()).await
        {
            after = Some(event);
            break;
        }
    }
    assert!(
        after.is_some(),
        "no event after the backend was terminated — the LISTEN did not re-attach"
    );
    assert!(
        producer.is_connected(),
        "delivery resumed but the producer still reports disconnected"
    );

    producer.stop().await.expect("stop");
    assert!(
        !producer.is_connected(),
        "stop() left the producer connected"
    );
}
