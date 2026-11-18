/* Cross-origin isolation for hosts that can't set response headers (a plain static server).
 * SharedArrayBuffer, which the engine's threads need, is only available to pages served with
 *   Cross-Origin-Opener-Policy: same-origin  and  Cross-Origin-Embedder-Policy: require-corp.
 * This file is both the page-side registration (loaded with <script src="coi-sw.js?register">)
 * and the service worker, which adds those headers to every same-origin response. When the
 * host already sends them (see _headers), nothing happens. After the first registration the
 * page reloads once. Needs https or localhost. */
if (typeof window === "undefined") {
	self.addEventListener("install", () => self.skipWaiting());
	self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
	self.addEventListener("fetch", (e) => {
		const r = e.request;
		if (r.cache === "only-if-cached" && r.mode !== "same-origin") return;
		e.respondWith(fetch(r).then((resp) => {
			if (resp.status === 0) return resp;
			const h = new Headers(resp.headers);
			h.set("Cross-Origin-Opener-Policy", "same-origin");
			h.set("Cross-Origin-Embedder-Policy", "require-corp");
			h.set("Cross-Origin-Resource-Policy", "same-origin");
			return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: h });
		}).catch((err) => { console.error(err); return Response.error(); }));
	});
} else if (!window.crossOriginIsolated && "serviceWorker" in navigator) {
	const reloaded = sessionStorage.getItem("coi-reloaded");
	navigator.serviceWorker.register(document.currentScript.src.split("?")[0]).then((reg) => {
		if (reg.active && !navigator.serviceWorker.controller && !reloaded) {
			sessionStorage.setItem("coi-reloaded", "1");
			location.reload();
		} else if (!reg.active) {
			reg.addEventListener("updatefound", () => {
				const w = reg.installing;
				w.addEventListener("statechange", () => { if (w.state === "activated" && !reloaded) { sessionStorage.setItem("coi-reloaded", "1"); location.reload(); } });
			});
		}
	}).catch((e) => console.error("service worker registration failed", e));
}
