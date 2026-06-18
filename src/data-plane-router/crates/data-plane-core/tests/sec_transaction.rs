//! Security: transaction session wire contract. `TxState` is a CLOSED set of
//! lifecycle states (open → committed | rolled_back | reaped) with a stable
//! snake_case wire encoding; `TxSession` and `TxBeginRequest` round-trip
//! faithfully so a tampered/garbage state string is rejected at deserialization
//! rather than silently treated as "open". (The state-machine *enforcement*
//! lives in the server tx manager; here we pin the type contract every layer
//! agrees on.)

use chrono::{TimeZone, Utc};
use data_plane_core::{
    CredentialRef, DatabaseMount, IdentitySource, IsolationLevel, PoolPolicy, RequestIdentity,
    TxBeginRequest, TxSession, TxState,
};
use uuid::Uuid;

// ── TxState: a CLOSED set with stable snake_case wire tags ──────────────────

#[test]
fn tx_state_wire_encoding_is_stable() {
    let cases = [
        (TxState::Open, "\"open\""),
        (TxState::Committed, "\"committed\""),
        (TxState::RolledBack, "\"rolled_back\""),
        (TxState::Reaped, "\"reaped\""),
    ];
    for (state, json) in cases {
        assert_eq!(serde_json::to_string(&state).unwrap(), json, "{state:?}");
        let back: TxState = serde_json::from_str(json).unwrap();
        assert_eq!(back, state, "round-trip {json}");
    }
}

#[test]
fn tx_state_rejects_unknown_or_tampered_values() {
    // A garbage / injected state string must FAIL deserialization — it can never
    // be silently coerced into a permissive state (e.g. "open").
    let bad = [
        "\"OPEN\"",
        "\"Committed\"",
        "\"rolledback\"",
        "\"rolled-back\"",
        "\"active\"",
        "\"open; DROP\"",
        "\"\"",
        "\"open \"",
        "5",
        "null",
        "true",
        "[\"open\"]",
        "{\"state\":\"open\"}",
    ];
    for v in bad {
        assert!(
            serde_json::from_str::<TxState>(v).is_err(),
            "tampered state {v} must be rejected, not coerced"
        );
    }
}

// ── TxSession: round-trips faithfully (no field drops, no state laundering) ─

#[test]
fn tx_session_round_trips_for_every_state() {
    let tx_id = Uuid::nil();
    let opened = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
    let expires = Utc.timestamp_opt(1_700_000_030, 0).unwrap();
    for state in [
        TxState::Open,
        TxState::Committed,
        TxState::RolledBack,
        TxState::Reaped,
    ] {
        let session = TxSession {
            tx_id,
            tenant_id: "acme".into(),
            mount_id: "db1".into(),
            state: state.clone(),
            opened_at: opened,
            expires_at: expires,
        };
        let json = serde_json::to_value(&session).unwrap();
        // The state is carried verbatim (no laundering to a different state).
        assert_eq!(json["state"], serde_json::to_value(&state).unwrap());
        let back: TxSession = serde_json::from_value(json).unwrap();
        assert_eq!(back, session, "{state:?} round-trip");
    }
}

#[test]
fn tx_session_with_unknown_state_is_rejected() {
    let bad = serde_json::json!({
        "tx_id": "00000000-0000-0000-0000-000000000000",
        "tenant_id": "acme",
        "mount_id": "db1",
        "state": "double_committed",
        "opened_at": "2023-11-14T22:13:20Z",
        "expires_at": "2023-11-14T22:13:50Z"
    });
    assert!(
        serde_json::from_value::<TxSession>(bad).is_err(),
        "an invalid state string must fail to deserialize into a TxSession"
    );
}

// ── TxBeginRequest: identity + mount + optional isolation/timeout ───────────

fn mount() -> DatabaseMount {
    DatabaseMount {
        id: "db1".into(),
        tenant_id: "acme".into(),
        project_id: None,
        engine: "postgresql".into(),
        name: "n".into(),
        credential_ref: CredentialRef {
            provider: "adapter-registry".into(),
            reference: "r".into(),
            version: "1".into(),
        },
        pool_policy: PoolPolicy::default(),
        capability_overrides: None,
        inline_dsn: None,
        isolation: None,
        replica_inline_dsn: None,
        read_replica_route: false,
    }
}

fn identity() -> RequestIdentity {
    RequestIdentity {
        tenant_id: "acme".into(),
        project_id: None,
        app_id: None,
        user_id: None,
        roles: vec![],
        scopes: vec![],
        source: IdentitySource::SignedEnvelope,
    }
}

#[test]
fn tx_begin_request_round_trips_with_and_without_optionals() {
    for (iso, timeout) in [
        (Some(IsolationLevel::Serializable), Some(30_000u64)),
        (Some(IsolationLevel::ReadCommitted), None),
        (None, Some(5_000)),
        (None, None),
    ] {
        let req = TxBeginRequest {
            identity: identity(),
            mount: mount(),
            isolation: iso.clone(),
            timeout_ms: timeout,
        };
        let json = serde_json::to_value(&req).unwrap();
        let back: TxBeginRequest = serde_json::from_value(json).unwrap();
        assert_eq!(back, req, "iso={iso:?} timeout={timeout:?}");
    }
}

#[test]
fn tx_begin_request_carries_the_verified_tenant_identity() {
    // The tenant the tx is scoped to comes from the TRUSTED identity, not from a
    // client-supplied field — pin that the identity rides in the request.
    let req = TxBeginRequest {
        identity: identity(),
        mount: mount(),
        isolation: None,
        timeout_ms: None,
    };
    assert_eq!(req.identity.tenant_id, "acme");
    assert!(
        req.identity.is_tenant_scoped(),
        "a tx must carry a tenant-scoped identity"
    );
    // The mount the request targets belongs to the same tenant.
    assert_eq!(req.mount.tenant_id, req.identity.tenant_id);
}

#[test]
fn isolation_level_wire_encoding_is_a_closed_set() {
    let cases = [
        (IsolationLevel::ReadCommitted, "\"read_committed\""),
        (IsolationLevel::RepeatableRead, "\"repeatable_read\""),
        (IsolationLevel::Serializable, "\"serializable\""),
        (IsolationLevel::Snapshot, "\"snapshot\""),
    ];
    for (lvl, json) in cases {
        assert_eq!(serde_json::to_string(&lvl).unwrap(), json);
        assert_eq!(serde_json::from_str::<IsolationLevel>(json).unwrap(), lvl);
    }
    // An unknown isolation level is rejected, never coerced.
    for bad in [
        "\"dirty_read\"",
        "\"READ_COMMITTED\"",
        "\"serializable;\"",
        "0",
    ] {
        assert!(
            serde_json::from_str::<IsolationLevel>(bad).is_err(),
            "{bad}"
        );
    }
}
