// serve.mjs — zero-dependency static server for the Canagrou SPA with
// History-API fallback (unknown non-asset paths → index.html, so /editor,
// /verify?token=… etc. resolve). Run via serve.sh inside a node container.
// Usage: PORT=5173 node serve.mjs   (serves this directory)
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('.', import.meta.url).pathname;
const PORT = Number(process.env.PORT || 5173);
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

/** resolveFile maps a URL path to a file, trying the web root then public/
 * (so the generated /baas-config.js and /overlays/* resolve), guarding against
 * traversal. */
async function resolveFile(urlPath) {
  const clean = normalize(decodeURIComponent(urlPath.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  const rel = clean === '/' ? 'index.html' : clean.replace(/^\/+/, '');
  // The services/ plugin layer is a SIBLING of web/ (vendor/Canagrou/services),
  // imported from web/src as ../../../services/* → browser requests /services/*.
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
      const s = await stat(candidate);
      if (s.isFile()) return candidate;
    } catch {
      // try the next root
    }
  }
  return null;
}

createServer(async (req, res) => {
  let file = await resolveFile(req.url || '/');
  if (!file && !extname(req.url || '').length) file = join(ROOT, 'index.html');
  if (!file) {
    res.writeHead(404).end('not found');
    return;
  }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] || 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(500).end('read error');
  }
}).listen(PORT, () => console.log(`Canagrou SPA → http://127.0.0.1:${PORT}`));
