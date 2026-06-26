/* Tracker service worker — offline app shell + installability. */
const CACHE = "beacon-v60";
const ASSETS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-180.png",
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  if (url.origin === location.origin) {
    // The app-shell document: NETWORK-FIRST so a deploy is picked up on the very
    // next load when online; fall back to cache only when offline. (Cache-first
    // here served stale HTML/CSS for a load or two after every deploy.)
    if (req.mode === "navigate" || req.destination === "document") {
      e.respondWith(
        fetch(req).then(res => {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
          return res;
        }).catch(() => caches.match(req).then(c => c || caches.match("./index.html")))
      );
      return;
    }
    // Other same-origin assets (icons, manifest): cache-first, then network.
    e.respondWith(
      caches.match(req).then(cached =>
        cached ||
        fetch(req).then(res => {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
          return res;
        }).catch(() => cached)
      )
    );
    return;
  }

  // CDN libraries (Leaflet / Supabase): network-first, fall back to cache when offline.
  if (url.hostname.includes("cdnjs") || url.hostname.includes("jsdelivr")) {
    e.respondWith(
      fetch(req).then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        return res;
      }).catch(() => caches.match(req))
    );
    return;
  }

  // Everything else (map tiles, Supabase API): straight to network.
});
