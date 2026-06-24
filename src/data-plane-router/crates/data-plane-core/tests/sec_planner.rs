/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sec_planner.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:35:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:35:13 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Security: capability-aware pre-flight gating. `required_capability` must map
//! every op kind to its flag; `validate_operation` must REJECT an op the engine
//! cannot serve (and oversize batches); `tier_gate` must DENY when the tenant's
//! package mask narrows away a supported op and ALLOW otherwise;
//! `apply_capability_overrides` is narrowing-only (never widens) and an absent
//! mask is exact parity.

use data_plane_core::{
    apply_capability_overrides, required_capability, tier_gate, validate_operation, DataOperation,
    DataOperationKind, DataPlaneError, EngineCapabilities,
};
use serde_json::{json, Value};

fn op(kind: DataOperationKind, data: Option<Value>) -> DataOperation {
    DataOperation {
        op: kind,
        resource: "things".to_string(),
        data,
        filter: None,
        sort: None,
        limit: None,
        offset: None,
        idempotency_key: None,
        expected_version: None,
        returning: None,
        aggregate: None,
        fields: None,
        search: None,
        vector: None,
    }
}

fn all_engines() -> Vec<(&'static str, EngineCapabilities)> {
    vec![
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
    ]
}

// ── required_capability: stable, total mapping over every op kind ───────────

#[test]
fn required_capability_covers_every_op_kind() {
    use DataOperationKind::*;
    let expected = [
        (List, "read"),
        (Get, "read"),
        (Insert, "write"),
        (Update, "write"),
        (Delete, "write"),
        (Upsert, "upsert"),
        (Batch, "batch"),
        (Aggregate, "aggregate"),
    ];
    // Hit every variant of DataOperationKind::ALL exactly once.
    assert_eq!(expected.len(), DataOperationKind::ALL.len());
    for (kind, cap) in expected {
        assert_eq!(required_capability(&kind), cap, "{kind:?}");
    }
}

// ── validate_operation gating is exactly EngineCapabilities::supports_op ────

#[test]
fn validate_operation_agrees_with_supports_op_for_every_engine_and_op() {
    for (name, caps) in all_engines() {
        for kind in DataOperationKind::ALL {
            let supported = caps.supports_op(&kind);
            let result = validate_operation(&op(kind.clone(), None), name, &caps);
            assert_eq!(
                result.is_ok(),
                supported,
                "{name}/{kind:?}: validate_operation must mirror supports_op ({supported})"
            );
            if !supported {
                match result.unwrap_err() {
                    DataPlaneError::UnsupportedCapability { engine, capability } => {
                        assert_eq!(engine, name);
                        assert_eq!(capability, required_capability(&kind));
                    }
                    other => {
                        panic!("{name}/{kind:?}: expected UnsupportedCapability, got {other:?}")
                    }
                }
            }
        }
    }
}

#[test]
fn engines_without_aggregate_reject_aggregate() {
    for (name, caps) in all_engines() {
        if !caps.aggregate {
            let err = validate_operation(&op(DataOperationKind::Aggregate, None), name, &caps)
                .unwrap_err();
            assert!(
                matches!(err, DataPlaneError::UnsupportedCapability { ref capability, .. } if capability == "aggregate"),
                "{name}: aggregate must be rejected"
            );
        }
    }
}

#[test]
fn http_rejects_batch_redis_and_kv_handle_it() {
    // http honestly cannot batch.
    let err = validate_operation(
        &op(DataOperationKind::Batch, None),
        "http",
        &EngineCapabilities::http(),
    )
    .unwrap_err();
    assert!(matches!(err, DataPlaneError::UnsupportedCapability { .. }));
}

// ── batch ceiling enforcement ───────────────────────────────────────────────

