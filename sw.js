// Velto Ops service worker — minimal, safe.
// Bump CACHE when shipping a new version to force fresh assets.
const CACHE = 'velto-ops-v93';
const SHELL = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-maskable-192.png',
  './icon-maskable-512.png',
  './apple-touch-icon.png',
  './badge-96.png',
  './favicon.png'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Resilient cache for our CDN libraries (jsPDF, supabase-js) so a CDN hiccup
  // doesn't break PDF/auth after first successful load. Cache-first, refresh in background.
  if ((url.hostname === 'cdn.jsdelivr.net' || url.hostname === 'cdnjs.cloudflare.com') && url.pathname.endsWith('.js')) {
    e.respondWith(
      caches.match(req).then(cached => {
        const net = fetch(req).then(resp => {
          if (resp && (resp.ok || resp.type === 'opaque')) { const copy = resp.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
          return resp;
        }).catch(() => cached);
        return cached || net;
      })
    );
    return;
  }
  // Pass through other cross-origin (Supabase live data, Google Drive, fonts) — never cache.
  if (url.origin !== location.origin) return;

  // Network-first for the HTML shell so updates land immediately when online.
  const isShell = req.mode === 'navigate'
    || url.pathname.endsWith('/')
    || url.pathname.endsWith('/index.html');

  if (isShell) {
    e.respondWith(
      fetch(req)
        .then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); return r; })
        .catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
    );
    return;
  }

  // Cache-first for everything else same-origin (icons, manifest).
  e.respondWith(
    caches.match(req).then(r => r || fetch(req).then(resp => {
      const copy = resp.clone();
      caches.open(CACHE).then(c => c.put(req, copy));
      return resp;
    }))
  );
});

// ---- Web Push: show a system notification even when the app is closed ----
self.addEventListener('push', event => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; }
  catch (e) { d = { title: 'Velto', body: event.data ? event.data.text() : '' }; }
  const title = d.title || 'Velto';
  const options = {
    body: d.body || '',
    icon: './icon-192.png',
    badge: './badge-96.png',        // monochrome glyph for the status bar
    tag: d.tag || 'velto-order',    // same tag replaces, no stacking duplicates
    renotify: true,
    requireInteraction: false,      // auto-dismiss like a modern app, not a sticky card
    silent: false,
    vibrate: [50, 30, 50],          // a short, soft tap — not an alarm
    timestamp: Date.now(),
    data: { url: d.url || './' },
    actions: [{ action: 'open', title: 'View order' }]
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || './';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for (const c of list) { if ('focus' in c) { c.focus(); return; } }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
