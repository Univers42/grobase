//! Capability-aware routing (gap G6): descriptive → enforced.
//!
//! The capability descriptor (`EngineCapabilities`) is the single source of
//! truth the planner gates on. [`validate_operation`] (Phase 1, in
//! [`crate::planner`]) already rejects an impossible `(engine, op)` pair —
//! `supports_op` plus the batch ceiling. This module adds **Phase 2**: it reads
//! the *shape* of an operation (does it pattern-search? join? aggregate? want a
//! stream / a transaction?) and routes it by the engine's advertised *cost*
//! capabilities, not by engine name.
//!
//! The cost rules are a `const` table of fn-pointer predicates over
//! [`EngineCapabilities`] — there is **no engine-name literal anywhere in this
//! file**. A rule fires only when the op shape demands a capability; the
//! verdict (`Reject` / `Federate` / `Native`) is derived from the predicate's
//! truth value, never from `if engine == "redis"` spaghetti.
//!
//! Parity-safe by construction: every Phase-2 rule fires only on op shapes no
//! live engine receives today (`$like`/`$ilike`, joins, analytical aggregates,
//! stream/transaction request flags). Plain CRUD has an empty shape, so it
//! always falls through to [`Plan::Native`]. Federation defaults OFF — a
//! `Federate` verdict is lowered to a clean `NotImplemented` until the analytics
//! plane (Trino) is wired (see doc 05). The seam to flip it on is one line.

use crate::capability::{JoinCapability, PatternSearchCapability};
use crate::{DataOperation, DataPlaneError, EngineCapabilities};

/// Where the planner decided an operation should run.
///
/// Not `PartialEq`/`Clone`: the `Reject` arm carries a [`DataPlaneError`]
/// (which is deliberately not `Clone`/`Eq` — its `String` fields would force a
/// brittle structural-equality contract on every error variant). Callers match
/// on the variant; tests use `matches!` plus [`Plan::federation_target`].
#[derive(Debug)]
pub enum Plan {
    /// Execute on the engine's own Rust pool (the only live path today).
    Native,
    /// Forward to a federation target (e.g. the analytics plane). Dormant until
    /// `planner_federation_enabled` — [`resolve_federation`] lowers it to a
    /// clean `NotImplemented` otherwise.
    Federate { target: &'static str },
    /// Refuse the operation with a precise contract error.
    Reject(DataPlaneError),
}

impl Plan {
    /// `Some(target)` iff this is a [`Plan::Federate`]; lets tests assert the
    /// target without a `PartialEq` impl on the error-carrying enum.
    #[must_use]
    pub fn federation_target(&self) -> Option<&'static str> {
        match self {
            Plan::Federate { target } => Some(target),
            _ => None,
        }
    }
}

/// A planning decision plus a static reason string for structured logs.
#[derive(Debug)]
pub struct PlanDecision {
    pub plan: Plan,
    pub reason: &'static str,
}

/// The federation target for join/analytical workloads. A single
/// `&'static str` constant so it appears in exactly one place (not as a literal
/// scattered through the rules). It names a *role* ("analytics"), never a
/// concrete execution or storage engine — the analytics plane (e.g. Trino) is an
/// implementation detail resolved at the federation seam, not in routing.
const ANALYTICS_TARGET: &str = "analytics";

/// The shape of an operation, computed **once** from the op + request context.
/// Pure booleans so the cost evaluator is a branch-free table walk.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpShape {
    /// A `$like`/`$ilike` predicate appears in the filter tree.
    pub requires_pattern_search: bool,
    /// The op joins across resources. Latent: `DataOperation` has no join field
    /// yet, so this is always `false` today (the rule is present but dormant).
    pub requires_joins: bool,
    /// A grouped aggregate (`Aggregate` with `group_by`) — an analytical shape.
    pub is_analytical: bool,
    /// The caller requested a change-stream. Modelled as a request flag, NOT a
    /// `DataOperationKind` variant (a `Stream` variant would break the
    /// exhaustive capability-honesty check).
    pub requires_stream: bool,
    /// The caller wants this op inside a transaction.
    pub requires_transaction: bool,
}

/// Request-level routing hints that aren't part of the operation itself
/// (parsed from headers / the transaction context by the server). Kept separate
/// so [`OpShape`] derivation stays pure and testable.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkloadContext {
    /// Caller asked for a change-stream / replication feed.
    pub stream_requested: bool,
    /// Op is being executed inside an open transaction session.
    pub in_transaction: bool,
}

