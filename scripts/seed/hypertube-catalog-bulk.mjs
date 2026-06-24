// Bulk catalog seeder — pages archive.org's collection:feature_films and upserts
// thousands of real public-domain films into the Hypertube Mongo `movies` mount.
// Zero-dep Node (uses only node:crypto + global fetch). Idempotent: each film
// upserts under a stable 24-hex `id` derived from its movie_id, so re-runs converge.
import { createHash } from "node:crypto";

const KONG = process.env.HT_KONG_URL || "http://127.0.0.1:8002";
const ANON = mustEnv("HT_ANON_APIKEY");
const APP_KEY = mustEnv("HT_API_KEY");
const DB_ID = mustEnv("HT_MONGO_DB_ID");
const TARGET_USABLE = Number(process.env.HT_CATALOG_TARGET || 1500);
const ROWS_PER_PAGE = 200;
const MAX_PAGES = Number(process.env.HT_CATALOG_MAX_PAGES || 30);
const JUNK = /capcut|template|\btest\b|sample|trailer|\bintro\b|logo|lyric|tutorial|#/i;
const UPLOAD_NOISE = /^(?:[A-Za-z]{1,3}\s+)?\d{1,4}\s+(?=\S)/;
const SEARCH_QUERY =
  'collection:(feature_films) AND mediatype:movies AND format:"Archive BitTorrent"';

/** Read an env var or abort with a clear message naming the missing key. */
function mustEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`missing required env: ${name}`);
  return v;
}

/** Stable 24-hex doc id for a movie_id (SHA-256 prefix) — keeps upserts idempotent. */
function stableId(movieId) {
  return createHash("sha256").update(movieId).digest("hex").slice(0, 24);
}

/** Resolve after `ms` milliseconds (cooperative throttle against Kong rate limits). */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Strip leading upload-index noise ("774 ", "C 6 ", "Ad 10 ") from a raw title. */
function cleanTitle(raw) {
  return String(raw ?? "").replace(UPLOAD_NOISE, "").trim();
}

/** Coerce archive.org's year field (string|array|number) to an int or null. */
function toYear(value) {
  const first = Array.isArray(value) ? value[0] : value;
  const n = parseInt(String(first ?? "").slice(0, 4), 10);
  return Number.isInteger(n) && n > 1800 && n < 2100 ? n : null;
}

/** Normalize archive.org `subject` (string|array, comma/semicolon lists) to genres. */
function toGenres(subject) {
  const parts = Array.isArray(subject) ? subject : [subject];
  const out = [];
  for (const part of parts) {
    for (const piece of String(part ?? "").split(/[;,]/)) {
      const g = piece.trim();
      if (g && g.length <= 40 && !out.includes(g)) out.push(g);
    }
  }
  return out.slice(0, 8);
}

/** True when a search doc is a usable film (has a clean, non-junk title ≥2 chars). */
function isUsable(title) {
  return title.length >= 2 && !JUNK.test(title);
}

/** Map one archive.org search doc to the shared `movies` collection contract. */
function toMovie(doc) {
  const identifier = doc.identifier;
  const title = cleanTitle(doc.title);
  if (!identifier || !isUsable(title)) return null;
  const movieId = `archive:${identifier}`;
  return {
    id: stableId(movieId),
    movie_id: movieId,
    title,
    year: toYear(doc.year),
    cover_url: `https://archive.org/services/img/${identifier}`,
    rating: null,
    genres: toGenres(doc.subject),
    summary: "",
    cast: [],
    length_min: null,
    popularity: Number.isFinite(Number(doc.downloads)) ? Number(doc.downloads) : 0,
    source: "archive.org",
  };
}

/** Fetch one page of the feature_films search; returns the raw docs array. */
async function fetchPage(page) {
  const url =
    "https://archive.org/advancedsearch.php?q=" +
    encodeURIComponent(SEARCH_QUERY) +
    "&fl[]=identifier&fl[]=title&fl[]=year&fl[]=downloads&fl[]=subject" +
    `&rows=${ROWS_PER_PAGE}&page=${page}&output=json`;
  const res = await fetch(url, { headers: { "User-Agent": "hypertube-seeder/1" } });
  if (!res.ok) throw new Error(`archive.org page ${page}: HTTP ${res.status}`);
  const json = await res.json();
  return json?.response?.docs ?? [];
}

/** Upsert one movie into the Mongo mount via the Grobase data plane (app key).
 *  On a 429 (Kong per-minute rate limit) it backs off the quota window and
 *  retries, so a bulk seed rides the 300/min cap instead of failing under it. */
async function upsert(movie) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(`${KONG}/query/v1/${DB_ID}/tables/movies`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: ANON,
        "X-Baas-Api-Key": APP_KEY,
      },
      body: JSON.stringify({ op: "upsert", data: movie }),
    });
    if (res.ok) return;
    if (res.status === 429 && attempt < 5) {
      const retryAfter = Number(res.headers.get("retry-after")) || 6;
      await sleep(retryAfter * 1000);
      continue;
    }
    throw new Error(`upsert ${movie.movie_id}: HTTP ${res.status} ${await res.text()}`);
  }
}

/** Page the search, dedup by movie_id, and collect up to TARGET_USABLE films. */
async function collect() {
  const movies = new Map();
  for (let page = 1; page <= MAX_PAGES && movies.size < TARGET_USABLE; page++) {
    const docs = await fetchPage(page);
    if (docs.length === 0) break;
    for (const doc of docs) {
      const movie = toMovie(doc);
      if (movie) movies.set(movie.movie_id, movie);
    }
    console.log(`page ${page}: scanned ${docs.length}, usable so far ${movies.size}`);
  }
  return [...movies.values()];
}

/** Upsert every collected film sequentially, logging progress every 200 rows. */
async function seed(movies) {
  let done = 0;
  let failed = 0;
  for (const movie of movies) {
    try {
      await upsert(movie);
      done++;
    } catch (err) {
      failed++;
      if (failed <= 10) console.error(`  skip: ${err.message}`);
    }
    if (done % 200 === 0 && done > 0) console.log(`upserted ${done}/${movies.length}`);
    await sleep(210);
  }
  return { done, failed };
}

/** Entry point: collect the catalog, upsert it, print a final summary. */
async function main() {
  console.log(`query: ${SEARCH_QUERY}`);
  console.log(`target usable: ${TARGET_USABLE} | mount: ${DB_ID}`);
  const movies = await collect();
  console.log(`collected ${movies.length} usable films — upserting…`);
  const { done, failed } = await seed(movies);
  console.log(`DONE: upserted ${done}, failed ${failed}, total ${movies.length}`);
}

main().catch((err) => {
  console.error(`FATAL: ${err.message}`);
  process.exit(1);
});
