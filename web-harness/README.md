# Browser harness for B1 and B2 (unofficial, not part of the engine fork)

Plays the M4 test replay (`..\m4-harness\m4-atg-barb-15min.sdfz`) in a Chromium tab. There are two pages:
- `/` (`index.html`): B1, the **headless** WASM engine. It checks the sync checksums and prints PASS/FAIL. No renderer, no audio.
- `/render.html`: B2, the engine **with the renderer** (`spring-web.js`, WebGL2). It shows the game in a canvas. Still no audio. See "Renderer page" below.

The phase 2 log, with timings, is in `..\BAR-web-phase2.md`.

| File | What it is |
|---|---|
| `pack-content.py` | `stage`: copies just what the replay needs out of a BAR install into a staging dir, keeping mtimes. That's the game's rapid package (`packages/44fd…df.sdp`) and its 19,026 pool files (2.0 GB), the map `all_that_glitters_v2.2.sd7`, the engine base archives and the replay. `bundle`: writes `manifest.json` plus one `.bin` per bundle (`base`, `map`, `game`, `demo`, `run`), each one its files concatenated in manifest order. |
| `build-cache.sh` | Plays the replay **natively** against the staged content only. That writes the archive scan/hash cache (`cache/ArchiveCache22.lua`) and proves the subset is complete (450/450). `bundle` rewrites the cache's paths to `/recoil/...` and ships it in the `run` bundle, so the browser never hashes the 2 GB game. |
| `serve.py` | Static server with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, which SharedArrayBuffer (pthreads) needs. `/` is `www/`, `/engine/` is the WASM build dir and `/content/` is the bundle dir. |
| `www/index.html`, `www/harness.js` | The page. It fills OPFS, starts `spring-headless-web.js` with the replay, and mirrors the engine's stdout/stderr to the console and the page. It also tracks load and sim time, main-thread lag (a 100 ms heartbeat) and memory, and prints PASS/FAIL. `window.harness` holds every log line, the timing marks and the result. |
| `www/opfs-loader.js` | Dedicated worker that streams each bundle into OPFS through sync access handles. |
| `www/render.html`, `www/render.js` | The renderer page (B2). Same OPFS content, then it starts `spring-web.js` with a 1280×720 canvas (`?w=`, `?h=`), which is transferred to the engine's worker as an OffscreenCanvas. `window.harness` works as on the B1 page, plus `harness.grab()` (see below). |
| `www/test_render.lua` | Diagnostic widget for `?testwidget=1`: rects drawn directly, from a display list and in `DrawScreenPost`, text through a loaded font (direct and from a list) and `gl.Text`, plus a `gl.ReadPixels` readback logged every 30 frames as `[webtest]`. |
| `www/test_units.lua` | Unit-visibility probe for `?testwidget=units` (camera on the densest unit cluster, `[unittest]` log lines). |

