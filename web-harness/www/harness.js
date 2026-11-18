// Browser harness for the headless replay: fill OPFS (opfs-loader.js), then start
// spring-headless-web.js (PROXY_TO_PTHREAD: main() runs in a worker) with the replay,
// mirror the engine's stdout/stderr to the console and the page, and keep track of
// load/sim timing, main-thread responsiveness and memory.
"use strict";

const params = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const t0 = performance.now();
const secs = (t) => (t / 1000).toFixed(1) + " s";

const harness = window.harness = {
	lines: [],       // every engine output line
	marks: {},       // name -> ms since engine start
	maxLagMs: 0,
	lagSpikes: [],   // [ms since engine start, lag ms] for every heartbeat late by > 50 ms
	peakMemMB: 0,
	peakWasmMB: 0,
	frame: -1,
	result: null,    // {matched, mismatched, desyncWarnings, exitCode}
	tEngine: null,
};

// ---- output -------------------------------------------------------------------
const logEl = $("log"), keyEl = $("key");
const KEY = /\[WebFS\]|\[DemoSync\]|\[ThreadPool::SetThreadCount\]\[2\]|\[M4\]|DESYNC|Beginning demo playback|\[Fatal\]|Fatal error|RuntimeError|Aborted|abort\(|\[harness\]/;
const MAX_DOM_LINES = 1500;
let pending = [], flushQueued = false;
let desyncWarnings = 0;

function flush() {
	flushQueued = false;
	if (!pending.length) return;
	const atBottom = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 4;
	logEl.append(pending.join("\n") + "\n");
	pending = [];
	while (logEl.childNodes.length > MAX_DOM_LINES / 50) logEl.removeChild(logEl.firstChild);
	if (atBottom) logEl.scrollTop = logEl.scrollHeight;
}

function line(text, isErr) {
	harness.lines.push(text);
	(isErr ? console.warn : console.log)(text);
	pending.push(text);
	if (!flushQueued) { flushQueued = true; requestAnimationFrame(flush); setTimeout(flush, 500); }
	if (KEY.test(text)) {
		const now = harness.tEngine == null ? 0 : performance.now() - harness.tEngine;
		keyEl.append(`[+${secs(now)}] ${text}\n`);
		keyEl.scrollTop = keyEl.scrollHeight;
	}
	parse(text);
}
const note = (text) => line("[harness] " + text);

function mark(name) {
	if (harness.marks[name] == null && harness.tEngine != null) harness.marks[name] = performance.now() - harness.tEngine;
}

function parse(text) {
	let m;
	if (text.includes("[WebFS]")) mark("webfs");
	if (text.includes("Beginning demo playback")) mark("playback");
	if ((m = /\[M4\] playback frame (\d+)/.exec(text))) {
		harness.frame = +m[1];
		if (harness.marks.firstFrame == null) { mark("firstFrame"); harness.marks.firstFrameNo = harness.frame; }
		$("s-frame").textContent = harness.frame;
	}
	if ((m = /\[M4\] quitting at frame (\d+)/.exec(text))) {
		mark("quit"); harness.frame = +m[1]; $("s-frame").textContent = harness.frame + " (quit)";
	}
	if (text.includes("[DESYNC WARNING]")) desyncWarnings += 1;
	if ((m = /\[DemoSync\] wasm heap size at exit: (\d+) MiB/.exec(text))) harness.engineHeapMiB = +m[1];
	if ((m = /\[DemoSync\] summary: (\d+) demo checksums matched, (\d+) mismatched/.exec(text))) {
		mark("summary");
		harness.result = { matched: +m[1], mismatched: +m[2], desyncWarnings };
		showResult();
	}
	updateTimes();
}

function updateTimes() {
	const k = harness.marks, parts = [];
	if (harness.contentSeconds != null) parts.push(`content ${harness.contentSeconds.toFixed(1)} s`);
	if (k.webfs != null) parts.push(`OPFS mount ${secs(k.webfs)}`);
	if (k.playback != null) parts.push(`load→playback ${secs(k.playback)}`);
	if (k.firstFrame != null && k.quit != null) parts.push(`sim frames ${k.firstFrameNo}→${harness.frame}: ${secs(k.quit - k.firstFrame)}`);
	if (k.quit != null) parts.push(`total ${secs(k.quit)}`);
	$("s-times").textContent = parts.join(" · ") || "-";
}

function showResult() {
	const r = harness.result;
	const ok = r && r.matched === 450 && r.mismatched === 0 && r.desyncWarnings === 0 && harness.frame >= 27000;
	$("s-result").innerHTML = r
		? `<span class="${ok ? "pass" : "fail"}">${ok ? "PASS" : "FAIL"}</span>: ${r.matched} matched, ${r.mismatched} mismatched, ${r.desyncWarnings} [DESYNC WARNING], last frame ${harness.frame}` +
		  (r.exitCode != null ? `, exit code ${r.exitCode}` : "")
		: "-";
}

// ---- responsiveness and memory --------------------------------------------------
let lastTick = performance.now();
setInterval(() => {
	const now = performance.now();
	const lag = now - lastTick - 100;
	lastTick = now;
	// the run (engine start to the widget's quit) and shutdown are tracked apart: at exit
	// EXIT_RUNTIME joins the pthreads from the main thread, which blocks it briefly
	if (harness.tEngine != null && harness.marks.quit == null) harness.maxLagMs = Math.max(harness.maxLagMs, lag);
	if (harness.tEngine != null && lag > 50) harness.lagSpikes.push([Math.round(now - harness.tEngine), Math.round(lag)]);
	if (harness.marks.quit != null) harness.maxExitLagMs = Math.max(harness.maxExitLagMs || 0, lag);
	$("s-lag").textContent = `${Math.max(0, lag).toFixed(0)} ms now, ${harness.maxLagMs.toFixed(0)} ms max during the run` +
		(harness.maxExitLagMs != null ? `, ${harness.maxExitLagMs.toFixed(0)} ms max during shutdown` : "");
}, 100);

async function sampleMemory() {
	let txt = [];
	try {
		const mem = window.Module && Module.wasmMemory;
		if (mem) {
			const mb = mem.buffer.byteLength / 1048576;
			harness.peakWasmMB = Math.max(harness.peakWasmMB, mb);
			txt.push(`wasm heap ${mb.toFixed(0)} MiB (peak ${harness.peakWasmMB.toFixed(0)})`);
		}
	} catch (e) { /* not exported */ }
	if (performance.measureUserAgentSpecificMemory) {
		try {
			const r = await performance.measureUserAgentSpecificMemory();
			const mb = r.bytes / 1048576;
			harness.peakMemMB = Math.max(harness.peakMemMB, mb);
			txt.push(`page+workers ${mb.toFixed(0)} MiB (peak ${harness.peakMemMB.toFixed(0)})`);
		} catch (e) { /* not available in every Chromium build (SecurityError in some embedders) */ }
	}
	$("s-mem").textContent = txt.join(" · ") || "n/a";
}
setInterval(sampleMemory, 15000);

// heap growth timeline: [ms since engine start, MiB, last log line] whenever the heap grew by >= 64 MiB
harness.heapTimeline = [];
setInterval(() => {
	try {
		const mem = window.Module && Module.wasmMemory;
		if (!mem) return;
		const mb = Math.round(mem.buffer.byteLength / 1048576);
		const last = harness.heapTimeline[harness.heapTimeline.length - 1];
		if (!last || mb - last[1] >= 64) harness.heapTimeline.push([Math.round(performance.now() - harness.tEngine), mb, (harness.lines[harness.lines.length - 1] || "").slice(0, 160)]);
	} catch (e) { /* not exported */ }
}, 250);

// ---- content -> OPFS ------------------------------------------------------------
function loadContent() {
	return new Promise((resolve, reject) => {
		const w = new Worker("opfs-loader.js");
		w.onmessage = (e) => {
			const d = e.data;
			if (d.type === "log") note(d.text);
			else if (d.type === "progress") {
				$("s-prog").value = d.done / d.total;
				$("s-content").textContent = `${(d.done / 1e6).toFixed(0)} / ${(d.total / 1e6).toFixed(0)} MB${d.file ? " (" + d.file + ")" : ""}`;
			} else if (d.type === "done") {
				w.terminate();
				harness.contentSeconds = d.seconds;
				$("s-prog").value = 1;
				$("s-content").textContent = `ready in ${d.seconds.toFixed(1)} s (fetched ${d.fetchedMB.toFixed(0)} MB; OPFS usage ${d.usageMB.toFixed(0)} MB of ${d.quotaMB.toFixed(0)} MB quota)`;
				note(`content ready in ${d.seconds.toFixed(1)} s, fetched ${d.fetchedMB.toFixed(0)} MB`);
				resolve(d);
			} else if (d.type === "error") { w.terminate(); reject(new Error(d.text)); }
		};
		w.onerror = (e) => reject(new Error(e.message));
		w.postMessage({ cmd: "load", fresh: params.get("fresh") === "1" });
	});
}

// ?watchfs=1 (debugging): every 2 s, count the files in the read-only content dirs and
// log a line whenever a count changes
async function watchFs() {
	const root = await navigator.storage.getDirectory();
	let last = "";
	const count = async (dir) => {
		let n = 0;
		for await (const [, h] of dir.entries()) n += h.kind === "file" ? 1 : await count(h);
		return n;
	};
	setInterval(async () => {
		const parts = [];
		for (const d of ["base", "maps", "packages", "demos"]) {
			try { parts.push(`${d}=${await count(await root.getDirectoryHandle(d))}`); } catch (e) { parts.push(`${d}=?`); }
		}
		try { await root.getFileHandle("mtimes.tsv"); parts.push("mtimes.tsv=1"); } catch (e) { parts.push("mtimes.tsv=0"); }
		const s = parts.join(" ");
		if (s !== last) { note("watchfs: " + s); last = s; }
	}, 2000);
}

// on exit: post the whole log plus a summary to serve.py (saved as logs/infolog-browser.txt)
function saveLog() {
	const summary = {
		userAgent: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency,
		result: harness.result, lastFrame: harness.frame, marks: harness.marks,
		contentSeconds: harness.contentSeconds, maxLagMsDuringRun: harness.maxLagMs,
		maxLagMsDuringShutdown: harness.maxExitLagMs, lagSpikes: harness.lagSpikes,
		wasmHeapPeakMiB: harness.peakWasmMB, engineHeapMiB: harness.engineHeapMiB,
	};
	const body = harness.lines.join("\n") + "\n\n[harness] summary " + JSON.stringify(summary, null, 1) + "\n";
	fetch("/log/infolog-browser.txt", { method: "POST", body })
		.then((r) => note(`log saved (${r.status})`), (e) => note("could not save log: " + e));
}

// ---- engine ---------------------------------------------------------------------
function startEngine(demo) {
	$("s-phase").textContent = "engine running";
	const args = ["--write-dir", "/recoil/write", demo];
	note("starting spring-headless-web " + args.join(" "));
	window.Module = {
		arguments: args,
		recoilEnv: { SPRING_DATADIR: "/recoil/write:/recoil", SPRING_WRITEDIR: "/recoil/write" },
		print: (t) => line(t, false),
		printErr: (t) => line(t, true),
		onExit: (code) => {
			mark("exit");
			note(`engine exited with code ${code}`);
			$("s-phase").textContent = `exited (code ${code})`;
			if (harness.result) harness.result.exitCode = code; else harness.result = { matched: 0, mismatched: 0, desyncWarnings, exitCode: code };
			showResult(); sampleMemory(); flush();
			saveLog();
		},
		onAbort: (what) => { note("abort: " + what); $("s-phase").textContent = "aborted"; },
	};
	harness.tEngine = performance.now();
	const s = document.createElement("script");
	s.src = "/engine/spring-headless-web.js";
	s.onerror = () => note("could not load /engine/spring-headless-web.js");
	document.body.append(s);
}

(async () => {
	$("s-coi").innerHTML = self.crossOriginIsolated ? '<span class="pass">yes</span>' : '<span class="fail">no: serve with COOP/COEP (serve.py)</span>';
	if (!self.crossOriginIsolated) return;
	try {
		$("s-phase").textContent = "loading content into OPFS";
		const c = await loadContent();
		if (params.get("watchfs") === "1") watchFs();
		if (params.get("autostart") === "0") { $("s-phase").textContent = "content loaded (autostart=0)"; return; }
		startEngine(c.demo);
	} catch (e) {
		note("error: " + e.message);
		$("s-phase").textContent = "error";
	}
})();
