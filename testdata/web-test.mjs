// The web version's model (zig-out/web/pstview.wasm) driven the way web/worker.js drives it,
// with files read from disk: open a folder, list, render, analyse, export (.eml and PST), hash,
// pasted headers. CI runs it after `zig build web`.
//
//   node testdata/web-test.mjs zig-out/web/pstview.wasm testdata/demo-mailbox [written.pst]
import fs from 'node:fs';
import path from 'node:path';
const [wasmPath, srcDir] = process.argv.slice(2);
let ex, outs = [], saved = [], js = [];
const files = [];
const enc = new TextEncoder(), dec = new TextDecoder();
const mem = () => new Uint8Array(ex.memory.buffer);
const str = (p, n) => dec.decode(mem().subarray(p, p + n));
const put = s => { const b = enc.encode(s); const p = ex.pv_alloc(Math.max(b.length, 1)); mem().set(b, p); return [p, b.length]; };
const call = (f, s, ...more) => { const [p, n] = put(s); try { return f(p, n, ...more); } finally { ex.pv_free(p, Math.max(n, 1)); } };
const wasi = new Proxy({
  fd_write(fd, iovs, count, written) { const dv = new DataView(ex.memory.buffer); let t = '', tot = 0; for (let i = 0; i < count; i++) { const p = dv.getUint32(iovs + i * 8, true), n = dv.getUint32(iovs + i * 8 + 4, true); t += str(p, n); tot += n; } dv.setUint32(written, tot, true); process.stderr.write('[wasm] ' + t); return 0; },
  random_get(p, n) { crypto.getRandomValues(mem().subarray(p, p + n)); return 0; },
  clock_time_get(_i, _p, out) { new DataView(ex.memory.buffer).setBigUint64(out, BigInt(Date.now()) * 1000000n, true); return 0; },
  environ_sizes_get(c, s) { const dv = new DataView(ex.memory.buffer); dv.setUint32(c, 0, true); dv.setUint32(s, 0, true); return 0; },
  environ_get() { return 0; },
  proc_exit(c) { throw new Error('exit ' + c); },
}, { get: (t, k) => t[k] || (() => 52) });
const pstview = {
  js_eval(_w, p, n) { js.push(str(p, n)); },
  read_file(id, off, p, n) { const fd = fs.openSync(files[id], 'r'); try { const b = Buffer.alloc(n); const got = fs.readSync(fd, b, 0, n, off); mem().set(b.subarray(0, got), p); return got; } finally { fs.closeSync(fd); } },
  out_file(np, nn, dp, dn) { outs.push({ name: str(np, nn), data: mem().slice(dp, dp + dn) }); },
  out_done() { saved.push(outs); outs = []; },
  open_url() {}, set_title(p, n) { js.push('TITLE ' + str(p, n)); },
  local_offset(t) { return -new Date(t * 1000).getTimezoneOffset() * 60; },
  decode(cp, cn, bp, bn, op, on) { try { const t = new TextDecoder(str(cp, cn), { fatal: true }).decode(mem().slice(bp, bp + bn)); const r = enc.encodeInto(t, mem().subarray(op, op + on)); return r.read < t.length ? -1 : r.written; } catch { return -1; } },
};
const { instance } = await WebAssembly.instantiate(fs.readFileSync(wasmPath), { wasi_snapshot_preview1: wasi, pstview });
ex = instance.exports;
ex.pv_init();
let seq = 0;
function req(...parts) {
  js = [];
  const id = ++seq;
  call((p, n) => ex.pv_message(0, p, n), [id, ...parts].join('\x1f'));
  const r = js.find(s => s.startsWith(`pv.reply(${id},`));
  if (!r) throw new Error('no reply to ' + parts[0] + ': ' + JSON.stringify(js).slice(0, 300));
  return JSON.parse(r.slice(`pv.reply(${id},`.length, -1));
}
const ok = (c, m) => { if (!c) { console.error('FAIL: ' + m); process.exit(1); } console.log('ok   ' + m); };
// the folder, as the page names a picked folder: /in/<n>/<folder>/<relative path>
const root = path.basename(srcDir);
for (const name of fs.readdirSync(srcDir)) {
  const full = path.join(srcDir, name);
  if (!fs.statSync(full).isFile()) continue;
  const id = files.push(full) - 1;
  call((p, n) => ex.pv_add_file(p, n, id, fs.statSync(full).size), `/in/1/${root}/${name}`);
}
const r0 = req('ready');
ok(r0.os === 'browser' && !r0.setup.available, 'ready: os browser, nothing to install');
call((p, n) => ex.pv_pick(p, n), `/in/1/${root}`);
const mb = req('openfolder');
ok(!mb.error && mb.folders && mb.folders.length > 0, `opened the folder: ${mb.name}, ${mb.folders && mb.folders.length} folders${mb.error ? ' ' + mb.error : ''}`);
const f = req('folder', mb.start);
ok(f.count > 0, `start folder lists ${f.count} messages`);
const rows = req('rows', 0, 50);
ok(rows.rows.length === f.count, `rows: ${rows.rows.length}, first "${rows.rows[0][4]}"`);
const m = req('msg', 0);
ok(!m.error && /Content-Security-Policy/.test(m.html), `message rendered (${m.html.length} bytes), subject "${m.subject}"`);
const an = req('analyse');
ok(an.count === f.count, 'header analysis of the folder');
saved = [];
const e = req('export', 'eml', 'all');
ok(!e.error && saved.length === 1 && saved[0].length >= f.count, `export .eml: ${saved[0] && saved[0].length} files: ${saved[0] && saved[0].map(x => x.name).slice(0, 4).join(', ')} ...${e.error ? ' ' + e.error : ''}`);
saved = [];
const pst = req('topst');
ok(!pst.error && saved.length === 1 && saved[0].some(x => /\.pst$/.test(x.name)), `whole mailbox as PST: ${saved[0] && saved[0].map(x => x.name + ' ' + x.data.length).join(', ')}${pst.error ? ' ' + pst.error : ''}`);
const pstFile = saved[0].find(x => /\.pst$/.test(x.name));
ok(pstFile && String.fromCharCode(...pstFile.data.slice(0, 4)) === '!BDN', 'the PST starts with !BDN');
fs.writeFileSync(process.argv[4] || '/dev/null', pstFile.data);
const h = req('hash');
ok(/SHA-256/.test(h.message), 'SHA-256 of the source');
const ht = req('hdrtext', 'Received: from a.example (a.example [192.0.2.1]) by b.example; Mon, 1 Jan 2024 10:00:00 +0000\nFrom: x@a.example\nSubject: t\n');
ok(!ht.error && ht.html, 'pasted headers analysed');
console.log('all passed');