## How it fits together
- The engine target is `engine-headless-web`, which outputs `~/build-wasm/spring-headless-web.{js,wasm}`. It's built from the same objects as the Node `engine-headless` with different link options (`RECOIL_WASM_WEB_LINK_OPTIONS`): `-sPROXY_TO_PTHREAD`, `-sWASMFS`, `-sENVIRONMENT=web,worker`. `main()` and the engine's busy main loop run in a worker, and the page's main thread only services proxied calls and log output.
- `Platform/Emscripten/WebFS.cpp` (web build only) mounts the OPFS root at `/recoil` at the start of `main()`, so the content is read outside the wasm heap. WASMFS doesn't keep file mtimes in OPFS (each file reports the time it was first looked up), and the archive scanner validates its cache by mtime. So the `run` bundle carries `mtimes.tsv`, and WebFS restores the original times before the scanner runs.
- Layout under `/recoil` (= the OPFS root): `base/ maps/ packages/ pool/ demos/ write/ mtimes.tsv`. The engine runs with `SPRING_DATADIR=/recoil/write:/recoil` and `--write-dir /recoil/write`.
- `write/springsettings.cfg` sets `VFSCacheArchiveFiles = 0` and `UseLuaMemPools = 0`, the values the Node and native runs pick up from the BAR install's config. Without it, the engine keeps every archive file it reads in the heap, and the browser run ends at about 4,054 of 4,095 MiB instead of about 2,813.
- When the engine exits, the page POSTs its whole log plus a JSON summary to `serve.py`, which saves it as `logs/infolog-browser.txt`. The engine also writes `/recoil/write/infolog.txt` inside OPFS.
- **OPFS caching between visits:** content bundles stay in OPFS and are fetched again only when their id (a hash of the file list, sizes and mtimes) changes. `write/` and the `run` bundle are rebuilt on every load. Before trusting a cached bundle, the loader spot-checks 66 of its files (existence and size) and fetches it again if any is missing. In one run every content file vanished from OPFS; see the phase 2 log. `?fresh=1` wipes OPFS first, and `?watchfs=1` logs the content-file counts whenever they change (for debugging). Site data for `localhost:<port>` can also be cleared from the browser's settings (it's about 2.1 GB).

## Run it (WSL)
```
H="/mnt/c/Beyond All Reason Web/web-harness"
BAR=/mnt/c/Users/<you>/AppData/Local/Programs/Beyond-All-Reason/data
# 1. stage + pre-build the cache (the native build dir must hold spring-headless and base/)
python3 "$H/pack-content.py" stage --bar "$BAR" --sdp 44fd01f1d430f1c94f27b75b242738df.sdp \
  --map all_that_glitters_v2.2.sd7 --demo "$H/../m4-harness/m4-atg-barb-15min.sdfz" \
  --base-build ~/build-native-wasmport --stage ~/web-content/stage
bash "$H/build-cache.sh" ~/web-content/stage ~/build-native-wasmport ~/m4/m4_play.lua
# 2. bundle
python3 "$H/pack-content.py" bundle --stage ~/web-content/stage --base-build ~/build-native-wasmport \
  --cache-write ~/web-content/stage/cache-write --widget ~/m4/m4_play.lua --out ~/web-content/out
# 3. build the browser engine and serve
~/wasm-build.sh engine-headless-web
python3 "$H/serve.py" --engine ~/build-wasm --content ~/web-content/out --port 8080
```
Then open `http://localhost:8080/` in Chromium (WSL2 forwards localhost to Windows).

Pass criterion: the result line says PASS, meaning `[DemoSync] summary: 450 demo checksums matched, 0 mismatched`, no `[DESYNC WARNING]`, and the last frame is ≥ 27,000. The main-thread lag should stay small throughout.

## Renderer page (B2)
Build and bundle:
- Build the engine with `~/wasm-build.sh engine-web`, which outputs `~/build-wasm/spring-web.{js,wasm}`. It runs with PROXY_TO_PTHREAD and an OffscreenCanvas WebGL2 context. The desktop-GL calls go through the shim in `rts/Rendering/GL/WebGL/`.
- Add `--fonts ~/RecoilEngine/cont/fonts` to the `bundle` command. The renderer needs the engine's default fonts, and they ship in the `base` bundle as `fonts/*`. The headless page doesn't use them.
- The `bundle` step puts game files a 1v1 skirmish doesn't need to start (music, raptor/scavenger assets, lava textures, scenarios: `DEFERRED_PREFIXES` in `pack-content.py`, about 0.8 GB) into `extra.bin`, marked `deferred` in the manifest. The page fetches it in one background stream 5 s after the game has loaded (`?deferred=0` skips it). Until it arrives, those files fail to load in the engine (a logged read error, then the caller carries on; music starts once its files are there).
- Translated shaders are cached in OPFS under `shadercache/` (`RECOIL_WEB_SHADER_CACHE`, set by the page; `?shadercache=0` turns it off). The first start compiles about 380 shaders through glslang + SPIRV-Cross; later starts read them back.
- The page shows the engine's load progress as a bar (stages from the load-screen messages, weighted by a measured first start), and doesn't mirror engine output to the browser console on the delivery page (`?console=1` does).

