// serve.mjs — zero-dependency static server + SAME-ORIGIN reverse proxy for the
// Nimbus SPA (built dist/). The browser only ever talks to THIS origin, so there
// is no CORS and we never mutate the shared Kong. It:
//   • serves the built SPA (dist/) and public/ (baas-config.js), with
//     History-API fallback to index.html;
//   • rewrites the served /baas-config.js `url` to this origin so SDK calls are
//     same-origin;
//   • proxies the gateway path prefixes to Kong over HTTP, plus the realtime WS.
// Kong's real URL is read from public/baas-config.js. Run via serve.sh.
// Usage: PORT=8124 node serve.mjs
import { createServer as httpServer, request as httpRequest } from 'node:http';
import { createServer as httpsServer } from 'node:https';
import { connect as netConnect } from 'node:net';
import { readFile, stat } from 'node:fs/promises';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('.', import.meta.url).pathname;
const DIST = join(ROOT, 'dist');
const PORT = Number(process.env.PORT || 8124);
const CERT = join(ROOT, 'certs', 'cert.pem');
const KEY = join(ROOT, 'certs', 'key.pem');
const TLS = !process.env.NO_TLS && existsSync(CERT) && existsSync(KEY);
const SELF_ORIGIN = `${TLS ? 'https' : 'http'}://localhost:${PORT}`;
const API_PREFIXES = ['/auth/', '/rest/', '/query/', '/storage/', '/functions/', '/analytics/', '/realtime/'];
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.webm': 'video/webm',
  '.mp4': 'video/mp4',
  '.ico': 'image/x-icon',
};
const CSP = [
  "default-src 'self'", "base-uri 'self'", "object-src 'none'", "form-action 'self'",
  "frame-ancestors 'none'", "script-src 'self'", "style-src 'self' 'unsafe-inline'",
  "font-src 'self' data:", "img-src 'self' data: blob:", "media-src 'self'", "connect-src 'self' ws: wss:",
].join('; ');

/** kongTarget reads the real gateway URL from the generated browser config. */
function kongTarget() {
  try {
    const cfg = readFileSync(join(ROOT, 'public', 'baas-config.js'), 'utf8');
    const m = cfg.match(/url:\s*['"]([^'"]+)['"]/);
    if (m && m[1]) return new URL(m[1]);
  } catch {
    // fall through to the default
  }
  return new URL(process.env.KONG_URL || 'http://127.0.0.1:8002');
}
const KONG = kongTarget();

const isApi = (path) => API_PREFIXES.some((p) => path === p.slice(0, -1) || path.startsWith(p));

/** proxyHttp forwards an API request to Kong on a fresh connection per request. */
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

/** resolveFile maps a URL path to a file under dist/ then public/. */
async function resolveFile(urlPath) {
  const clean = normalize(decodeURIComponent(urlPath.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  const rel = clean === '/' ? 'index.html' : clean.replace(/^\/+/, '');
  for (const dir of [DIST, join(ROOT, 'public')]) {
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

/** serveConfig serves baas-config.js with `url` rewritten to this origin. */
async function serveConfig(res) {
  const raw = await readFile(join(ROOT, 'public', 'baas-config.js'), 'utf8');
  const body = raw.replace(/url:\s*['"][^'"]*['"]/, `url: '${SELF_ORIGIN}'`);
  res.writeHead(200, { 'Content-Type': TYPES['.js'], 'Cache-Control': 'no-store' }).end(body);
}

const handler = async (req, res) => {
  const path = (req.url || '/').split('?')[0];
  if (isApi(path)) return proxyHttp(req, res);
  if (path === '/baas-config.js') return serveConfig(res).catch(() => res.writeHead(500).end('config error'));
  let file = await resolveFile(req.url || '/');
  if (!file && !extname(path).length) file = join(DIST, 'index.html');
  if (!file) {
    res.writeHead(404).end('not found');
    return;
  }
  try {
    res
      .writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream', 'Content-Security-Policy': CSP })
      .end(await readFile(file));
  } catch {
    res.writeHead(500).end('read error');
  }
};

/** proxyUpgrade pipes a WebSocket upgrade (realtime) through to Kong. */
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
server.listen(PORT, () => console.log(`Nimbus SPA → ${SELF_ORIGIN}  (proxying gateway → ${KONG.origin}${TLS ? ', TLS on' : ''})`));