#[test]
fn batch_over_engine_ceiling_is_rejected_at_boundary() {
    // redis ceiling = 100; dynamodb = 25. Test the exact boundary on each.
    for (name, caps, ceiling) in [
        ("redis", EngineCapabilities::redis(), 100usize),
        ("dynamodb", EngineCapabilities::dynamodb(), 25usize),
    ] {
        // at the ceiling: allowed
        let at: Vec<Value> = (0..ceiling).map(|i| json!({ "i": i })).collect();
        assert!(
            validate_operation(&op(DataOperationKind::Batch, Some(json!(at))), name, &caps).is_ok(),
            "{name}: batch of exactly {ceiling} is allowed"
        );
        // one over: rejected with a max_batch_size message
        let over: Vec<Value> = (0..=ceiling).map(|i| json!({ "i": i })).collect();
        let err = validate_operation(
            &op(DataOperationKind::Batch, Some(json!(over))),
            name,
            &caps,
        )
        .unwrap_err();
        match err {
            DataPlaneError::UnsupportedCapability { capability, .. } => {
                assert!(
                    capability.contains("max_batch_size"),
                    "{name}: {capability}"
                );
            }
            other => panic!("{name}: expected UnsupportedCapability, got {other:?}"),
        }
    }
}

#[test]
fn non_array_batch_payload_is_left_to_adapter() {
    let mut caps = EngineCapabilities::http();
    caps.batch = true; // pretend it batches, to reach the size check
    for data in [
        Some(json!({ "a": 1 })),
        Some(json!("string")),
        Some(json!(5)),
        None,
    ] {
        assert!(
            validate_operation(&op(DataOperationKind::Batch, data.clone()), "http", &caps).is_ok(),
            "non-array batch payload {data:?} is left to the adapter, not rejected here"
        );
    }
}

#[test]
fn empty_batch_is_within_any_ceiling() {
    let caps = EngineCapabilities::dynamodb(); // ceiling 25
    assert!(validate_operation(
        &op(DataOperationKind::Batch, Some(json!([]))),
        "dynamodb",
        &caps
    )
    .is_ok());
}

// ── apply_capability_overrides: narrowing-only, parity for absent mask ──────

#[test]
fn no_mask_is_exact_parity_for_every_engine() {
    for (_name, caps) in all_engines() {
        assert_eq!(
            apply_capability_overrides(&caps, None),
            caps,
            "None mask = identity"
        );
        // Non-object masks are also a no-op.
        for nonobj in [
            json!(42),
            json!("x"),
            json!([1, 2]),
            json!(true),
            json!(null),
        ] {
            assert_eq!(
                apply_capability_overrides(&caps, Some(&nonobj)),
                caps,
                "non-object mask {nonobj:?} = identity"
            );
        }
        // A limits-only mask (rps/burst/max_rows) doesn't touch capabilities.
        assert_eq!(
            apply_capability_overrides(&caps, Some(&json!({ "rps": 20, "max_rows": 1000 }))),
            caps
        );
    }
}

#[test]
fn explicit_false_narrows_each_flag_individually() {
    let pg = EngineCapabilities::postgresql();
    let flags = [
        "read",
        "write",
        "upsert",
        "batch",
        "aggregate",
        "transactions",
        "schema_ddl",
        "ddl",
        "introspect",
    ];
    for flag in flags {
        let narrowed = apply_capability_overrides(&pg, Some(&json!({ flag: false })));
        // The masked flag must be off; all OTHER flags unchanged from pg.
        let read = if flag == "read" { false } else { pg.read };
        let write = if flag == "write" { false } else { pg.write };
        assert_eq!(narrowed.read, read, "{flag}->read");
        assert_eq!(narrowed.write, write, "{flag}->write");
        // The targeted flag is definitely false.
        let got = match flag {
            "read" => narrowed.read,
            "write" => narrowed.write,
            "upsert" => narrowed.upsert,
            "batch" => narrowed.batch,
            "aggregate" => narrowed.aggregate,
            "transactions" => narrowed.transactions,
            "schema_ddl" => narrowed.schema_ddl,
            "ddl" => narrowed.ddl,
            "introspect" => narrowed.introspect,
            _ => unreachable!(),
        };
        assert!(!got, "{flag} must be narrowed off");
    }
}

