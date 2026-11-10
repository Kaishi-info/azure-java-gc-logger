// Offline dashboard tests: pure functions run in a VM context without a DOM.
// Synthetic data only. Run: node tests/test_dashboard.cjs
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');

const html = fs.readFileSync(path.join(__dirname, '..', 'dashboard', 'index.html'), 'utf8');
const src = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const ctx = { __GC_TIMELINE_NO_INIT__: true, Intl, Date, Number, String, Math, Object, Array, Map, Set, JSON, console, globalThis: null };
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(src + '\n;globalThis.__api = { ST, I18N, parseSamples, parseJsonl, parseGcLog, hostFromFile, detectGaps, hourlyFloor, analyzeHost, analyze, heatmap, daily, makeDemo, buildRawExport, buildAnalysisExport, linreg, tzParts };', ctx);
const A = ctx.__api;

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('PASS  ' + name); }
  catch (e) { console.log('FAIL  ' + name + '\n      ' + e.message); process.exitCode = 1; }
}
const HOUR = 3600000, DAY = 86400000;
const csvHead = 'timestamp_utc,host,pid,old_used_mib,old_capacity_mib,heap_used_mib,heap_capacity_mib,old_pct,fgc_total,ygc_total,gct_total_s,gct_delta_ms,fgc_delta';
function series({ host = 'H1', hours = 24, stepMin = 1, start = Date.UTC(2026, 0, 5), floor = t => 500, pid = () => 100, skip = () => false }) {
  const out = [];
  for (let m = 0; m < hours * 60; m += stepMin) {
    const t = start + m * 60000;
    if (skip(t)) continue;
    const used = floor(t) + (m % 30) * 5; // sawtooth above the floor
    out.push({ t, host, pid: pid(t), old_used_mib: used, old_capacity_mib: 2048, old_pct: 100 * used / 2048, heap_used_mib: used + 200, gct_delta_ms: 10, fgc_delta: 0 });
  }
  return out;
}