impl OpShape {
    /// Derive the shape from the op + context. Walks the filter JSON once for a
    /// `$like`/`$ilike` operator (cheap, depth-bounded by the parser's own
    /// limits) and reads the aggregate spec for a `group_by`.
    #[must_use]
    pub fn of(op: &DataOperation, ctx: &WorkloadContext) -> Self {
        Self {
            requires_pattern_search: op
                .filter
                .as_ref()
                .map(filter_has_pattern_search)
                .unwrap_or(false),
            // No join field on DataOperation yet — dormant by construction.
            requires_joins: false,
            is_analytical: op
                .aggregate
                .as_ref()
                .map(|a| !a.group_by.is_empty())
                .unwrap_or(false),
            requires_stream: ctx.stream_requested,
            requires_transaction: ctx.in_transaction,
        }
    }
}

/// True when the (already-validated) filter JSON uses `$like`/`$ilike` anywhere.
/// Operates on the raw wire JSON so it needs no second parse; the grammar is the
/// one enforced by [`crate::filter::Filter::parse`].
fn filter_has_pattern_search(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Object(map) => map.iter().any(|(k, v)| {
            k == "$like" || k == "$ilike" || filter_has_pattern_search(v)
        }),
        serde_json::Value::Array(items) => items.iter().any(filter_has_pattern_search),
        _ => false,
    }
}

/// Which shape requirement a [`CostRule`] guards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShapeReq {
    Stream,
    Transaction,
    PatternSearch,
    JoinOrAnalytical,
}

impl ShapeReq {
    /// Whether this requirement is active for the given op shape.
    #[inline]
    fn active(self, shape: &OpShape) -> bool {
        match self {
            ShapeReq::Stream => shape.requires_stream,
            ShapeReq::Transaction => shape.requires_transaction,
            ShapeReq::PatternSearch => shape.requires_pattern_search,
            ShapeReq::JoinOrAnalytical => shape.requires_joins || shape.is_analytical,
        }
    }
}

