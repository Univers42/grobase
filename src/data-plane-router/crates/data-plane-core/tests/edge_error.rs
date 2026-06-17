//! Edge-case suite for `DataPlaneError` (error.rs): variant construction,
//! Display text, and `prefix_message` preserving the variant (and therefore the
//! mapped HTTP status) while prefixing free-text payloads.
//!
//! Tests only — no source logic changed. Behavior asserted against the code.

use data_plane_core::*;

// ── Display text per variant (the `#[error(...)]` strings) ────────────────────

#[test]
fn unsupported_capability_display() {
    let e = DataPlaneError::UnsupportedCapability { engine: "redis".into(), capability: "aggregate".into() };
    let s = e.to_string();
    assert!(s.contains("redis"));
    assert!(s.contains("aggregate"));
}

#[test]
fn capability_gated_display() {
    let e = DataPlaneError::CapabilityGated { capability: "vector".into() };
    assert!(e.to_string().contains("vector"));
    assert!(e.to_string().contains("package tier"));
}

#[test]
fn mount_not_found_display() {
    let e = DataPlaneError::MountNotFound { mount_id: "db-99".into() };
    assert!(e.to_string().contains("db-99"));
}

#[test]
fn transaction_not_found_display() {
    let e = DataPlaneError::TransactionNotFound { tx_id: "tx-abc".into() };
    assert!(e.to_string().contains("tx-abc"));
}

#[test]
fn invalid_identifier_display() {
    let e = DataPlaneError::InvalidIdentifier { value: "1; DROP".into() };
    assert!(e.to_string().contains("1; DROP"));
}

#[test]
fn credential_unavailable_display() {
    let e = DataPlaneError::CredentialUnavailable { mount_id: "m1".into() };
    assert!(e.to_string().contains("m1"));
}

#[test]
fn credential_provider_failed_display() {
    let e = DataPlaneError::CredentialProviderFailed { provider: "vault".into(), mount_id: "m1".into() };
    let s = e.to_string();
    assert!(s.contains("vault"));
    assert!(s.contains("m1"));
}

#[test]
fn backend_display() {
    let e = DataPlaneError::Backend { message: "connection refused".into() };
    assert!(e.to_string().contains("connection refused"));
}

#[test]
fn conflict_display() {
    let e = DataPlaneError::Conflict { message: "unique violation".into() };
    assert!(e.to_string().contains("unique violation"));
    assert!(e.to_string().starts_with("conflict:"));
}

#[test]
fn invalid_request_display() {
    let e = DataPlaneError::InvalidRequest { message: "empty filter".into() };
    assert!(e.to_string().contains("empty filter"));
    assert!(e.to_string().starts_with("invalid request:"));
}

#[test]
fn not_implemented_display() {
    let e = DataPlaneError::NotImplemented { feature: "two-phase commit".into() };
    assert!(e.to_string().contains("two-phase commit"));
}

#[test]
fn display_text_never_panics_on_empty_payloads() {
    // Constructing + Display on empty-string payloads must not panic.
    let variants = [
        DataPlaneError::UnsupportedCapability { engine: "".into(), capability: "".into() },
        DataPlaneError::CapabilityGated { capability: "".into() },
        DataPlaneError::MountNotFound { mount_id: "".into() },
        DataPlaneError::TransactionNotFound { tx_id: "".into() },
        DataPlaneError::InvalidIdentifier { value: "".into() },
        DataPlaneError::CredentialUnavailable { mount_id: "".into() },
        DataPlaneError::CredentialProviderFailed { provider: "".into(), mount_id: "".into() },
        DataPlaneError::Backend { message: "".into() },
        DataPlaneError::Conflict { message: "".into() },
        DataPlaneError::InvalidRequest { message: "".into() },
        DataPlaneError::NotImplemented { feature: "".into() },
    ];
    for v in variants {
        let _ = v.to_string();
    }
}