Then serve as above and open `http://localhost:8080/render.html`. The page writes the window and loading settings into `write/springsettings.cfg` before starting the engine: windowed at the canvas size, `LoadingMT = 0`, `VSync = 0`, `MSAALevel = 0`.

Query parameters:

| Parameter | Effect |
|---|---|
| `?w=1280&h=720` | Canvas and window size. |
| `?speed=N` | Replay speed set in `m4_play.lua` (default 1; the headless page uses 1000). |
| `?cfg=Key:Value,Key:Value` | Adds or overrides engine settings in `springsettings.cfg`. |
| `?capture=N` | `RECOIL_WEB_CAPTURE=N`: every N seconds the engine dumps its framebuffer to `write/capture.rgba` and logs the frame-end GL state. |
| `?trace=1` | `RECOIL_WEB_TRACE`: logs the first 60 draws after each capture (slow, for debugging). Also reports draws that raise a GL error, with the program's sampler units and bound textures (at most 24 program/error pairs). |
| `?glcheck=1` | `RECOIL_WEB_GLCHECK`: reads `glGetError` after every GL call and logs which entry point raised each error, with a call stack (wasm function indices; map them with `..\scratchpad\symstack.py` and `spring-web.js.symbols`). Error counts per entry point are logged every 20 s. Very slow: for finding error sources only, not for full replays. |
| `?testwidget=units` | Installs `www/test_units.lua`: from game frame 900 keeps the camera on the densest unit cluster (re-picked every 600 frames) and logs `[unittest]` visibility and pixel-readback lines. Moves the camera and reads only; use it with `?capture=N` to get frames that show units. |
| `?testwidget=1` | Installs `www/test_render.lua` as a user widget. |
| `?testwidget=vao` | Installs `www/test_luavao.lua`: indexed/array instancing, pixel readback, fixed ushort restart, and unsupported-operation rejection checks. Look for `[vaotest] PASS` in the log. |
| `?autostart=0` | Loads the content but doesn't start the engine. Opening it between runs resets the page cleanly. |
| `?fresh=1` | Wipes OPFS first, as on the headless page. |

Grabbing frames: `await harness.grab("name.png")` in the page console converts the latest `capture.rgba` to a PNG. It posts the PNG to `serve.py`, which saves it as `logs/name.png`, and it returns `{w, h, bytes, age}`, where `age` is in seconds. This is the reliable way to see a frame: a hidden tab or pane doesn't present one. When the engine exits, its log is saved as `logs/infolog-render.txt`. While the pane is hidden, page log forwarding can stall, so read `write/infolog.txt` from OPFS instead.

Load takes about 55 s from cached OPFS content. With the pane hidden the main loop is timer-driven (about 50 ms per iteration); otherwise it uses requestAnimationFrame. What renders and what doesn't is listed in the B2 entry of `..\BAR-web-phase2.md`.

### Multiplayer
Browsers have no UDP, so the engine's game traffic goes over a WebSocket relay (`relay/`, a Cloudflare Worker; see its [README](relay/README.md)). With `RECOIL_WEB_NET=1` the engine (`rts/System/Net/WebNet.cpp`) writes its datagrams into a ring in shared wasm memory. `www/webnet-worker.js`, a dedicated worker so a background tab doesn't stall it, sends them to the relay and writes incoming ones into a second ring. The host's engine runs the normal game server, so this is the engine's own netcode, unchanged.

