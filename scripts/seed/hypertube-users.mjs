// hypertube-users.mjs — seed ~8 real demo users + public profiles + a few
// comments into the Hypertube Grobase tenant. Idempotent: GoTrue admin upserts
// by email (re-find on conflict); profiles/comments upsert through the data
// plane by a stable `id`, so re-runs converge. Profiles NEVER carry email —
// that lives only in GoTrue. Avatars are deterministic DiceBear SVG URLs that
// load in-browser with no API key. Fully HTTP (Kong) so it runs in a container.
import { createHash } from "node:crypto";

const DEMO_USERS = [
  ["ava@hypertube.local", "ava", "Ava", "Reyes", "Sci-fi obsessive. Will defend Solaris (1972) to anyone."],
  ["liam@hypertube.local", "liam", "Liam", "O'Brien", "Noir and silent-era buff. Buster Keaton is the GOAT."],
  ["mia@hypertube.local", "mia", "Mia", "Kovac", "Documentary nerd and amateur film archivist."],
  ["noah@hypertube.local", "noah", "Noah", "Adeyemi", "Here for the public-domain horror. The older the print, the better."],
  ["zoe@hypertube.local", "zoe", "Zoe", "Lindqvist", "Animation and shorts. Watches everything twice."],
  ["ezra@hypertube.local", "ezra", "Ezra", "Cohen", "Westerns, war pictures, and a soft spot for melodrama."],
  ["iris@hypertube.local", "iris", "Iris", "Tanaka", "Comedy historian. If it made people laugh in 1925, I want it."],
  ["omar@hypertube.local", "omar", "Omar", "Haddad", "Mystery and crime serials. Subtitles always on."],
];

const PASSWORD = "Hypertube#2026";
const AVATAR_BASE = "https://api.dicebear.com/9.x/avataaars/svg?seed=";

const COMMENT_TEXTS = [
  "A genuine classic — the restoration holds up beautifully.",
  "Watched this last night, the pacing is far ahead of its time.",
  "Underrated gem. The cinematography alone is worth it.",
  "Comfort film. I come back to this one every winter.",
  "The ending still gets me every single time.",
  "Cannot believe this is public domain — total find.",
];

/** avatarUrl returns the deterministic DiceBear SVG URL for a username. */
function avatarUrl(username) {
  return `${AVATAR_BASE}${encodeURIComponent(username)}`;
}

/** stableId returns a deterministic 24-hex doc id so upserts converge on re-run. */
function stableId(seed) {
  return createHash("sha256").update(seed).digest("hex").slice(0, 24);
}

/** Read an env var or abort with a clear message naming the missing key. */
function mustEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`missing required env: ${name}`);
  return v;
}

/** loadConfig assembles Kong endpoints + keys from the environment. */
function loadConfig() {
  return {
    kong: process.env.HT_KONG_URL || "http://127.0.0.1:8002",
    anon: mustEnv("HT_ANON_APIKEY"),
    serviceKey: mustEnv("HT_SERVICE_APIKEY"),
    appKey: mustEnv("HT_API_KEY"),
    dbId: mustEnv("HT_MONGO_DB_ID"),
  };
}

/** findUserSub looks an existing GoTrue user up by email, returning its sub. */
async function findUserSub(cfg, email) {
  const res = await fetch(`${cfg.kong}/auth/v1/admin/users`, {
    headers: { apikey: cfg.anon, Authorization: `Bearer ${cfg.serviceKey}` },
  });
  if (!res.ok) return "";
  const data = await res.json();
  const match = (data.users || []).find((u) => u.email === email);
  return match ? match.id : "";
}

/** createUser admin-creates (or re-finds) a GoTrue user, returning its sub. */
async function createUser(cfg, email, username, first, last) {
  const res = await fetch(`${cfg.kong}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: cfg.anon,
      Authorization: `Bearer ${cfg.serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email,
      password: PASSWORD,
      email_confirm: true,
      user_metadata: { username, first_name: first, last_name: last },
    }),
  });
  if (res.status === 200 || res.status === 201) return (await res.json()).id || "";
  const sub = await findUserSub(cfg, email);
  if (sub) return sub;
  throw new Error(`GoTrue user ${email} failed (${res.status}): ${await res.text()}`);
}

/** upsertDoc upserts one document into a shared collection via the data plane. */
async function upsertDoc(cfg, table, doc) {
  const res = await fetch(`${cfg.kong}/query/v1/${cfg.dbId}/tables/${table}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: cfg.anon,
      "X-Baas-Api-Key": cfg.appKey,
    },
    body: JSON.stringify({ op: "upsert", data: doc }),
  });
  if (!res.ok) throw new Error(`upsert ${table}: HTTP ${res.status} ${await res.text()}`);
}

/** upsertProfile writes a public profile doc (no email) keyed by user_id. */
async function upsertProfile(cfg, sub, username, first, last, info) {
  await upsertDoc(cfg, "profiles", {
    id: sub,
    user_id: sub,
    username,
    first_name: first,
    last_name: last,
    avatar_url: avatarUrl(username),
    info,
    preferred_lang: "en",
  });
}

/** pickMovieIds returns up to `n` existing movie_ids from the catalog. */
async function pickMovieIds(cfg, n) {
  const res = await fetch(`${cfg.kong}/query/v1/${cfg.dbId}/tables/movies`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: cfg.anon,
      "X-Baas-Api-Key": cfg.appKey,
    },
    body: JSON.stringify({ op: "list", limit: n }),
  });
  if (!res.ok) return [];
  const body = await res.json();
  const rows = body.rows || body.data || body || [];
  return rows.map((m) => m.movie_id).filter(Boolean);
}

/** seedComments upserts a handful of comments across a couple of films. */
async function seedComments(cfg, movieIds, people) {
  if (movieIds.length === 0 || people.length === 0) return 0;
  let count = 0;
  for (let i = 0; i < movieIds.length && i < 2; i++) {
    const movieId = movieIds[i];
    for (let j = 0; j < 3 && j < people.length; j++) {
      const p = people[(i * 3 + j) % people.length];
      await upsertDoc(cfg, "comments", {
        id: stableId(`${movieId}:${p.sub}`),
        movie_id: movieId,
        author_id: p.sub,
        author_username: p.username,
        content: COMMENT_TEXTS[(i * 3 + j) % COMMENT_TEXTS.length],
        created_at: new Date().toISOString(),
      });
      count++;
    }
  }
  return count;
}

/** main seeds users + profiles, then a few comments on the top films. */
async function main() {
  const cfg = loadConfig();
  const people = [];
  for (const [email, username, first, last, info] of DEMO_USERS) {
    const sub = await createUser(cfg, email, username, first, last);
    await upsertProfile(cfg, sub, username, first, last, info);
    people.push({ sub, username });
    process.stdout.write(`[hypertube-users] ${email} → ${sub.slice(0, 8)}…\n`);
  }
  const movieIds = await pickMovieIds(cfg, 2);
  const comments = await seedComments(cfg, movieIds, people);
  process.stdout.write(
    `[hypertube-users] DONE: ${people.length} users/profiles, ${comments} comments on ${movieIds.length} films\n`,
  );
}

main().catch((err) => {
  process.stderr.write(`[hypertube-users] FAIL: ${err.message}\n`);
  process.exit(1);
});
