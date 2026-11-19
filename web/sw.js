// pstview's service worker: the app's own files are kept, so an installed pstview starts
// without a network. Network first (a new version arrives when online), the kept copy when
// offline. Mailboxes never pass through here: they are read from the user's files.
'use strict';
const CACHE = 'pstview';
const FILES = ['./', 'index.html', 'worker.js', 'pstview.wasm', 'manifest.webmanifest', 'icon-192.png', 'icon-256.png', 'icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(fetch(e.request).then(r => {
    if (r.ok) {
      const copy = r.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
    }
    return r;
  }).catch(() => caches.match(e.request, { ignoreSearch: true })));
});
