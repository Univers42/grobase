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
const normCatalog = (m) => ({ id: m.id, title: m.title || m.name, poster: m.posterPath, backdrop: m.backdropPath, vote: m.voteAverage || 0, overview: m.overview });
const normLike = (l) => ({ id: l.media_id, title: l.title, poster: l.poster_path, vote: l.vote_average || 0 });
const discover = (page = 1) => tmdb(`/discover/movie?page=${page}`).then((d) => arr(d).map(normCatalog));
const discoverTv = (page = 1) => tmdb(`/discover/tv?page=${page}`).then((d) => arr(d).map(normCatalog));
const search = (q) => tmdb(`/search?query=${encodeURIComponent(q)}`).then((d) => arr(d).filter((m) => m.mediaType !== 'PERSON').map(normCatalog));
const detail = (id) => tmdb(`/movie/${id}`);
const likeCount = (id) => rest.rpc('like_count', { p_media_id: id, p_media_type: 'MOVIE' }).catch(() => 0);
const reviewsFor = (id) => rest.get(`reviews?media_id=eq.${id}&media_type=eq.MOVIE&select=*&order=created_at.desc`).catch(() => []);
const myLikes = () => (me() ? rest.get('likes?select=*&order=created_at.desc').catch(() => []) : Promise.resolve([]));
const myReviews = () => (me() ? rest.get(`reviews?user_id=eq.${me()}&select=*&order=created_at.desc`).catch(() => []) : Promise.resolve([]));

// Classic films that reliably HAVE trailers (current popular releases often don't
// yet), so the trailer button always plays something recognizable.
const CLASSICS = [
  { id: 27205, title: 'Inception', poster: '/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg', vote: 8.4 },
  { id: 603, title: 'The Matrix', poster: '/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg', vote: 8.2 },
  { id: 157336, title: 'Interstellar', poster: '/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg', vote: 8.4 },
  { id: 155, title: 'The Dark Knight', poster: '/qJ2tW6WMUDux911r6m7haRef0WH.jpg', vote: 8.5 },
  { id: 680, title: 'Pulp Fiction', poster: '/d5iIlFn5s0ImszYzBPb8JPIfbXD.jpg', vote: 8.5 },
  { id: 13, title: 'Forrest Gump', poster: '/arw2vcBveWOVZr6pxd9XTd1TdQa.jpg', vote: 8.5 },
  { id: 550, title: 'Fight Club', poster: '/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg', vote: 8.4 },
  { id: 278, title: 'The Shawshank Redemption', poster: '/q6y0Go1tsGEsmtFryDOJo3dEmqu.jpg', vote: 8.7 },
  { id: 238, title: 'The Godfather', poster: '/3bhkrj58Vtu7enYsRolD1fZdja1.jpg', vote: 8.7 },
  { id: 122, title: 'The Return of the King', poster: '/rCzpDGLbOoPwLjy3OAm5NUPOTrC.jpg', vote: 8.5 },
];

let PROFILES = {};
async function loadProfiles() { try { (await rest.get('movieverse_profiles?select=id,username')).forEach((p) => { PROFILES[p.id] = p.username; }); } catch { /* anon may be limited */ } }

// ── rendering ─────────────────────────────────────────────────────────────────
const cardHTML = (c) => `
  <div class="card" data-id="${c.id}">
    <img loading="lazy" src="${posterURL(c.poster)}" alt="" />
    <button class="card-trailer" data-trailer="${c.id}" title="Ver tráiler">▶ Tráiler</button>
    <div class="meta"><div class="t">${esc(c.title || '—')}</div><div class="r">★ ${(+c.vote || 0).toFixed(1)}</div></div>
  </div>`;
const grid = (list) => (list.length ? `<div class="grid">${list.map(cardHTML).join('')}</div>` : `<div class="empty">Sin resultados. (¿TMDB_API_KEY configurada en .env?)</div>`);
const row = (title, list) => (list.length ? `<div class="row"><h3>${esc(title)}</h3><div class="row-scroll">${list.map(cardHTML).join('')}</div></div>` : '');
const heroHTML = (m) => `
  <div class="hero" data-id="${m.id}">
    <img class="bg" src="${posterURL(m.backdrop || m.poster, 780)}" alt="" />
    <div class="shade"></div>
    <div class="info">
      <h1>${esc(m.title)}</h1>
      <p class="ov">${esc(m.overview || '')}</p>
      <div class="actions"><button class="btn" data-trailer="${m.id}">▶ Ver tráiler</button><button class="btn ghost" data-id="${m.id}">Info</button><span class="pill">★ ${(+m.vote).toFixed(1)}</span></div>
    </div>
  </div>`;

function renderNav() {
  const s = session();
  el('nav').innerHTML = s
    ? `<span class="navlink" data-go="#/profile">@${esc(s.username || 'perfil')}</span><button class="btn ghost" id="logout">Salir</button>`
    : `<span class="navlink" data-go="#/login">Entrar</span>`;
}

