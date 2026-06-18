// smoke.mjs — exercises the real Canagrou web client lib against a LIVE stack:
// auth → profile → post → like → comment → storage upload/download → realtime
// EVENT → cleanup. Run in a node:22 --network host container (global fetch +
// WebSocket). Reads vendor/Canagrou/web/.env for the BaaS config. Browser-only
// globals (window, localStorage, URL.createObjectURL) are shimmed.
import { readFileSync } from 'node:fs';

const envText = readFileSync(new URL('../.env', import.meta.url), 'utf8');
const env = Object.fromEntries(
  envText.split('\n').filter((l) => l.includes('=') && !l.startsWith('#')).map((l) => {
    const i = l.indexOf('=');
    return [l.slice(0, i), l.slice(i + 1)];
  }),
);
const mounts = JSON.parse(env.VITE_BAAS_LIVE_MOUNTS || '[]');
const cfg = {
  url: env.VITE_BAAS_URL,
  anonKey: env.VITE_BAAS_KONG_KEY,
  apiKey: env.VITE_BAAS_API_KEY,
  dbId: mounts[0]?.dbId,
  storageBucket: env.VITE_BAAS_STORAGE_BUCKET,
  storageToken: env.VITE_BAAS_STORAGE_TOKEN,
  realtimeToken: env.VITE_BAAS_REALTIME_TOKEN,
};

const ls = new Map();
globalThis.window = { __BAAS__: cfg };
globalThis.localStorage = {
  getItem: (k) => (ls.has(k) ? ls.get(k) : null),
  setItem: (k, v) => ls.set(k, v),
  removeItem: (k) => ls.delete(k),
};
globalThis.URL.createObjectURL = () => 'blob:stub';

const { baas } = await import('../src/lib/baas.js');
let pass = 0;
const ok = (m) => {
  pass += 1;
  console.log(`  ✓ ${m}`);
};
const die = (m) => {
  console.error(`  ✗ ${m}`);
  process.exit(1);
};

const stamp = Date.now();
const email = `smoke_${stamp}@canagrou.local`;
const username = `smoke_${stamp}`;

const s = await baas.auth.signUp({ email, password: 'Sm0ke!pass42', username });
const userId = (s.user && s.user.id) || baas.auth.currentUser()?.id;
userId ? ok(`auth.signUp → user ${userId.slice(0, 8)}`) : die('signUp returned no user id');

await baas.db.insert('profiles', { id: userId, username });
ok('db.insert profile');

const post = await baas.db.insert('posts', { user_id: userId, image_key: `${userId}.png` });
post && post.id ? ok(`db.insert post → id ${post.id}`) : die('post insert returned no id');

const seen = await baas.db.list('posts', { where: { id: post.id } });
seen.length === 1 && seen[0].image_key === `${userId}.png` ? ok('db.list reads back the post') : die('post read-back mismatch');

await baas.db.insert('likes', { user_id: userId, post_id: post.id });
const likes = await baas.db.list('likes', { where: { post_id: post.id } });
likes.length === 1 ? ok('like toggle → count 1') : die(`expected 1 like, got ${likes.length}`);

await baas.db.insert('comments', { user_id: userId, post_id: post.id, content: 'smoke comment' });
const comments = await baas.db.list('comments', { where: { post_id: post.id } });
comments.length === 1 && comments[0].content === 'smoke comment' ? ok('comment add → list') : die('comment mismatch');

const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x42]);
const key = `${userId}.png`;
await baas.storage.upload(key, new Blob([bytes]), 'image/png');
ok('storage.upload');
const dl = await fetch(`${cfg.url}/storage/v1/object/${cfg.storageBucket}/${key}`, {
  headers: { apikey: cfg.anonKey, Authorization: `Bearer ${cfg.storageToken}` },
});
const dlBytes = new Uint8Array(await dl.arrayBuffer());
dlBytes.length === bytes.length && dlBytes.every((b, i) => b === bytes[i])
  ? ok('storage download byte-identical')
  : die('storage bytes differ');

const got = await new Promise((resolve) => {
  const timer = setTimeout(() => resolve(null), 8000);
  const sub = baas.realtime.subscribe('posts', (ev) => {
    clearTimeout(timer);
    sub.close();
    resolve(ev);
  });
  setTimeout(() => baas.db.insert('posts', { user_id: userId, image_key: `${userId}-rt.png` }), 1500);
});
got && got.event ? ok(`realtime EVENT '${got.event}' received`) : die('no realtime EVENT within 8s');

await baas.db.remove('posts', { user_id: userId });
await baas.storage.remove(key);
await baas.db.remove('profiles', { id: userId });
ok('cleanup');

console.log(`\nSMOKE PASS — ${pass} checks green`);
