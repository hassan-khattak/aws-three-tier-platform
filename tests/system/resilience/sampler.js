// Continuous in-VPC sampler for failure tests. Requests / and /api/status
// every INTERVAL_MS for DURATION_S; logs each failure, a summary every 10 s,
// and a final report with outage windows. Passed to the probe task as a
// command override. Env: PROBE_URL, DURATION_S, INTERVAL_MS.
const base = process.env.PROBE_URL;
const durationMs = Number(process.env.DURATION_S || 180) * 1000;
const interval = Number(process.env.INTERVAL_MS || 500);
const paths = ['/', '/api/status'];
const stats = Object.fromEntries(paths.map((p) => [p, { ok: 0, fail: 0, maxMs: 0, windows: [], open: null, lastOk: null }]));
const log = (o) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }));
async function hit(path) {
  const s = stats[path];
  const started = Date.now();
  let outcome;
  try {
    const r = await fetch(base + path, { signal: AbortSignal.timeout(6000), redirect: 'manual' });
    const body = await r.text();
    const fresh = path === '/' ? /Welcome, it's /.test(body) : (() => { try { const b = JSON.parse(body); return Math.abs(Date.now() - Date.parse(b[0].time)) < 60000; } catch { return false; } })();
    outcome = r.status === 200 && fresh ? 'ok' : `http_${r.status}`;
  } catch (e) { outcome = e.name; }
  const ms = Date.now() - started;
  s.maxMs = Math.max(s.maxMs, ms);
  if (outcome === 'ok') {
    s.ok++; s.lastOk = new Date().toISOString();
    if (s.open) { s.open.end = new Date().toISOString(); s.open.ms = Date.parse(s.open.end) - Date.parse(s.open.start); s.windows.push(s.open); s.open = null; }
  } else {
    s.fail++;
    if (!s.open) s.open = { start: new Date(started).toISOString(), first: outcome, failures: 0 };
    s.open.failures++;
    log({ fail: path, outcome, ms });
  }
}
(async () => {
  const end = Date.now() + durationMs;
  let nextReport = Date.now() + 10000;
  log({ sampler: 'start', base, durationMs, interval });
  while (Date.now() < end) {
    const tick = Date.now();
    await Promise.all(paths.map(hit));
    if (Date.now() >= nextReport) { log({ window: Object.fromEntries(paths.map((p) => [p, { ok: stats[p].ok, fail: stats[p].fail }])) }); nextReport += 10000; }
    await new Promise((r) => setTimeout(r, Math.max(0, interval - (Date.now() - tick))));
  }
  for (const p of paths) if (stats[p].open) { stats[p].open.end = 'still failing at end'; stats[p].windows.push(stats[p].open); }
  log({ sampler: 'done', results: stats });
  process.exitCode = paths.some((p) => stats[p].open || stats[p].ok === 0) ? 1 : 0;
})();
