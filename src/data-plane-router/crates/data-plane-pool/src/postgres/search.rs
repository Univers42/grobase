//! Full-text + pgvector search-clause builders the list path layers on. Pure
//! (params-in/SQL-out) — `quote_ident`-safe identifiers, bound query/embedding
//! params, allowlisted language `regconfig` and metric operators.

use super::BoxedParam;
use crate::ident::quote_ident;
use data_plane_core::{DataPlaneError, DataPlaneResult};

/// Allowlisted Postgres text-search configuration (`regconfig`) — inlined as a
/// literal (never from raw client text), default `english`.
fn ts_language(lang: Option<&str>) -> DataPlaneResult<&'static str> {
    Ok(match lang.unwrap_or("english").to_ascii_lowercase().as_str() {
        "english" => "english",
        "simple" => "simple",
        "spanish" => "spanish",
        "french" => "french",
        "german" => "german",
        "portuguese" => "portuguese",
        "italian" => "italian",
        "dutch" => "dutch",
        "russian" => "russian",
        other => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("unsupported search language '{other}'"),
            })
        }
    })
}

/// Lowers a [`SearchSpec`] to `(predicate, rank_expr)`: a ranked Postgres
/// full-text match over `concat_ws`-joined columns. The query string is BOUND
/// (`$n`), the language is an allowlisted literal, columns are `quote_ident`'d.
/// Both the predicate and the rank reference the same `$n` (parameter reuse).
pub(super) fn build_search(
    spec: &data_plane_core::SearchSpec,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<(String, String)> {
    if spec.columns.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "search requires at least one column".to_string(),
        });
    }
    if spec.query.trim().is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "search requires a non-empty query".to_string(),
        });
    }
    let lang = ts_language(spec.language.as_deref())?;
    let cols = spec
        .columns
        .iter()
        .map(|c| quote_ident(c))
        .collect::<DataPlaneResult<Vec<_>>>()?;
    let doc = format!("concat_ws(' ', {})", cols.join(", "));
    params.push(Box::new(spec.query.clone()));
    let q = params.len();
    let tsv = format!("to_tsvector('{lang}', {doc})");
    let tsq = format!("websearch_to_tsquery('{lang}', ${q})");
    Ok((format!("{tsv} @@ {tsq}"), format!("ts_rank({tsv}, {tsq})")))
}

/// Lowers a [`VectorSpec`] to a pgvector distance expression `"col" <op> $n::vector`.
/// The embedding is bound as a `'[…]'` text literal cast to `vector`; the metric
/// operator is an allowlist (`cosine`→`<=>`, `l2`→`<->`, `ip`→`<#>`).
pub(super) fn build_vector_order(
    spec: &data_plane_core::VectorSpec,
    params: &mut Vec<BoxedParam>,
) -> DataPlaneResult<String> {
    if spec.query.is_empty() {
        return Err(DataPlaneError::InvalidRequest {
            message: "vector search requires a non-empty query embedding".to_string(),
        });
    }
    let col = quote_ident(&spec.column)?;
    let opsym = match spec
        .metric
        .as_deref()
        .unwrap_or("cosine")
        .to_ascii_lowercase()
        .as_str()
    {
        "cosine" => "<=>",
        "l2" | "euclidean" => "<->",
        "ip" | "inner" | "dot" => "<#>",
        other => {
            return Err(DataPlaneError::InvalidRequest {
                message: format!("unsupported vector metric '{other}'"),
            })
        }
    };
    let lit = format!(
        "[{}]",
        spec.query
            .iter()
            .map(|f| if f.is_finite() { format!("{f}") } else { "0".to_string() })
            .collect::<Vec<_>>()
            .join(",")
    );
    params.push(Box::new(lit));
    let p = params.len();
    // `$n::text::vector`, not `$n::vector`: the inner `::text` makes Postgres infer
    // the bind param as TEXT (so the bound Rust String matches), then pgvector
    // parses the text literal into a vector. A bare `$n::vector` makes the driver
    // expect a native vector param and fails to serialize the String.
    Ok(format!("{col} {opsym} ${p}::text::vector"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_lowers_to_ranked_multicolumn_tsvector_match() {
        let mut p: Vec<BoxedParam> = Vec::new();
        let (pred, rank) = build_search(
            &data_plane_core::SearchSpec {
                query: "hello world".into(),
                columns: vec!["title".into(), "body".into()],
                language: Some("english".into()),
            },
            &mut p,
        )
        .unwrap();
        assert_eq!(
            pred,
            "to_tsvector('english', concat_ws(' ', \"title\", \"body\")) @@ websearch_to_tsquery('english', $1)"
        );
        assert_eq!(
            rank,
            "ts_rank(to_tsvector('english', concat_ws(' ', \"title\", \"body\")), websearch_to_tsquery('english', $1))"
        );
        assert_eq!(p.len(), 1, "query bound ONCE, reused by predicate + rank");
    }

    #[test]
    fn fts_defaults_english_and_rejects_bad_language_or_no_columns() {
        let mut p: Vec<BoxedParam> = Vec::new();
        let (pred, _) = build_search(
            &data_plane_core::SearchSpec { query: "x".into(), columns: vec!["c".into()], language: None },
            &mut p,
        )
        .unwrap();
        assert!(pred.starts_with("to_tsvector('english',"), "default lang: {pred}");
        // a hostile regconfig string is rejected, never inlined into the SQL.
        let mut p2: Vec<BoxedParam> = Vec::new();
        assert!(matches!(
            build_search(
                &data_plane_core::SearchSpec {
                    query: "x".into(),
                    columns: vec!["c".into()],
                    language: Some("english'); DROP TABLE x;--".into()),
                },
                &mut p2,
            )
            .unwrap_err(),
            DataPlaneError::InvalidRequest { .. }
        ));
        // empty columns / empty query are rejected.
        let mut p3: Vec<BoxedParam> = Vec::new();
        assert!(build_search(
            &data_plane_core::SearchSpec { query: "x".into(), columns: vec![], language: None },
            &mut p3
        )
        .is_err());
    }

    #[test]
    fn vector_lowers_to_pgvector_distance_per_metric() {
        let mut p: Vec<BoxedParam> = Vec::new();
        let ord = build_vector_order(
            &data_plane_core::VectorSpec {
                column: "embedding".into(),
                query: vec![0.1, 0.2, 0.3],
                k: Some(5),
                metric: Some("cosine".into()),
            },
            &mut p,
        )
        .unwrap();
        assert_eq!(ord, "\"embedding\" <=> $1::text::vector");
        assert_eq!(p.len(), 1, "embedding bound as one text param, cast to vector");
        for (m, sym) in [("l2", "<->"), ("ip", "<#>"), ("cosine", "<=>")] {
            let mut pp: Vec<BoxedParam> = Vec::new();
            let o = build_vector_order(
                &data_plane_core::VectorSpec { column: "e".into(), query: vec![1.0], k: None, metric: Some(m.into()) },
                &mut pp,
            )
            .unwrap();
            assert!(o.contains(sym), "metric {m} should use {sym}: {o}");
        }
        // bad metric + empty embedding are rejected.
        let mut pe: Vec<BoxedParam> = Vec::new();
        assert!(build_vector_order(
            &data_plane_core::VectorSpec { column: "e".into(), query: vec![1.0], k: None, metric: Some("nope".into()) },
            &mut pe
        )
        .is_err());
        let mut pq: Vec<BoxedParam> = Vec::new();
        assert!(build_vector_order(
            &data_plane_core::VectorSpec { column: "e".into(), query: vec![], k: None, metric: None },
            &mut pq
        )
        .is_err());
    }
}
