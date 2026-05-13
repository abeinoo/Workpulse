// Bump CACHE_VERSION on each production deploy to invalidate stale caches.
const CACHE_VERSION = "v2";
const STATIC_CACHE  = `workpulse-static-${CACHE_VERSION}`;
const RUNTIME_CACHE = `workpulse-runtime-${CACHE_VERSION}`;

const PRECACHE_URLS = [
  "/offline.html",
  "/manifest.json",
  "/icon-192.png",
  "/icon.png",
  "/apple-touch-icon.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then((cache) => cache.addAll(PRECACHE_URLS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((k) => k !== STATIC_CACHE && k !== RUNTIME_CACHE)
            .map((k) => caches.delete(k))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;

  // Only handle same-origin GETs
  if (request.method !== "GET" || !request.url.startsWith(self.location.origin)) return;

  const { pathname } = new URL(request.url);

  // Never intercept auth, admin, or API routes — always hit the network
  if (
    pathname.startsWith("/users/") ||
    pathname.startsWith("/api/")   ||
    pathname.startsWith("/admin/")
  ) return;

  // Cache-first for static assets (images, fonts, icons)
  if (/\.(png|svg|ico|jpg|jpeg|gif|webp|woff2?|ttf)$/.test(pathname)) {
    event.respondWith(
      caches.match(request).then((cached) => {
        if (cached) return cached;
        return fetch(request).then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(RUNTIME_CACHE).then((c) => c.put(request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // Network-first for HTML navigation — fall back to offline page
  if (request.headers.get("accept")?.includes("text/html")) {
    event.respondWith(
      fetch(request).catch(() => caches.match("/offline.html"))
    );
    return;
  }

  // Network-first with runtime cache for CSS / JS
  event.respondWith(
    fetch(request)
      .then((response) => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(RUNTIME_CACHE).then((c) => c.put(request, clone));
        }
        return response;
      })
      .catch(() => caches.match(request))
  );
});

// Allow the page to force-activate a waiting service worker
self.addEventListener("message", (event) => {
  if (event.data?.type === "SKIP_WAITING") self.skipWaiting();
});
