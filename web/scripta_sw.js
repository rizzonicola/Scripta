'use strict';

// Service worker personalizzato di Scripta.
//
// Strategia:
//  - precache di TUTTI gli asset della build (tranne mappe, simboli e il
//    service worker stesso), così l'app funziona offline dopo il primo avvio;
//  - navigazione network-first con fallback alla index.html in cache;
//  - asset same-origin cache-first;
//  - richieste cross-origin e non-GET lasciate al browser (mai intercettate);
//  - NIENTE skipWaiting(): una nuova versione si installa in background e
//    resta in attesa finché tutte le finestre/tab della versione precedente
//    non vengono chiuse. L'aggiornamento è quindi automatico e invisibile.
//
// L'id build e la lista precache vengono sostituiti da
// tool/web/build_web.dart dopo `flutter build web`.

const BUILD_ID = '__SCRIPT_BUILD_ID__';
const CACHE_PREFIX = 'scripta-';
const CACHE_NAME = CACHE_PREFIX + BUILD_ID;
const INDEX_URL = new URL('index.html', self.registration.scope).href;

// Lista iniettata a build time: percorsi relativi alla root dell'app.
const PRECACHE = /* __SCRIPT_PRECACHE__ */ [];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE_NAME);
      // addAll è atomico: se un asset manca, l'installazione fallisce e il
      // browser riproverà al prossimo avvio invece di lasciare una cache
      // parziale che sembrerebbe valida.
      await cache.addAll(PRECACHE);
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((name) => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME)
          .map((name) => caches.delete(name)),
      );
      // Nessun clients.claim(): quando questo SW si attiva non ci sono più
      // client della versione precedente; le nuove pagine lo usano subito.
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;

  // Solo GET same-origin: API di sync, download esterni e richieste POST
  // restano completamente fuori dal service worker.
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(networkFirstNavigation(request));
    return;
  }

  event.respondWith(cacheFirst(request));
});

async function networkFirstNavigation(request) {
  try {
    const response = await fetch(request);
    if (response && response.ok) return response;
  } catch (_) {
    // Rete assente: si usa la index.html precached.
  }

  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(INDEX_URL, { ignoreSearch: true });
  if (cached) return cached;
  return Response.error();
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request, { ignoreSearch: true });
  if (cached) return cached;
  return fetch(request);
}
