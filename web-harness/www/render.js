// Browser harness for the renderer build (B2): fill OPFS (opfs-loader.js), then start
// spring-web.js. With PROXY_TO_PTHREAD + OFFSCREENCANVAS_SUPPORT the engine's main()
// runs in a worker and <canvas id="canvas"> is transferred to it (WebGL2 context there).
// The engine's stdout/stderr go to the console and the page; when the engine exits the
// log is posted to serve.py (logs/infolog-render.txt).
"use strict";

const params = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const secs = (t) => (t / 1000).toFixed(1) + " s";

const harness = window.harness = {
	lines: [],
	marks: {},
	maxLagMs: 0,
	peakWasmMB: 0,
	frame: -1,
	exitCode: null,
	tEngine: null,
};

// ---- audio (B3) ---------------------------------------------------------------
// The engine's OpenAL calls are proxied to this thread by Emscripten, which creates the
// AudioContext here. Browsers keep it suspended until a user gesture, so every context is
// recorded and resumed on the first pointer/key event (or at once with the
// --autoplay-policy=no-user-gesture-required flag that the headless tests use).
// To measure the output, every connection to a context's destination is also fed to an
// AnalyserNode; harness.audio.peak is the largest sample seen, rms the latest level.
harness.audio = { contexts: 0, states: [], peak: 0, rms: 0, resumedByGesture: false, samples: 0 };
(() => {
	const AC = window.AudioContext || window.webkitAudioContext;
	if (!AC) return;
	const ctxs = [], analysers = new Map();
	const Wrapped = function (...a) { const c = new AC(...a); ctxs.push(c); harness.audio.contexts = ctxs.length; return c; };
	Wrapped.prototype = AC.prototype;
	window.AudioContext = Wrapped;
	const origConnect = AudioNode.prototype.connect;
	AudioNode.prototype.connect = function (dest, ...rest) {
		const r = origConnect.call(this, dest, ...rest);
		if (dest instanceof AudioDestinationNode && this.context === dest.context) {
			let an = analysers.get(dest.context);
			if (!an) { an = dest.context.createAnalyser(); an.fftSize = 2048; analysers.set(dest.context, an); }
			try { origConnect.call(this, an); } catch (e) { /* already connected */ }
		}
		return r;
	};
	const buf = new Float32Array(2048);
	setInterval(() => {
		harness.audio.states = ctxs.map((c) => c.state);
		for (const an of analysers.values()) {
			an.getFloatTimeDomainData(buf);
			let sum = 0, pk = 0;
			for (const v of buf) { sum += v * v; const a = Math.abs(v); if (a > pk) pk = a; }
			harness.audio.rms = Math.sqrt(sum / buf.length);
			harness.audio.peak = Math.max(harness.audio.peak, pk);
			harness.audio.samples++;
		}
	}, 100);
	const resume = () => {
		for (const c of ctxs) if (c.state === "suspended") { c.resume(); harness.audio.resumedByGesture = true; }
	};
	for (const ev of ["pointerdown", "keydown", "click", "touchend"]) window.addEventListener(ev, resume, true);
	setInterval(() => { if (ctxs.some((c) => c.state === "suspended")) harness.audio.needsGesture = true; else harness.audio.needsGesture = false; }, 500);
})();

// ---- canvas input ---------------------------------------------------------------
// Keep game mouse input inside the game: middle-click would start the browser's
// autoscroll and the wheel would scroll the page, and dragging could start a text/image
// selection. The engine's own listeners still receive the events.
(() => {
	const cv = document.getElementById("canvas");
	if (!cv) return;
	const stop = (e) => { if (e.button === 1) e.preventDefault(); };
	// not on pointerdown: preventDefault there suppresses the mousedown the engine listens for
	cv.addEventListener("mousedown", stop);
	// keep receiving moves/releases while a button is held, also outside the canvas
	cv.addEventListener("pointerdown", (e) => { try { cv.setPointerCapture(e.pointerId); } catch (_) {} });
	cv.addEventListener("auxclick", stop);
	// the engine's middle-drag camera switches SDL to relative mouse mode, which needs
	// pointer lock; the engine runs in a worker, so lock here, inside the user gesture
	cv.addEventListener("mousedown", (e) => { if (e.button === 1 && cv.requestPointerLock) cv.requestPointerLock(); });
	window.addEventListener("mouseup", (e) => { if (e.button === 1 && document.pointerLockElement === cv) document.exitPointerLock(); });
	cv.addEventListener("wheel", (e) => e.preventDefault(), { passive: false });
	cv.addEventListener("dragstart", (e) => e.preventDefault());
	cv.addEventListener("selectstart", (e) => e.preventDefault());
})();

