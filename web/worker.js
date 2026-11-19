// pstview in the web browser: the model (src/web.zig as pstview.wasm) runs here, in a Web
// Worker, so that it can read slices of the user's files synchronously (FileReaderSync): a
// mailbox of any size is read in place and never loaded whole, and nothing is uploaded.
//
// Page -> worker: {t: 'msg', s} a request ("id \x1f command \x1f args", as on the desktop);
//                 {t: 'files', list: [{file, path}], pick: [path], drop} files picked or dropped.
// Worker -> page: {t: 'js', s} "pv.name(json...)" for the page to call; {t: 'save', files} files
//                 written by a request (downloads); {t: 'url', s}; {t: 'title', s}; {t: 'error', s}.
'use strict';

let ex = null;          // the module's exports
const files = [];       // File objects by id
let outs = [];          // files written by the request being answered
const waiting = [];     // messages that arrived before the module was ready
const enc = new TextEncoder();
const dec = new TextDecoder();
const reader = new FileReaderSync();

const mem = () => new Uint8Array(ex.memory.buffer);
const str = (p, n) => dec.decode(mem().subarray(p, p + n));
function put(s) {
  const b = typeof s === 'string' ? enc.encode(s) : s;
  const p = ex.pv_alloc(Math.max(b.length, 1));
  mem().set(b, p);
  return [p, b.length];
}
function withString(s, f) {
  const [p, n] = put(s);
  try { f(p, n); } finally { ex.pv_free(p, Math.max(n, 1)); }
}

// What the standard library asks of WASI: a console for its messages, random bytes and the
// time. Files go through pstview's own functions below; everything else is "not supported".
const ENOSYS = 52;
const wasi = new Proxy({
  fd_write(fd, iovs, count, written) {
    const dv = new DataView(ex.memory.buffer);
    let text = '', total = 0;
    for (let i = 0; i < count; i++) {
      const p = dv.getUint32(iovs + i * 8, true), n = dv.getUint32(iovs + i * 8 + 4, true);
      text += str(p, n);
      total += n;
    }
    dv.setUint32(written, total, true);
    if (text.trim()) console.log(text.replace(/\n$/, ''));
    return 0;
  },
  random_get(p, n) {
    for (let i = 0; i < n; i += 65536) crypto.getRandomValues(mem().subarray(p + i, p + Math.min(n, i + 65536)));
    return 0;
  },
  clock_time_get(_id, _precision, out) {
    new DataView(ex.memory.buffer).setBigUint64(out, BigInt(Date.now()) * 1000000n, true);
    return 0;
  },
  environ_sizes_get(count, size) {
    const dv = new DataView(ex.memory.buffer);
    dv.setUint32(count, 0, true);
    dv.setUint32(size, 0, true);
    return 0;
  },
  environ_get() { return 0; },
  proc_exit(code) { throw new Error('pstview exited (' + code + ')'); },
}, { get: (t, k) => t[k] || (() => ENOSYS) });

// Reads: each FileReaderSync call has a fixed cost, and the readers make many small reads close
// to each other (a PST's pages and blocks). Small reads are served from 512 KiB chunks of the
// file, the most recently used 64 MiB of them kept.
const CHUNK = 512 * 1024;
const KEEP = 128;
const chunks = new Map(); // "id:index" -> Uint8Array, least recently used first

function readDirect(f, offset, p, n) {
  const buf = new Uint8Array(reader.readAsArrayBuffer(f.slice(offset, offset + n)));
  mem().set(buf, p);
  return buf.length;
}

function chunk(id, f, index) {
  const key = id + ':' + index;
  let c = chunks.get(key);
  if (c) {
    chunks.delete(key); // (to the end: most recently used)
  } else {
    c = new Uint8Array(reader.readAsArrayBuffer(f.slice(index * CHUNK, (index + 1) * CHUNK)));
    if (chunks.size >= KEEP) chunks.delete(chunks.keys().next().value);
  }
  chunks.set(key, c);
  return c;
}

function readCached(id, f, offset, p, n) {
  let done = 0;
  while (done < n) {
    const at = offset + done, index = Math.floor(at / CHUNK), c = chunk(id, f, index);
    const from = at - index * CHUNK;
    if (from >= c.length) break; // end of file
    const k = Math.min(n - done, c.length - from);
    mem().set(c.subarray(from, from + k), p + done);
    done += k;
  }
  return done;
}

const pstview = {
  js_eval(_win, p, n) { postMessage({ t: 'js', s: str(p, n) }); },
  read_file(id, offset, p, n) {
    const f = files[id];
    if (!f) return -1;
    try {
      return n >= CHUNK ? readDirect(f, offset, p, n) : readCached(id, f, offset, p, n);
    } catch (e) {
      return -1;
    }
  },
  out_file(np, nn, dp, dn) { outs.push({ name: str(np, nn), data: mem().slice(dp, dp + dn) }); },
  out_done() {
    postMessage({ t: 'save', files: outs }, outs.map(o => o.data.buffer));
    outs = [];
  },
  open_url(p, n) { postMessage({ t: 'url', s: str(p, n) }); },
  set_title(p, n) { postMessage({ t: 'title', s: str(p, n) }); },
  local_offset(t) { return -new Date(t * 1000).getTimezoneOffset() * 60; },
  decode(cp, cn, bp, bn, op, on) {
    try {
      const text = new TextDecoder(str(cp, cn), { fatal: true }).decode(mem().slice(bp, bp + bn));
      const r = enc.encodeInto(text, mem().subarray(op, op + on));
      return r.read < text.length ? -1 : r.written;
    } catch (e) {
      return -1; // a charset the browser does not know, or bytes that do not decode
    }
  },
};

function handle(m) {
  if (m.t === 'msg') {
    withString(m.s, (p, n) => ex.pv_message(0, p, n));
  } else if (m.t === 'files') {
    for (const { file, path } of m.list) {
      const id = files.push(file) - 1;
      withString(path, (p, n) => ex.pv_add_file(p, n, id, file.size));
    }
    for (const path of m.pick || []) withString(path, (p, n) => ex.pv_pick(p, n));
    if (m.drop) ex.pv_drop();
  }
}

onmessage = e => {
  if (!ex) { waiting.push(e.data); return; }
  try {
    handle(e.data);
  } catch (err) {
    postMessage({ t: 'error', s: String(err && err.stack || err) });
  }
};

WebAssembly.instantiateStreaming(fetch('pstview.wasm'), { wasi_snapshot_preview1: wasi, pstview })
  .then(({ instance }) => {
    ex = instance.exports;
    ex.pv_init();
    while (waiting.length) handle(waiting.shift());
  })
  .catch(err => postMessage({ t: 'error', s: 'pstview could not start: ' + err }));
