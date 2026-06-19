//! Tenant-scoped filter/document builders and the NoSQL-injection allowlists.
//!
//! Pure (no DB): every read intersects the client filter with the
//! server-trusted owner/tenant scope ([`build_tenant_filter`]); every write
//! strips reserved fields and re-injects the trusted ones ([`build_owned_doc`]).
//! The operator allowlists ([`reject_unsafe_operators`]/
//! [`reject_top_level_operators`]) close the injection surface before any value
//! reaches `bson::to_document`.
//
// ponytail: file >300 lines is co-located unit tests (~245 lines of code, the
//   rest is the injection/owner-scope test matrix kept next to what it pins).
//   Implementation stays under the limit; split tests out only if it grows.

use bson::{doc, Bson, Document};
use data_plane_core::{AggFunc, Aggregate, DataPlaneError, DataPlaneResult, RequestIdentity};
use serde_json::Value;

use super::convert::json_to_doc;
use super::pool::MongoPool;

/// Fields the server controls — strip from any client payload before write,
/// re-inject from the verified identity. Prevents tenant escape via document
/// shape (the equivalent of SQL injection for document stores).
const RESERVED_FIELDS: [&str; 3] = ["_id", "owner_id", "tenant_id"];

/// Trust fields enforced on FILTERS. `_id` is deliberately NOT here: it is the
/// row selector, not a trust field — stripping it turned every by-pk
/// get/update/delete into an all-owned-documents `update_many`/`delete_many`
/// (a single cell edit in the live UI would overwrite the whole collection).
const FILTER_TRUST_FIELDS: [&str; 2] = ["owner_id", "tenant_id"];

/// MongoDB query operators that are safe to accept from an untrusted client
/// filter — comparison, logical, element and array operators only. This is a
/// **default-deny allowlist**: any `$`-prefixed key not in this set is rejected,
/// which closes the NoSQL-injection surface of the raw `bson::to_document`
/// passthrough — notably the evaluation operators `$where`/`$expr`/`$function`/
/// `$accumulator`/`$jsonSchema` that can execute server-side JavaScript or run
/// arbitrary expressions. (`$regex` is permitted as the standard pattern-search
/// operator; bounding its ReDoS cost is tracked with the shared-Filter follow-up.)
const SAFE_MONGO_OPERATORS: &[&str] = &[
    "$eq",
    "$ne",
    "$gt",
    "$gte",
    "$lt",
    "$lte",
    "$in",
    "$nin",
    "$and",
    "$or",
    "$nor",
    "$not",
    "$exists",
    "$type",
    "$regex",
    "$options",
    "$all",
    "$elemMatch",
    "$size",
    "$mod",
    "$bitsAllSet",
    "$bitsAnySet",
    "$bitsAllClear",
    "$bitsAnyClear",
];

/// Rejects a write `data` document whose top-level keys include a `$`-prefixed
/// name. Such names are never valid stored field names (Mongo rejects them under
/// `$set` with a server error), so this turns a would-be 502 into a clean 400 —
/// keeping the write path symmetric with the filter allowlist. Dotted
/// (nested-path) keys are intentionally allowed: they are legitimate nested
/// updates and cannot escape tenancy (the trust fields are re-injected at the
/// top level).
fn reject_top_level_operators(data: &Value) -> DataPlaneResult<()> {
    if let Value::Object(map) = data {
        for key in map.keys() {
            if key.starts_with('$') {
                return Err(DataPlaneError::InvalidRequest {
                    message: format!("write data must not contain operator key '{key}'"),
                });
            }
        }
    }
    Ok(())
}

