/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sec_capability.rs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:35:04 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:35:06 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Security: capability descriptor honesty + wire back-compat. The optional
//! `#[serde(default)]` flags (batch/aggregate/introspect/schema_ddl) must
//! default to the SAFE value `false` when a partial descriptor omits them — so
//! a tampered / truncated capability payload can never SILENTLY widen what an
//! engine claims to serve. `supports_op` is the single source of truth the
//! planner gates on; `IsolationLevel` round-trips as a closed set.

use data_plane_core::{DataOperationKind, EngineCapabilities, IsolationLevel};
use serde_json::json;

// ── serde back-compat: absent optional flags default to false (SAFE) ────────

#[test]
fn absent_optional_capability_flags_default_to_false() {
    // A minimal/legacy descriptor that omits the additive flags must NOT be
    // read as if the engine supported batch/aggregate/introspect/schema_ddl.
    let minimal = json!({
        "read": true,
        "write": true,
        "upsert": true,
        "stream": false,
        "ddl": false,
        "transactions": false,
        "savepoints": false,
        "isolation_levels": [],
        "two_phase_commit": false,
        "native_idempotency": false,
        "max_batch_size": 100,
        "cost": {
            "latency_class": "native",
            "pattern_search": "scan",
            "joins": "none"
        }
    });
    let caps: EngineCapabilities = serde_json::from_value(minimal).expect("deserializes");
    assert!(!caps.batch, "absent batch defaults to false (safe)");
    assert!(!caps.aggregate, "absent aggregate defaults to false");
    assert!(!caps.introspect, "absent introspect defaults to false");
    assert!(!caps.schema_ddl, "absent schema_ddl defaults to false");
    // And the op gate agrees: the missing flags mean those ops are unsupported.
    assert!(!caps.supports_op(&DataOperationKind::Batch));
    assert!(!caps.supports_op(&DataOperationKind::Aggregate));
}

#[test]
fn descriptor_round_trips_for_every_engine_constructor() {
    let engines = [
        ("postgresql", EngineCapabilities::postgresql()),
        ("cockroachdb", EngineCapabilities::cockroachdb()),
        ("mysql", EngineCapabilities::mysql()),
        ("mariadb", EngineCapabilities::mariadb()),
        ("mongodb", EngineCapabilities::mongodb()),
        ("sqlite", EngineCapabilities::sqlite()),
        ("mssql", EngineCapabilities::mssql()),
        ("redis", EngineCapabilities::redis()),
        ("dynamodb", EngineCapabilities::dynamodb()),
        ("http", EngineCapabilities::http()),
    ];
    for (name, caps) in engines {
        let json = serde_json::to_value(&caps).unwrap();
        let back: EngineCapabilities = serde_json::from_value(json).unwrap();
        assert_eq!(back, caps, "{name} descriptor must round-trip exactly");
    }
}

// ── supports_op is the single source of truth, total over every op ──────────

#[test]
fn supports_op_matches_the_declared_flags_for_every_engine() {
    let engines = [
        EngineCapabilities::postgresql(),
        EngineCapabilities::mysql(),
        EngineCapabilities::mongodb(),
        EngineCapabilities::sqlite(),
        EngineCapabilities::mssql(),
        EngineCapabilities::redis(),
        EngineCapabilities::dynamodb(),
        EngineCapabilities::http(),
    ];
    for caps in engines {
        // read flag governs List + Get
        assert_eq!(caps.supports_op(&DataOperationKind::List), caps.read);
        assert_eq!(caps.supports_op(&DataOperationKind::Get), caps.read);
        // write flag governs Insert/Update/Delete
        assert_eq!(caps.supports_op(&DataOperationKind::Insert), caps.write);
        assert_eq!(caps.supports_op(&DataOperationKind::Update), caps.write);
        assert_eq!(caps.supports_op(&DataOperationKind::Delete), caps.write);
        // dedicated flags
        assert_eq!(caps.supports_op(&DataOperationKind::Upsert), caps.upsert);
        assert_eq!(caps.supports_op(&DataOperationKind::Batch), caps.batch);
        assert_eq!(
            caps.supports_op(&DataOperationKind::Aggregate),
            caps.aggregate
        );
    }
}

#[test]
fn route_only_flags_never_leak_into_supports_op() {
    // introspect / schema_ddl / ddl are ROUTE capabilities — flipping them must
    // not change what supports_op (the data-op gate) returns.
    let mut caps = EngineCapabilities::redis(); // batch:true, aggregate:false
    let before: Vec<bool> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    caps.introspect = true;
    caps.schema_ddl = true;
    caps.ddl = true;
    let after: Vec<bool> = DataOperationKind::ALL
        .iter()
        .map(|k| caps.supports_op(k))
        .collect();
    assert_eq!(before, after, "route flags must not affect data-op support");
}

#[test]
fn engine_honesty_matches_documented_surface() {
    // Pin the documented honesty call-outs so a refactor can't quietly lie.
    let http = EngineCapabilities::http();
    assert!(!http.batch && !http.aggregate, "http: no batch/aggregate");
    let redis = EngineCapabilities::redis();
    assert!(
        redis.batch && !redis.aggregate,
        "redis: batch yes, aggregate no"
    );
    let mongo = EngineCapabilities::mongodb();
    assert!(
        !mongo.transactions,
        "mongo honestly reports no transactions"
    );
    assert!(
        mongo.schema_ddl && !mongo.ddl,
        "mongo: validator DDL yes, migrate no"
    );
    let dynamo = EngineCapabilities::dynamodb();
    assert!(
        dynamo.transactions && dynamo.native_idempotency,
        "dynamodb: tx + idempotency"
    );
    assert!(!dynamo.aggregate, "dynamodb: no server-side aggregate");
    assert_eq!(dynamo.max_batch_size, 25, "dynamodb BatchWriteItem limit");
    let crdb = EngineCapabilities::cockroachdb();
    assert!(!crdb.stream, "cockroachdb: no LISTEN/NOTIFY");
    assert_eq!(crdb.isolation_levels, vec![IsolationLevel::Serializable]);
}

// ── IsolationLevel round-trips as a closed snake_case set ───────────────────

#[test]
fn isolation_level_round_trips_and_rejects_unknown() {
    for lvl in [
        IsolationLevel::ReadCommitted,
        IsolationLevel::RepeatableRead,
        IsolationLevel::Serializable,
        IsolationLevel::Snapshot,
    ] {
        let s = serde_json::to_string(&lvl).unwrap();
        let back: IsolationLevel = serde_json::from_str(&s).unwrap();
        assert_eq!(back, lvl);
    }
    for bad in [
        "\"phantom\"",
        "\"Serializable\"",
        "\"read committed\"",
        "42",
        "null",
    ] {
        assert!(
            serde_json::from_str::<IsolationLevel>(bad).is_err(),
            "{bad}"
        );
    }
}

#[test]
fn max_batch_size_is_a_positive_bound_for_batch_engines() {
    // Every engine that advertises batch declares a non-zero ceiling — a zero
    // would mean "batch supported but no item ever fits", an incoherent claim.
    for caps in [
        EngineCapabilities::postgresql(),
        EngineCapabilities::mysql(),
        EngineCapabilities::mongodb(),
        EngineCapabilities::sqlite(),
        EngineCapabilities::redis(),
        EngineCapabilities::dynamodb(),
    ] {
        if caps.batch {
            assert!(
                caps.max_batch_size > 0,
                "batch engine must declare a positive ceiling"
            );
        }
    }
}
