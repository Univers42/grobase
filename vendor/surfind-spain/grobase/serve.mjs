// serve.mjs — zero-dependency static server + SAME-ORIGIN reverse proxy for the
// Surfind Spain SPA (built web/dist). The browser only ever talks to THIS
// origin, so the app needs no CORS on Kong and no per-port CSP. It:
//   • serves the built SPA (../web/dist) with History-API fallback to index.html;
//   • proxies the gateway path prefixes to Kong (HTTP + realtime WS upgrade).
// Kong is KONG_URL (in-container: http://kong:8000) else http://127.0.0.1:8000.
// Usage: PORT=5183 KONG_URL=http://kong:8000 node serve.mjs
import { createServer as httpServer, request as httpRequest } from 'node:http';
import { connect as netConnect } from 'node:net';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, '..', 'web', 'dist');
const PORT = Number(process.env.PORT || 5183);
const SELF_ORIGIN = `http://localhost:${PORT}`;
const API_PREFIXES = ['/auth/', '/rest/', '/realtime/', '/storage/', '/rpc/', '/query/'];
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.woff2': 'font/woff2', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.ico': 'image/x-icon',
  '.webmanifest': 'application/manifest+json',
};

const KONG = new URL(process.env.KONG_URL || 'http://127.0.0.1:8000');
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

/** resolveFile maps a URL path to a file under dist/. */
async function resolveFile(urlPath) {
  const clean = normalize(decodeURIComponent(urlPath.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  const rel = clean === '/' ? 'index.html' : clean.replace(/^\/+/, '');
  const candidate = join(DIST, rel);
  if (!candidate.startsWith(DIST)) return null;
  try {
    if ((await stat(candidate)).isFile()) return candidate;
  } catch {
    return null;
  }
  return null;
}

const handler = async (req, res) => {
  const path = (req.url || '/').split('?')[0];
  if (isApi(path)) return proxyHttp(req, res);
  let file = await resolveFile(req.url || '/');
  if (!file && !extname(path).length) file = join(DIST, 'index.html');
  if (!file) {
    res.writeHead(404).end('not found');
    return;
  }
  try {
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream' }).end(await readFile(file));
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

const server = httpServer(handler);
server.on('upgrade', proxyUpgrade);
server.on('clientError', (_err, socket) => socket.writable && socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'));
process.on('uncaughtException', (err) => console.error('[serve] uncaught:', err && err.message));
process.on('unhandledRejection', (err) => console.error('[serve] unhandled:', err && err.message));
server.listen(PORT, () => console.log(`surfind-spain SPA → ${SELF_ORIGIN}  (proxying gateway → ${KONG.origin})`));