| Parameter | Effect |
|---|---|
| `?mp=host` / `?mp=join` | Host a room or join one. Needs `&relay=wss://…` (or `window.BAR_RELAY`, which the delivery page sets in `config.js`), `&name=`, and `&room=CODE` to join. A host without `room` gets a random code. |
| `?mpteams=ffa\|2`, `?mpai=<Lua AI>` | Host only: free-for-all or two teams, and an optional AI player. |
| `?mpstart=N` | Host only: start as soon as N players are in the room (for tests). Otherwise call `harness.mpStart()`, or press Start game on the delivery page. |
| `?spectate=1` | Join as a spectator. |

The delivery page (`dist/index.html`) has Skirmish / Host / Join modes. A host gets an invite link (`?mp=join&room=CODE`) that opens the page ready to join. Native engines can join or host through `webnet-bridge.py` (cross-play; same engine commit only).

Cursor lock: the first click into the game captures the mouse (Pointer Lock), like a desktop RTS window, so edge scrolling and middle-drag camera work without the cursor leaving the canvas. Esc releases it. `?mouselock=0` turns this off. Middle-click autoscroll is blocked page-wide.

### Shader cross-compilation diagnostics (B2)

The optional glslang 16.6.0 / SPIRV-Cross vulkan-sdk-1.4.363.0 path compiles desktop GLSL through SPIR-V to GLSL ES 3.00. Unsupported shaders fall back to the text translator. Cross-compilation is enabled by default when the optional libraries are built in. WebGL2 LuaVAOs now support the basic indexed/array instanced drawing used by BAR scum, so its successful shader no longer reaches a nil VAO during initialization. Explicit mode 0 retains the text translator for comparisons.

- No `glslang` parameter, or `?glslang=1`: use cross-compiled shaders (default when the libraries are present).
- `?glslang=0`: use text translation only.
- `?glslang=2`: run the cross-compiler, then discard its output (diagnostic control).
- `?glslanglimit=N`: use cross-compiled output for only the first N shaders (requires cross-compilation enabled).
- `?trace=1`: also writes failed cross-compiler inputs as `xc-fail-N.glsl` in OPFS `write/`. These contain the desktop GLSL input, before SPIRV-Cross.

**OPFS navigation:** first open `/render.html?autostart=0` and wait for the `content ready` message before navigating to the run URL. Do not navigate away while the loader worker is writing. An interrupted load previously left content files missing and the engine failed on a missing font. Cached bundles are spot-checked, but that does not make interruption safe.

The renderer page also has **Save log** and **Save captured frame** buttons. The latter needs `?capture=N` and saves the latest engine framebuffer dump as `logs/frame.png`; it does not capture the surrounding browser UI.


### WebGL2 LuaVAO subset

The browser renderer requires VBOs, VAOs and instanced attributes for `gl.GetVAO()`. It no longer requires base-vertex or multi-draw-indirect support merely to create one. Desktop/headless capability checks retain their previous requirements. No new GL extensions are advertised.

Supported browser drawing uses WebGL2's ordinary and instanced `DrawArrays`/`DrawElements` paths with zero base vertex and base instance, core point/line/triangle primitives, and byte or ushort index buffers. WebGL2's fixed-index restart matches these two index formats, so these draws do not call the unsupported desktop `glPrimitiveRestartIndex` stub.

Nonzero base offsets, adjacency/patch primitives, indirect submission and uint index buffers fail with Lua errors before VAO initialization/binding. Uint buffers need follow-up work because LuaVBO uses custom restart index `0xffffff`, while WebGL2 fixes uint restart at `0xffffffff`. They are rejected rather than silently drawing with different semantics.

The optional `?testwidget=vao` creates two indexed instances and two array instances, checks four framebuffer pixels, catches the unsupported-operation errors with `pcall`, then verifies drawing still succeeds. It logs at startup and periodically during simulation. Its deliberately rejected calls produce expected sol2 exception messages. The test is separate from BAR's scum visuals: the M4 AI replay establishes that scum initializes and LuaRules survives, but does not exercise raptor scum growth.