#[test]
fn display_text_handles_unicode_and_control_chars() {
    let e = DataPlaneError::Backend { message: "naïve\tダメ\n".into() };
    assert!(e.to_string().contains("naïve"));
}

// ── prefix_message: free-text variants get prefixed (variant preserved) ────────

/// Assert prefix_message on a free-text variant: same variant discriminant,
/// payload now starts with the prefix and ends with the original text.
fn assert_prefixed(make: impl Fn(String) -> DataPlaneError, get: impl Fn(&DataPlaneError) -> Option<&str>) {
    let original = make("boom".into());
    let prefixed = DataPlaneError::prefix_message("ctx: ", make("boom".into()));
    // Same variant kind (same Display prefix shape).
    assert_eq!(
        std::mem::discriminant(&original),
        std::mem::discriminant(&prefixed)
    );
    let text = get(&prefixed).expect("variant carries free text");
    assert!(text.starts_with("ctx: "), "prefix applied: {text}");
    assert!(text.ends_with("boom"), "original preserved: {text}");
}

#[test]
fn prefix_message_prefixes_backend() {
    assert_prefixed(
        |m| DataPlaneError::Backend { message: m },
        |e| match e { DataPlaneError::Backend { message } => Some(message), _ => None },
    );
}

#[test]
fn prefix_message_prefixes_conflict() {
    assert_prefixed(
        |m| DataPlaneError::Conflict { message: m },
        |e| match e { DataPlaneError::Conflict { message } => Some(message), _ => None },
    );
}

#[test]
fn prefix_message_prefixes_invalid_request() {
    assert_prefixed(
        |m| DataPlaneError::InvalidRequest { message: m },
        |e| match e { DataPlaneError::InvalidRequest { message } => Some(message), _ => None },
    );
}

#[test]
fn prefix_message_prefixes_invalid_identifier_value() {
    assert_prefixed(
        |m| DataPlaneError::InvalidIdentifier { value: m },
        |e| match e { DataPlaneError::InvalidIdentifier { value } => Some(value), _ => None },
    );
}

#[test]
fn prefix_message_prefixes_not_implemented_feature() {
    assert_prefixed(
        |m| DataPlaneError::NotImplemented { feature: m },
        |e| match e { DataPlaneError::NotImplemented { feature } => Some(feature), _ => None },
    );
}

#[test]
fn prefix_message_empty_prefix_is_identity_text() {
    let prefixed = DataPlaneError::prefix_message("", DataPlaneError::Backend { message: "x".into() });
    match prefixed {
        DataPlaneError::Backend { message } => assert_eq!(message, "x"),
        other => panic!("variant changed: {other:?}"),
    }
}

#[test]
fn prefix_message_can_be_applied_repeatedly() {
    let e = DataPlaneError::InvalidRequest { message: "core".into() };
    let once = DataPlaneError::prefix_message("a: ", e);
    let twice = DataPlaneError::prefix_message("b: ", once);
    match twice {
        DataPlaneError::InvalidRequest { message } => assert_eq!(message, "b: a: core"),
        other => panic!("variant changed: {other:?}"),
    }
}

#[test]
fn prefix_message_with_unicode_prefix() {
    let e = DataPlaneError::Conflict { message: "dup".into() };
    let p = DataPlaneError::prefix_message("バッチ項目3: ", e);
    match p {
        DataPlaneError::Conflict { message } => {
            assert!(message.starts_with("バッチ項目3: "));
            assert!(message.ends_with("dup"));
        }
        other => panic!("variant changed: {other:?}"),
    }
}

// ── prefix_message: non-free-text variants pass through unchanged ─────────────

#[test]
fn prefix_message_passes_through_unsupported_capability() {
    let e = DataPlaneError::UnsupportedCapability { engine: "redis".into(), capability: "agg".into() };
    let p = DataPlaneError::prefix_message("ctx: ", e);
    match p {
        DataPlaneError::UnsupportedCapability { engine, capability } => {
            // Neither field is prefixed — structured variant passes through as-is.
            assert_eq!(engine, "redis");
            assert_eq!(capability, "agg");
        }
        other => panic!("variant changed: {other:?}"),
    }
}

