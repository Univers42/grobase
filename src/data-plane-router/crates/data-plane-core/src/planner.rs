/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   planner.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:34:39 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:34:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Capability-aware pre-flight validation (wiki/04-data-plane.md §2, gap G6).
//!
//! The router advertises an [`EngineCapabilities`] descriptor per engine at
//! `/v1/capabilities`, and the SDK is typed against it at compile time. This
//! module makes the **runtime** agree: it rejects an impossible `(engine,
//! operation)` pair with a precise [`DataPlaneError::UnsupportedCapability`]
//! (→ HTTP 400) *before* a connection pool is opened, instead of letting the
//! request fail deep inside an adapter.
//!
//! It is intentionally conservative. Every engine mounted in the Rust router
//! today advertises `read = write = upsert = true`, so this rejects nothing
//! that previously succeeded — it only turns genuinely impossible combinations
//! (e.g. an `upsert` against an engine that advertises `upsert: false`, or a
//! `batch` larger than the engine's `max_batch_size`) into a clean contract
//! error. That keeps the change additive and parity-safe.

use crate::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, EngineCapabilities,
};
use serde_json::Value;

/// The name of the capability flag an operation requires — used only for the
/// error message; the actual gate is [`EngineCapabilities::supports_op`], which
/// is the single source of truth shared with the descriptor.
#[must_use]
pub fn required_capability(kind: &DataOperationKind) -> &'static str {
    match kind {
        DataOperationKind::List | DataOperationKind::Get => "read",
        DataOperationKind::Insert | DataOperationKind::Update | DataOperationKind::Delete => {
            "write"
        }
        DataOperationKind::Upsert => "upsert",
        DataOperationKind::Batch => "batch",
        DataOperationKind::Aggregate => "aggregate",
    }
}

/// Validate an operation against an engine's advertised capabilities.
///
/// Returns `Ok(())` when the engine can serve the operation, or
/// [`DataPlaneError::UnsupportedCapability`] (mapped to HTTP 400 by the server)
/// when it cannot. Pure and side-effect free, so it is cheap to unit-test
/// exhaustively (op × engine) and safe to call on the hot path before dispatch.
pub fn validate_operation(
    op: &DataOperation,
    engine: &str,
    caps: &EngineCapabilities,
) -> DataPlaneResult<()> {
    if !caps.supports_op(&op.op) {
        return Err(DataPlaneError::UnsupportedCapability {
            engine: engine.to_string(),
            capability: required_capability(&op.op).to_string(),
        });
    }

    // A batch must fit the engine's advertised ceiling. We only inspect the
    // payload when it is a JSON array (the batch wire shape); anything else is
    // left for the adapter to interpret.
    if op.op == DataOperationKind::Batch {
        if let Some(Value::Array(items)) = op.data.as_ref() {
            if items.len() as u64 > u64::from(caps.max_batch_size) {
                return Err(DataPlaneError::UnsupportedCapability {
                    engine: engine.to_string(),
                    capability: format!("max_batch_size={}", caps.max_batch_size),
                });
            }
        }
    }

    Ok(())
}

/// Narrow an engine descriptor by a tenant's package capability mask
/// (`capability_overrides`, stamped on the mount from the key-verify response —
/// Phase 4 tiering).
///
/// **NARROWING ONLY**: a flag explicitly set to `false` in the mask removes a
/// capability the engine has; a missing flag, a `true`, or a non-bool value
/// leaves the descriptor untouched — a package can never WIDEN a capability past
/// what the engine actually serves (that would re-introduce capability
/// dishonesty). Unknown keys are ignored. A `None` / non-object override returns
/// the descriptor unchanged — the parity path for an untiered mount.
#[must_use]
pub fn apply_capability_overrides(
    caps: &EngineCapabilities,
    overrides: Option<&Value>,
) -> EngineCapabilities {
    let mut out = caps.clone();
    let Some(Value::Object(mask)) = overrides else {
        return out;
    };
    // Only an explicit `false` narrows; absent / `true` / non-bool keeps current.
    let narrow = |cur: bool, key: &str| {
        matches!(mask.get(key), Some(Value::Bool(false)))
            .then_some(false)
            .unwrap_or(cur)
    };
    out.read = narrow(out.read, "read");
    out.write = narrow(out.write, "write");
    out.upsert = narrow(out.upsert, "upsert");
    out.batch = narrow(out.batch, "batch");
    out.aggregate = narrow(out.aggregate, "aggregate");
    out.transactions = narrow(out.transactions, "transactions");
    out.schema_ddl = narrow(out.schema_ddl, "schema_ddl");
    out.ddl = narrow(out.ddl, "ddl");
    out.introspect = narrow(out.introspect, "introspect");
    out
}

