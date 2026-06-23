// MovieVerse client — talks ONLY to Grobase, same-origin (nginx proxies /auth,
// /rest, /tmdb to Kong). Auth = GoTrue; user data = PostgREST + RLS; catalog =
// the Go TMDB proxy. The public anon key is safe in the browser — RLS enforces
// real access. No build step, no framework: one ES module, plain fetch + DOM.
const CFG = window.__GROBASE__ || { url: '', anonKey: '', tmdbBase: '/tmdb/v1' };
const PLACEHOLDER = 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%222%22 height=%223%22/%3E';
// The proxy already returns full poster URLs; DB-seeded rows store a raw TMDB path.
const posterURL = (p) => (!p ? PLACEHOLDER : (String(p).startsWith('http') ? p : `https://image.tmdb.org/t/p/w342${p}`));
const $ = (s, r = document) => r.querySelector(s);
const el = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const stars = (n) => '★'.repeat(n) + '☆'.repeat(10 - n);

// ── session ──────────────────────────────────────────────────────────────────
const SKEY = 'mv.session';
const session = () => { try { return JSON.parse(localStorage.getItem(SKEY) || 'null'); } catch { return null; } };
const setSession = (s) => (s ? localStorage.setItem(SKEY, JSON.stringify(s)) : localStorage.removeItem(SKEY));
const me = () => (session() || {}).user_id || null;

