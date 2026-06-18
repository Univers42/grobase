//! Resource/id segment validation — the character rules that keep the
//! `{owner}:{resource}:{id}` key envelope un-forgeable.

use data_plane_core::{DataPlaneError, DataPlaneResult};

/// Same character set as the TS adapter's `RESOURCE_REGEX`:
/// `[A-Za-z0-9_:-]{1,128}`. Rejects keys that could break the
/// `{owner}:{resource}:{id}` envelope.
pub(super) fn is_valid_segment(s: &str, max_len: usize, allow_extra: &[u8]) -> bool {
    if s.is_empty() || s.len() > max_len {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || allow_extra.contains(&b))
}

pub(super) fn validate_resource(name: &str) -> DataPlaneResult<()> {
    if !is_valid_segment(name, 128, b"-:") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: name.to_string(),
        });
    }
    // Reject leading/trailing/consecutive `:` — they would corrupt the
    // `{owner}:{resource}:{id}` envelope. The `:` separator is allowed for
    // namespaced resources like `users:archive` but never at the edges.
    if name.starts_with(':') || name.ends_with(':') || name.contains("::") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: name.to_string(),
        });
    }
    Ok(())
}

pub(super) fn validate_id(id: &str) -> DataPlaneResult<()> {
    if !is_valid_segment(id, 256, b"-_:") {
        return Err(DataPlaneError::InvalidIdentifier {
            value: id.to_string(),
        });
    }
    Ok(())
}
