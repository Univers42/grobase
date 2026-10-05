//! The JS SDK's committed engine catalog (`sdks/js/src/generated/engines.ts`)
//! equals what GET /query/v1/engines serves: each Rust descriptor mapped by
//! `toEngineCaps` in query-router's engines.controller.ts and rendered the way
//! `sdks/js/scripts/codegen-engines.mjs` writes it. The SDK derives its
//! compile-time types from that file, so a drift is a type that lies.
//!
//! The file sits outside this workspace. A build that mounts only the data
//! plane (the `make rust-data-plane-test` container) skips the check; CI sets
//! `GROBASE_REQUIRE_SDK_CATALOG=1`, which turns a missing file into a failure.

use std::path::PathBuf;

use data_plane_core::EngineCapabilities;
use serde_json::Value;

/// The engines compose forwards to the Rust data plane by default
/// (`RUST_DATA_PLANE_FORWARD_ENGINES` in orchestrators/compose/base/app-services.yml).
const FORWARDED: [&str; 9] = [
    "postgresql",
    "cockroachdb",
    "mongodb",
    "mysql",
    "mariadb",
    "redis",
    "sqlite",
    "mssql",
    "http",
];

fn descriptor(engine: &str) -> EngineCapabilities {
    match engine {
        "postgresql" => EngineCapabilities::postgresql(),
        "cockroachdb" => EngineCapabilities::cockroachdb(),
        "mongodb" => EngineCapabilities::mongodb(),
        "mysql" => EngineCapabilities::mysql(),
        "mariadb" => EngineCapabilities::mariadb(),
        "redis" => EngineCapabilities::redis(),
        "sqlite" => EngineCapabilities::sqlite(),
        "mssql" => EngineCapabilities::mssql(),
        "http" => EngineCapabilities::http(),
        other => panic!("no descriptor for {other}"),
    }
}

/// `pick` from engines.controller.ts: the wire token when it is one the SDK
/// models, else the fallback.
fn pick(value: &Value, allowed: &[&str], fallback: &'static str) -> String {
    match value.as_str() {
        Some(s) if allowed.contains(&s) => s.to_string(),
        _ => fallback.to_string(),
    }
}

/// The catalog line codegen-engines.mjs renders for `engine`.
fn expected_line(engine: &str) -> String {
    let c = descriptor(engine);
    let cost = serde_json::to_value(&c.cost).expect("cost serializes");
    let joins = pick(&cost["joins"], &["native", "limited", "none"], "none");
    let pattern = pick(
        &cost["pattern_search"],
        &["native", "indexed", "limited", "scan", "remote", "none"],
        "none",
    );
    let latency = pick(
        &cost["latency_class"],
        &["native", "adapter", "fdw", "remote"],
        "native",
    );
    format!(
        "  {engine}: {{ read: {}, write: {}, upsert: {}, txIntra: {}, stream: {}, semantic: {{ joins: '{joins}', patternSearch: '{pattern}', ddl: {}, migrationVersioning: {}, latencyClass: '{latency}' }} }},",
        c.read, c.write, c.upsert, c.transactions, c.stream, c.ddl, c.ddl
    )
}

fn catalog() -> Option<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../../sdks/js/src/generated/engines.ts");
    match std::fs::read_to_string(&path) {
        Ok(text) => Some(text),
        Err(e) if std::env::var("GROBASE_REQUIRE_SDK_CATALOG").as_deref() == Ok("1") => {
            panic!("{} unreadable: {e}", path.display())
        }
        Err(_) => None,
    }
}

#[test]
fn sdk_engine_catalog_matches_the_rust_descriptors() {
    let Some(text) = catalog() else {
        eprintln!("skipped: sdks/js is not in this checkout");
        return;
    };
    for engine in FORWARDED {
        let want = expected_line(engine);
        assert!(
            text.lines().any(|l| l == want),
            "engines.ts has drifted for {engine}; regenerate with \
             sdks/js/scripts/codegen-engines.mjs. Expected:\n{want}"
        );
    }
    let entries = text
        .lines()
        .filter(|l| l.starts_with("  ") && l.contains(": { read: "))
        .count();
    assert_eq!(
        entries,
        FORWARDED.len(),
        "engines.ts lists {entries} engines; the data plane forwards {}",
        FORWARDED.len()
    );
}
