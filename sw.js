// Sardor Trading Journal — Service Worker
// Tezroq ochilish uchun statik fayllarni keshda saqlaydi.
// Diqqat: Firebase/Firestore ma'lumotlari baribir internet talab qiladi,
// bu SW faqat ilova qobig'ini (HTML/CSS/JS/rasm) tezroq yuklaydi.

const CACHE_VERSION = 'tj-cache-v30';
const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icon.png'
];

// O'rnatish — asosiy fayllarni keshga oldindan yuklab qo'yish
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

// Eski keshlarni tozalash
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key))
      )
    )
  );
  self.clients.claim();
});

// So'rovlarni ushlab olish
self.addEventListener('fetch', (event) => {
  const { request } = event;

  // Faqat GET so'rovlarni keshlaymiz
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Firebase/Firestore/Auth so'rovlariga tegmaymiz — ular doim internetdan bevosita ketishi kerak
  if (url.origin !== self.location.origin) {
    return; // brauzerning odatiy tarmoq so'roviga qo'yib beramiz
  }

  // O'zimizning statik fayllar uchun: avval keshdan, bo'lmasa tarmoqdan olib keshga yozamiz
  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;
      return fetch(request)
        .then((response) => {
          const responseClone = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, responseClone));
          return response;
        })
        .catch(() => cached); // internet yo'q va keshda ham yo'q bo'lsa — xato qaytadi
    })
  );
});