#[test]
fn prefix_message_passes_through_capability_gated() {
    let e = DataPlaneError::CapabilityGated { capability: "vector".into() };
    let p = DataPlaneError::prefix_message("ctx: ", e);
    match p {
        DataPlaneError::CapabilityGated { capability } => assert_eq!(capability, "vector"),
        other => panic!("variant changed: {other:?}"),
    }
}

#[test]
fn prefix_message_passes_through_mount_not_found() {
    let e = DataPlaneError::MountNotFound { mount_id: "db-1".into() };
    let p = DataPlaneError::prefix_message("ctx: ", e);
    match p {
        DataPlaneError::MountNotFound { mount_id } => assert_eq!(mount_id, "db-1"),
        other => panic!("variant changed: {other:?}"),
    }
}

#[test]
fn prefix_message_passes_through_transaction_not_found() {
    let e = DataPlaneError::TransactionNotFound { tx_id: "tx-1".into() };
    let p = DataPlaneError::prefix_message("ctx: ", e);
    match p {
        DataPlaneError::TransactionNotFound { tx_id } => assert_eq!(tx_id, "tx-1"),
        other => panic!("variant changed: {other:?}"),
    }
}

#[test]
fn prefix_message_passes_through_credential_unavailable() {
    let e = DataPlaneError::CredentialUnavailable { mount_id: "m1".into() };
    let p = DataPlaneError::prefix_message("ctx: ", e);
    assert!(matches!(p, DataPlaneError::CredentialUnavailable { mount_id } if mount_id == "m1"));
}

#[test]
fn prefix_message_passes_through_credential_provider_failed() {
    let e = DataPlaneError::CredentialProviderFailed { provider: "vault".into(), mount_id: "m1".into() };
    let p = DataPlaneError::prefix_message("ctx: ", e);
    match p {
        DataPlaneError::CredentialProviderFailed { provider, mount_id } => {
            assert_eq!(provider, "vault");
            assert_eq!(mount_id, "m1");
        }
        other => panic!("variant changed: {other:?}"),
    }
}

// ── DataPlaneResult type alias works as a normal Result ───────────────────────

#[test]
fn data_plane_result_ok_and_err() {
    let ok: DataPlaneResult<u32> = Ok(7);
    assert_eq!(ok.unwrap(), 7);
    let err: DataPlaneResult<u32> = Err(DataPlaneError::Backend { message: "x".into() });
    assert!(err.is_err());
}

#[test]
fn data_plane_error_is_std_error() {
    // thiserror derives std::error::Error; ensure it is usable as a trait object.
    fn as_dyn(e: DataPlaneError) -> Box<dyn std::error::Error> {
        Box::new(e)
    }
    let boxed = as_dyn(DataPlaneError::NotImplemented { feature: "f".into() });
    assert!(boxed.to_string().contains("f"));
}

#[test]
fn prefix_message_preserves_display_status_shape_for_invalid_request() {
    // The whole point: prefixing keeps the variant, so the Display prefix that
    // the server maps to a 4xx status is unchanged.
    let p = DataPlaneError::prefix_message("batch item 3: ", DataPlaneError::InvalidRequest { message: "bad".into() });
    assert!(p.to_string().starts_with("invalid request:"), "{}", p.to_string());
    assert!(p.to_string().contains("batch item 3: bad"));
}

#[test]
fn prefix_message_preserves_display_status_shape_for_conflict() {
    let p = DataPlaneError::prefix_message("row 2: ", DataPlaneError::Conflict { message: "dup".into() });
    assert!(p.to_string().starts_with("conflict:"));
    assert!(p.to_string().contains("row 2: dup"));
}
