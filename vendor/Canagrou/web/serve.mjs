// serve.mjs — zero-dependency static server + SAME-ORIGIN reverse proxy for the
// Canagrou SPA. The browser only ever talks to THIS origin, so there is no CORS
// (the dev gateway's allowlist doesn't include arbitrary dev ports, and we must
// not mutate the shared Kong). It:
//   • serves the SPA (web/), public/ (baas-config.js, overlays), and the sibling
//     services/ plugin layer, with History-API fallback to index.html;
//   • rewrites the served /baas-config.js `url` to this origin so all SDK calls
//     are same-origin;
//   • proxies the gateway path prefixes (/auth /rest /query /storage /functions
//     /graphql /analytics /realtime) to Kong over HTTP, and proxies the realtime
//     WebSocket upgrade too.
// Kong's real URL is read from public/baas-config.js (the generated config).
// Run via serve.sh inside a node container. Usage: PORT=8123 node serve.mjs
import { createServer as httpServer, request as httpRequest } from 'node:http';
import { createServer as httpsServer } from 'node:https';
import { connect as netConnect } from 'node:net';
import { readFile, stat } from 'node:fs/promises';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('.', import.meta.url).pathname;
const PORT = Number(process.env.PORT || 8123);
// TLS protects the user-facing connection (login/portal). Enabled when a
// self-signed cert is present (serve.sh generates one); falls back to HTTP.
const CERT = join(ROOT, 'certs', 'cert.pem');
const KEY = join(ROOT, 'certs', 'key.pem');
const TLS = !process.env.NO_TLS && existsSync(CERT) && existsSync(KEY);
const SELF_ORIGIN = `${TLS ? 'https' : 'http'}://localhost:${PORT}`;
const API_PREFIXES = ['/auth/', '/rest/', '/query/', '/storage/', '/functions/', '/graphql/', '/analytics/', '/realtime/'];
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

/** kongTarget reads the real gateway URL from the generated browser config. */
function kongTarget() {
  try {
    const cfg = readFileSync(join(ROOT, 'public', 'baas-config.js'), 'utf8');
    const m = cfg.match(/url:\s*"([^"]+)"/);
    if (m) return new URL(m[1]);
  } catch {
    // fall through to the default
  }
  return new URL(process.env.KONG_URL || 'http://127.0.0.1:8002');
}
const KONG = kongTarget();

const isApi = (path) => API_PREFIXES.some((p) => path === p.slice(0, -1) || path.startsWith(p));

/** proxyHttp forwards an API request to Kong and streams the response back.
 * Uses a FRESH connection per request (agent:false, Connection:close) — pooled
 * keep-alive to Kong went stale under the browser's request pattern and Kong
 * replied 502 "invalid response from upstream". Hop-by-hop headers are stripped.
 */
function proxyHttp(req, res) {
  const headers = { ...req.headers, host: KONG.host, connection: 'close' };
  delete headers['proxy-connection'];
  delete headers['keep-alive'];
  const upstream = httpRequest(
    { host: KONG.hostname, port: KONG.port, method: req.method, path: req.url, headers, agent: false },
    (r) => {
      res.writeHead(r.statusCode || 502, r.headers);
      r.pipe(res);
    },
  );
  upstream.on('error', () => {
    if (!res.headersSent) res.writeHead(502);
    res.end('upstream error');
  });
  req.pipe(upstream);
}

/** resolveFile maps a URL path to a file (web root → public → sibling services). */
async function resolveFile(urlPath) {
  const clean = normalize(decodeURIComponent(urlPath.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  const rel = clean === '/' ? 'index.html' : clean.replace(/^\/+/, '');
  if (rel.startsWith('services/')) {
    const sib = join(ROOT, '..', rel);
    if (sib.startsWith(join(ROOT, '..', 'services'))) {
      try {
        if ((await stat(sib)).isFile()) return sib;
      } catch {
        return null;
      }
    }
  }
  for (const dir of [ROOT, join(ROOT, 'public')]) {
    const candidate = join(dir, rel);
    if (!candidate.startsWith(dir)) continue;
    try {
      if ((await stat(candidate)).isFile()) return candidate;
    } catch {
      // try the next root
    }
  }
  return null;
}

// NOSTORE — never let the browser cache the SPA (bare server has no
// ETag/Last-Modified, so heuristic caching served STALE modules → users kept the
// old buggy code after a fix). Dev convenience over caching.
const NOSTORE = 'no-store, no-cache, must-revalidate';

/** serveConfig serves baas-config.js with `url` rewritten to this origin. */
async function serveConfig(res) {
  const raw = await readFile(join(ROOT, 'public', 'baas-config.js'), 'utf8');
  const body = raw.replace(/url:\s*"[^"]*"/, `url: "${SELF_ORIGIN}"`);
  res.writeHead(200, { 'Content-Type': TYPES['.js'], 'Cache-Control': NOSTORE }).end(body);
}

const handler = async (req, res) => {
  const path = (req.url || '/').split('?')[0];
  if (isApi(path)) return proxyHttp(req, res);
  if (path === '/baas-config.js') return serveConfig(res).catch(() => res.writeHead(500).end('config error'));
  let file = await resolveFile(req.url || '/');
  if (!file && !extname(path).length) file = join(ROOT, 'index.html');
  if (!file) {
    res.writeHead(404).end('not found');
    return;
  }
  try {
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream', 'Cache-Control': NOSTORE }).end(await readFile(file));
  } catch {
    res.writeHead(500).end('read error');
  }
};

/** proxyUpgrade pipes a WebSocket upgrade (realtime) through to Kong, tearing
 * down BOTH sockets together — without this, a WS left open by a page that
 * navigates away leaks an upstream connection, and after enough navigations new
 * connections are refused (ERR_TOO_MANY_RETRIES). */
function proxyUpgrade(req, socket, head) {
  const upstream = netConnect(Number(KONG.port), KONG.hostname, () => {
    const headers = { ...req.headers, host: KONG.host };
    const lines = Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\r\n');
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${lines}\r\n\r\n`);
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream);
    upstream.pipe(socket);
  });
  const close = () => {
    socket.destroy();
    upstream.destroy();
  };
  upstream.on('error', close);
  upstream.on('close', close);
  socket.on('error', close);
  socket.on('close', close);
}

const server = TLS
  ? httpsServer({ cert: readFileSync(CERT), key: readFileSync(KEY) }, handler)
  : httpServer(handler);
server.on('upgrade', proxyUpgrade);
server.on('clientError', (_err, socket) => socket.writable && socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'));
process.on('uncaughtException', (err) => console.error('[serve] uncaught:', err && err.message));
process.on('unhandledRejection', (err) => console.error('[serve] unhandled:', err && err.message));
server.listen(PORT, () => console.log(`Canagrou SPA → ${SELF_ORIGIN}  (proxying gateway → ${KONG.origin}${TLS ? ', TLS on' : ''})`));