// ── api ──────────────────────────────────────────────────────────────────────
function headers(auth = false, write = false) {
  const h = { apikey: CFG.anonKey };
  if (write) h['Content-Type'] = 'application/json';
  const s = session();
  if (auth && s && s.access_token) h.Authorization = `Bearer ${s.access_token}`;
  return h;
}
async function jfetch(path, opts = {}) {
  const r = await fetch(CFG.url + path, opts);
  const txt = await r.text();
  const body = txt ? JSON.parse(txt) : null;
  if (!r.ok) throw new Error((body && (body.message || body.error_description || body.error)) || `HTTP ${r.status}`);
  return body;
}
const auth = {
  login: (email, password) => jfetch('/auth/v1/token?grant_type=password', { method: 'POST', headers: headers(false, true), body: JSON.stringify({ email, password }) }),
  signup: (email, password, username) => jfetch('/auth/v1/signup', { method: 'POST', headers: headers(false, true), body: JSON.stringify({ email, password, data: { username } }) }),
};
const rest = {
  get: (path) => jfetch('/rest/v1/' + path, { headers: headers(true) }),
  post: (table, row) => jfetch('/rest/v1/' + table, { method: 'POST', headers: { ...headers(true, true), Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(row) }),
  del: (path) => fetch(CFG.url + '/rest/v1/' + path, { method: 'DELETE', headers: headers(true) }),
  rpc: (name, args) => jfetch('/rest/v1/rpc/' + name, { method: 'POST', headers: headers(true, true), body: JSON.stringify(args) }),
};
const tmdb = (path) => jfetch(`${CFG.tmdbBase}${path}`, { headers: headers(false) });

// ── data (proxy returns flat arrays, camelCase, full poster URLs) ─────────────
const arr = (x) => (Array.isArray(x) ? x : []);
const normCatalog = (m) => ({ id: m.id, title: m.title || m.name, poster: m.posterPath, vote: m.voteAverage || 0 });
const normLike = (l) => ({ id: l.media_id, title: l.title, poster: l.poster_path, vote: l.vote_average || 0 });
const discover = (page = 1) => tmdb(`/discover/movie?page=${page}`).then((d) => arr(d).map(normCatalog));
const search = (q) => tmdb(`/search?query=${encodeURIComponent(q)}`).then((d) => arr(d).filter((m) => m.mediaType !== 'PERSON').map(normCatalog));
const detail = (id) => tmdb(`/movie/${id}`);
const likeCount = (id) => rest.rpc('like_count', { p_media_id: id, p_media_type: 'MOVIE' }).catch(() => 0);
const reviewsFor = (id) => rest.get(`reviews?media_id=eq.${id}&media_type=eq.MOVIE&select=*&order=created_at.desc`).catch(() => []);
const myLikes = () => (me() ? rest.get('likes?select=*&order=created_at.desc').catch(() => []) : Promise.resolve([]));
const myReviews = () => (me() ? rest.get(`reviews?user_id=eq.${me()}&select=*&order=created_at.desc`).catch(() => []) : Promise.resolve([]));

let PROFILES = {};
async function loadProfiles() { try { (await rest.get('movieverse_profiles?select=id,username')).forEach((p) => { PROFILES[p.id] = p.username; }); } catch { /* anon may be limited */ } }

// ── rendering ─────────────────────────────────────────────────────────────────
const cardHTML = (c) => `
  <div class="card" data-id="${c.id}">
    <img loading="lazy" src="${posterURL(c.poster)}" alt="" />
    <div class="meta"><div class="t">${esc(c.title || '—')}</div><div class="r">★ ${(+c.vote || 0).toFixed(1)}</div></div>
  </div>`;
const grid = (list) => (list.length ? `<div class="grid">${list.map(cardHTML).join('')}</div>` : `<div class="empty">Sin resultados. (¿TMDB_API_KEY configurada en .env?)</div>`);

function renderNav() {
  const s = session();
  el('nav').innerHTML = s
    ? `<span class="navlink" data-go="#/profile">@${esc(s.username || 'perfil')}</span><button class="btn ghost" id="logout">Salir</button>`
    : `<span class="navlink" data-go="#/login">Entrar</span>`;
}

async function viewHome() {
  el('app').innerHTML = `<h1>Películas populares</h1><div class="empty">Cargando catálogo…</div>`;
  try { el('app').innerHTML = `<h1>Películas populares</h1>${grid(await discover(1))}`; }
  catch { el('app').innerHTML = `<h1>Películas populares</h1><div class="empty">El catálogo no respondió.</div>`; }
}
async function viewSearch(q) {
  el('app').innerHTML = `<h1>Resultados: “${esc(q)}”</h1><div class="empty">Buscando…</div>`;
  try { el('app').innerHTML = `<h1>Resultados: “${esc(q)}”</h1>${grid(await search(q))}`; }
  catch { el('app').innerHTML = `<h1>Resultados</h1><div class="empty">La búsqueda no respondió.</div>`; }
}

function viewLogin() {
  el('app').innerHTML = `
    <div class="form">
      <h1>Entrar / Registrarse</h1>
      <input id="f-email" type="email" placeholder="email" />
      <input id="f-pass" type="password" placeholder="contraseña" />
      <input id="f-user" type="text" placeholder="usuario (solo al registrarse)" />
      <div class="row"><button class="btn" id="do-login">Entrar</button><button class="btn ghost" id="do-signup">Crear cuenta</button></div>
      <p class="err" id="f-err"></p>
      <p class="muted">Demo: neo@movieverse.local · MovieVerse#2026</p>
    </div>`;
  const finish = (s, username) => { setSession({ access_token: s.access_token, user_id: (s.user && s.user.id) || s.id, username }); renderNav(); location.hash = '#/profile'; };
  $('#do-login').onclick = async () => {
    try { const s = await auth.login(el('f-email').value.trim(), el('f-pass').value); finish(s, PROFILES[(s.user && s.user.id)] || el('f-email').value.split('@')[0]); }
    catch (e) { el('f-err').textContent = e.message; }
  };
  $('#do-signup').onclick = async () => {
    try {
      const u = el('f-user').value.trim() || el('f-email').value.split('@')[0];
      const s = await auth.signup(el('f-email').value.trim(), el('f-pass').value, u);
      if (!s.access_token) { el('f-err').textContent = 'Revisa tu email para confirmar, luego entra.'; return; }
      finish(s, u);
    } catch (e) { el('f-err').textContent = e.message; }
  };
}

async function viewProfile() {
  if (!me()) { location.hash = '#/login'; return; }
  el('app').innerHTML = `<h1>Mi perfil</h1><div class="empty">Cargando…</div>`;
  const [likes, reviews] = await Promise.all([myLikes(), myReviews()]);
  el('app').innerHTML = `
    <h1>Mi perfil <span class="muted">· @${esc((session() || {}).username || '')}</span></h1>
    <h3>Me gusta (${likes.length})</h3>
    ${likes.length ? `<div class="grid">${likes.map(normLike).map(cardHTML).join('')}</div>` : '<p class="muted">Aún no has dado me gusta.</p>'}
    <h3 style="margin-top:26px">Mis reseñas (${reviews.length})</h3>
    ${reviews.length ? reviews.map((r) => `<div class="rev"><div class="who">${esc(r.title)} <span class="stars">${stars(r.rating)}</span></div><div class="cm">${esc(r.comment || '')}</div></div>`).join('') : '<p class="muted">Aún no has escrito reseñas.</p>'}`;
}

// ── detail modal ──────────────────────────────────────────────────────────────
async function openMovie(id) {
  el('modal').classList.add('open');
  el('sheet').innerHTML = `<span class="x" id="mx">×</span><div class="sect"><p class="muted">Cargando…</p></div>`;
  let d; try { d = await detail(id); } catch { d = { id, title: 'Película', overview: '' }; }
  const [count, reviews, mine] = await Promise.all([likeCount(id), reviewsFor(id), myLikes()]);
  const liked = mine.some((l) => String(l.media_id) === String(id));
  el('sheet').innerHTML = `
    <span class="x" id="mx">×</span>
    <div class="hero">
      <img src="${posterURL(d.posterPath)}" alt="" />
      <div>
        <h2>${esc(d.title || d.name)}</h2>
        <p class="row" style="gap:8px"><span class="pill">★ ${(d.voteAverage || 0).toFixed(1)}</span><span class="pill" id="lc">♥ ${count}</span><span class="muted">${esc((d.releaseDate || '').slice(0, 4))}</span></p>
        <p class="ov">${esc(d.overview || 'Sin sinopsis.')}</p>
        <button class="btn ${liked ? 'ghost' : ''}" id="likeBtn" ${me() ? '' : 'disabled title="Entra para dar me gusta"'}>${liked ? '♥ Te gusta' : '♡ Me gusta'}</button>
      </div>
    </div>
    <div class="sect">
      <h3>Reseñas (${reviews.length})</h3>
      ${me() ? `<div class="row" style="margin:8px 0"><select id="rv-rating">${[10, 9, 8, 7, 6, 5, 4, 3, 2, 1].map((n) => `<option value="${n}">${n}/10</option>`).join('')}</select></div>
        <textarea id="rv-text" rows="2" placeholder="Escribe tu reseña…"></textarea>
        <button class="btn" id="rv-add" style="margin-top:8px">Publicar reseña</button>` : '<p class="muted">Entra para escribir una reseña.</p>'}
      <div id="rv-list">${reviews.map((r) => `<div class="rev"><div class="who">${esc(PROFILES[r.user_id] || 'usuario')} <span class="stars">${stars(r.rating)}</span></div><div class="cm">${esc(r.comment || '')}</div></div>`).join('') || '<p class="muted">Sé el primero en reseñar.</p>'}</div>
    </div>`;
  $('#mx').onclick = closeModal;
  const lb = $('#likeBtn');
  if (lb && me()) lb.onclick = async () => {
    try {
      if (liked) await rest.del(`likes?media_id=eq.${id}&media_type=eq.MOVIE`);
      else await rest.post('likes', { user_id: me(), media_id: id, media_type: 'MOVIE', title: d.title || d.name, poster_path: d.posterPath, vote_average: d.voteAverage });
      openMovie(id);
    } catch (e) { alert(e.message); }
  };
  const add = $('#rv-add');
  if (add) add.onclick = async () => {
    try {
      await rest.post('reviews', { user_id: me(), media_id: id, media_type: 'MOVIE', title: d.title || d.name, poster_path: d.posterPath, rating: +$('#rv-rating').value, comment: $('#rv-text').value });
      openMovie(id);
    } catch (e) { alert(e.message); }
  };
}
const closeModal = () => el('modal').classList.remove('open');

// ── router + wiring ────────────────────────────────────────────────────────────
function route() {
  const h = location.hash || '#/';
  if (h.startsWith('#/login')) return viewLogin();
  if (h.startsWith('#/profile')) return viewProfile();
  return viewHome();
}
document.addEventListener('click', (e) => {
  const card = e.target.closest('.card'); if (card) return openMovie(card.dataset.id);
  const go = e.target.closest('[data-go]'); if (go) { location.hash = go.dataset.go; return; }
  if (e.target.id === 'logout') { setSession(null); renderNav(); location.hash = '#/'; route(); }
});
el('modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });
let st; el('search').addEventListener('input', (e) => { clearTimeout(st); const q = e.target.value.trim(); st = setTimeout(() => { if (q) { location.hash = '#/'; viewSearch(q); } else route(); }, 350); });
window.addEventListener('hashchange', route);

(async function init() {
  if (!CFG.anonKey) { el('app').innerHTML = '<div class="empty">Falta config.js — ejecuta <code>make movieverse</code>.</div>'; return; }
  await loadProfiles();
  renderNav();
  route();
})();
