/* RSA FFM — Service Worker (PWA)
   Chiến lược:
   - Khung app (index.html + icon + manifest + thư viện CDN): cache để mở nhanh & chạy khi
     mạng chập chờn.
   - index.html (điều hướng): NETWORK-FIRST -> luôn lấy bản mới nhất khi có mạng, rớt mạng thì
     dùng bản cache. Nhờ vậy mỗi lần bạn deploy lại Vercel, mở app là thấy bản mới.
   - Supabase (đăng nhập, đọc/ghi đơn) và mọi request khác: KHÔNG can thiệp -> đi thẳng ra
     mạng như bình thường (dữ liệu không bao giờ bị cache sai). */

const VERSION = "rsa-ffm-v1.2";
const SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./favicon.svg",
  "./favicon.png",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-maskable-512.png",
  "./apple-touch-icon.png",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js",
  "https://cdn.jsdelivr.net/npm/papaparse@5.4.1/papaparse.min.js",
  "https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js"
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;                       // chỉ xử lý đọc
  const url = new URL(req.url);

  // Supabase và bất kỳ API nào khác -> đi thẳng, không cache
  if (url.hostname.endsWith("supabase.co")) return;

  const isNav = req.mode === "navigate" ||
    (url.origin === self.location.origin && url.pathname.endsWith("index.html"));

  // Điều hướng / index.html -> network-first
  if (isNav) {
    e.respondWith(
      fetch(req)
        .then(res => {
          const copy = res.clone();
          caches.open(VERSION).then(c => c.put("./index.html", copy));
          return res;
        })
        .catch(() => caches.match("./index.html").then(r => r || caches.match("./")))
    );
    return;
  }

  // Khung tĩnh + thư viện CDN -> cache-first, nền tự cập nhật
  if (url.origin === self.location.origin || url.hostname.endsWith("jsdelivr.net")) {
    e.respondWith(
      caches.match(req).then(hit => {
        const net = fetch(req).then(res => {
          if (res && res.status === 200) {
            const copy = res.clone();
            caches.open(VERSION).then(c => c.put(req, copy));
          }
          return res;
        }).catch(() => hit);
        return hit || net;
      })
    );
  }
  // còn lại: mặc định trình duyệt
});