// ---- output -------------------------------------------------------------------
const logEl = $("log"), keyEl = $("key");
const KEY = /\[WebFS\]|\[WebGL|\[GR::|\[DemoSync\]|\[M4\]|DESYNC|Beginning demo playback|\[Fatal\]|Fatal error|Error:|RuntimeError|Aborted|abort\(|\[harness\]|GL version|GLSL version|GL renderer|shader|Shader/;
let pending = [], flushQueued = false;

function flush() {
	flushQueued = false;
	if (!pending.length) return;
	const atBottom = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 4;
	logEl.append(pending.join("\n") + "\n");
	pending = [];
	while (logEl.childNodes.length > 40) logEl.removeChild(logEl.firstChild);
	if (atBottom) logEl.scrollTop = logEl.scrollHeight;
}

// The delivery page doesn't mirror every engine line to the console (?console=1 does):
// with DevTools open that costs the page thread, which also services the engine's proxied
// audio calls. The kept log is capped for the same reason.
const mirrorConsole = document.body.dataset.gate !== "play" || params.get("console") === "1";
const MAX_LINES = 200000;
let keyCount = 0;
function line(text, isErr) {
	harness.lines.push(text);
	if (harness.lines.length > MAX_LINES) harness.lines.splice(0, MAX_LINES / 4);
	if (mirrorConsole || isErr) (isErr ? console.warn : console.log)(text);
	pending.push(text);
	if (!flushQueued) { flushQueued = true; setTimeout(flush, 250); }
	if (KEY.test(text) && keyCount < 4000) {
		keyCount += 1;
		const now = harness.tEngine == null ? 0 : performance.now() - harness.tEngine;
		keyEl.append(`[+${secs(now)}] ${text.slice(0, 600)}\n`);
		keyEl.scrollTop = keyEl.scrollHeight;
	}
	let m;
	// the in-canvas load screen does not repaint while the engine loads (single-threaded), so
	// show the engine's loading step on the page; "loadstatus" exists on the delivery page
	if ((m = /LoadScreen::SetLoadMessage\] text="([^"]*)"/.exec(text))) { setLoadStatus("Loading: " + m[1]); engineProgress(m[1]); }
	else if (/\[Game::Load\]\[[78]\]/.test(text)) engineProgress(text.includes("][8]") ? "done" : "Starting the game");
	else if (/\[f=0*[1-9]\d*\]/.test(text) && !/\[f=-/.test(text)) { setLoadStatus(""); engineProgress("done"); }
	if (text.includes("Beginning demo playback") && harness.marks.playback == null) harness.marks.playback = performance.now() - harness.tEngine;
	if ((m = /\[M4\] playback frame (\d+)/.exec(text)) || (m = /\[f=(\d+)\]/.exec(text))) {
		harness.frame = +m[1];
		$("s-frame").textContent = harness.frame;
	}
}
const note = (text) => line("[harness] " + text);

// ---- engine load progress ----------------------------------------------------------
// The engine loads single-threaded and its own load screen doesn't repaint, so the page
// shows a progress bar driven by the load-screen messages in the log. Each step's start is
// placed where it fell in a measured first start (117 s, most of it shader compiles in the
// Lua stages); within a step the bar creeps towards the next one. Listeners:
// window.onEngineProgress(fraction, step, done).
const LOAD_STEPS = [
	["Parsing Map Information", 0.04], ["Loading SMF", 0.055], ["Loading Map", 0.06],
	["Loading GameData Definitions", 0.08], ["Loading Radar Icons", 0.115], ["Loading Sound Definitions", 0.30],
	["Creating Water", 0.355], ["Finalizing Models", 0.41], ["[LoadFinalize]", 0.42], ["[PathManager", 0.42],
	["Loading LuaRules", 0.425], ["Loading LuaGaia", 0.49], ["Loading LuaUI", 0.50], ["Starting the game", 0.97],
];
const LOAD_TOTAL_S = 117;
const loadProg = harness.loadProgress = { base: 0, next: 0.04, since: 0, step: "Starting the engine", done: false, fraction: 0 };
function engineProgress(step) {
	if (loadProg.done) return;
	if (step === "done") {
		loadProg.done = true; loadProg.fraction = 1;
		setLoadStatus("");
		if (window.onEngineProgress) window.onEngineProgress(1, "Ready", true);
		setTimeout(loadDeferred, 5000);
		return;
	}
	const i = LOAD_STEPS.findIndex(([p]) => step.startsWith(p));
	if (i < 0) { loadProg.step = step; return; }
	if (LOAD_STEPS[i][1] < loadProg.base) return;
	loadProg.base = LOAD_STEPS[i][1];
	loadProg.next = (LOAD_STEPS.slice(i + 1).find(([, f]) => f > loadProg.base) || [0, 1])[1];
	loadProg.since = performance.now();
	loadProg.step = step.replace(/^\[\w+(::\w+)?\]\s*/, "");
}
setInterval(() => {
	if (harness.tEngine == null || loadProg.done) return;
	if (!loadProg.since) loadProg.since = harness.tEngine;
	const expect = Math.max(1, (loadProg.next - loadProg.base) * LOAD_TOTAL_S) * 1000;
	const t = (performance.now() - loadProg.since) / expect;
	loadProg.fraction = loadProg.base + (loadProg.next - loadProg.base) * 0.95 * (1 - Math.exp(-t));
	if (window.onEngineProgress) window.onEngineProgress(loadProg.fraction, loadProg.step, false);
}, 200);

let loadStatusStart = 0;
function setLoadStatus(msg) {
	const el = document.getElementById("loadstatus");
	if (!el) return;
	if (!msg) { el.textContent = ""; loadStatusStart = 0; return; }
	if (!loadStatusStart) loadStatusStart = performance.now();
	el.textContent = `${msg}  (${Math.round((performance.now() - loadStatusStart) / 1000)} s into loading; the first start takes 2 to 3 minutes and the game picture below stays still until it is done)`;
}
setInterval(() => { const el = document.getElementById("loadstatus"); if (el && loadStatusStart) el.textContent = el.textContent.replace(/\(\d+ s into/, `(${Math.round((performance.now() - loadStatusStart) / 1000)} s into`); }, 1000);

// ---- responsiveness and memory --------------------------------------------------
let lastTick = performance.now();
setInterval(() => {
	const now = performance.now();
	const lag = now - lastTick - 100;
	lastTick = now;
	if (harness.tEngine != null && harness.exitCode == null) harness.maxLagMs = Math.max(harness.maxLagMs, lag);
	$("s-lag").textContent = `${Math.max(0, lag).toFixed(0)} ms now, ${harness.maxLagMs.toFixed(0)} ms max`;
	try {
		const mem = window.Module && Module.wasmMemory;
		if (mem) {
			const mb = mem.buffer.byteLength / 1048576;
			harness.peakWasmMB = Math.max(harness.peakWasmMB, mb);
			$("s-mem").textContent = `${mb.toFixed(0)} MiB`;
		}
	} catch (e) { /* not exported */ }
}, 100);

// ---- content -> OPFS ------------------------------------------------------------
function loadContent() {
	return new Promise((resolve, reject) => {
		const w = new Worker("opfs-loader.js");
		w.onmessage = (e) => {
			const d = e.data;
			if (d.type === "log") note(d.text);
			else if (d.type === "progress") {
				$("s-prog").value = d.done / d.total;
				$("s-content").textContent = `${(d.done / 1e6).toFixed(0)} / ${(d.total / 1e6).toFixed(0)} MB`;
			} else if (d.type === "done") {
				w.terminate();
				$("s-prog").value = 1;
				$("s-content").textContent = `ready in ${d.seconds.toFixed(1)} s (fetched ${d.fetchedMB.toFixed(0)} MB)`;
				note(`content ready in ${d.seconds.toFixed(1)} s, fetched ${d.fetchedMB.toFixed(0)} MB`);
				resolve(d);
			} else if (d.type === "error") { w.terminate(); reject(new Error(d.text)); }
		};
		w.onerror = (e) => reject(new Error(e.message));
		w.postMessage({ cmd: "load", fresh: params.get("fresh") === "1" });
	});
}

function saveLog() {
	const summary = {
		userAgent: navigator.userAgent, lastFrame: harness.frame, marks: harness.marks,
		exitCode: harness.exitCode, maxLagMs: harness.maxLagMs, wasmHeapPeakMiB: harness.peakWasmMB,
	};
	const body = harness.lines.join("\n") + "\n\n[harness] summary " + JSON.stringify(summary, null, 1) + "\n";
	// the harness server stores the log; a plain static server answers the POST with an error,
	// so the page offers the log as a file download instead
	const download = () => {
		const a = document.createElement("a");
		a.href = URL.createObjectURL(new Blob([body], { type: "text/plain" }));
		a.download = "bar-web-log.txt";
		a.click();
		note("log downloaded as bar-web-log.txt");
	};
	return fetch("/log/infolog-render.txt", { method: "POST", body })
		.then((r) => { if (r.ok) note(`log saved (${r.status})`); else download(); }, download);
}
harness.saveLog = saveLog;

// ?capture=N: the engine dumps its framebuffer to write/capture.rgba every N seconds
// (RECOIL_WEB_CAPTURE). harness.grab() turns the latest dump into a PNG and posts it to
// serve.py (logs/frame.png), for checking the picture when the tab itself can't be seen.
harness.grab = async (name = "frame.png") => {
	const root = await navigator.storage.getDirectory();
	const dir = await root.getDirectoryHandle("write");
	const file = await (await dir.getFileHandle("capture.rgba")).getFile();
	const buf = await file.arrayBuffer();
	const [w, h] = new Int32Array(buf, 0, 2);
	const src = new Uint8ClampedArray(buf, 8);
	const img = new ImageData(w, h);
	for (let y = 0; y < h; y++) img.data.set(src.subarray((h - 1 - y) * w * 4, (h - y) * w * 4), y * w * 4);
	for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255; // the canvas is opaque
	const c = new OffscreenCanvas(w, h);
	c.getContext("2d").putImageData(img, 0, 0);
	const blob = await c.convertToBlob({ type: "image/png" });
	const r = await fetch("/log/" + name, { method: "POST", body: blob });
	return { w, h, bytes: blob.size, status: r.status, age: (Date.now() - file.lastModified) / 1000 };
};

// The run bundle's write/springsettings.cfg is rewritten on every load; add the settings
// the renderer build needs (windowed at the canvas size, single-threaded loading, ...).
async function writeSettings(settings) {
	const root = await navigator.storage.getDirectory();
	const dir = await root.getDirectoryHandle("write");
	const fh = await dir.getFileHandle("springsettings.cfg", { create: true });
	const old = await (await fh.getFile()).text();
	const text = old.trimEnd() + "\n" + Object.entries(settings).map(([k, v]) => `${k} = ${v}`).join("\n") + "\n";
	const w = await fh.createWritable();
	await w.write(text);
	await w.close();
	note("springsettings.cfg: " + text.trim().split("\n").join("; "));
}

// The run bundle ships the headless playback widget (m4_play.lua), which runs the replay
// at speed 1000; set the speed the page asked for instead (?speed=N, default 1).
async function setReplaySpeed(speed) {
	const root = await navigator.storage.getDirectory();
	let dir = await root.getDirectoryHandle("write");
	for (const d of ["LuaUI", "Widgets"]) dir = await dir.getDirectoryHandle(d);
	const fh = await dir.getFileHandle("m4_play.lua");
	const old = await (await fh.getFile()).text();
	const text = old.replace(/local SPEED = \d+/, "local SPEED = " + speed);
	const w = await fh.createWritable();
	await w.write(text);
	await w.close();
	note("replay speed " + speed);
}

// ?testwidget=1: rects/text/display lists; ?testwidget=vao: instanced VAO
// draws, pixel readback and rejection checks; ?testwidget=units: keeps the camera
// on a unit cluster and logs unit visibility; ?testwidget=gl: polygon-mode and depth-copy
// pixel checks (test_glfix.lua). All are opt-in user widgets.
const TEST_WIDGETS = { "1": "test_render.lua", vao: "test_luavao.lua", units: "test_units.lua", gl: "test_glfix.lua", live: "test_live.lua" };
async function addTestWidget() {
	const src = await (await fetch(TEST_WIDGETS[params.get("testwidget")])).text();
	const root = await navigator.storage.getDirectory();
	let dir = await root.getDirectoryHandle("write");
	for (const d of ["LuaUI", "Widgets"]) dir = await dir.getDirectoryHandle(d);
	const w = await (await dir.getFileHandle("test_render.lua", { create: true })).createWritable();
	await w.write(src);
	await w.close();
	note("test widget installed");
}

// ?skirmish=1 (B4): a local game instead of the replay, started from a generated start
// script. No lobby (chobby) is involved: the engine acts as its own host, as with
// `spring script.txt`. ?map=<map name> (default All That Glitters v2.2), ?ai=<LuaAI>
// (default SimpleAI, one of the AIs in the game's luaai.lua), ?spectate=1 for no human
// player: the AIs play each other (?ai2= picks the second one, default SimpleAI).
// Skirmish AIs written in C++ (BARb) can't be used: the browser build can't load shared
// libraries, so only the game's Lua AIs are available.
const GAME_TYPE = "Beyond All Reason test-31943-6cd6caa";
async function writeSkirmishScript() {
	const map = params.get("map") || "All That Glitters v2.2";
	const ai = params.get("ai") || "SimpleAI";
	const spectate = params.get("spectate") === "1";
	const ai2 = params.get("ai2") || "SimpleAI";
	const teams = spectate
		? [["Armada", ai], ["Cortex", ai2]]
		: [["Armada", ""], ["Cortex", ai]];
	const L = [];
	L.push("[game]", "{", `	gametype=${GAME_TYPE};`, `	mapname=${map};`, "	ishost=1;", "	hostip=127.0.0.1;", "	hostport=0;",
		"	myplayername=Player;", "	startpostype=2;", "	numplayers=1;", "	numusers=1;",
		"	[player0]", "	{", "		name=Player;", `		spectator=${spectate ? 1 : 0};`, "		team=0;", "	}");
	teams.forEach(([side, luaai], i) => {
		L.push(`	[team${i}]`, "	{", `		allyteam=${i};`, "		teamleader=0;", `		side=${side};`,
			`		rgbcolor=${i ? "1 0.2 0.1" : "0.1 0.4 1"};`);
		if (luaai) L.push(`		luaai=${luaai};`);
		L.push("	}", `	[allyteam${i}]`, "	{", "		numallies=0;", "	}");
	});
	L.push("	[modoptions]", "	{", "		maxspeed=20;", "	}", "}");
	const t = L.join(String.fromCharCode(10)) + String.fromCharCode(10);
	const root = await navigator.storage.getDirectory();
	const dir = await root.getDirectoryHandle("write");
	const w = await (await (dir.getFileHandle("script.txt", { create: true }))).createWritable();
	await w.write(t);
	await w.close();
	// the replay driver widget would cap the speed and quit the game
	let wd = dir;
	for (const d of ["LuaUI", "Widgets"]) wd = await wd.getDirectoryHandle(d);
	await wd.removeEntry("m4_play.lua").catch(() => {});
	note("skirmish script: map=" + map + " ai=" + (spectate ? ai + " vs " + ai2 : ai));
	return "/recoil/write/script.txt";
}

// ---- ?glprofile=1: WebGL call profiler -------------------------------------------
// The WebGL2 context lives in the engine's pthread worker. Emscripten starts its workers
// from Module.mainScriptUrlOrBlob, so a blob that wraps every WebGL2RenderingContext
// method with a timer and then imports spring-web.js puts the profiler there. Every 5 s
// the worker that draws reports, over a BroadcastChannel, frames drawn and the calls with
// the most total time: "[glprof] ..." lines in the log. Compare browsers with these.
async function installGlProfiler() {
	const code = (params.get("noglcache") === "1" ? "self.__recoilNoGlCache = true;" : "") +
		`if (typeof WorkerGlobalScope !== "undefined") (() => {
		const P = WebGL2RenderingContext.prototype, stats = new Map();
		let frames = 0, t0 = performance.now();
		for (const k of Object.getOwnPropertyNames(P)) {
			const d = Object.getOwnPropertyDescriptor(P, k);
			if (!d || typeof d.value !== "function" || k === "constructor") continue;
			const f = d.value;
			P[k] = function (...a) {
				const t = performance.now();
				try { return f.apply(this, a); } finally {
					const dt = performance.now() - t;
					const key = (k === "getParameter" || k === "getError") ? k + "(0x" + (a[0] || 0).toString(16) + ")" : k;
					let e = stats.get(key); if (!e) stats.set(key, e = [0, 0, 0]);
					e[0]++; e[1] += dt; if (dt > e[2]) e[2] = dt;
				}
			};
		}
		// one swap per frame: the engine's frame ends in the OffscreenCanvas commit, which
		// Emscripten does with requestAnimationFrame or implicitly; count clears of the default framebuffer instead
		const ch = new BroadcastChannel("glprof");
		// the engine thread never returns to its event loop, so timers don't fire there:
		// report from inside the wrapped clear()
		const clear = P.clear;
		P.clear = function (m) {
			frames++;
			if (performance.now() - t0 > 5000) report();
			return clear.call(this, m);
		};
		function report() {
			const now = performance.now(), secs = (now - t0) / 1000;
			let total = 0; for (const e of stats.values()) total += e[1];
			const top = [...stats].sort((x, y) => y[1][1] - x[1][1]).slice(0, 20)
				.map(([k, e]) => k + " n=" + e[0] + " ms=" + e[1].toFixed(0) + " max=" + e[2].toFixed(1)).join("; ");
			ch.postMessage("[glprof] " + secs.toFixed(1) + " s: clears " + frames + ", calls " + [...stats.values()].reduce((s, e) => s + e[0], 0) +
				", time in WebGL " + total.toFixed(0) + " ms (" + (100 * total / (now - t0)).toFixed(0) + "%). top: " + top);
			stats.clear(); frames = 0; t0 = now;
		}
	})();
`;
	// Emscripten starts its workers from the main script's own URL, so the engine script
	// itself is loaded as a blob with the profiler in front; the wasm is looked up in /engine/
	const engineText = await (await fetch("/engine/spring-web.js")).text();
	Module.locateFile = (path) => new URL("/engine/" + path, location.href).href;
	return URL.createObjectURL(new Blob([code, engineText], { type: "text/javascript" }));
}

// ---- engine ---------------------------------------------------------------------
function startEngine(demo, engineSrc = "/engine/spring-web.js" + (params.get("noglcache") === "1" ? "?noglcache=1" : "")) {
	$("s-phase").textContent = "engine running";
	const canvas = $("canvas");
	const w = +(params.get("w") || 1280), h = +(params.get("h") || 720);
	canvas.width = w; canvas.height = h;
	canvas.style.width = w + "px"; canvas.style.height = h + "px";

	const args = ["--write-dir", "/recoil/write", demo];
	const shaderCache = params.get("shadercache") !== "0";
	note("starting spring-web " + args.join(" "));
	window.Module = {
		arguments: args,
		canvas,
		recoilEnv: {
			SPRING_DATADIR: "/recoil/write:/recoil",
			SPRING_WRITEDIR: "/recoil/write",
			// translated shaders, kept in OPFS between visits (?shadercache=0 turns it off)
			...(shaderCache ? { RECOIL_WEB_SHADER_CACHE: "/recoil/shadercache" } : {}),
			...(params.get("capture") ? { RECOIL_WEB_CAPTURE: params.get("capture") } : {}),
			...(params.get("trace") === "1" ? { RECOIL_WEB_TRACE: "1" } : {}),
			...(params.get("glcheck") ? { RECOIL_WEB_GLCHECK: params.get("glcheck") } : {}),
			// ?dumpshaders=<text>: write the WebGL source of shaders containing <text> to write/shader-dump-N.glsl
			...(params.get("dumpshaders") ? { RECOIL_WEB_DUMP_SHADERS: params.get("dumpshaders") } : {}),
			...(params.get("glslang") ? { RECOIL_WEB_GLSLANG: params.get("glslang") } : {}),
			...(params.get("glslanglimit") ? { RECOIL_WEB_GLSLANG_LIMIT: params.get("glslanglimit") } : {}),
			// ?nogl4=1: don't advertise the emulated indirect/base-instance draws, so the engine reports no GL4
			...(params.get("nogl4") === "1" ? { RECOIL_WEB_NO_GL4: "1" } : {}),
		},
		print: (t) => line(t, false),
		printErr: (t) => line(t, true),
		onExit: (code) => {
			harness.exitCode = code;
			note(`engine exited with code ${code}`);
			$("s-phase").textContent = `exited (code ${code})`;
			flush();
			saveLog();
		},
		onAbort: (what) => { note("abort: " + what); $("s-phase").textContent = "aborted"; saveLog(); },
	};
	harness.tEngine = performance.now();
	const s = document.createElement("script");
	s.src = engineSrc;
	s.onerror = () => note("could not load /engine/spring-web.js");
	document.body.append(s);
}

window.addEventListener("error", (e) => note("page error: " + e.message));
window.addEventListener("unhandledrejection", (e) => note("unhandled rejection: " + (e.reason && e.reason.message || e.reason)));

(async () => {
	$("s-coi").innerHTML = self.crossOriginIsolated ? '<span class="pass">yes</span>' : '<span class="fail">no: serve with COOP/COEP (serve.py)</span>';
	if (!self.crossOriginIsolated) return;
	try {
		$("s-phase").textContent = "loading content into OPFS";
		const c = await loadContent();
		if (params.get("autostart") === "0") { $("s-phase").textContent = "content loaded (autostart=0)"; return; }
		// the delivery page (dist/index.html) holds the start until the Play button is pressed:
		// the click is the user gesture that lets the browser start audio
		if (document.body.dataset.gate === "play") {
			$("s-phase").textContent = "ready: press Play";
			await new Promise((resolve) => { $("play").disabled = false; $("play").addEventListener("click", resolve, { once: true }); });
			if (window.applyPlayOptions) window.applyPlayOptions(params);
		}
		const settings = {
			Fullscreen: 0, WindowBorderless: 1, WindowPosX: 0, WindowPosY: 0,
			XResolutionWindowed: +(params.get("w") || 1280), YResolutionWindowed: +(params.get("h") || 720),
			LoadingMT: 0, VSync: 0, MSAALevel: 0,
			// the engine swaps even when it skipped drawing a frame (ForceSwapBuffers=1 is the
			// default); a WebGL canvas then presents a cleared, black frame: whole-screen flicker
			ForceSwapBuffers: 0,
			WebLiveSpeed: +(params.get("livespeed") || 1), WebPreset: params.get("preset") || "",
		};
		// ?cfg=Key:Value,Key:Value adds or overrides engine settings
		for (const kv of (params.get("cfg") || "").split(",")) {
			const [k, v] = kv.split(":");
			if (k && v != null) settings[k] = v;
		}
		await writeSettings(settings);
		await (await navigator.storage.getDirectory()).getDirectoryHandle("shadercache", { create: true });
		await setReplaySpeed(+(params.get("speed") || 1));
		if (params.get("testwidget") in TEST_WIDGETS) await addTestWidget();
		const target = params.get("skirmish") === "1" ? await writeSkirmishScript() : c.demo;
		if (params.get("glprofile") === "1") {
			new BroadcastChannel("glprof").onmessage = (e) => line(String(e.data));
			window.Module = {}; // installGlProfiler sets locateFile; startEngine merges it back
			const src = await installGlProfiler();
			const locateFile = window.Module.locateFile;
			startEngine(target, src);
			window.Module.locateFile = locateFile;
			note("WebGL profiler installed in the engine workers");
		} else startEngine(target);
	} catch (e) {
		note("error: " + e.message);
		$("s-phase").textContent = "error";
	}
})();

// the "extra" content bundle (music, other game modes' assets) is fetched once the game is
// running, in one low-priority stream; files the engine asks for before then fail to load
let deferredStarted = false;
function loadDeferred() {
	if (deferredStarted || params.get("deferred") === "0") return;
	deferredStarted = true;
	const w = new Worker("opfs-loader.js");
	w.onmessage = (e) => {
		const d = e.data;
		if (d.type === "log") note(d.text);
		else if (d.type === "progress" && window.onDeferredProgress) window.onDeferredProgress(d.done / d.total, d.done, d.total);
		else if (d.type === "deferreddone" || d.type === "error") {
			w.terminate();
			note(d.type === "error" ? "extra content: " + d.text : `extra content ready (fetched ${d.fetchedMB.toFixed(0)} MB in ${d.seconds.toFixed(0)} s)`);
			if (window.onDeferredProgress) window.onDeferredProgress(1, 0, 0);
		}
	};
	w.postMessage({ cmd: "deferred" });
}

$("save-log").addEventListener("click", () => harness.saveLog());
$("grab-frame").addEventListener("click", () => harness.grab()
	.then((r) => note(`frame saved (${r.status}, ${r.w}×${r.h}, age ${r.age.toFixed(1)} s)`))
	.catch((e) => note("could not save frame (use ?capture=N): " + e)));


