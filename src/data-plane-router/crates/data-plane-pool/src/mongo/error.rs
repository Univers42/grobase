/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   error.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:27:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Mongo error classification — pure message-based mapping of driver errors to
//! the right client/server bucket (`Conflict`/`InvalidRequest`/`Backend`).

use data_plane_core::DataPlaneError;

pub(super) fn mongo_err(e: mongodb::error::Error) -> DataPlaneError {
    classify_mongo_message(format!("mongo backend: {e}"))
}

/// Pure classifier behind [`mongo_err`] (testable without a driver error).
/// `$jsonSchema` validator rejections (server code 121 DocumentValidation-
/// Failure, "Document failed validation") and duplicate `_id` inserts (E11000
/// duplicate key) are the CALLER's fault — their values don't fit the
/// declared contract — so they map to 409 Conflict, not an engine 5xx (which
/// would make outbox clients retry a write that can never succeed).
fn classify_mongo_message(message: String) -> DataPlaneError {
    let lower = message.to_lowercase();
    if lower.contains("document failed validation")
        || lower.contains("documentvalidationfailure")
        || lower.contains("duplicate key error")
    {
        return DataPlaneError::Conflict { message };
    }
    DataPlaneError::Backend { message }
}

/// DDL-path error classifier (additive — the query path keeps [`mongo_err`]):
/// `createCollection` on an existing namespace is the caller's conflict
/// (409), and dropping / modifying a namespace that doesn't exist is a client
/// error (400), not an engine failure.
pub(super) fn mongo_ddl_err(e: mongodb::error::Error) -> DataPlaneError {
    classify_mongo_ddl_message(format!("mongo backend: {e}"))
}

/// Pure message classifier behind [`mongo_ddl_err`] (testable without a
/// driver error). The server's NamespaceExists / NamespaceNotFound errors
/// carry these tokens in their message.
fn classify_mongo_ddl_message(message: String) -> DataPlaneError {
    let lower = message.to_lowercase();
    if lower.contains("already exists") || lower.contains("namespaceexists") {
        return DataPlaneError::Conflict { message };
    }
    if lower.contains("ns not found") || lower.contains("namespacenotfound") {
        return DataPlaneError::InvalidRequest { message };
    }
    DataPlaneError::Backend { message }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validator_rejections_classify_as_conflict() {
        // `$jsonSchema` says no → the caller's values don't fit the declared
        // contract: 409, never an opaque 502 (verified live before the fix).
        let validation = classify_mongo_message(
            "mongo backend: WriteError { code: 121, message: \"Document failed validation\" }"
                .into(),
        );
        assert!(
            matches!(validation, DataPlaneError::Conflict { .. }),
            "{validation:?}"
        );
        let dup = classify_mongo_message(
            "mongo backend: E11000 duplicate key error collection: activity.notes".into(),
        );
        assert!(matches!(dup, DataPlaneError::Conflict { .. }), "{dup:?}");
        let other = classify_mongo_message("mongo backend: connection reset".into());
        assert!(matches!(other, DataPlaneError::Backend { .. }), "{other:?}");
    }

    #[test]
    fn mongo_ddl_error_classifier_maps_namespace_errors() {
        // Pure classification by message (the live errors carry these tokens).
        assert!(matches!(
            classify_mongo_ddl_message("Collection already exists. NS: db.t".into()),
            DataPlaneError::Conflict { .. }
        ));
        assert!(matches!(
            classify_mongo_ddl_message("Command failed: ns not found".into()),
            DataPlaneError::InvalidRequest { .. }
        ));
        assert!(matches!(
            classify_mongo_ddl_message("socket closed".into()),
            DataPlaneError::Backend { .. }
        ));
    }

    // ── classify_mongo_message: validation + duplicate-key → Conflict ─────────

    #[test]
    fn classify_mongo_message_full_matrix() {
        for conflict in [
            "Document failed validation",
            "DocumentValidationFailure: schema mismatch",
            "E11000 duplicate key error collection: db.t",
        ] {
            assert!(
                matches!(
                    classify_mongo_message(conflict.into()),
                    DataPlaneError::Conflict { .. }
                ),
                "{conflict:?} → Conflict"
            );
        }
        for backend in [
            "connection timed out",
            "not master",
            "server selection error",
        ] {
            assert!(
                matches!(
                    classify_mongo_message(backend.into()),
                    DataPlaneError::Backend { .. }
                ),
                "{backend:?} → Backend"
            );
        }
    }
}
