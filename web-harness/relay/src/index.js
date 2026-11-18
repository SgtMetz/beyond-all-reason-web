// Multiplayer relay for the browser port of Beyond All Reason.
//
// A browser can't send UDP, so every peer of a game opens a WebSocket to
// /room/<code> here and the room (one Durable Object) routes the engine's datagrams
// between them. Each peer gets a virtual IPv4 address 10.77.x.y; the engine uses those
// as ordinary UDP endpoints (see rts/System/Net/WebNet.h in the engine).
//
// Binary frames, peer -> relay: u32 destination IP, u16 destination port, u16 source port, payload
//               relay -> peer: u32 source IP,      u16 source port,      u16 destination port, payload
// (big-endian header). Text frames are JSON lobby messages: the relay sends "welcome" and
// "peers"; anything a peer sends is passed on to the others (or to "to") with "from" set.
// A "bridge" peer (webnet-bridge.py) connects native engines over real UDP.

import { DurableObject } from "cloudflare:workers";

const MAX_PEERS = 32;
const MAX_FRAME = 16384;
const MAX_TEXT = 8192;

const ipString = (n) => `${n >>> 24}.${(n >>> 16) & 255}.${(n >>> 8) & 255}.${n & 255}`;
const ipOf = (id) => ((10 << 24) | (77 << 16) | id) >>> 0;

export class Room extends DurableObject {
	peers() {
		const out = [];
		for (const ws of this.ctx.getWebSockets()) {
			const a = ws.deserializeAttachment();
			if (a) out.push({ ws, ...a });
		}
		return out;
	}

	broadcastPeers() {
		const list = this.peers().map(({ id, name, role, ip }) => ({ id, name, role, ip: ipString(ip) }));
		const msg = JSON.stringify({ type: "peers", peers: list });
		for (const p of this.peers()) {
			try { p.ws.send(msg); } catch (_) {}
		}
	}

	async fetch(request) {
		if (request.headers.get("Upgrade") !== "websocket")
			return new Response("expected a WebSocket", { status: 426 });

		const url = new URL(request.url);
		const name = (url.searchParams.get("name") || "Player").replace(/[^\w\-\[\]]/g, "").slice(0, 20) || "Player";
		const role = ["host", "player", "bridge", "spectator"].includes(url.searchParams.get("role")) ? url.searchParams.get("role") : "player";
		const existing = this.peers();
		if (existing.length >= MAX_PEERS)
			return new Response("room full", { status: 409 });
		if (role === "host" && existing.some((p) => p.role === "host"))
			return new Response("room already has a host", { status: 409 });
		if (role !== "bridge" && existing.some((p) => p.name.toLowerCase() === name.toLowerCase()))
			return new Response("name taken in this room", { status: 409 });

		// lowest free id (1..254 on the first octet, enough for a game)
		const used = new Set(existing.map((p) => p.id));
		let id = 1;
		while (used.has(id)) id++;

		const pair = new WebSocketPair();
		const [client, server] = Object.values(pair);
		this.ctx.acceptWebSocket(server);
		const ip = ipOf(id);
		server.serializeAttachment({ id, name, role, ip });
		server.send(JSON.stringify({ type: "welcome", id, name, role, ip: ipString(ip), ipNum: ip }));
		this.broadcastPeers();
		return new Response(null, { status: 101, webSocket: client });
	}

	async webSocketMessage(ws, message) {
		const me = ws.deserializeAttachment();
		if (!me) return;

		if (typeof message === "string") {
			if (message.length > MAX_TEXT) return;
			let msg;
			try { msg = JSON.parse(message); } catch (_) { return; }
			if (!msg || typeof msg !== "object") return;
			msg.from = me.id;
			msg.fromName = me.name;
			const text = JSON.stringify(msg);
			for (const p of this.peers()) {
				if (p.id === me.id) continue;
				if (msg.to != null && msg.to !== p.id) continue;
				try { p.ws.send(text); } catch (_) {}
			}
			return;
		}

		// datagram
		if (message.byteLength < 8 || message.byteLength > MAX_FRAME) return;
		const inView = new DataView(message);
		const dstIP = inView.getUint32(0) >>> 0;
		const dstPort = inView.getUint16(4);
		const srcPort = inView.getUint16(6);
		const target = this.peers().find((p) => p.ip === dstIP);
		if (!target) return;

		const out = new Uint8Array(message.byteLength);
		out.set(new Uint8Array(message, 8), 8);
		const outView = new DataView(out.buffer);
		outView.setUint32(0, me.ip);
		outView.setUint16(4, srcPort);
		outView.setUint16(6, dstPort);
		try { target.ws.send(out); } catch (_) {}
	}

	async webSocketClose(ws, code) {
		try { ws.close(code === 1005 ? 1000 : code, "bye"); } catch (_) {}
		this.broadcastPeers();
	}

	async webSocketError(ws) {
		this.broadcastPeers();
	}
}

export default {
	async fetch(request, env) {
		const url = new URL(request.url);
		const m = url.pathname.match(/^\/room\/([A-Za-z0-9]{3,16})$/);
		if (!m) {
			if (url.pathname === "/") return new Response("BAR web multiplayer relay\n", { headers: { "content-type": "text/plain" } });
			return new Response("not found", { status: 404 });
		}
		const stub = env.ROOMS.get(env.ROOMS.idFromName(m[1].toUpperCase()));
		return stub.fetch(request);
	},
};