/// Tier gate (Phase 4): the engine descriptor says what the ENGINE can do; the
/// tenant's package mask may narrow it. Returns
/// [`DataPlaneError::CapabilityGated`] (→ 403) when the engine supports the op
/// but the package tier masks it off — DISTINCT from the planner's 422 for an
/// op the engine genuinely can't serve. A no-op when the engine doesn't support
/// the op (that's the planner's 422 to raise) or when there is no mask (parity).
pub fn tier_gate(
    op: &DataOperation,
    caps: &EngineCapabilities,
    overrides: Option<&Value>,
) -> DataPlaneResult<()> {
    let effective = apply_capability_overrides(caps, overrides);
    if caps.supports_op(&op.op) && !effective.supports_op(&op.op) {
        return Err(DataPlaneError::CapabilityGated {
            capability: required_capability(&op.op).to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::operation::DataOperationKind::{
        Aggregate, Batch, Delete, Get, Insert, List, Update, Upsert,
    };
    use serde_json::json;

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

    #[test]
    fn required_capability_mapping_is_stable() {
        assert_eq!(required_capability(&List), "read");
        assert_eq!(required_capability(&Get), "read");
        assert_eq!(required_capability(&Insert), "write");
        assert_eq!(required_capability(&Update), "write");
        assert_eq!(required_capability(&Delete), "write");
        assert_eq!(required_capability(&Batch), "batch");
        assert_eq!(required_capability(&Upsert), "upsert");
        assert_eq!(required_capability(&Aggregate), "aggregate");
    }

    #[test]
    fn aggregate_gated_by_capability() {
        // pg/mysql/mongo serve aggregate; redis/http don't → clean 400, not 501.
        for (name, caps) in [
            ("postgresql", EngineCapabilities::postgresql()),
            ("mysql", EngineCapabilities::mysql()),
            ("mongodb", EngineCapabilities::mongodb()),
        ] {
            assert!(
                validate_operation(&op(Aggregate, None), name, &caps).is_ok(),
                "{name} should serve aggregate"
            );
        }
        for (name, caps) in [
            ("redis", EngineCapabilities::redis()),
            ("http", EngineCapabilities::http()),
        ] {
            let err = validate_operation(&op(Aggregate, None), name, &caps).unwrap_err();
            match err {
                DataPlaneError::UnsupportedCapability { capability, .. } => {
                    assert_eq!(capability, "aggregate", "{name}");
                }
                other => panic!("{name}: expected UnsupportedCapability, got {other:?}"),
            }
        }
    }

    #[test]
    fn batch_gated_by_capability() {
        // pg/mysql/mongo/redis serve batch; http does not (a remote REST
        // passthrough cannot give batch semantics) → clean 400, not 501.
        for (name, caps) in [
            ("postgresql", EngineCapabilities::postgresql()),
            ("mongodb", EngineCapabilities::mongodb()),
            ("mysql", EngineCapabilities::mysql()),
            ("redis", EngineCapabilities::redis()),
        ] {
            assert!(
                validate_operation(&op(Batch, None), name, &caps).is_ok(),
                "{name} should serve batch"
            );
        }
        let err =
            validate_operation(&op(Batch, None), "http", &EngineCapabilities::http()).unwrap_err();
        match err {
            DataPlaneError::UnsupportedCapability { capability, .. } => {
                assert_eq!(capability, "batch");
            }
            other => panic!("http: expected UnsupportedCapability, got {other:?}"),
        }
    }

    #[test]
    fn every_live_engine_serves_full_crud_and_upsert() {
        // The engines actually mounted today all advertise read+write+upsert,
        // so the gate must be a no-op for them (parity invariant).
        let engines = [
            ("postgresql", EngineCapabilities::postgresql()),
            ("mongodb", EngineCapabilities::mongodb()),
            ("mysql", EngineCapabilities::mysql()),
            ("redis", EngineCapabilities::redis()),
            ("http", EngineCapabilities::http()),
        ];
        for (name, caps) in &engines {
            for kind in [List, Get, Insert, Update, Delete, Upsert] {
                let serves = validate_operation(&op(kind.clone(), None), name, caps).is_ok();
                assert!(serves, "{name} should serve {kind:?}");
            }
        }
    }

    #[test]
    fn missing_write_capability_is_rejected() {
        let mut caps = EngineCapabilities::redis();
        caps.write = false;
        let err = validate_operation(&op(Insert, None), "redis", &caps).unwrap_err();
        match err {
            DataPlaneError::UnsupportedCapability { capability, .. } => {
                assert_eq!(capability, "write");
            }
            other => panic!("expected UnsupportedCapability, got {other:?}"),
        }
    }

    #[test]
    fn missing_upsert_capability_is_rejected() {
        let mut caps = EngineCapabilities::postgresql();
        caps.upsert = false;
        let err = validate_operation(&op(Upsert, None), "postgresql", &caps).unwrap_err();
        assert!(matches!(err, DataPlaneError::UnsupportedCapability { .. }));
    }

    #[test]
    fn batch_within_ceiling_is_allowed_over_ceiling_is_rejected() {
        // The ceiling check only applies once an engine actually supports batch.
        let mut caps = EngineCapabilities::redis(); // max_batch_size = 100
        caps.batch = true;
        let within: Vec<Value> = (0..100).map(|i| json!({ "i": i })).collect();
        assert!(validate_operation(&op(Batch, Some(json!(within))), "redis", &caps).is_ok());

        let over: Vec<Value> = (0..101).map(|i| json!({ "i": i })).collect();
        let err = validate_operation(&op(Batch, Some(json!(over))), "redis", &caps).unwrap_err();
        match err {
            DataPlaneError::UnsupportedCapability { capability, .. } => {
                assert!(capability.contains("max_batch_size"));
            }
            other => panic!("expected UnsupportedCapability, got {other:?}"),
        }
    }

    #[test]
    fn non_array_batch_payload_is_left_to_the_adapter() {
        let mut caps = EngineCapabilities::http(); // max_batch_size = 50
        caps.batch = true; // pretend http supports batch, to reach the size check
                           // An object (not an array) is not the batch wire shape; don't reject here.
        assert!(validate_operation(&op(Batch, Some(json!({ "a": 1 }))), "http", &caps).is_ok());
        assert!(validate_operation(&op(Batch, None), "http", &caps).is_ok());
    }

    // ── Phase 4 tiering: capability_overrides narrowing + tier_gate ──────────

    #[test]
    fn overrides_narrow_only_never_widen() {
        // A mask can turn a capability OFF (aggregate true → false) ...
        let pg = EngineCapabilities::postgresql();
        let narrowed = apply_capability_overrides(&pg, Some(&json!({ "aggregate": false })));
        assert!(!narrowed.aggregate, "explicit false narrows");
        assert!(narrowed.read && narrowed.write, "untouched flags survive");
        // ... but can NEVER turn one ON that the engine lacks (http has no batch).
        let http = EngineCapabilities::http();
        let widened = apply_capability_overrides(&http, Some(&json!({ "batch": true })));
        assert!(
            !widened.batch,
            "a mask cannot widen past the engine descriptor"
        );
    }

    #[test]
    fn no_override_is_identity() {
        let pg = EngineCapabilities::postgresql();
        assert_eq!(apply_capability_overrides(&pg, None), pg);
        // A non-object override (e.g. the limits-only payload) is also a no-op.
        assert_eq!(apply_capability_overrides(&pg, Some(&json!(42))), pg);
        assert_eq!(
            apply_capability_overrides(&pg, Some(&json!({ "rps": 20 }))),
            pg
        );
    }

    #[test]
    fn tier_gate_403_when_package_masks_a_supported_op() {
        // Essential tier masks aggregate off; pg serves it → 403 CapabilityGated,
        // NOT the 422 the planner raises when the engine itself can't.
        let pg = EngineCapabilities::postgresql();
        let mask = json!({ "aggregate": false, "batch": false, "transactions": false });
        let err = tier_gate(&op(Aggregate, None), &pg, Some(&mask)).unwrap_err();
        match err {
            DataPlaneError::CapabilityGated { capability } => assert_eq!(capability, "aggregate"),
            other => panic!("expected CapabilityGated, got {other:?}"),
        }
        // batch likewise gated for this tier.
        assert!(matches!(
            tier_gate(&op(Batch, None), &pg, Some(&mask)).unwrap_err(),
            DataPlaneError::CapabilityGated { .. }
        ));
        // CRUD stays allowed under the same mask (narrowing only touches masked keys).
        assert!(tier_gate(&op(Insert, None), &pg, Some(&mask)).is_ok());
        assert!(tier_gate(&op(List, None), &pg, Some(&mask)).is_ok());
    }

    #[test]
    fn tier_gate_noop_without_mask_or_when_engine_already_cant() {
        let pg = EngineCapabilities::postgresql();
        // No mask → never a tier denial (parity path).
        assert!(tier_gate(&op(Aggregate, None), &pg, None).is_ok());
        // Engine genuinely can't (redis has no aggregate): tier_gate stays silent
        // so the planner's 422 is the one that fires, not a misleading 403.
        let redis = EngineCapabilities::redis();
        assert!(tier_gate(
            &op(Aggregate, None),
            &redis,
            Some(&json!({ "aggregate": false }))
        )
        .is_ok());
    }
}
