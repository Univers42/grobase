//! Error domain for the stream engine: every failure maps to a client-safe HTTP
//! status with no internal leakage.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

/// StreamError is the single fallible outcome of resolve + proxy. Each variant
/// fixes the HTTP status the client sees; the Display text is logged, never sent.
#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    #[error("unresolvable movie id: {0}")]
    NotFound(String),
    #[error("bad range header")]
    BadRange,
    #[error("upstream failure: {0}")]
    Upstream(String),
}

impl StreamError {
    /// status maps a variant to its client-facing HTTP code.
    #[inline]
    fn status(&self) -> StatusCode {
        match self {
            StreamError::NotFound(_) => StatusCode::NOT_FOUND,
            StreamError::BadRange => StatusCode::RANGE_NOT_SATISFIABLE,
            StreamError::Upstream(_) => StatusCode::BAD_GATEWAY,
        }
    }
}

impl IntoResponse for StreamError {
    /// into_response logs the internal detail and returns only the bare status to
    /// the caller, never the error body.
    fn into_response(self) -> Response {
        tracing::warn!(error = %self, "stream request failed");
        self.status().into_response()
    }
}

/// Result is the crate-wide fallible alias.
pub type Result<T> = std::result::Result<T, StreamError>;