#[test]
fn mask_can_never_widen_a_capability_the_engine_lacks() {
    // http lacks batch/aggregate; a mask setting them true must NOT enable them.
    let http = EngineCapabilities::http();
    let widened = apply_capability_overrides(
        &http,
        Some(&json!({ "batch": true, "aggregate": true, "transactions": true })),
    );
    assert!(!widened.batch, "mask cannot widen batch past the engine");
    assert!(!widened.aggregate, "mask cannot widen aggregate");
    assert!(!widened.transactions, "mask cannot widen transactions");
    // redis lacks aggregate; same.
    let redis = EngineCapabilities::redis();
    assert!(!apply_capability_overrides(&redis, Some(&json!({ "aggregate": true }))).aggregate);
}

#[test]
fn non_bool_or_true_mask_values_are_ignored() {
    let pg = EngineCapabilities::postgresql();
    // `true`, numbers, strings, null — none narrow (only explicit false does).
    for v in [json!(true), json!(1), json!("false"), json!(null), json!(0)] {
        let out = apply_capability_overrides(&pg, Some(&json!({ "aggregate": v })));
        assert!(out.aggregate, "aggregate stays on for mask value {v:?}");
    }
}

// ── tier_gate: 403 when tier masks a supported op; no-op otherwise ──────────

#[test]
fn tier_gate_denies_masked_supported_ops() {
    let pg = EngineCapabilities::postgresql();
    // A tier that masks aggregate+batch+transactions off.
    let mask = json!({ "aggregate": false, "batch": false, "transactions": false });
    for kind in [DataOperationKind::Aggregate, DataOperationKind::Batch] {
        let err = tier_gate(&op(kind.clone(), None), &pg, Some(&mask)).unwrap_err();
        match err {
            DataPlaneError::CapabilityGated { capability } => {
                assert_eq!(capability, required_capability(&kind), "{kind:?}");
            }
            other => panic!("{kind:?}: expected CapabilityGated, got {other:?}"),
        }
    }
    // CRUD still allowed under the same mask (only masked keys are affected).
    for kind in [
        DataOperationKind::List,
        DataOperationKind::Get,
        DataOperationKind::Insert,
        DataOperationKind::Update,
        DataOperationKind::Delete,
        DataOperationKind::Upsert,
    ] {
        assert!(
            tier_gate(&op(kind.clone(), None), &pg, Some(&mask)).is_ok(),
            "{kind:?}"
        );
    }
}

#[test]
fn tier_gate_is_noop_without_mask() {
    let pg = EngineCapabilities::postgresql();
    for kind in DataOperationKind::ALL {
        // No mask → never a tier denial (parity), regardless of op support.
        assert!(
            tier_gate(&op(kind.clone(), None), &pg, None).is_ok(),
            "{kind:?}"
        );
    }
}

#[test]
fn tier_gate_silent_when_engine_itself_cannot_serve() {
    // redis has no aggregate; tier_gate must stay silent so the planner's 422
    // (UnsupportedCapability) fires instead of a misleading 403.
    let redis = EngineCapabilities::redis();
    assert!(
        tier_gate(
            &op(DataOperationKind::Aggregate, None),
            &redis,
            Some(&json!({ "aggregate": false }))
        )
        .is_ok(),
        "no 403 for an op the engine genuinely can't serve"
    );
}

#[test]
fn tier_gate_denies_read_or_write_when_masked() {
    // A read-only tier masks write/upsert; a no-write tier denies mutation.
    let pg = EngineCapabilities::postgresql();
    let read_only = json!({ "write": false, "upsert": false });
    for kind in [
        DataOperationKind::Insert,
        DataOperationKind::Update,
        DataOperationKind::Delete,
    ] {
        assert!(
            matches!(
                tier_gate(&op(kind.clone(), None), &pg, Some(&read_only)).unwrap_err(),
                DataPlaneError::CapabilityGated { ref capability } if capability == "write"
            ),
            "{kind:?} must be gated to 403 under a read-only tier"
        );
    }
    assert!(matches!(
        tier_gate(&op(DataOperationKind::Upsert, None), &pg, Some(&read_only)).unwrap_err(),
        DataPlaneError::CapabilityGated { .. }
    ));
    // Reads still allowed.
    assert!(tier_gate(&op(DataOperationKind::List, None), &pg, Some(&read_only)).is_ok());
    assert!(tier_gate(&op(DataOperationKind::Get, None), &pg, Some(&read_only)).is_ok());
}