/// What to do when a rule's requirement is active but the engine can't satisfy
/// it on its own pool.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Verdict {
    /// Refuse with `UnsupportedCapability` for this capability name.
    Reject(&'static str),
    /// Forward to the analytics plane (subject to the federation flag).
    Federate,
    /// Engine can do it remotely / via scan — try to federate, else reject.
    FederateOrReject(&'static str),
}

/// One cost rule: when `needs` is active for the op shape, the engine must be
/// `satisfied_by` its capabilities; otherwise apply `on_unsatisfied`. A `const`
/// fn-pointer table — no engine names, only predicates over capabilities.
struct CostRule {
    needs: ShapeReq,
    satisfied_by: fn(&EngineCapabilities) -> bool,
    on_unsatisfied: Verdict,
    /// For a `FederateOrReject` verdict: the per-rule predicate deciding whether
    /// the engine is *remote-capable* (→ federate) versus genuinely incapable
    /// (→ reject). Keeps the generic `verdict_to_plan` from reading any specific
    /// capability by name — each rule supplies its own remote-capable test (the
    /// pattern-search rule consults `cost.pattern_search == Remote`). Unused by
    /// `Reject`/`Federate` verdicts (set to the const `never_federates`).
    can_federate: fn(&EngineCapabilities) -> bool,
    /// Static reason for logs when this rule decides the outcome.
    reason: &'static str,
}

/// Default `can_federate` predicate for rules whose verdict is not
/// `FederateOrReject` (the field is never consulted in those cases).
fn never_federates(_caps: &EngineCapabilities) -> bool {
    false
}

/// The cost policy: a fixed, ordered slice of rules evaluated in priority order.
/// Hard requirements (stream, transaction) first — they `Reject` outright;
/// cost-class requirements (pattern-search, join/analytical) after, since they
/// can fall back to federation. Plain CRUD matches no rule → `Native`.
const COST_POLICY: &[CostRule] = &[
    CostRule {
        needs: ShapeReq::Stream,
        satisfied_by: |c| c.stream,
        on_unsatisfied: Verdict::Reject("stream"),
        // Dormant until a workload header wires `stream_requested` (S2) — no live
        // request sets this flag today, so this rule is reachable but never fires.
        can_federate: never_federates,
        reason: "stream_requested_but_engine_lacks_stream",
    },
    CostRule {
        needs: ShapeReq::Transaction,
        satisfied_by: |c| c.transactions,
        on_unsatisfied: Verdict::Reject("transactions"),
        // Dormant until a workload header wires `in_transaction` (S2) — reachable
        // once the transaction session context is threaded, never fires today.
        can_federate: never_federates,
        reason: "transaction_requested_but_engine_lacks_transactions",
    },
    CostRule {
        needs: ShapeReq::PatternSearch,
        // Any pattern-search class except `None` can serve it locally (Native,
        // Indexed, Limited, Scan). `Remote` engines federate; `None` rejects.
        satisfied_by: |c| {
            !matches!(c.cost.pattern_search, PatternSearchCapability::None)
                && !matches!(c.cost.pattern_search, PatternSearchCapability::Remote)
        },
        on_unsatisfied: Verdict::FederateOrReject("pattern_search"),
        // Remote-capable iff the engine's pattern-search class is `Remote`. The
        // predicate lives with the rule, so the generic `verdict_to_plan` never
        // reads a specific capability by name (a future `FederateOrReject("joins")`
        // rule would supply its own join-remote test instead).
        can_federate: |c| matches!(c.cost.pattern_search, PatternSearchCapability::Remote),
        reason: "pattern_search_routed_by_cost",
    },
    CostRule {
        needs: ShapeReq::JoinOrAnalytical,
        // Local execution needs a real join capability; otherwise push the
        // analytical/join workload to the analytics plane.
        satisfied_by: |c| !matches!(c.cost.joins, JoinCapability::None),
        on_unsatisfied: Verdict::Federate,
        can_federate: never_federates,
        reason: "join_or_analytical_routed_by_cost",
    },
];

/// Resolve a `Verdict` whose requirement is active and unsatisfied into a
/// concrete [`Plan`]. `FederateOrReject` distinguishes a remote-capable engine
/// (can federate) from one that simply can't (→ reject) using the rule's own
/// `can_federate` predicate — never a capability read by name here. `engine` is
/// threaded into the reject error so the client message names the real engine
/// (N1: no more "(planned)" placeholder).
fn verdict_to_plan(
    verdict: Verdict,
    engine: &str,
    caps: &EngineCapabilities,
    can_federate: fn(&EngineCapabilities) -> bool,
) -> Plan {
    match verdict {
        Verdict::Reject(cap) => Plan::Reject(DataPlaneError::UnsupportedCapability {
            engine: engine.to_string(),
            capability: cap.to_string(),
        }),
        Verdict::Federate => Plan::Federate { target: ANALYTICS_TARGET },
        Verdict::FederateOrReject(cap) => {
            // A remote-capable engine can be federated; a genuinely incapable one
            // is rejected. The "remote-capable" test is supplied by the rule
            // (`can_federate`), so this generic helper stays capability-agnostic.
            if can_federate(caps) {
                Plan::Federate { target: ANALYTICS_TARGET }
            } else {
                Plan::Reject(DataPlaneError::UnsupportedCapability {
                    engine: engine.to_string(),
                    capability: cap.to_string(),
                })
            }
        }
    }
}

/// Plan an operation against an engine's capabilities + the request context.
///
/// Two phases:
/// 1. **Phase 1 — feasibility.** Reuse [`crate::validate_operation`]
///    (`supports_op` + batch ceiling). A failure is an immediate `Reject`.
/// 2. **Phase 2 — cost routing.** Compute the [`OpShape`] once, then walk the
///    `const` [`COST_POLICY`]: the first active+unsatisfied rule decides the
///    plan. No rule fires for plain CRUD → `Native`.
///
/// `Federate` verdicts are lowered by [`resolve_federation`] (federation OFF by
/// default), so today every reachable outcome is `Native` or `Reject`.
#[must_use]
pub fn plan(
    op: &DataOperation,
    engine: &str,
    caps: &EngineCapabilities,
    ctx: &WorkloadContext,
    federation_enabled: bool,
) -> PlanDecision {
    // Phase 1: feasibility (single source of truth: supports_op + ceiling).
    if let Err(err) = crate::validate_operation(op, engine, caps) {
        return PlanDecision { plan: Plan::Reject(err), reason: "phase1_unsupported_capability" };
    }

    // Phase 2: cost routing over the const rule table.
    let shape = OpShape::of(op, ctx);
    for rule in COST_POLICY {
        if rule.needs.active(&shape) && !(rule.satisfied_by)(caps) {
            let verdict = verdict_to_plan(rule.on_unsatisfied, engine, caps, rule.can_federate);
            let plan = resolve_federation(verdict, federation_enabled);
            return PlanDecision { plan, reason: rule.reason };
        }
    }

    PlanDecision { plan: Plan::Native, reason: "native" }
}

/// Federation seam. While `planner_federation_enabled` is false (the default), a
/// `Federate` plan is lowered to a clean `NotImplemented` — we never silently
/// "succeed" a workload we can't run. Flip the flag (once Trino is wired) to let
/// `Federate` pass through. One-line seam by design.
#[must_use]
pub fn resolve_federation(plan: Plan, federation_enabled: bool) -> Plan {
    match plan {
        Plan::Federate { .. } if !federation_enabled => Plan::Reject(DataPlaneError::NotImplemented {
            feature: "federation: needs analytics plane (Trino) — see doc 05".to_string(),
        }),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::operation::DataOperationKind;
    use crate::{Aggregate, AggFunc, AggregateSpec};
    use serde_json::{json, Value};

    fn op(kind: DataOperationKind, filter: Option<Value>) -> DataOperation {
        DataOperation {
            op: kind,
            resource: "things".to_string(),
            data: None,
            filter,
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

    fn grouped_aggregate() -> DataOperation {
        let mut o = op(DataOperationKind::Aggregate, None);
        o.aggregate = Some(AggregateSpec {
            group_by: vec!["category".to_string()],
            aggregates: vec![Aggregate {
                func: AggFunc::Count,
                field: None,
                distinct: false,
                alias: "n".to_string(),
            }],
        });
        o
    }

    const NO_CTX: WorkloadContext = WorkloadContext { stream_requested: false, in_transaction: false };
    const STREAM_CTX: WorkloadContext = WorkloadContext { stream_requested: true, in_transaction: false };
    const TX_CTX: WorkloadContext = WorkloadContext { stream_requested: false, in_transaction: true };

    fn engines() -> [(&'static str, EngineCapabilities); 5] {
        [
            ("postgresql", EngineCapabilities::postgresql()),
            ("mongodb", EngineCapabilities::mongodb()),
            ("mysql", EngineCapabilities::mysql()),
            ("redis", EngineCapabilities::redis()),
            ("http", EngineCapabilities::http()),
        ]
    }

    // ── Parity: every live engine, every CRUD/upsert op, plain shape = Native ──
    #[test]
    fn every_live_engine_crud_is_native() {
        use DataOperationKind::{Delete, Get, Insert, List, Update, Upsert};
        for (name, caps) in engines() {
            for kind in [List, Get, Insert, Update, Delete, Upsert] {
                let d = plan(&op(kind.clone(), None), name, &caps, &NO_CTX, false);
                assert!(matches!(d.plan, Plan::Native), "{name} {kind:?} must stay Native");
            }
        }
    }

    // ── Phase 1 still rejects an impossible (engine, op) pair (422 upstream). ──
    #[test]
    fn phase1_rejects_unsupported_op() {
        // http is the one engine without batch (a remote REST passthrough has
        // no batch semantics) → Phase-1 Reject(UnsupportedCapability).
        let d = plan(
            &op(DataOperationKind::Batch, None),
            "http",
            &EngineCapabilities::http(),
            &NO_CTX,
            false,
        );
        assert!(
            matches!(d.plan, Plan::Reject(DataPlaneError::UnsupportedCapability { .. })),
            "http batch must Phase-1 reject"
        );
        // Engines that DO advertise batch pass Phase 1.
        for (name, caps) in engines() {
            if name == "http" {
                continue;
            }
            let d = plan(&op(DataOperationKind::Batch, None), name, &caps, &NO_CTX, false);
            assert!(
                !matches!(d.plan, Plan::Reject(_)),
                "{name} batch must pass Phase 1"
            );
        }
    }

    // ── stream → engine without stream = Reject("stream"). ────────────────────
    #[test]
    fn stream_on_non_streaming_engine_rejects() {
        // redis advertises stream:false.
        let d = plan(&op(DataOperationKind::List, None), "redis", &EngineCapabilities::redis(), &STREAM_CTX, false);
        match d.plan {
            Plan::Reject(DataPlaneError::UnsupportedCapability { engine, capability }) => {
                assert_eq!(capability, "stream");
                // N1: the Phase-2 reject names the real engine, not "(planned)".
                assert_eq!(engine, "redis");
            }
            other => panic!("expected stream reject, got {other:?}"),
        }
        // postgres advertises stream:true → not rejected for the stream reason.
        let d = plan(&op(DataOperationKind::List, None), "postgresql", &EngineCapabilities::postgresql(), &STREAM_CTX, false);
        assert!(matches!(d.plan, Plan::Native));
    }

    // ── transaction → engine without transactions = Reject("transactions"). ───
    #[test]
    fn transaction_on_non_txn_engine_rejects() {
        // redis: transactions:false.
        let d = plan(&op(DataOperationKind::Insert, None), "redis", &EngineCapabilities::redis(), &TX_CTX, false);
        match d.plan {
            Plan::Reject(DataPlaneError::UnsupportedCapability { capability, .. }) => {
                assert_eq!(capability, "transactions");
            }
            other => panic!("expected transactions reject, got {other:?}"),
        }
        // postgres: transactions:true.
        let d = plan(&op(DataOperationKind::Insert, None), "postgresql", &EngineCapabilities::postgresql(), &TX_CTX, false);
        assert!(matches!(d.plan, Plan::Native));
    }

    // ── $like → redis (Scan) = Native (can serve locally). ────────────────────
    #[test]
    fn pattern_search_on_scan_engine_is_native() {
        let f = json!({ "name": { "$like": "ab%" } });
        let d = plan(&op(DataOperationKind::List, Some(f)), "redis", &EngineCapabilities::redis(), &NO_CTX, false);
        assert!(matches!(d.plan, Plan::Native), "redis Scan serves $like locally");
    }

    // ── $like → http (Remote) = Federate, which (OFF) lowers to NotImplemented. ─
    #[test]
    fn pattern_search_on_remote_engine_federates_then_rejects() {
        let f = json!({ "name": { "$ilike": "ab%" } });
        // Federation OFF (default): Federate is lowered to NotImplemented.
        let d = plan(&op(DataOperationKind::List, Some(f.clone())), "http", &EngineCapabilities::http(), &NO_CTX, false);
        assert!(
            matches!(d.plan, Plan::Reject(DataPlaneError::NotImplemented { .. })),
            "http $like federates → NotImplemented while OFF, got {:?}",
            d.plan
        );
        // Federation ON: the same op resolves to Federate{analytics} (a role
        // token, not a concrete engine name).
        let d = plan(&op(DataOperationKind::List, Some(f)), "http", &EngineCapabilities::http(), &NO_CTX, true);
        assert_eq!(d.plan.federation_target(), Some("analytics"));
    }

    // ── analytical group_by → KV (joins:None) = Federate → reject while OFF. ───
    #[test]
    fn analytical_on_kv_engine_federates_then_rejects() {
        // redis advertises aggregate:false → Phase 1 would reject first. Use a
        // synthetic engine that supports aggregate but has no joins (joins:None)
        // to exercise the Phase-2 analytical rule in isolation.
        let mut caps = EngineCapabilities::redis();
        caps.aggregate = true; // let it pass Phase 1
        let d = plan(&grouped_aggregate(), "redis", &caps, &NO_CTX, false);
        assert!(
            matches!(d.plan, Plan::Reject(DataPlaneError::NotImplemented { .. })),
            "KV analytical federates → NotImplemented while OFF, got {:?}",
            d.plan
        );
        // With joins capability (postgres), an analytical aggregate stays Native.
        let d = plan(&grouped_aggregate(), "postgresql", &EngineCapabilities::postgresql(), &NO_CTX, false);
        assert!(matches!(d.plan, Plan::Native), "postgres serves analytical locally");
    }

    // ── nested $like in $and/$or is detected. ─────────────────────────────────
    #[test]
    fn nested_pattern_search_detected() {
        let f = json!({ "$or": [{ "a": 1 }, { "b": { "$like": "x%" } }] });
        assert!(filter_has_pattern_search(&f));
        let f2 = json!({ "$and": [{ "a": { "$gt": 1 } }, { "c": 2 }] });
        assert!(!filter_has_pattern_search(&f2));
    }

    // ── federation seam: only Federate is lowered; Native/Reject pass through. ─
    #[test]
    fn resolve_federation_only_lowers_federate() {
        assert!(matches!(resolve_federation(Plan::Native, false), Plan::Native));
        assert!(matches!(
            resolve_federation(Plan::Federate { target: "analytics" }, false),
            Plan::Reject(DataPlaneError::NotImplemented { .. })
        ));
        assert_eq!(
            resolve_federation(Plan::Federate { target: "analytics" }, true).federation_target(),
            Some("analytics")
        );
    }
}
