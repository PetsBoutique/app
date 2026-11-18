// Service worker: PWA e notificações push
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
self.addEventListener("push", (e) => { let d = {}; try { d = e.data.json(); } catch (x) {}
  e.waitUntil(self.registration.showNotification(d.titulo || "Pets Boutique", { body: d.texto || "", icon: "logo.png", badge: "logo.png", data: { url: d.url || "./" } })); });
self.addEventListener("notificationclick", (e) => { e.notification.close(); e.waitUntil(clients.openWindow((e.notification.data && e.notification.data.url) || "./")); });
