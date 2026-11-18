// Browser multiplayer transport (page side).
//
// The engine (rts/System/Net/WebNet.cpp, active with RECOIL_WEB_NET=1) writes its outgoing
// UDP datagrams into a byte ring in the shared wasm memory and reads incoming ones from a
// second ring. webnet-worker.js holds the WebSocket to the relay (web-harness/relay) and
// moves datagrams between it and the rings; this class runs the lobby messages on the page.
"use strict";

class WebNet {
	constructor({ relay, room, name, role }) {
		this.relay = relay.replace(/\/+$/, "");
		this.room = room;
		this.name = name;
		this.role = role;
		this.peers = [];
		this.welcome = null;
		this.handlers = new Set();
		this.stats = { sent: 0, recv: 0, dropped: 0 };
		this.worker = new Worker("webnet-worker.js");
	}

	connect() {
		return new Promise((resolve, reject) => {
			let opened = false;
			this.worker.onmessage = (e) => {
				const m = e.data;
				if (m.type === "stats") { this.stats = m.stats; return; }
				if (m.type === "close") {
					if (!opened) reject(new Error(m.reason || "could not join the room (name taken, room full, or the relay is unreachable)"));
					for (const h of this.handlers) h({ type: "closed", code: m.code });
					return;
				}
				let msg;
				try { msg = JSON.parse(m.data); } catch (_) { return; }
				if (msg.type === "welcome") { this.welcome = msg; opened = true; resolve(msg); }
				if (msg.type === "peers") this.peers = msg.peers;
				for (const h of this.handlers) h(msg);
			};
			const url = `${this.relay}/room/${encodeURIComponent(this.room)}?name=${encodeURIComponent(this.name)}&role=${this.role}`;
			this.worker.postMessage({ type: "connect", url });
		});
	}

	on(handler) { this.handlers.add(handler); return () => this.handlers.delete(handler); }
	send(msg) { this.worker.postMessage({ type: "send", data: JSON.stringify(msg) }); }

	// call once the engine module object exists; waits until its exports are ready
	attach(mod) {
		const tryAttach = () => {
			if (!mod._recoil_webnet_out || !mod.wasmMemory) return false;
			this.worker.postMessage({
				type: "attach", memory: mod.wasmMemory,
				out: mod._recoil_webnet_out(), in: mod._recoil_webnet_in(),
				ringBytes: mod._recoil_webnet_ring_bytes(), myip: mod._recoil_webnet_myip(),
				ipNum: this.welcome.ipNum,
			});
			return true;
		};
		if (!tryAttach()) {
			const t = setInterval(() => { if (tryAttach()) clearInterval(t); }, 50);
		}
	}

	close() { this.worker.postMessage({ type: "close" }); }
}
window.WebNet = WebNet;