/// Recursively rejects any `$`-prefixed key in a client filter that is not in
/// [`SAFE_MONGO_OPERATORS`]. Walked before the filter is handed to
/// `bson::to_document`, so a `$where`/`$expr`/`$function` injection never reaches
/// the driver. Field names (non-`$` keys) are unrestricted — the danger is the
/// operators, and the trust fields are re-injected after this check.
fn reject_unsafe_operators(value: &Value) -> DataPlaneResult<()> {
    match value {
        Value::Object(map) => {
            for (key, val) in map {
                if key.starts_with('$') && !SAFE_MONGO_OPERATORS.contains(&key.as_str()) {
                    return Err(DataPlaneError::InvalidRequest {
                        message: format!("filter operator '{key}' is not permitted"),
                    });
                }
                reject_unsafe_operators(val)?;
            }
            Ok(())
        }
        Value::Array(items) => {
            for item in items {
                reject_unsafe_operators(item)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// Strip server-controlled fields from a client payload, then re-inject the
/// trusted values so the wire document is always tenant-scoped.
pub(super) fn build_owned_doc(
    data: &Value,
    identity: &RequestIdentity,
    tenant_id: &str,
) -> DataPlaneResult<Document> {
    reject_top_level_operators(data)?;
    let mut doc = json_to_doc(data)?;
    for field in RESERVED_FIELDS {
        doc.remove(field);
    }
    doc.insert("owner_id", MongoPool::owner(identity));
    doc.insert("tenant_id", tenant_id.to_string());
    Ok(doc)
}

/// No-full-collection guard for update/delete — parity with the relational
/// pools' "refusing full-table update" rule. The injected owner/tenant scope
/// is NOT row selectivity: without it, `filter: {}` rewrites every owned
/// document in one call. The filter must constrain on at least one field the
/// CLIENT chose (trust fields are stripped before querying, so they don't
/// count).
pub(super) fn require_row_filter(filter: Option<&Value>, op_name: &str) -> DataPlaneResult<()> {
    let selective = filter.and_then(Value::as_object).is_some_and(|map| {
        map.keys()
            .any(|key| !FILTER_TRUST_FIELDS.contains(&key.as_str()))
    });
    if selective {
        return Ok(());
    }
    Err(DataPlaneError::InvalidRequest {
        message: format!(
            "{op_name} requires a non-empty `filter` (refusing full-collection {op_name})"
        ),
    })
}

/// Take the client filter (if any) and intersect it with the server-side
/// tenant scope so an attacker cannot drop the predicate.
/// Validates a client-supplied aggregate key (group column, field, alias)
/// before it becomes a BSON document KEY or a `$`-path: no `$` prefix (would
/// be parsed as an operator), no dots (would address a nested path), no NUL.
pub(super) fn safe_agg_key(name: &str) -> DataPlaneResult<()> {
    let ok =
        !name.is_empty() && !name.starts_with('$') && !name.contains('.') && !name.contains('\0');
    if ok {
        Ok(())
    } else {
        Err(DataPlaneError::InvalidRequest {
            message: format!("invalid aggregate column name '{name}'"),
        })
    }
}

/// One `$group` accumulator from the allowlisted [`AggFunc`] enum.
/// `count` with no field is `{$sum: 1}`; `count(field)` counts documents
/// where the field is present and non-null (SQL `COUNT(col)` semantics).
pub(super) fn build_mongo_aggregate_expr(agg: &Aggregate) -> DataPlaneResult<Bson> {
    if let Some(field) = agg.field.as_deref() {
        safe_agg_key(field)?;
    }
    let field_ref = |f: &str| Bson::String(format!("${f}"));
    let expr = match (agg.func, agg.field.as_deref()) {
        (AggFunc::Count, None) => doc! { "$sum": 1 },
        (AggFunc::Count, Some(f)) => doc! {
            "$sum": { "$cond": [ { "$gt": [ { "$ifNull": [ field_ref(f), Bson::Null ] }, Bson::Null ] }, 1, 0 ] }
        },
        (AggFunc::Sum, Some(f)) => doc! { "$sum": field_ref(f) },
        (AggFunc::Avg, Some(f)) => doc! { "$avg": field_ref(f) },
        (AggFunc::Min, Some(f)) => doc! { "$min": field_ref(f) },
        (AggFunc::Max, Some(f)) => doc! { "$max": field_ref(f) },
        (func, None) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("aggregate '{func:?}' requires a `field`"),
            })
        }
    };
    Ok(Bson::Document(expr))
}

/// Intersect the client filter with the server-trusted scope so an attacker
/// cannot drop the predicate. `shared` marks a `shared_resources` collection
/// (F1 per-table isolation): its reads scope by `tenant_id` ONLY — the
/// `owner_id` predicate is omitted, so the catalog is readable across owners.
/// Only reads pass `shared=true`; mutations stay owner-scoped.
pub(super) fn build_tenant_filter(
    filter: Option<&Value>,
    identity: &RequestIdentity,
    tenant_id: &str,
    shared: bool,
) -> DataPlaneResult<Document> {
    let mut doc = match filter {
        Some(v @ Value::Object(_)) => {
            // Default-deny operator allowlist BEFORE conversion → no `$where`/
            // `$expr`/`$function` injection reaches the driver.
            reject_unsafe_operators(v)?;
            json_to_doc(v)?
        }
        Some(other) => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("filter must be a JSON object, got {other:?}"),
            });
        }
        None => Document::new(),
    };
    // Mongo only understands $and/$or/$nor at the TOP level; any other
    // $-operator there (e.g. `$not`) is a driver error that would surface as
    // an opaque 502 — fail it closed as the 400 it really is.
    for key in doc.keys() {
        if key.starts_with('$') && !matches!(key.as_str(), "$and" | "$or" | "$nor") {
            return Err(DataPlaneError::InvalidRequest {
                message: format!(
                    "filter operator '{key}' is not valid at the top level (use $and/$or/$nor)"
                ),
            });
        }
    }
    // Strip any client-provided override of the trust fields. `_id` passes
    // through — it is how get/update/delete target one row (still ANDed with
    // the server-trusted owner/tenant scope below).
    for field in FILTER_TRUST_FIELDS {
        doc.remove(field);
    }
    if let Some(id) = doc.remove("_id") {
        doc.insert("_id", coerce_id_filter(id));
    }
    if !shared {
        doc.insert("owner_id", MongoPool::owner(identity));
    }
    doc.insert("tenant_id", tenant_id.to_string());
    Ok(doc)
}

