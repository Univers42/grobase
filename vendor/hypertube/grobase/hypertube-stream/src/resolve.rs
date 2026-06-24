//! Resolution domain: turn a movie_id ("archive:<identifier>") into the upstream
//! direct media URL + content length, caching the result so repeat plays skip
//! the metadata round-trip.

use std::collections::HashMap;
use std::sync::Arc;

use reqwest::Client;
use serde::Deserialize;
use tokio::sync::RwLock;

use crate::config::Config;
use crate::error::{Result, StreamError};

/// Resolved is a cached upstream locator: the direct media URL and its total
/// byte length (None when the upstream never advertised one).
#[derive(Debug, Clone)]
pub struct Resolved {
    pub url: String,
    pub content_length: Option<u64>,
}

/// Resolver owns the resolution cache and the pooled HTTP client used for the
/// catalog + archive.org metadata lookups. Injected via app state, never global.
pub struct Resolver {
    config: Config,
    http: Client,
    cache: RwLock<HashMap<String, Resolved>>,
}

impl Resolver {
    /// new builds a resolver over a shared pooled client and an empty cache.
    pub fn new(config: Config, http: Client) -> Self {
        Resolver {
            config,
            http,
            cache: RwLock::new(HashMap::new()),
        }
    }

    /// resolve returns the cached locator for id, or looks it up (catalog first,
    /// archive.org metadata second), caches, and returns it.
    pub async fn resolve(&self, id: &str) -> Result<Resolved> {
        if let Some(hit) = self.cache.read().await.get(id).cloned() {
            return Ok(hit);
        }
        let resolved = self.lookup(id).await?;
        self.cache
            .write()
            .await
            .insert(id.to_string(), resolved.clone());
        Ok(resolved)
    }

    /// lookup tries the Grobase catalog's stream_url field, then falls back to
    /// archive.org metadata for any "archive:<identifier>" id.
    async fn lookup(&self, id: &str) -> Result<Resolved> {
        if let Some(url) = self.catalog_url(id).await {
            return Ok(Resolved {
                url,
                content_length: None,
            });
        }
        let identifier = id
            .strip_prefix("archive:")
            .ok_or_else(|| StreamError::NotFound(id.to_string()))?;
        self.archive_locator(identifier).await
    }

    /// catalog_url reads movies.stream_url for id via the data plane, returning
    /// None on any miss so the archive.org fallback can run.
    async fn catalog_url(&self, id: &str) -> Option<String> {
        if !self.config.catalog_enabled() {
            return None;
        }
        let row = self.catalog_query(id).await.ok()??;
        row.stream_url.filter(|s| !s.is_empty())
    }

    /// catalog_query POSTs a single-row "get" to {dataplane}/query/v1/{db}/tables/movies
    /// with the app-key headers (no Bearer — shared catalog read).
    async fn catalog_query(&self, id: &str) -> Result<Option<CatalogRow>> {
        let url = format!(
            "{}/query/v1/{}/tables/movies",
            self.config.dataplane_url,
            self.config.db_id.as_deref().unwrap_or_default()
        );
        let body = serde_json::json!({
            "op": "get",
            "filter": { "movie_id": { "$eq": id } },
            "limit": 1
        });
        let res = self
            .http
            .post(&url)
            .header(
                "apikey",
                self.config.anon_apikey.as_deref().unwrap_or_default(),
            )
            .header(
                "X-Baas-Api-Key",
                self.config.app_api_key.as_deref().unwrap_or_default(),
            )
            .json(&body)
            .send()
            .await
            .map_err(|e| StreamError::Upstream(e.to_string()))?;
        if !res.status().is_success() {
            return Ok(None);
        }
        let envelope: CatalogEnvelope = res
            .json()
            .await
            .map_err(|e| StreamError::Upstream(e.to_string()))?;
        Ok(envelope.rows.into_iter().next())
    }

    /// archive_locator fetches archive.org metadata, picks the largest playable
    /// file, and builds its direct download URL + content length.
    async fn archive_locator(&self, identifier: &str) -> Result<Resolved> {
        let meta_url = format!("https://archive.org/metadata/{identifier}");
        let meta: ArchiveMeta = self
            .http
            .get(&meta_url)
            .send()
            .await
            .map_err(|e| StreamError::Upstream(e.to_string()))?
            .json()
            .await
            .map_err(|e| StreamError::Upstream(e.to_string()))?;
        let file = pick_file(&meta.files)
            .ok_or_else(|| StreamError::NotFound(format!("archive:{identifier}")))?;
        Ok(Resolved {
            url: format!("https://archive.org/download/{identifier}/{}", file.name),
            content_length: file.size.as_deref().and_then(|s| s.parse().ok()),
        })
    }
}

/// pick_file selects the largest video file, preferring mp4, then ogv/webm.
fn pick_file(files: &[ArchiveFile]) -> Option<&ArchiveFile> {
    ["mp4", "ogv", "webm"]
        .iter()
        .find_map(|ext| largest_with_ext(files, ext))
}

/// largest_with_ext returns the biggest file whose name ends in ".<ext>".
fn largest_with_ext<'a>(files: &'a [ArchiveFile], ext: &str) -> Option<&'a ArchiveFile> {
    let suffix = format!(".{ext}");
    files
        .iter()
        .filter(|f| f.name.to_ascii_lowercase().ends_with(&suffix))
        .max_by_key(|f| {
            f.size
                .as_deref()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0)
        })
}

/// CatalogEnvelope is the {"rows":[...]} data-plane response shape.
#[derive(Deserialize)]
struct CatalogEnvelope {
    #[serde(default)]
    rows: Vec<CatalogRow>,
}

/// CatalogRow is the only catalog field resolve needs: an optional direct URL.
#[derive(Deserialize)]
struct CatalogRow {
    #[serde(default)]
    stream_url: Option<String>,
}

/// ArchiveMeta is the subset of archive.org's /metadata response we parse.
#[derive(Deserialize)]
struct ArchiveMeta {
    #[serde(default)]
    files: Vec<ArchiveFile>,
}

/// ArchiveFile is one entry of the archive.org file listing (size is a string).
#[derive(Deserialize)]
struct ArchiveFile {
    name: String,
    #[serde(default)]
    size: Option<String>,
}

/// SharedResolver is the app-state handle threaded into handlers.
pub type SharedResolver = Arc<Resolver>;
