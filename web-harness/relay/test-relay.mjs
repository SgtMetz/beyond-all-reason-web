// Smoke test for the relay: two peers join a room, exchange lobby text and one datagram each way.
// usage: node test-relay.mjs [ws://localhost:5173]
const base = process.argv[2] || "ws://localhost:5173";
const room = "T" + Math.floor(Math.random() * 1e6);

function open(name, role) {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(`${base}/room/${room}?name=${name}&role=${role}`);
		ws.binaryType = "arraybuffer";
		const peer = { ws, name, msgs: [], bins: [] };
		ws.onmessage = (e) => {
			if (typeof e.data === "string") {
				const m = JSON.parse(e.data);
				if (m.type === "welcome") { peer.welcome = m; resolve(peer); }
				peer.msgs.push(m);
			} else peer.bins.push(new Uint8Array(e.data));
		};
		ws.onerror = (e) => reject(new Error("ws error " + name));
		setTimeout(() => reject(new Error("timeout " + name)), 8000);
	});
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const host = await open("Alice", "host");
const guest = await open("Bob", "player");
console.log("welcome", host.welcome.ip, guest.welcome.ip);
host.ws.send(JSON.stringify({ type: "lobby", map: "x" }));

function dgram(dstIPNum, dstPort, srcPort, text) {
	const p = new TextEncoder().encode(text);
	const b = new Uint8Array(8 + p.length);
	const v = new DataView(b.buffer);
	v.setUint32(0, dstIPNum); v.setUint16(4, dstPort); v.setUint16(6, srcPort);
	b.set(p, 8);
	return b;
}
guest.ws.send(dgram(host.welcome.ipNum, 8452, 40000, "hello host"));
host.ws.send(dgram(guest.welcome.ipNum, 40000, 8452, "hello guest"));
await sleep(800);

const show = (b) => { const v = new DataView(b.buffer); return `${v.getUint32(0) >>> 0}:${v.getUint16(4)}->${v.getUint16(6)} "${new TextDecoder().decode(b.slice(8))}"`; };
console.log("host got", host.bins.map(show), host.msgs.map((m) => m.type));
console.log("guest got", guest.bins.map(show), guest.msgs.map((m) => m.type + (m.from ? "@" + m.from : "")));
const ok = host.bins.length === 1 && guest.bins.length === 1 && guest.msgs.some((m) => m.type === "lobby" && m.from === host.welcome.id);
console.log(ok ? "PASS" : "FAIL");
host.ws.close(); guest.ws.close();
process.exit(ok ? 0 : 1);
