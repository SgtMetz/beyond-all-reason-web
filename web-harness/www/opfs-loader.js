// Dedicated worker: copies the content bundles listed in /content/manifest.json into
// the origin private file system (OPFS), where the engine reads them (WASMFS mounts the
// OPFS root at /recoil). Sync access handles are only available in workers.
//
// Bundles are kept between visits: OPFS file .bundles.json records the id (a hash of
// the file list) of every bundle written completely, and a bundle is fetched again
// only when its id changed. The "run" bundle (widget, archive cache, mtimes) and the
// write dir are always reset, so every run starts from the same state.
// Bundles marked "deferred" in the manifest (music, raptor/scavenger assets: files a 1v1
// skirmish doesn't need to start) are skipped by "load" and fetched by "deferred", which
// the page sends once the game is running: one stream, so it doesn't compete with the game.
// Message in:  {cmd: "load", fresh: bool} | {cmd: "deferred"}
// Messages out: {type: "log"|"progress"|"done"|"error", ...}

const post = (type, data) => postMessage({ type, ...data });
const log = (text) => post("log", { text });

async function getDir(root, parts, create) {
	let d = root;
	for (const p of parts) d = await d.getDirectoryHandle(p, { create });
	return d;
}

async function removeEntry(dir, name) {
	try { await dir.removeEntry(name, { recursive: true }); } catch (e) { if (e.name !== "NotFoundError") throw e; }
}

async function readState(root) {
	try {
		const fh = await root.getFileHandle(".bundles.json");
		return JSON.parse(await (await fh.getFile()).text());
	} catch (e) { return {}; }
}

async function writeState(root, state) {
	const fh = await root.getFileHandle(".bundles.json", { create: true });
	const h = await fh.createSyncAccessHandle();
	const bytes = new TextEncoder().encode(JSON.stringify(state));
	h.truncate(0); h.write(bytes, { at: 0 }); h.flush(); h.close();
}

// spot-check a cached bundle: its first and last file plus up to 64 others must exist with
// the manifest size. (In one run every content file was found missing although
// .bundles.json said the bundles were complete; see BAR-web-phase2.md.)
async function verifyBundle(root, bundle) {
	const files = bundle.files;
	const picks = new Set([0, files.length - 1]);
	for (let k = 0; k < Math.min(64, files.length); k++) picks.add(Math.floor((k * 7919) % files.length));
	for (const idx of picks) {
		const [path, size] = files[idx];
		const parts = path.split("/");
		const name = parts.pop();
		try {
			const dir = await getDir(root, parts, false);
			const f = await (await dir.getFileHandle(name)).getFile();
			if (f.size !== size) return `${path}: size ${f.size}, expected ${size}`;
		} catch (e) {
			return `${path}: ${e.name}`;
		}
	}
	return null;
}

// stream files [first, last) of one bundle: its files are concatenated in manifest order, so
// a range of files is a byte range. byteOffset is where file `first` starts in the bundle.
// With a range of the whole bundle no Range header is sent.
async function writeBundle(root, bundle, onBytes, first = 0, last = bundle.files.length, byteOffset = 0) {
	const whole = (first === 0 && last === bundle.files.length);
	let length = 0;
	for (let i = first; i < last; i++) length += bundle.files[i][1];
	const resp = await fetch("/content/" + bundle.file, whole ? {} : { headers: { Range: `bytes=${byteOffset}-${byteOffset + length - 1}` } });
	if (!resp.ok) throw new Error(`fetch ${bundle.file}: HTTP ${resp.status}`);
	if (!whole && resp.status !== 206) throw new Error(`${bundle.file}: server ignored the Range request (HTTP ${resp.status})`);
	const reader = resp.body.getReader();
	const dirCache = new Map();
	let chunk = new Uint8Array(0), chunkPos = 0;

	for (const [path, size] of bundle.files.slice(first, last)) {
		const parts = path.split("/");
		const name = parts.pop();
		const key = parts.join("/");
		let dir = dirCache.get(key);
		if (!dir) { dir = await getDir(root, parts, true); dirCache.set(key, dir); }
		const fh = await dir.getFileHandle(name, { create: true });
		const h = await fh.createSyncAccessHandle();
		h.truncate(0);
		let written = 0;
		while (written < size) {
			if (chunkPos === chunk.length) {
				const { value, done } = await reader.read();
				if (done) { h.close(); throw new Error(`${bundle.file}: truncated at ${path}`); }
				chunk = value; chunkPos = 0;
			}
			const n = Math.min(size - written, chunk.length - chunkPos);
			h.write(chunk.subarray(chunkPos, chunkPos + n), { at: written });
			written += n; chunkPos += n;
			onBytes(n);
		}
		h.flush(); h.close();
	}
}