Verified explicit-enabled run: `/render.html?glslang=1&speed=100&capture=10&testwidget=vao`, 450/450 checksums, no desync warnings, exit 0 at frame 27,090. `logs/b2-luavao-enabled.txt` includes pixel-test passes during simulation. `logs/b2-luavao-enabled.png` is a simulation framebuffer showing textured terrain, HUD and minimaps. It does not establish correct unit or scum rendering. Codex implemented this subset and ran the automated build, replay and pixel checks; these checks do not constitute human verification for an upstream contribution.

Build/regression evidence for this continuation: `logs/b2-luavao-builds.txt` (three WASM targets), `logs/b2-luavao-default-build.txt` (renderer rebuilt with the restored default), `logs/b2-luavao-native-build.txt`, `logs/b2-luavao-ctest.txt` (28/28), and `logs/b2-luavao-node.txt` (450/450, exit 0, frame 27,060). The test widget is local harness content and is not bundled into the engine fork.

Browser headless `/` also passes: 450/450, zero desync warnings, exit 0, frame 27,053. Saved separately as `logs/b2-luavao-headless-browser.txt`.

Separate default run `/render.html?speed=100&capture=10` (no shader-mode parameter, no test widget): **450/450**, zero desync warnings, exit 0 at frame **27,077**, heap **2,800 MiB**. Both scum halves load and LuaRules survives initialization. Evidence: `logs/b2-luavao-default.txt`; inspected simulation capture: `logs/b2-luavao-default.png`. The restored default is engine commit `a81f1c1`, following LuaVAO commit `c133702`. The default remains a tested choice for this replay in Chromium 157; SSBO shaders, complete unit/scum rendering, texture/FBO errors and other browsers remain open.

Shipping: `push-fork.sh` pushed streflop first (unchanged `047da3b`), then engine `a81f1c1`, only to the SgtMetz forks. Both worktrees are clean and match their fork branches. Push evidence: `logs/b2-luavao-push.txt`. No upstream push or PR.


### Units, GenEnvLut and LuaIntro (B2, Claude Code)

Units were missing because the engine deletes shaders before linking and the shim dropped their info, so model programs lost the compat attribute bindings. Fragment-only programs (LuaIntro blur, pause screen) couldn't link in WebGL2, and GenEnvLut's RGB16F render target wasn't renderable. Engine commits `3ffb8f7` (deferred shader deletion), `ae2e386` (generated fixed-function vertex stage), `e69b177` (RGB float targets stored as RGBA) and `14d4039` (trace-mode draw-error report) fix these; details are in `..\BAR-web-phase2.md`.

Runs, each 450/450 with no desync warnings and exit 0: unit probe `logs/b2-units-fixed-probe.txt` (frame 27,077) with capture `logs/b2-units-fixed-1.png`; default `logs/b2-units-default.txt` (frame 27,051) with `logs/b2-units-default-1.png`; LuaVAO test `logs/b2-units-vao.txt` (frame 27,070, `[vaotest] PASS`). Before the lifetime fix: `logs/b2-fbo-units-probe-run1.txt`, `-run2.txt`, `logs/b2-units-probe-2.png` (no unit models). GenEnvLut and `CopyToTexture` errors are 0 in all three; scum loads in both LuaRules halves.

Still open: under-construction units are solid silhouettes (no clip planes), SSBO GL4 widgets, CUS GL4, one DXT1 upload error in some runs, other browsers. These are automated checks run by Claude Code, not human verification.
Shipped: engine `14d4039` pushed to the SgtMetz fork after streflop (`047da3b`); both worktrees clean and matching `fork/wasm-port`. Evidence: `logs/b2-units-push.txt`. No upstream push or PR.

### Clip planes, UBOs, clip-query fix (B2, Claude Code)