async function viewHome() {
  el('app').innerHTML = '<div class="empty">Cargando catálogo…</div>';
  try {
    const [pop, tv] = await Promise.all([discover(1), discoverTv(1)]);
    const hc = CLASSICS[Math.floor(Math.random() * 4)];
    let hero;
    try { const hd = await detail(hc.id); hero = { id: hc.id, title: hd.title || hc.title, backdrop: hd.backdropPath, poster: hc.poster, vote: hd.voteAverage || hc.vote, overview: hd.overview }; }
    catch { hero = pop.find((m) => m.backdrop) || pop[0]; }
    el('app').innerHTML = (hero ? heroHTML(hero) : '') + row('Clásicos imprescindibles (con tráiler)', CLASSICS) + row('Populares ahora', pop) + row('Series', tv);
  } catch { el('app').innerHTML = '<div class="empty">El catálogo no respondió. (¿TMDB_API_KEY en .env?)</div>'; }
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
        <div class="row" style="gap:8px">
          <button class="btn ${liked ? 'ghost' : ''}" id="likeBtn" ${me() ? '' : 'disabled title="Entra para dar me gusta"'}>${liked ? '♥ Te gusta' : '♡ Me gusta'}</button>
          ${d.trailerKey ? '<button class="btn" id="trailerBtn">▶ Ver tráiler</button>' : ''}
        </div>
      </div>
    </div>
    ${d.trailerKey ? '<div class="trailer-wrap" id="trailerBox"></div>' : ''}
    <div class="sect">
      <h3>Reseñas (${reviews.length})</h3>
      ${me() ? `<div class="row" style="margin:8px 0"><select id="rv-rating">${[10, 9, 8, 7, 6, 5, 4, 3, 2, 1].map((n) => `<option value="${n}">${n}/10</option>`).join('')}</select></div>
        <textarea id="rv-text" rows="2" placeholder="Escribe tu reseña…"></textarea>
        <button class="btn" id="rv-add" style="margin-top:8px">Publicar reseña</button>` : '<p class="muted">Entra para escribir una reseña.</p>'}
      <div id="rv-list">${reviews.map((r) => `<div class="rev"><div class="who">${esc(PROFILES[r.user_id] || 'usuario')} <span class="stars">${stars(r.rating)}</span></div><div class="cm">${esc(r.comment || '')}</div></div>`).join('') || '<p class="muted">Sé el primero en reseñar.</p>'}</div>
    </div>`;
  $('#mx').onclick = closeModal;
  const tb = $('#trailerBtn');
  if (tb && d.trailerKey) tb.onclick = () => {
    el('sheet').querySelector('#trailerBox').innerHTML = `<iframe class="trailer" src="https://www.youtube.com/embed/${encodeURIComponent(d.trailerKey)}?autoplay=1&rel=0" allow="autoplay; encrypted-media" allowfullscreen></iframe>`;
    tb.style.display = 'none';
  };
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
const closeModal = () => { el('modal').classList.remove('open'); el('sheet').innerHTML = ''; };

/** openTrailer pops a big centered video lightbox and autoplays the YouTube
 *  trailer — one click from a card/hero, Netflix-style. Friendly message if the
 *  title has no trailer. */
async function openTrailer(id) {
  el('modal').classList.add('open');
  el('sheet').innerHTML = '<span class="x" id="mx">×</span><div class="trailer-wrap"><p class="muted">Cargando tráiler…</p></div>';
  $('#mx').onclick = closeModal;
  let d; try { d = await detail(id); } catch { d = {}; }
  if (!d.trailerKey) {
    el('sheet').innerHTML = `<span class="x" id="mx">×</span><div class="sect"><h3>${esc(d.title || 'Tráiler')}</h3><p class="muted">No hay tráiler disponible para este título.</p></div>`;
  } else {
    el('sheet').innerHTML = `<span class="x" id="mx">×</span><div class="trailer-wrap"><h3 style="margin:4px 0 10px">${esc(d.title || '')} — Tráiler</h3><iframe class="trailer" src="https://www.youtube.com/embed/${encodeURIComponent(d.trailerKey)}?autoplay=1&rel=0" allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe></div>`;
  }
  $('#mx').onclick = closeModal;
}

// ── router + wiring ────────────────────────────────────────────────────────────
function route() {
  const h = location.hash || '#/';
  if (h.startsWith('#/login')) return viewLogin();
  if (h.startsWith('#/profile')) return viewProfile();
  return viewHome();
}
document.addEventListener('click', (e) => {
  const go = e.target.closest('[data-go]'); if (go) { location.hash = go.dataset.go; return; }
  const tr = e.target.closest('[data-trailer]'); if (tr) { e.stopPropagation(); return openTrailer(tr.dataset.trailer); }
  const idEl = e.target.closest('[data-id]'); if (idEl) return openMovie(idEl.dataset.id);
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