/// `_id` values round-trip as strings on the wire (`normalize_doc` hex-encodes
/// `ObjectId`s), so a client filtering on a 24-hex string may mean EITHER the
/// literal string `_id` (seeded data) or the ObjectId it encodes (driver-
/// assigned ids). Match both; everything else passes through unchanged.
fn coerce_id_filter(id: Bson) -> Bson {
    match id {
        Bson::String(s) => match bson::oid::ObjectId::parse_str(&s) {
            Ok(oid) => bson::bson!({ "$in": [oid, s] }),
            Err(_) => Bson::String(s),
        },
        other => other,
    }
}

pub(super) fn build_sort(
    sort: Option<&std::collections::BTreeMap<String, String>>,
) -> Option<Document> {
    let map = sort?;
    if map.is_empty() {
        return None;
    }
    let mut out = Document::new();
    for (k, dir) in map {
        let value: i32 = if dir.eq_ignore_ascii_case("desc") {
            -1
        } else {
            1
        };
        out.insert(k, value);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn probe_identity() -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t1".to_string(),
            project_id: None,
            app_id: None,
            user_id: Some("api-key:k1".to_string()),
            roles: vec![],
            scopes: vec![],
            source: data_plane_core::IdentitySource::ServiceToken,
        }
    }

    #[test]
    fn tenant_filter_preserves_id_and_enforces_trust_fields() {
        // `_id` is the row selector and MUST survive: stripping it widened a
        // by-pk update/delete to every owned document. Client attempts to spoof
        // owner_id/tenant_id are still overridden by the verified identity.
        let client = json!({ "_id": "evt-000001", "owner_id": "spoof", "tenant_id": "spoof" });
        let doc = build_tenant_filter(Some(&client), &probe_identity(), "t1", false).unwrap();
        assert_eq!(doc.get_str("_id").unwrap(), "evt-000001");
        assert_eq!(doc.get_str("owner_id").unwrap(), "api-key:k1");
        assert_eq!(doc.get_str("tenant_id").unwrap(), "t1");
    }

    #[test]
    fn shared_resource_read_omits_owner_but_keeps_tenant() {
        // F1: a shared collection's reads scope by tenant ONLY — the owner_id
        // predicate is omitted so the catalog is readable across owners. A
        // non-shared read still injects owner_id (byte-parity).
        let shared =
            build_tenant_filter(Some(&json!({ "kind": "x" })), &probe_identity(), "t1", true)
                .unwrap();
        assert!(
            !shared.contains_key("owner_id"),
            "shared read must not owner-scope: {shared:?}"
        );
        assert_eq!(shared.get_str("tenant_id").unwrap(), "t1");
        let scoped =
            build_tenant_filter(Some(&json!({ "kind": "x" })), &probe_identity(), "t1", false)
                .unwrap();
        assert_eq!(scoped.get_str("owner_id").unwrap(), "api-key:k1");
    }

    #[test]
    fn shared_pool_stamps_and_filters_each_requests_own_tenant() {
        // SHARE_POOLS isolation proof: the adapter's call sites now pass
        // `&identity.tenant_id` (not the pool's `self.tenant_id`) into
        // build_owned_doc / build_tenant_filter, so ONE pool shared across
        // tenants stamps + filters each request by its OWN tenant + owner.
        // Two distinct identities must produce two distinct stamps — never the
        // pool-opener's. This is what makes skipping the single-owner guard safe.
        let id_a = RequestIdentity {
            tenant_id: "tenant-a".into(),
            user_id: Some("api-key:a".into()),
            ..probe_identity()
        };
        let id_b = RequestIdentity {
            tenant_id: "tenant-b".into(),
            user_id: Some("api-key:b".into()),
            ..probe_identity()
        };
        let data = json!({ "kind": "login" });

        // Writes: each request stamps its own owner + tenant.
        let doc_a = build_owned_doc(&data, &id_a, &id_a.tenant_id).unwrap();
        let doc_b = build_owned_doc(&data, &id_b, &id_b.tenant_id).unwrap();
        assert_eq!(doc_a.get_str("tenant_id").unwrap(), "tenant-a");
        assert_eq!(doc_a.get_str("owner_id").unwrap(), "api-key:a");
        assert_eq!(doc_b.get_str("tenant_id").unwrap(), "tenant-b");
        assert_eq!(doc_b.get_str("owner_id").unwrap(), "api-key:b");

        // Reads: each request filters by its own owner + tenant — so tenant-a
        // can never select tenant-b's documents through the shared pool.
        let filt_a = build_tenant_filter(Some(&json!({})), &id_a, &id_a.tenant_id, false).unwrap();
        assert_eq!(filt_a.get_str("tenant_id").unwrap(), "tenant-a");
        assert_eq!(filt_a.get_str("owner_id").unwrap(), "api-key:a");
        let filt_b = build_tenant_filter(Some(&json!({})), &id_b, &id_b.tenant_id, false).unwrap();
        assert_eq!(filt_b.get_str("tenant_id").unwrap(), "tenant-b");
        assert_eq!(filt_b.get_str("owner_id").unwrap(), "api-key:b");
    }

    #[test]
    fn update_set_strips_owner_and_tenant_and_reinjects_trusted() {
        // Re-homing fix: `run_update` builds its `$set` from `build_owned_doc`
        // (same as insert/upsert), so a client `data` carrying a foreign
        // `owner_id`/`tenant_id` CANNOT move its own document into another
        // tenant's namespace. The reserved fields are stripped and re-injected
        // from the verified identity (mirrors the postgres `update` test that
        // asserts the client `owner_id` is never settable). `_id` is reserved
        // too — a client cannot rewrite the row's `_id` through `$set`.
        let client = json!({
            "name": "ok",
            "owner_id": "api-key:victim",
            "tenant_id": "victim-tenant",
            "_id": "spoofed",
        });
        let set_doc = build_owned_doc(&client, &probe_identity(), "t1").unwrap();
        // The legitimate field survives.
        assert_eq!(set_doc.get_str("name").unwrap(), "ok");
        // The spoofed owner/tenant are replaced by the verified identity, never
        // the attacker's values.
        assert_eq!(set_doc.get_str("owner_id").unwrap(), "api-key:k1");
        assert_eq!(set_doc.get_str("tenant_id").unwrap(), "t1");
        assert_ne!(set_doc.get_str("owner_id").unwrap(), "api-key:victim");
        assert_ne!(set_doc.get_str("tenant_id").unwrap(), "victim-tenant");
        // `_id` is a reserved field — stripped, never carried into `$set`.
        assert!(
            !set_doc.contains_key("_id"),
            "client `_id` must not reach $set: {set_doc:?}"
        );
        // Operator keys in update data are still a clean 400 (rejection preserved).
        assert!(matches!(
            build_owned_doc(&json!({ "$rename": { "a": "b" } }), &probe_identity(), "t1")
                .unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
    }

    #[test]
    fn update_delete_require_a_selective_filter() {
        // Parity with the relational no-full-table guard: `{}` (or trust-field
        //-only filters, which are stripped anyway) must not mass-write every
        // owned document. Verified live before the fix: filter {} modified 39
        // docs in one call.
        for bad in [None, Some(json!({})), Some(json!({ "owner_id": "spoof" }))] {
            let err = require_row_filter(bad.as_ref(), "update").unwrap_err();
            assert!(
                matches!(err, DataPlaneError::InvalidRequest { .. }),
                "{bad:?} → {err:?}"
            );
        }
        assert!(require_row_filter(Some(&json!({ "_id": "n-1" })), "update").is_ok());
        assert!(require_row_filter(Some(&json!({ "kind": "login" })), "delete").is_ok());
    }

    #[test]
    fn tenant_filter_rejects_unknown_top_level_operators() {
        // `$not` is operator-position-only in Mongo; at the top level the
        // driver errors out (opaque 502) — fail closed as a 400 instead.
        let bad = json!({ "$not": { "kind": { "$in": ["login"] } } });
        let err = build_tenant_filter(Some(&bad), &probe_identity(), "t1", false).unwrap_err();
        assert!(
            matches!(err, DataPlaneError::InvalidRequest { .. }),
            "{err:?}"
        );
        // The real top-level combinators still pass.
        let ok = json!({ "$or": [{ "kind": "login" }, { "kind": "search" }] });
        assert!(build_tenant_filter(Some(&ok), &probe_identity(), "t1", false).is_ok());
    }

    #[test]
    fn tenant_filter_coerces_objectid_hex_to_dual_match() {
        // Wire `_id`s are strings (normalize_doc hex-encodes ObjectIds), so a
        // 24-hex value must match both the ObjectId and the literal string.
        let hex = "665f1e2a9b3c4d5e6f708192";
        let client = json!({ "_id": hex });
        let doc = build_tenant_filter(Some(&client), &probe_identity(), "t1", false).unwrap();
        let id = doc.get_document("_id").unwrap();
        let candidates = id.get_array("$in").unwrap();
        let oid = bson::oid::ObjectId::parse_str(hex).unwrap();
        assert!(candidates.contains(&Bson::ObjectId(oid)));
        assert!(candidates.contains(&Bson::String(hex.to_string())));
        // Non-hex pk strings stay literal (seeded ids like `evt-000001`).
        let plain =
            build_tenant_filter(Some(&json!({ "_id": "evt-1" })), &probe_identity(), "t1", false)
                .unwrap();
        assert_eq!(plain.get_str("_id").unwrap(), "evt-1");
    }

    #[test]
    fn rejects_javascript_and_expression_operators() {
        // The NoSQL-injection fix: code/expression operators are refused, at any
        // nesting depth, with a client error (400).
        for bad in [
            json!({ "$where": "this.x == 1" }),
            json!({ "$expr": { "$eq": ["$a", "$b"] } }),
            json!({ "name": { "$function": { "body": "f", "args": [], "lang": "js" } } }),
            json!({ "$or": [{ "x": 1 }, { "$where": "true" }] }), // nested under $or
            json!({ "a": { "b": { "$accumulator": {} } } }),      // deeply nested
        ] {
            let err = reject_unsafe_operators(&bad).unwrap_err();
            assert!(
                matches!(err, DataPlaneError::InvalidRequest { .. }),
                "{bad}: {err:?}"
            );
        }
    }

    #[test]
    fn allows_standard_query_operators() {
        for ok in [
            json!({ "age": { "$gte": 18 } }),
            json!({ "status": { "$in": ["a", "b"], "$nin": ["c"] } }),
            json!({ "$or": [{ "a": 1 }, { "b": { "$lt": 5 } }], "$nor": [{ "z": 9 }] }),
            json!({ "name": { "$regex": "^a", "$options": "i" } }),
            json!({ "tags": { "$elemMatch": { "$eq": "x" } } }),
            json!({ "plain": "equality", "n": 3 }),
        ] {
            assert!(reject_unsafe_operators(&ok).is_ok(), "{ok}");
        }
    }

    #[test]
    fn allowlist_is_exact_and_case_sensitive() {
        // `$jsonSchema` (eval) is denied; a case variant of a safe op is not a
        // real operator and is denied too (exact match) — both fail closed.
        assert!(reject_unsafe_operators(&json!({ "$jsonSchema": {} })).is_err());
        assert!(reject_unsafe_operators(&json!({ "a": { "$GTE": 1 } })).is_err());
        // a safe operator nested under an unsafe one is still rejected (key
        // checked before recursing).
        assert!(reject_unsafe_operators(&json!({ "$where": { "$eq": 1 } })).is_err());
    }

    #[test]
    fn write_data_rejects_top_level_operator_keys() {
        // The write-path symmetry fix: a `$`-prefixed top-level key in write data
        // is a clean 400, not a 502 from the driver.
        for bad in [
            json!({ "$rename": { "a": "b" } }),
            json!({ "$set": { "x": 1 } }),
        ] {
            assert!(
                matches!(
                    reject_top_level_operators(&bad).unwrap_err(),
                    DataPlaneError::InvalidRequest { .. }
                ),
                "{bad}"
            );
        }
        // ordinary and dotted (nested-path) keys are allowed.
        assert!(reject_top_level_operators(&json!({ "name": "x", "profile.age": 3 })).is_ok());
    }

    // ── coerce_id_filter: hex → dual-match, others passthrough ───────────────

    #[test]
    fn coerce_id_filter_expands_24_hex_to_objectid_or_string() {
        let hex = "507f1f77bcf86cd799439011";
        let coerced = coerce_id_filter(Bson::String(hex.to_string()));
        // → { $in: [ObjectId(hex), "hex"] }
        let Bson::Document(d) = coerced else {
            panic!("expected a $in document");
        };
        let arr = d.get_array("$in").unwrap();
        assert_eq!(arr.len(), 2);
        assert!(matches!(arr[0], Bson::ObjectId(_)));
        assert_eq!(arr[1], Bson::String(hex.to_string()));
    }

    #[test]
    fn coerce_id_filter_leaves_non_hex_string_unchanged() {
        let s = "not-an-oid";
        assert_eq!(
            coerce_id_filter(Bson::String(s.into())),
            Bson::String(s.into())
        );
        // too-short hex isn't an ObjectId either.
        assert_eq!(
            coerce_id_filter(Bson::String("abc".into())),
            Bson::String("abc".into())
        );
    }

    #[test]
    fn coerce_id_filter_passes_through_non_strings() {
        assert_eq!(coerce_id_filter(Bson::Int64(5)), Bson::Int64(5));
        assert_eq!(coerce_id_filter(Bson::Null), Bson::Null);
        let doc = doc! { "$gt": 1 };
        assert_eq!(
            coerce_id_filter(Bson::Document(doc.clone())),
            Bson::Document(doc)
        );
    }

    // ── build_sort: direction mapping, empty, multi-key ──────────────────────

    #[test]
    fn build_sort_maps_directions_and_handles_empty() {
        assert!(build_sort(None).is_none());
        let empty = std::collections::BTreeMap::new();
        assert!(build_sort(Some(&empty)).is_none());

        let mut m = std::collections::BTreeMap::new();
        m.insert("a".to_string(), "asc".to_string());
        m.insert("b".to_string(), "DESC".to_string());
        m.insert("c".to_string(), "whatever".to_string()); // non-desc → asc(1)
        let doc = build_sort(Some(&m)).unwrap();
        assert_eq!(doc.get_i32("a").unwrap(), 1);
        assert_eq!(doc.get_i32("b").unwrap(), -1);
        assert_eq!(doc.get_i32("c").unwrap(), 1);
    }

    // ── safe_agg_key: $-prefix / dot / NUL / empty ───────────────────────────

    #[test]
    fn safe_agg_key_accepts_plain_names() {
        for ok in ["name", "total_amount", "col1", "Owner"] {
            assert!(safe_agg_key(ok).is_ok(), "should accept {ok:?}");
        }
    }

    #[test]
    fn safe_agg_key_rejects_operators_paths_and_nul() {
        for bad in ["", "$sum", "$where", "a.b", "nested.path", "a\0b"] {
            assert!(safe_agg_key(bad).is_err(), "should reject {bad:?}");
        }
    }

    // ── build_mongo_aggregate_expr: per-func shapes + guards ──────────────────

    fn agg(func: AggFunc, field: Option<&str>) -> Aggregate {
        Aggregate {
            func,
            field: field.map(str::to_string),
            distinct: false,
            alias: "out".to_string(),
        }
    }

    #[test]
    fn aggregate_count_with_and_without_field() {
        // count() with no field → { $sum: 1 }
        let b = build_mongo_aggregate_expr(&agg(AggFunc::Count, None)).unwrap();
        assert_eq!(b, Bson::Document(doc! { "$sum": 1 }));
        // count(field) → conditional sum (presence/non-null)
        let Bson::Document(d) =
            build_mongo_aggregate_expr(&agg(AggFunc::Count, Some("col"))).unwrap()
        else {
            panic!()
        };
        assert!(d.contains_key("$sum"));
    }

    #[test]
    fn aggregate_sum_avg_min_max_reference_the_field() {
        for (func, key) in [
            (AggFunc::Sum, "$sum"),
            (AggFunc::Avg, "$avg"),
            (AggFunc::Min, "$min"),
            (AggFunc::Max, "$max"),
        ] {
            let Bson::Document(d) = build_mongo_aggregate_expr(&agg(func, Some("amount"))).unwrap()
            else {
                panic!()
            };
            assert_eq!(d.get_str(key).unwrap(), "$amount", "func {func:?}");
        }
    }

    #[test]
    fn aggregate_sum_without_field_is_rejected() {
        for func in [AggFunc::Sum, AggFunc::Avg, AggFunc::Min, AggFunc::Max] {
            assert!(
                matches!(
                    build_mongo_aggregate_expr(&agg(func, None)),
                    Err(DataPlaneError::InvalidRequest { .. })
                ),
                "func {func:?} requires a field"
            );
        }
    }

    #[test]
    fn aggregate_rejects_unsafe_field_name() {
        assert!(build_mongo_aggregate_expr(&agg(AggFunc::Sum, Some("$injected"))).is_err());
        assert!(build_mongo_aggregate_expr(&agg(AggFunc::Max, Some("a.b"))).is_err());
    }

    // ── reject_top_level_operators / reject_unsafe_operators ──────────────────

    #[test]
    fn reject_top_level_operators_blocks_dollar_keys_only_at_top() {
        assert!(reject_top_level_operators(&json!({ "name": "x", "n": 1 })).is_ok());
        // dotted (nested-path) keys ARE allowed at the top level.
        assert!(reject_top_level_operators(&json!({ "a.b": 1 })).is_ok());
        // a $-key at the top is rejected.
        assert!(reject_top_level_operators(&json!({ "$set": { "x": 1 } })).is_err());
        // a nested $-key is fine for THIS check (it only inspects the top).
        assert!(reject_top_level_operators(&json!({ "doc": { "$x": 1 } })).is_ok());
        // a non-object is a no-op (Ok).
        assert!(reject_top_level_operators(&json!([1, 2])).is_ok());
    }

    #[test]
    fn reject_unsafe_operators_allows_safe_recurses_into_arrays() {
        // safe operators pass at any depth.
        assert!(reject_unsafe_operators(&json!({ "age": { "$gte": 18 } })).is_ok());
        assert!(reject_unsafe_operators(
            &json!({ "$and": [ { "a": 1 }, { "b": { "$in": [1, 2] } } ] })
        )
        .is_ok());
        assert!(reject_unsafe_operators(&json!({ "tags": { "$all": ["x"] } })).is_ok());
        // unsafe operators are rejected wherever they appear.
        assert!(reject_unsafe_operators(&json!({ "$where": "this.x" })).is_err());
        assert!(reject_unsafe_operators(&json!({ "a": { "$expr": {} } })).is_err());
        assert!(reject_unsafe_operators(&json!({ "$or": [ { "$function": {} } ] })).is_err());
        // case-sensitive: $GT is NOT in the allowlist.
        assert!(reject_unsafe_operators(&json!({ "a": { "$GT": 1 } })).is_err());
    }

    #[test]
    fn reject_unsafe_operators_ignores_non_dollar_field_names() {
        // Field names (non-$) are unrestricted — only operators are gated.
        assert!(reject_unsafe_operators(&json!({ "weird name!": 1, "owner_id": "x" })).is_ok());
    }

    // ── require_row_filter: selectivity guard ────────────────────────────────

    #[test]
    fn require_row_filter_demands_a_client_chosen_field() {
        // None / empty / only-trust-fields → refused (full-collection guard).
        assert!(require_row_filter(None, "delete").is_err());
        assert!(require_row_filter(Some(&json!({})), "delete").is_err());
        assert!(require_row_filter(Some(&json!({ "owner_id": "x" })), "update").is_err());
        assert!(require_row_filter(
            Some(&json!({ "owner_id": "x", "tenant_id": "y" })),
            "update"
        )
        .is_err());
        // a non-object is not selective.
        assert!(require_row_filter(Some(&json!([1])), "delete").is_err());
        // at least one client field → ok.
        assert!(require_row_filter(Some(&json!({ "_id": "x" })), "get").is_ok());
        assert!(require_row_filter(Some(&json!({ "status": "open" })), "update").is_ok());
        assert!(
            require_row_filter(Some(&json!({ "owner_id": "x", "name": "real" })), "delete").is_ok()
        );
    }
}
