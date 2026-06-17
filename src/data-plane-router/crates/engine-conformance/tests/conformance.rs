//! Driver for the engine-conformance battery.
//!
//! Reads `CONFORMANCE_ENGINE` + `CONFORMANCE_DSN` from the environment, builds
//! the matching adapter with the DSN supplied inline on the mount, and runs the
//! full suite. With no env set (e.g. `cargo test` in CI with no database) the
//! test SKIPS cleanly so the workspace build stays green without infra — the
//! live run happens via the `conformance-runner` compose service on the
//! mini-baas network (`make conformance-<engine>`).

use std::sync::Arc;

use data_plane_core::EngineAdapter;
use data_plane_pool::{
    EnvMountResolver, MongoEngineAdapter, MountResolver, MssqlEngineAdapter, MysqlEngineAdapter,
    PgDialect, PostgresEngineAdapter, RedisEngineAdapter, SqliteEngineAdapter,
};
use engine_conformance::{mount_for, run_suite};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_conformance() {
    let engine = match std::env::var("CONFORMANCE_ENGINE") {
        Ok(e) if !e.trim().is_empty() => e,
        _ => {
            eprintln!("SKIP: CONFORMANCE_ENGINE unset (run via `make conformance-<engine>`)");
            return;
        }
    };
    let dsn = std::env::var("CONFORMANCE_DSN").unwrap_or_default();
    assert!(
        !dsn.trim().is_empty(),
        "CONFORMANCE_ENGINE={engine} requires CONFORMANCE_DSN"
    );
    let tenant = std::env::var("CONFORMANCE_TENANT").unwrap_or_else(|_| "conf-tenant".to_string());

    let resolver: Arc<dyn MountResolver> = Arc::new(EnvMountResolver::default());
    let adapter: Arc<dyn EngineAdapter> = match engine.as_str() {
        "postgresql" => Arc::new(PostgresEngineAdapter::new(resolver)),
        "cockroachdb" => {
            Arc::new(PostgresEngineAdapter::with_dialect(resolver, PgDialect::Cockroach))
        }
        "mysql" => Arc::new(MysqlEngineAdapter::new(resolver)),
        "mariadb" => Arc::new(MysqlEngineAdapter::with_engine_name(resolver, "mariadb")),
        "mongodb" => Arc::new(MongoEngineAdapter::new(resolver)),
        "redis" => Arc::new(RedisEngineAdapter::new(resolver)),
        "sqlite" => Arc::new(SqliteEngineAdapter::new(resolver)),
        "mssql" => Arc::new(MssqlEngineAdapter::new(resolver)),
        other => panic!("CONFORMANCE_ENGINE='{other}' is not wired in tests/conformance.rs"),
    };

    let mount = mount_for(&engine, &tenant, &dsn);
    let report = run_suite(adapter, mount).await;
    println!("{report}");
    assert!(report.is_green(), "conformance failed for {engine}:\n{report}");
}
