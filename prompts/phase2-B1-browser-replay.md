# Task: BAR→Web phase 2, milestone B1: headless replay plays to the end in a browser tab with no desync

You are continuing a port of the Recoil RTS engine (version 2026.07.04, used by Beyond All Reason) to WebAssembly. Phase 1 is done: the headless engine builds with Emscripten and plays a native BAR replay to the end **under Node** with every sync checksum matching (450/450). Your job is the first phase 2 step: get **the same headless replay** to play to the end **in a Chromium browser tab**, with the same checksum result. No renderer and no audio yet; this milestone only removes the dependence on Node.

Read these first:
- `C:\Beyond All Reason Web\BAR-web-phase1-scoping.md`: the full phase 1 log. It covers the build scripts, link flags, each fix, and the M4 "Caveats / open items for phase 2".
- `C:\Beyond All Reason Web\m4-harness\README.md`: the test replay, the playback script and widget, and the pass criterion.

## Environment
- Windows 11 host. Build in WSL **Ubuntu-24.04**, which has emsdk (emcc 7.0.0, Node 24), cmake 3.28 and ninja.
- Engine source: `~/RecoilEngine`, branch `wasm-port`. The streflop submodule is also on its own `wasm-port` branch.
- WASM build dir: `~/build-wasm`. Rebuild with `~/wasm-configure.sh` and `~/wasm-build.sh [target]`; build logs go to `~/build-wasm-<target>.log`, and `~/err-summary.sh` summarizes errors. Native control build: `~/build-native-wasmport`.
- Node playback harness: `~/m4` (`play.sh native|wasm <demo>`, plus the `m4_play.lua` widget). The test replay is `m4-atg-barb-15min.sdfz`: 27,000 frames with 450 echoed sync checksums.
- BAR content lives in the Windows install, mounted at `/mnt/c/.../Beyond-All-Reason/data`. The game and map archives the replay needs are game `test-31943-6cd6caa` and map All That Glitters v2.2, plus engine base content. Under Node, startup scans every archive in that folder.

## Tooling gotchas (learned the hard way)
- Call `wsl.exe` with `MSYS_NO_PATHCONV=1`, and put commands in script files: wsl expands `$VAR` itself.
- Processes started with `setsid nohup` die when wsl.exe exits. Run anything long (builds take minutes; a playback takes 4–7 minutes) as a background task of your own harness and wait for it to report back. Don't sleep-poll.
- `Spring.GetReplayLength()` returns 0 for this replay, because it was recorded with quitforce. End of demo is detected when that call starts returning nil.

## What is known to need work
1. **The main loop has to leave the browser main thread.** Emscripten proxies every pthread's stdio and file-system calls to the main thread. Under Node, the fix was to call `emscripten_main_thread_process_queued_calls()` on every pass of `SpringApp::Run`'s loop, see `rts/System/SpringApp.cpp`. A browser main thread can't block or busy-loop, so run the engine in a worker (`-sPROXY_TO_PTHREAD`, or an equivalent design) and keep the page's main thread free.
2. **File system.** Node uses `-sNODERAWFS`; the browser can't. Get the needed content into the browser, preferably OPFS (WASMFS with an OPFS backend) or an equivalent. Bring only the archives this replay needs, not the whole data folder: a game `.sdd`/`.sdz`/pool content, the map, the engine base archives, the replay, the widget and the write dir. If the archive scan/hash cache can be pre-built natively and shipped, do that; startup under Node already took 3.7 minutes.
3. **Link options.** The Node flags are kept in `RECOIL_WASM_NODE_LINK_OPTIONS` in the top-level `CMakeLists.txt`, and used by `rts/builds/headless/CMakeLists.txt`. Add a separate browser variant, for example a CMake option or a `RECOIL_WASM_TARGET=node|web` switch, that **does not break the Node build or its tests**.
4. **Threads.** The pthread pool is 32 (`RECOIL_WASM_PTHREAD_POOL_SIZE`), and the game uses about 16 threads by game start. Check whether the browser needs a bigger pool, given that extra workers only start when the main thread yields.
5. **Cross-origin isolation.** SharedArrayBuffer requires the page to be served with COOP/COEP headers (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`). Add a tiny local static server that sets them, for example a short Node or Python script, plus a minimal HTML page that starts the engine with the replay and sends the infolog to the console and the page.
6. **Optional, if it gets in your way:** a fatal error during loading ends in `RuntimeError: null function or function signature mismatch`, somewhere in `SpringApp::Kill` / `KillLua`. Fix it if it's blocking your debugging; otherwise leave it.

## Pass criterion
Load the page in Chromium; the built-in browser pane is fine, served from `localhost`. The replay plays to frame 27,000, the log shows `[DemoSync] summary: 450 demo checksums matched, 0 mismatched` with no `[DESYNC WARNING]`, and the tab stays responsive throughout. Also confirm that the Node build still passes: `ctest` in `~/build-wasm` (28/28) and `~/m4/play.sh wasm` (450/450). Record load time, sim time and peak memory next to the Node numbers in the scoping doc.

## Deliverables
- Engine changes as commits on `wasm-port` in `~/RecoilEngine` (and in streflop if needed). Write focused commit messages that end with the Co-Authored-By line your harness supplies.
- Browser harness code (page, server, content-packing script) **outside the engine fork**, in `C:\Beyond All Reason Web\web-harness\` with a README, alongside `m4-harness\`.
- A new "B1" progress-log section in `BAR-web-phase1-scoping.md` (or a new `BAR-web-phase2.md` that links back to it): what broke, how each was fixed, the timing table, and the caveats.

## Hard rules
- **Push only to the fork.** When finished, run `~/push-fork.sh` in WSL; it pushes streflop first, then the engine, to the `fork` remotes (SgtMetz). **Never push to `origin`** (that's upstream) and never open upstream PRs: Recoil's `AI_POLICY.md` forbids AI-written PRs without a maintainer-accepted issue.
- Don't regress the Node path. The native and Node checksum runs are the oracle.
- Don't put credentials or personal details anywhere in the code, commits or docs.
- If something is blocked by a design choice only the user can make (for example, whether OPFS content may be cached between visits), stop and ask instead of guessing.