Engine commits `f313fcf` (user clip planes via `WEBGL_clip_cull_distance`; build stages of units under construction), `67bd3d5` (arrays of arrays flattened), `02d2b3f` (engine UBOs; RGBA canvas forced opaque at swap), `1c2b70e` (`glGet*` of clip planes answer the emulated enables; fixes terrain clipped by a stale build-stage plane) and `8af110e` (texture allocation hooks no longer blame earlier calls' GL errors). Details and the reverted SSBO experiment are in `..\BAR-web-phase2.md`.

The browser pane's WebGL was blocked after GPU context losses, so the final replays ran in headless Chrome 157 (ANGLE D3D11, real GPU) driven over the DevTools protocol by `..\scratchpad\validate.ps1` with a throwaway profile. The page itself is unchanged; frames are saved with `harness.grab(name)`. Final-code unit probe: `logs/b2-clipfix-units.txt` (450/450, exit 0, frame 27,073) with `logs/b2-clipfix-units-*.png`; before the clip-query fix: `logs/b2-final-units-run2-11.png` (terrain cut). Default and LuaVAO replays were not rerun on the final tree.

Still open: SSBO GL4 widgets, CUS GL4, geometry-shader variants, filled wireframe build stage, unattributed `0x500`/`0x502` with BAR's first-launch settings, other browsers/GPUs. These are automated checks run by Claude Code, not human verification.

### GL error attribution and renderbuffer formats (B2, Claude Code)

Engine commits `34be612` (`?glcheck=1` per-call GL error check, opt-in) and `60bdc81` (sized renderbuffer formats). The glcheck run traced the per-frame `0x506` errors to the reflection cubemap. Its `GL_DEPTH_COMPONENT` depth renderbuffer is rejected by WebGL2, so the FBO was incomplete; it is now `DEPTH_COMPONENT24`. The other recurring errors now have known sources (depth-copy blit, shadow sampler parameters, `CMetalExtractionTexture`, one LuaVAO instanced draw, DDS mipmaps); see the table in `..\BAR-web-phase2.md`. Evidence: `logs/b2-glcheck-baseline*.txt`, `logs/b2-glcheck-rbfix*.txt`.

Validation in headless Chrome 157 (`..\scratchpad\rbfix-runs.ps1`), each 450/450 with 0 desync warnings and exit 0: unit probe `logs/b2-rbfix-units.txt` (frame 27,098, captures `b2-rbfix-units-*.png`), default `logs/b2-rbfix-default.txt` (frame 27,051, `b2-rbfix-default-*.png`), LuaVAO test `logs/b2-rbfix-vao.txt` (frame 27,083, 22× `[vaotest] PASS`). Scum loads in both LuaRules halves in all three. These are automated checks run by Claude Code, not human verification.
Shipped: engine `60bdc81` pushed to the SgtMetz fork after streflop (`047da3b`); both worktrees clean and matching `fork/wasm-port`. Evidence: `logs/b2-rbfix-push.txt`. No upstream push or PR.

### Depth-buffer copy (B2, Claude Code)

Engine commit `e013691`. WebGL2 blits depth only between identical formats. The default framebuffer is DEPTH24_STENCIL8 and the engine's depth copy (ground decals, soft particles) is a `DEPTH_COMPONENT24` texture, so the per-frame copy failed. The shim now re-specifies such a texture as DEPTH24_STENCIL8 before its first depth blit with the default framebuffer. Runs, each 450/450 with 0 desync warnings and exit 0: `logs/b2-depthfix-units.txt` (frame 27,057), `logs/b2-depthfix-default.txt` (27,067), `logs/b2-depthfix-vao.txt` (27,056, 21× `[vaotest] PASS`); glcheck evidence `logs/b2-glcheck-depthfix*.txt`. The visual effect on decals and particles is not yet established from the captures. These are automated checks run by Claude Code, not human verification.
Shipped: engine `e013691` pushed to the SgtMetz fork after streflop (`047da3b`); both worktrees clean and matching `fork/wasm-port`. Evidence: `logs/b2-depthfix-push.txt`. No upstream push or PR.
