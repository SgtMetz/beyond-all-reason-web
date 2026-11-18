// Multiplayer transport worker (see webnet.js). Holds the relay WebSocket and moves the
// engine's datagrams between it and the two rings in the shared wasm memory. It runs in a
// dedicated worker because a background tab throttles the page's own timers to about once
// a second, which would stall a player's game traffic whenever they switch tabs.
//
// Ring: i32 head, i32 tail, then RING_BYTES of data. Record: u32 len, u32 ip, u16 remote
// port, u16 local port, payload padded to 4 bytes (little-endian, as wasm). len 0xFFFFFFFF
// = wrap marker; fewer than 12 bytes left before the end = implicit wrap.
// Relay frames: u32 ip, u16 port, u16 port, payload (big-endian header).
"use strict";

let ws = null, mem = null, outAddr = 0, inAddr = 0, RB = 0;
const pending = [];
const stats = { sent: 0, recv: 0, dropped: 0 };

function drain() {
	if (!mem || !ws || ws.readyState !== 1) return;
	const buf = mem.buffer;
	const i32 = new Int32Array(buf), dv = new DataView(buf), u8 = new Uint8Array(buf);
	const data = outAddr + 8;
	const head = Atomics.load(i32, outAddr >> 2);
	let tail = Atomics.load(i32, (outAddr + 4) >> 2);
	while (tail !== head) {
		if (RB - tail < 12) { tail = 0; continue; }
		const len = dv.getUint32(data + tail, true);
		if (len === 0xFFFFFFFF) { tail = 0; continue; }
		const frame = new Uint8Array(8 + len);
		const fv = new DataView(frame.buffer);
		fv.setUint32(0, dv.getUint32(data + tail + 4, true));
		fv.setUint16(4, dv.getUint16(data + tail + 8, true));
		fv.setUint16(6, dv.getUint16(data + tail + 10, true));
		frame.set(u8.subarray(data + tail + 12, data + tail + 12 + len), 8);
		ws.send(frame);
		stats.sent++;
		tail += 12 + ((len + 3) & ~3);
		if (tail === RB) tail = 0;
	}
	Atomics.store(i32, (outAddr + 4) >> 2, tail);
}

function deliver(frame) {
	if (frame.length < 8) return;
	if (!mem) { if (pending.length < 4096) pending.push(frame); return; }
	const fv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
	const len = frame.length - 8;
	const buf = mem.buffer;
	const i32 = new Int32Array(buf), dv = new DataView(buf), u8 = new Uint8Array(buf);
	const data = inAddr + 8;
	const need = 12 + ((len + 3) & ~3);
	const head = Atomics.load(i32, inAddr >> 2);
	const tail = Atomics.load(i32, (inAddr + 4) >> 2);
	let pos = head;
	if (head >= tail) {
		const endSpace = RB - head - (tail === 0 ? 4 : 0);
		if (endSpace < need) {
			if (tail < need + 4) { stats.dropped++; return; }
			if (RB - head >= 12) dv.setUint32(data + head, 0xFFFFFFFF, true);
			pos = 0;
		}
	} else if (tail - head < need + 4) { stats.dropped++; return; }
	dv.setUint32(data + pos, len, true);
	dv.setUint32(data + pos + 4, fv.getUint32(0), true);
	dv.setUint16(data + pos + 8, fv.getUint16(4), true);
	dv.setUint16(data + pos + 10, fv.getUint16(6), true);
	u8.set(frame.subarray(8), data + pos + 12);
	let next = pos + need;
	if (next === RB) next = 0;
	Atomics.store(i32, inAddr >> 2, next);
	stats.recv++;
}

onmessage = (e) => {
	const m = e.data;
	if (m.type === "connect") {
		ws = new WebSocket(m.url);
		ws.binaryType = "arraybuffer";
		ws.onmessage = (ev) => {
			if (typeof ev.data === "string") postMessage({ type: "text", data: ev.data });
			else deliver(new Uint8Array(ev.data));
		};
		ws.onclose = (ev) => postMessage({ type: "close", code: ev.code, reason: ev.reason });
		ws.onerror = () => {};
	} else if (m.type === "send") {
		if (ws && ws.readyState === 1) ws.send(m.data);
	} else if (m.type === "attach") {
		mem = m.memory; outAddr = m.out; inAddr = m.in; RB = m.ringBytes;
		Atomics.store(new Int32Array(mem.buffer), m.myip >> 2, m.ipNum | 0);
		for (const f of pending.splice(0)) deliver(f);
		// engine -> relay; 4 ms is the timer floor
		setInterval(drain, 4);
		setInterval(() => postMessage({ type: "stats", stats }), 2000);
	} else if (m.type === "close") {
		if (ws) ws.close();
	}
};