// ---------------------------------------------------------------- static / safety
test('no network APIs or remote URLs in the dashboard', () => {
  for (const bad of [/https?:\/\//i, /\bfetch\s*\(/, /XMLHttpRequest/, /WebSocket/, /sendBeacon/, /EventSource/, /\bimport\s*\(/, /<script[^>]+src=/i, /<link[^>]+href=/i, /@import/]) {
    assert.ok(!bad.test(html), 'found ' + bad);
  }
});
test('CSP blocks all connections', () => {
  assert.match(html, /Content-Security-Policy" content="default-src 'none';[^"]*connect-src 'none'/);
});
test('sanitized: no institution or student wording', () => {
  for (const bad of [/学生/, /答案/, /student/i, /university/i, /大学/, /kaishi/i, /開志/]) assert.ok(!bad.test(html), 'found ' + bad); // public-content: allow
});
test('i18n: ja and en have the same keys, and every data-i18n key exists', () => {
  const ja = Object.keys(A.I18N.ja).sort(), en = Object.keys(A.I18N.en).sort();
  assert.deepStrictEqual(ja, en);
  for (const m of html.matchAll(/data-i18n="(\w+)"/g)) assert.ok(A.I18N.en[m[1]], 'missing key ' + m[1]);
});

// ---------------------------------------------------------------- parsing
test('collector CSV parses with numbers and source', () => {
  const s = A.parseSamples(csvHead + '\n2026-01-15T00:20:00Z,APP01,123,900,1024,1000,2000,87.89,1,10,2.4,40,1\n', 'a.csv');
  assert.strictEqual(s.length, 1);
  assert.strictEqual(s[0].host, 'APP01'); assert.strictEqual(s[0].old_pct, 87.89); assert.strictEqual(s[0].old_capacity_mib, 1024); assert.strictEqual(s[0].source, 'a.csv');
});
test('NDJSON: metrics, events, old-format metrics without capacity, bad lines counted', () => {
  const j = A.parseJsonl([
    '{"record_type":"metric","timestamp_utc":"2026-01-15T00:20:00Z","host":"APP01","pid":1,"old_pct":88}',
    '{"record_type":"event","timestamp_utc":"2026-01-15T00:22:00Z","host":"APP02","pid":2,"event_name":"JAVA_GC_OLD_HIGH","old_pct":86.1}',
    'not json', ''
  ].join('\n'));
  assert.strictEqual(j.samples.length, 1); assert.strictEqual(j.samples[0].old_capacity_mib, null);
  assert.strictEqual(j.events.length, 1); assert.strictEqual(j.skipped, 1);
});
test('missing numeric values stay null (not zero)', () => {
  const s = A.parseSamples(csvHead + '\n2026-01-15T00:20:00Z,APP01,123,,,,,,,,,,\n');
  assert.strictEqual(s[0].old_pct, null); assert.strictEqual(s[0].gct_delta_ms, null);
});
test('Unified GC log: utctime/time decorations, kinds, units', () => {
  const log = [
    '[2026-01-15T09:20:00.000+0900][10.0s][info][gc] GC(1) Pause Young (Normal) (G1 Evacuation Pause) 1024M->768M(4096M) 12.5ms',
    '[2026-11-10T07:16:30.589+0000][95.794s][info][gc] GC(68) Pause Full (G1 Evacuation Pause) 126M->104M(128M) 13.557ms',
    '[2026-11-10T07:16:31.000Z][info][gc] GC(70) Pause Young (Mixed) (G1 Evacuation Pause) 2G->1G(4G) 3.000ms',
    '[12.345s][info][gc] GC(2) Pause Young (Normal) (G1 Evacuation Pause) 24M->4M(256M) 3.123ms',
    '[2026-11-10T07:16:31.000+0000][info][gc,heap] GC(70) Eden regions: 10->0(12)',
    '[2026-11-10T07:16:31.000+0000][info][gc] GC(71) Concurrent Cycle 5.201ms'
  ].join('\n');
  const g = A.parseGcLog(log, 'H');
  assert.strictEqual(g.gcs.length, 3);
  assert.strictEqual(g.gcs[0].t, Date.parse('2026-01-15T00:20:00Z')); assert.strictEqual(g.gcs[0].after_mib, 768); assert.strictEqual(g.gcs[0].kind, 'Young');
  assert.strictEqual(g.gcs[1].kind, 'Full'); assert.strictEqual(g.gcs[1].after_mib, 104);
  assert.strictEqual(g.gcs[2].after_mib, 1024);
  assert.strictEqual(g.skipped, 1, 'uptime-only heap line is counted as skipped');
});
test('host name from GC log file names', () => {
  const cases = { 'APP01_gc.log': 'APP01', 'app02-gc.log.3': 'app02', 'LEAK.log': 'LEAK', 'web01.gc.log': 'web01', 'gc.log': 'unknown', 'dir/APP03_gc.log.0': 'APP03', 'my host!.log': 'my_host_' };
  for (const [f, h] of Object.entries(cases)) assert.strictEqual(A.hostFromFile(f), h, f);
});

// ---------------------------------------------------------------- analysis
test('gaps: detected from the median interval, never filled', () => {
  const start = Date.UTC(2026, 0, 5);
  const s = series({ hours: 6, skip: t => t >= start + 2 * HOUR && t < start + 3 * HOUR });
  const gaps = A.detectGaps(s, 60000);
  assert.strictEqual(gaps.length, 1); assert.strictEqual(gaps[0].minutes, 61);
  const a = A.analyzeHost('H1', s, [], []);
  assert.ok(a.coverage_pct < 85 && a.coverage_pct > 80, 'coverage ' + a.coverage_pct);
});
test('rising baseline is assessed as rising with a time-to-limit', () => {
  const start = Date.UTC(2026, 0, 5);
  const a = A.analyzeHost('H1', series({ hours: 48, floor: t => 500 + (t - start) / HOUR * 10 }), [], []);
  assert.strictEqual(a.assessment, 'rising');
  assert.ok(Math.abs(a.baseline.slope_mib_per_day - 240) < 5, 'slope ' + a.baseline.slope_mib_per_day);
  assert.ok(a.baseline.r2 > 0.99);
  assert.ok(a.time_to_limit_hours > 0);
  assert.ok(a.top_rises.length > 0);
});
test('flat baseline is assessed as flat', () => {
  const a = A.analyzeHost('H1', series({ hours: 48 }), [], []);
  assert.strictEqual(a.assessment, 'flat'); assert.strictEqual(a.time_to_limit_hours, null);
});
test('short data is "insufficient", not a verdict', () => {
  assert.strictEqual(A.analyzeHost('H1', series({ hours: 3 }), [], []).assessment, 'insufficient');
});
test('PID change starts a new segment: pre-restart growth is not extrapolated', () => {
  const start = Date.UTC(2026, 0, 5), restart = start + 24 * HOUR;
  const s = series({ hours: 48, floor: t => t < restart ? 500 + (t - start) / HOUR * 30 : 500, pid: t => t < restart ? 1 : 2 });
  const a = A.analyzeHost('H1', s, [], []);
  assert.strictEqual(a.restarts.length, 1); assert.strictEqual(a.assessment, 'flat');
});
test('post-GC trend uses Full GC "after" values when available', () => {
  const start = Date.UTC(2026, 0, 5);
  const gcs = Array.from({ length: 12 }, (_, i) => ({ t: start + i * 2 * HOUR, host: 'H1', kind: 'Full', after_mib: 300 + i * 20 }));
  const a = A.analyzeHost('H1', series({ hours: 24 }), gcs, []);
  assert.strictEqual(a.post_gc.basis, 'full_gc_after'); assert.ok(Math.abs(a.post_gc.slope_mib_per_day - 240) < 1);
});
test('heatmap: 7x24, no-data cells are null, values by weekday/hour in the time zone', () => {
  const mon0utc = Date.UTC(2026, 0, 5, 0, 30); // Monday 00:30 UTC = Monday 09:30 JST
  const cells = A.heatmap([{ t: mon0utc, host: 'H', old_pct: 50 }, { t: mon0utc + 60000, host: 'H', old_pct: 70 }], 'Asia/Tokyo', 'maxOld', '*');
  assert.strictEqual(cells.length, 7); assert.strictEqual(cells[0].length, 24);
  assert.strictEqual(cells[0][9].v, 70); assert.strictEqual(cells[0][0].v, null); assert.strictEqual(cells[6][23].v, null);
  const utc = A.heatmap([{ t: mon0utc, host: 'H', old_pct: 50 }], 'UTC', 'avgOld', '*');
  assert.strictEqual(utc[0][0].v, 50);
});
test('daily summary groups by local date', () => {
  const t1 = Date.UTC(2026, 0, 5, 14, 59), t2 = Date.UTC(2026, 0, 5, 15, 1); // 23:59 and 00:01 JST
  const rows = A.daily([{ t: t1, host: 'H', old_used_mib: 1, old_pct: 1 }, { t: t2, host: 'H', old_used_mib: 2, old_pct: 2 }], [], 'Asia/Tokyo', [{ host: 'H', interval_sec: 60 }]);
  assert.strictEqual(rows.length, 2);
});

// ---------------------------------------------------------------- demo + exports
test('7-day synthetic demo: leaking host rises, healthy host flat, gap and restart found', () => {
  const d = A.makeDemo();
  const span = (Math.max(...d.samples.map(s => s.t)) - Math.min(...d.samples.map(s => s.t))) / DAY;
  assert.ok(span > 6.9 && span <= 7, 'span ' + span);
  const r = { from: Math.min(...d.samples.map(s => s.t)), to: Math.max(...d.samples.map(s => s.t)) };
  const a = A.analyze(d.samples, d.gcs, d.events, r);
  const h1 = a.hosts.find(h => h.host === 'APP01'), h2 = a.hosts.find(h => h.host === 'APP02');
  assert.strictEqual(h1.assessment, 'rising'); assert.strictEqual(h1.restarts.length, 1);
  assert.strictEqual(h2.assessment, 'flat'); assert.strictEqual(h2.gaps.length, 1);
  assert.ok(h2.gaps[0].minutes >= 180);
});
test('exports: raw and analysis JSON are self-describing and round-trip', () => {
  const d = A.makeDemo();
  Object.assign(A.ST, { samples: d.samples, gcs: d.gcs, events: d.events, demo: true, files: [], timeZone: 'Asia/Tokyo', range: '7d' });
  const r = { from: d.samples[0].t, to: d.samples[d.samples.length - 1].t };
  const raw = JSON.parse(JSON.stringify(A.buildRawExport(r)));
  assert.strictEqual(raw.schema, 'java-gc-timeline/raw@1'); assert.strictEqual(raw.synthetic_demo, true);
  assert.strictEqual(raw.samples.length, d.samples.length); assert.match(raw.samples[0].timestamp_utc, /Z$/);
  assert.ok(raw.gc_events.length > 0 && raw.collector_events.length > 0);
  const an = JSON.parse(JSON.stringify(A.buildAnalysisExport(r)));
  assert.strictEqual(an.schema, 'java-gc-timeline/analysis@1');
  assert.ok(an.caveats.length >= 4);
  assert.strictEqual(an.hosts.length, 2);
  const h1 = an.hosts.find(h => h.host === 'APP01');
  assert.ok(h1.first_utc.endsWith('Z') && h1.restarts[0].at_utc.endsWith('Z'));
  assert.ok(Array.isArray(h1.top_rises) && h1.top_rises[0].hour_start_utc);
  assert.strictEqual(an.heatmap.maxOld.cells.length, 7);
  assert.ok(an.daily.length >= 14);
  assert.ok(an.event_counts.JAVA_GC_OLD_HIGH >= 1);
});

console.log(`\n${passed} passed` + (process.exitCode ? ', some FAILED' : ''));
