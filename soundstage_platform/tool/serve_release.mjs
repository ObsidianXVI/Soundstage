// A static server for `build/web` that behaves like production hosting
// (Firebase Hosting): brotli/gzip compression, cache headers, and the
// cross-origin isolation headers Flutter's multi-threaded skwasm renderer
// needs. No dependencies; Node 18+.
//
//   node tool/serve_release.mjs [dir=build/web] [--port 8080] [--no-compress] [--no-cache]
//
// Open http://localhost:8080/ (add ?wheel=native to compare wheel scrolling).
import { createServer } from 'node:http';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { join, extname, normalize } from 'node:path';
import zlib from 'node:zlib';

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => (args.includes(n) ? args[args.indexOf(n) + 1] : d);
const root = args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--port') ?? 'build/web';
const port = Number(opt('--port', 8080));
const compress = !flag('--no-compress');
const noCache = flag('--no-cache');

const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json', '.png': 'image/png',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.wav': 'audio/wav', '.lrc': 'text/plain',
  '.txt': 'text/plain', '.otf': 'font/otf', '.symbols': 'text/plain',
};
const compressible = new Set(['.html', '.js', '.mjs', '.wasm', '.json', '.ttf', '.otf', '.lrc', '.txt', '.symbols']);  // audio stays raw: Safari needs byte ranges
const cache = new Map();

function body(path, enc) {
  const key = `${path}|${enc}|${statSync(path).mtimeMs}`;
  if (cache.has(key)) return cache.get(key);
  const raw = readFileSync(path);
  const out = enc === 'br'
    ? zlib.brotliCompressSync(raw, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: raw.length } })
    : enc === 'gzip' ? zlib.gzipSync(raw, { level: 9 }) : raw;
  cache.set(key, out);
  return out;
}

createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let path = normalize(join(root, decodeURIComponent(url.pathname)));
  if (!path.startsWith(normalize(root))) { res.writeHead(403).end(); return; }
  if (existsSync(path) && statSync(path).isDirectory()) path = join(path, 'index.html');
  if (!existsSync(path)) { res.writeHead(404).end('not found'); return; }
  const ext = extname(path);
  const accept = req.headers['accept-encoding'] ?? '';
  const enc = compress && compressible.has(ext)
    ? (accept.includes('br') ? 'br' : accept.includes('gzip') ? 'gzip' : 'identity')
    : 'identity';
  let data = body(path, enc);
  let status = 200;
  const headers = {
    'Content-Type': types[ext] ?? 'application/octet-stream',
    'Content-Length': data.length,
    'Cache-Control': noCache ? 'no-store' : ext === '.html' || path.endsWith('flutter_service_worker.js') ? 'no-cache' : 'public, max-age=3600',
    // Cross-origin isolation: lets skwasm use threads (SharedArrayBuffer).
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Embedder-Policy': 'credentialless',
    'Accept-Ranges': enc === 'identity' ? 'bytes' : 'none',
  };
  const range = enc === 'identity' && /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '');
  if (range) {
    const total = data.length;
    const start = range[1] === '' ? total - Number(range[2]) : Number(range[1]);
    const end = range[1] === '' || range[2] === '' ? total - 1 : Math.min(Number(range[2]), total - 1);
    headers['Content-Range'] = `bytes ${start}-${end}/${total}`;
    data = data.subarray(start, end + 1);
    headers['Content-Length'] = data.length;
    status = 206;
  }
  if (enc !== 'identity') { headers['Content-Encoding'] = enc; headers['Vary'] = 'Accept-Encoding'; }
  res.writeHead(status, headers).end(data);
}).listen(port, () => console.log(`Serving ${root} on http://localhost:${port}/ (${compress ? 'br/gzip' : 'no compression'})`));