// split a big bundle into contiguous file ranges of about equal bytes
function splitBundle(bundle) {
	if (bundle.files.length < 500 || bundle.size < 100e6) return [];
	const n = Math.max(4, Math.min(8, self.navigator.hardwareConcurrency || 4));
	const parts = [];
	const target = bundle.size / n;
	let first = 0, offset = 0, acc = 0, startOffset = 0;
	for (let i = 0; i < bundle.files.length; i++) {
		acc += bundle.files[i][1]; offset += bundle.files[i][1];
		if ((acc >= target && parts.length < n - 1) || i === bundle.files.length - 1) {
			parts.push({ first, last: i + 1, byteOffset: startOffset });
			first = i + 1; startOffset = offset; acc = 0;
		}
	}
	return parts;
}

// each part goes to a sub-worker (this same script) with its own connection
function writeParallel(bundle, parts, onBytes) {
	return Promise.all(parts.map((p) => new Promise((resolve, reject) => {
		const w = new Worker("opfs-loader.js");
		w.onmessage = (e) => {
			if (e.data.type === "bytes") onBytes(e.data.n);
			else if (e.data.type === "partdone") { w.terminate(); resolve(); }
			else if (e.data.type === "error") { w.terminate(); reject(new Error(e.data.text)); }
		};
		w.onerror = (e) => { w.terminate(); reject(new Error(e.message)); };
		w.postMessage({ cmd: "part", bundle, ...p });
	})));
}

async function load(fresh, deferredOnly = false) {
	const t0 = performance.now();
	const manifest = await (await fetch("/content/manifest.json")).json();
	const root = await navigator.storage.getDirectory();

	if (fresh) {
		log("fresh=1: clearing OPFS");
		for await (const name of root.keys()) await removeEntry(root, name);
	}
	// the write dir and the per-run files are always rebuilt
	if (!deferredOnly) await removeEntry(root, "write");

	const state = fresh ? {} : await readState(root);
	const bundles = manifest.bundles.filter((b) => !!b.deferred === deferredOnly);
	const total = bundles.reduce((s, b) => s + b.size, 0);
	let done = 0, fetched = 0;

	for (const b of bundles) {
		if (b.name !== "run" && state[b.name] === b.id) {
			const bad = await verifyBundle(root, b);
			if (!bad) {
				log(`bundle ${b.name}: cached in OPFS (${b.files.length} files, ${(b.size / 1e6).toFixed(0)} MB)`);
				done += b.size;
				post("progress", { done, total });
				continue;
			}
			log(`bundle ${b.name}: cached copy is damaged (${bad}), fetching it again`);
		}
		const tb = performance.now();
		delete state[b.name];
		await writeState(root, state);
		let last = 0;
		let bundleBytes = 0;
		const onBytes = (n) => {
			done += n; fetched += n; bundleBytes += n;
			const now = performance.now();
			if (now - last > 250) { last = now; post("progress", { done, total, file: b.name }); }
		};
		// big bundles (the game: 18,000 files) are written by several workers at once, each
		// fetching its own byte range; the single-stream write is what takes minutes
		const parts = deferredOnly ? [] : splitBundle(b);
		if (parts.length > 1) {
			try {
				log(`bundle ${b.name}: ${parts.length} parallel parts`);
				await writeParallel(b, parts, onBytes);
			} catch (e) {
				log(`bundle ${b.name}: parallel load failed (${e.message}), loading in one stream`);
				done -= bundleBytes; fetched -= bundleBytes; bundleBytes = 0; // progress restarts
				await writeBundle(root, b, onBytes);
			}
		} else {
			await writeBundle(root, b, onBytes);
		}
		state[b.name] = b.id;
		await writeState(root, state);
		log(`bundle ${b.name}: wrote ${b.files.length} files, ${(b.size / 1e6).toFixed(0)} MB in ${((performance.now() - tb) / 1000).toFixed(1)} s`);
	}
	const est = await navigator.storage.estimate();
	post(deferredOnly ? "deferreddone" : "done", {
		demo: manifest.demo, seconds: (performance.now() - t0) / 1000, fetchedMB: fetched / 1e6,
		usageMB: est.usage / 1e6, quotaMB: est.quota / 1e6,
	});
}

onmessage = (e) => {
	if (e.data.cmd === "part") {
		const { bundle, first, last, byteOffset } = e.data;
		let pending = 0;
		const flushBytes = () => { if (pending) { postMessage({ type: "bytes", n: pending }); pending = 0; } };
		navigator.storage.getDirectory()
			.then((root) => writeBundle(root, bundle, (n) => { pending += n; if (pending > 4e6) flushBytes(); }, first, last, byteOffset))
			.then(() => { flushBytes(); postMessage({ type: "partdone" }); })
			.catch((err) => post("error", { text: String(err && err.stack || err) }));
	} else if (e.data.cmd === "deferred") load(false, true).catch((err) => post("error", { text: String(err && err.stack || err) }));
	else if (e.data.cmd === "load") load(!!e.data.fresh).catch((err) => post("error", { text: String(err && err.stack || err) }));
};
