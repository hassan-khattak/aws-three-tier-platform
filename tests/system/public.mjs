// Public check through the CDN: samples the dynamic routes and a static
// asset, records every sample (no silent retries) and exits non-zero on any
// failure. Used as the release smoke test and for evidence.
//
// node tests/system/public.mjs --url https://<distribution> [--samples 10]
//   [--interval-ms 500] [--timeout-ms 5000] [--out results.json]
import { writeFileSync } from 'node:fs';

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, arg, i, all) => {
  if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]?.startsWith('--') || all[i + 1] === undefined ? true : all[i + 1]]);
  return pairs;
}, []));
if (args.help || !args.url) {
  console.log('Usage: node tests/system/public.mjs --url https://<distribution> [--samples 10] [--interval-ms 500] [--timeout-ms 5000] [--out file.json]');
  process.exit(args.help ? 0 : 2);
}
const base = String(args.url).replace(/\/+$/, '');
const samples = Number(args.samples || 10);
const interval = Number(args['interval-ms'] || 500);
const timeout = Number(args['timeout-ms'] || 5000);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const checks = {
  '/': (status, body) => status === 200 && /Welcome, it's [^<]+<\/p>/.test(body) && /<pre>[0-9a-f-]{36}<\/pre>/.test(body),
  '/api/status': (status, body) => {
    try { const b = JSON.parse(body); return status === 200 && b.length === 1 && Number.isFinite(Date.parse(b[0].time)) && UUID.test(b[0].request_uuid); } catch { return false; }
  },
  '/stylesheets/style.css': (status, body) => status === 200 && body.length > 0,
};
const id = (path, body) => (path === '/api/status' ? (() => { try { return JSON.parse(body)[0].request_uuid; } catch { return null; } })() : (body.match(/<pre>([0-9a-f-]{36})<\/pre>/) || [])[1] || null);

const results = [];
for (let i = 0; i < samples; i++) {
  for (const path of Object.keys(checks)) {
    const started = Date.now();
    const sample = { t: new Date().toISOString(), url: base + path };
    try {
      const r = await fetch(base + path, { signal: AbortSignal.timeout(timeout), redirect: 'manual' });
      const body = await r.text();
      Object.assign(sample, {
        status: r.status, ms: Date.now() - started, ok: checks[path](r.status, body) && Date.now() - started < timeout,
        request_id: id(path, body), x_cache: r.headers.get('x-cache'), age: r.headers.get('age'),
        pop: r.headers.get('x-amz-cf-pop'), cache_control: r.headers.get('cache-control'),
      });
    } catch (e) {
      Object.assign(sample, { ms: Date.now() - started, ok: false, error: e.name });
    }
    results.push(sample);
  }
  if (i < samples - 1) await new Promise((r) => setTimeout(r, interval));
}

const dynamicIds = results.filter((r) => r.request_id).map((r) => r.request_id);
const summary = {
  base, samples, total: results.length, failed: results.filter((r) => !r.ok).length,
  // Each dynamic response must be fresh: no repeated request ID.
  dynamic_ids_unique: new Set(dynamicIds).size === dynamicIds.length,
  static_hits: results.filter((r) => r.url.endsWith('.css') && /^Hit from/.test(r.x_cache || '')).length,
  max_ms: Math.max(...results.map((r) => r.ms)), pops: [...new Set(results.map((r) => r.pop).filter(Boolean))],
};
for (const r of results) console.log(JSON.stringify(r));
console.log(JSON.stringify({ summary }));
if (args.out) writeFileSync(String(args.out), JSON.stringify({ summary, results }, null, 2));
process.exitCode = summary.failed === 0 && summary.dynamic_ids_unique ? 0 : 1;
