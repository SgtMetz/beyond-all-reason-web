# BAR → Web: Phase 1 scoping (Recoil 2026.07.04, headless)

Source: `C:\Beyond All Reason Web\RecoilEngine` (tag `2026.07.04`, matches the installed client's `recoil_2026.07.04`, so native replays can serve as a sync oracle).
Engine size: ~385k lines of first-party C++23, plus 30 vendored libs under `rts/lib`.

## Phase 1 goal
Build `engine-headless` with Emscripten and play back a native BAR replay (`.sdfz`) in Node or a browser with **no desync**. That proves the sim, Lua, VFS and threading all work in WASM before any rendering work starts.

## Good news
| Area | Finding |
|---|---|
| Graphics/SDL | Headless already links `rts/lib/headlessStubs` (GL/GLEW/SDL stubs). No GL needed in phase 1. The only snag: `find_package(OpenGL)` in `rts/builds/headless/CMakeLists.txt` must be made optional. |
| Sound | Headless uses `NO_SOUND` / `no-sound` lib. |
| Networking | `GameServer.cpp:170`: the UDP listener is skipped when `onlyLocal`; local games and replays use `CLocalConnection`. asio only needs to *compile*, not run. |
| Float determinism | Native SSE builds **clear** DAZ/FTZ (`streflop/FPUSettings.h:473`) → plain IEEE-754 single precision with denormals, which is exactly WASM's float semantics. Bit-identical results with native x86 are plausible, provided `-ffp-contract=off` (no FMA fusion) and streflop's own libm is used. |
| Non-x86 precedent | An ARM64 path already exists (`STREFLOP_NEON`, `sse2neon`, `SSE2NEON` switch in `System/simd_compat.h`), so x86 assumptions are already partly abstracted. |
| SSE intrinsics | Only 7 first-party files. Emscripten compiles `<xmmintrin.h>`/`<emmintrin.h>` to WASM SIMD128 with `-msimd128 -msse2`. |

## Blockers to work through (in expected order)
1. ~~**Toolchain missing on this machine**~~: resolved 2026-11-12 (WSL2 Ubuntu 24.04 + emsdk; see Progress log).
2. **streflop autodetect** (`rts/lib/streflop/CMakeLists.txt:17-34`) hits `FATAL_ERROR` on `wasm32`. Add a WASM mode: no-op `streflop_init` (no MXCSR or x87 on WASM), using the soft/NEON-style branch as a template.
3. **Inline asm / CPU detection**: `System/Platform/CpuID.cpp`, `System/Sync/backtrace.c` (and Win-only `CrashHandler.cpp`). Need `#ifdef __EMSCRIPTEN__` stubs.
4. **Platform layer**: Emscripten presents as Linux-ish. Expect fallout in `System/Platform/Linux/*` (`CpuTopology`, `ThreadSupport`, `CrashHandler` with libunwind `unw_*`, signals), `Platform/Misc.cpp` (`fork`/`execv`, `dlopen`), `Main.cpp`. Needs a `Platform/Emscripten` variant, or guards around them.
5. **Threads**: `ThreadPool` (`WorkerThreadCount`, which can be set to 0 = main thread only), the futex-based mutexes in `Platform/Linux/Futex.h`, and the QTPFS pathing threads. Plan: first build with `WorkerThreadCount=0` and pthreads on (`-pthread`, needs COOP/COEP in browsers). Single-threaded performance is a later concern.
6. **pr-downloader** requires libcurl + zlib + minizip and is linked into headless. For phase 1, stub or exclude it: content is preloaded into the VFS, not downloaded.
7. **Dependencies**: DevIL (images, `find_package_static`), zlib (use Emscripten port `-sUSE_ZLIB=1`), Tracy (disable), mimalloc (use the default allocator), luasocket (stub).
8. **Game content / VFS**: BAR game + map archives are hundreds of MB. Phase 1 can mount them from the host filesystem under Node (`NODEFS`). Browser delivery (IDBFS/OPFS, streaming) is a phase 2 problem.
9. **Skirmish AIs** (BARb, CircuitAI) are loaded as shared libraries. Not needed for replay playback; later they need static linking or Emscripten side modules.

## Proposed milestones
- **M0**: WSL2 + emsdk + CMake/Ninja installed; native Linux headless build succeeds (baseline). **Done 2026-11-12.**
- **M1**: `emcmake cmake` configures with a WASM toolchain branch (streflop mode, optional OpenGL, pr-downloader off). **Done 2026-11-12.**
- **M2**: `engine-headless.wasm` links (stubs for platform calls). **Done 2026-11-14.**
- **M3**: Unit tests (`test_Float3`, `test_SyncedPrimitive`, …) pass under Node. **Done 2026-11-14** (28/28).
- **M4**: Native BAR replay plays to the end under Node with no desync (sync checksums match native). **Done 2026-11-14** (450/450 checksums).

M4 is the go/no-go point for phase 2 (renderer, audio, browser delivery, multiplayer).

**Phase 2 continues in [BAR-web-phase2.md](BAR-web-phase2.md)** (B1, 2026-11-14: the same replay in a Chromium tab, 450/450).

## Progress log

### 2026-11-12: environment + M1 configure

**Environment (done)**
- WSL 3.0.5, kernel 6.18; distro `Ubuntu-24.04` (24.04.5 LTS), WSL2, user `evmet`. 12 cores, ~7.6 GB RAM visible to WSL (limit build parallelism to about `-j6` to avoid OOM in C++23 TUs).
- Toolchain: cmake 3.28.3 (Recoil needs ≥ 3.27), ninja 1.11.1, gcc-13 13.3.0, emcc 7.0.0, node v24.19.0 (from emsdk).
- Source: `~/RecoilEngine`, fresh shallow clone of tag `2026.07.04` with submodules. It was cloned rather than copied because the Windows checkout has `core.autocrlf=true` (CRLF files). HEAD `de693612` and all 17 submodule SHAs match the Windows checkout.
- Emscripten ports pre-built: zlib, libpng, libjpeg, freetype, sdl2.

**M0 (native baseline): DONE**
- `~/build-native/spring-headless` (627 MB with debug info). 1296 ninja steps, 12m31s wall time at `-j6`, no errors, 1 compiler warning.
- `--version` prints `2026.07.04 (Headless)`; `--sync-version` prints `2026.07.04`, matching the installed client's `recoil_2026.07.04`.
- Base content (`springcontent.sdz`, `maphelper.sdz`, `cursors.sdz`) built into `~/build-native/base`.
- The first configure attempt failed with `Could NOT find Freetype` (`rts/lib/CMakeLists.txt:196`), fixed by installing:
- Missing apt packages: `libfreetype-dev libfontconfig-dev libopenal-dev libvorbis-dev libogg-dev libexpat1-dev libpng-dev p7zip-full`. `7z` is needed by `cont/base` to pack base content. Installed 2026-11-12 via `wsl -u root` (no password needed).
- The baseline builds from a separate git worktree, `~/RecoilEngine-native`, detached at the unmodified tag `2026.07.04`. Script: `~/native-build.sh` (`-j6`, ccache, legacy on, dedicated off, `AI_TYPES=NONE`). Logs: `~/configure-native.log`, `~/build-native.log`.

**M1 (emcmake configure): done.** Branch `wasm-port` in `~/RecoilEngine` (commit `c07c8dc`), plus branch `wasm-port` in submodule `rts/lib/streflop` (`2da0617`). Local only. Configure script: `~/wasm-configure.sh` (log in `~/configure-wasm.log`). Build script: `~/wasm-build.sh [target]` (log `~/build-wasm-<target>.log`), error summary: `~/err-summary.sh`.

> Tooling gotcha: `wsl.exe` expands `$VAR` in its own command line before bash sees it. Put anything with shell variables in a script file and run that.

Blockers hit, in order, and the fix used:
| # | Error | Fix |
|---|---|---|
| 1 | `CMakeLists.txt:106` "requires a 64-bit build environment" | New `IS_WASM_BUILD` under `EMSCRIPTEN`; **wasm32 chosen** (not memory64). Pointer-size assumptions are limited to arch `#define`s (`MainDefines.h`, `Threading.cpp`, `Misc.cpp`) and mem-pool sizing (`*MemPool.h`). These are M2 compile issues, not sync issues. |
| 2 | Arch detection | **Emscripten reports `CMAKE_SYSTEM_PROCESSOR=x86`**, so every `EMSCRIPTEN` check must come before x86 matching (streflop would otherwise silently pick SSE mode). |
| 3 | Compiler flags | WASM branch: `-msimd128 -msse -msse2 -ffp-contract=off`. Configure also shows `-frounding-math -pthread` already on. |
| 4 | streflop autodetect | `STREFLOP_WASM` option, autodetected, compile def `STREFLOP_WASM`, no ldbl-96 sources. **Headers not done yet** (`streflop.h`, `FPUSettings.h`, `SMath.cpp`, `System.h`, `rts/System/Sync/FPUCheck.cpp`). That's M2 work: WASM has fixed round-to-nearest, no FP status/control register, denormals preserved, so `streflop_init` and fe* are no-ops. |
| 5 | `Could NOT find DevIL` | DevIL is only used by `Rendering/Textures/Bitmap.cpp`. On WASM: use DevIL if found on `CMAKE_PREFIX_PATH` (`~/wasm-deps`), else a placeholder target plus `WASM_NO_DEVIL`. DevIL v1.8.0 source is cloned at `~/wasm-deps/src/DevIL`. Building it was **blocked by Claude Code's auto-mode safety check** (it won't build downloaded external code without an explicit permission rule). The user can build it with the approach below, or add a Bash permission rule. |
| 6 | `Could NOT find CURL` (pr-downloader) | Placeholder `prd::libcurl` defined before `add_subdirectory(pr-downloader)` (submodule untouched). The engine only needs `prd::base64` and `prd::jsoncpp`. Headless no longer links `pr-downloader` on WASM, so `Lua/LuaVFSDownload.cpp` needs a stub in M2. |
| 7 | `Could NOT find SevenZip` | Host tool, needed natively too: `p7zip-full` (installed). With the real `/bin/7z`, the WASM configure succeeds without overrides. |
| 8 | `Could NOT find OggVorbis` | `-DNO_SOUND=ON` (headless always uses `no-sound`). Phase 2: Emscripten OpenAL + vorbis port. |
| 9 | `get_target_property() called with non-existent target "Game"` | Upstream coupling: headless clones the `Game` target defined in `builds/legacy`. When legacy is off, `GameHeadless` is now built directly from `${sources_engine_Game}`. |
| 10 | `REALTIME_LIBRARY` NOTFOUND (tests) | Skip `find_library(rt)` on WASM. |
| — | libunwind, mimalloc, system OpenGL | Skipped on WASM (`USE_MIMALLOC=OFF`; headless `find_package(OpenGL)` guarded). Tracy is already `TRACY_ENABLE=OFF`. |

Other findings:
- `tools/sync-test/reference/streflop_results_{SSE_x86_64,NEON_arm64}.txt` are reference outputs of streflop math. Generating the same file under WASM and diffing it against the SSE one is a cheap float-determinism check to run before M3/M4.
- `tools/CMakeLists.txt` clears `CMAKE_CXX_FLAGS` before pr-downloader, so `prd::jsoncpp`/`prd::base64` compile **without `-pthread`**. Expect a wasm-ld "shared-memory/atomics" mismatch at link time (M2): re-add `-pthread` for WASM there.
- `test/CMakeLists.txt` pings `::1` at configure time to decide on the UDP test (harmless).

**DevIL for WASM (manual step).** Run in Ubuntu:
```
source ~/emsdk/emsdk_env.sh
emcmake cmake -S ~/wasm-deps/src/DevIL/DevIL -B ~/wasm-deps/build-devil -G Ninja -Wno-dev \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-pthread -O3" -DCMAKE_CXX_FLAGS="-pthread -O3" \
  -DIL_NO_TIF=1 -DIL_NO_EXR=1 -DIL_NO_JP2=1 -DIL_NO_MNG=1 -DIL_NO_LCMS=1 -DIL_USE_DXTC_NVIDIA=0 -DIL_USE_DXTC_SQUISH=0
ninja -C ~/wasm-deps/build-devil IL ILU
```
Then copy `libIL.a` and `libILU.a` to `~/wasm-deps/lib`, and `include/IL/*.h` plus the generated `config.h` to `~/wasm-deps/include/IL`. `-pthread` is required because wasm-ld rejects mixing objects with and without atomics.

### 2026-11-14: M2 done, `engine-headless.wasm` links and runs under Node

**Result:** `~/build-wasm/spring-headless.wasm` (14.3 MB, Release, `ASSERTIONS=1`) + `spring-headless.js` (170 KB). Under Node 24, `node spring-headless.js --version` prints `2026.07.04-2-g271425e wasm-port (Headless)`, and `--sync-version` works and exits cleanly. Commits on the local `wasm-port` branch: `271425e` (streflop headers + sync-test), `9fbe6b5` (M2). streflop submodule: `8d61aad`, `047da3b`.

**Float determinism (early M3/M4 signal).** `tools/sync-test` now builds with emcmake (`STREFLOP_MODE=WASM`). The WASM run is **bit-exact against both reference files**: 52,080/52,080 vs `NEON_arm64` (65 NaN-both) and 47,852/47,852 vs `SSE_x86_64` (that reference predates ~4k newer tests). A native SSE run of the current test also matches the SSE reference. Script: `~/sync-test.sh`.

**What it took (in order hit):**
| Area | Problem | Fix |
|---|---|---|
| streflop | no WASM mode | `STREFLOP_WASM` in `streflop.h`, `FPUSettings.h` (fe* no-ops, `fesetround` fails for non-nearest), `SMath.cpp`. **`streflop_cond.h` must list `STREFLOP_WASM`**, or the engine silently uses system libm (desync risk). |
| streflop | Emscripten `compat/math.h` `#define isinff isinf` / `isnanf isnan` → redefinition errors | `#undef` both in `SMath.h` |
| `MainDefines.h` | `#error unknown CPU-architecture`; `_X11` defined | `__wasm__` counts as non-x86; no `_X11` on Emscripten |
| `simd_compat.h` | `x86intrin.h`/`immintrin.h` pull in x86-only headers (ia32/fma4/ammintrin) | Emscripten: only `xmmintrin.h` + `emmintrin.h` |
| `MemPoolTypes.h` (196 TUs) | musl `limits.h` `#define PAGE_SIZE` clobbers `PAGE_SIZE()` members | `#undef PAGE_SIZE` |
| luasocket | musl `netinet/tcp.h` `#define TCP_LISTEN 10` | `#undef` in `restrictions.h` |
| smmalloc, assimp | libc++ has fewer transitive includes than libstdc++ | add `<type_traits>`/`<cstdlib>` (`smmalloc.h`), `<cmath>` (`AssIO.h`) |
| Platform | `Linux/{CrashHandler,CpuTopology,Futex,ThreadSupport}.cpp` need signals/ucontext/`execinfo`, futex(2), `/proc`, `/sys`, `cpuid` | New `rts/System/Platform/Emscripten/*` used by an `EMSCRIPTEN` branch in `rts/System/CMakeLists.txt`. Futex → `emscripten_futex_wait/wake`; topology = N logical cores (`emscripten_num_logical_cores`), never pin; thread Suspend/Resume → `THREADERR_MISC` (watchdog can't capture other threads' stacks); crash handler logs `emscripten_get_callstack`. |
| `Threading.cpp`, `Misc.cpp` | `#error "Unsupported architecture"`, `prctl`, exe path `#error implement this`, `getifaddrs`/`AF_PACKET` | wasm branches; `emscripten_set_thread_name`; **exe path is fixed at `/recoil/spring-headless`** (engine base content is looked up next to it); MAC = zeros |
| `ThreadAffinityGuard.cpp` | `SYS_gettid` | tid 0 on Emscripten |
| link | `sched_getaffinity/setaffinity` declared but not implemented in musl | defined in `Emscripten/CpuTopology.cpp` (all cores, set = no-op) |
| link | `wordexp`/`wordfree` missing | `DataDirLocater::SubstEnvVars` expands `~`, `$VAR`, `${VAR}` itself on Emscripten |
| `Bitmap.cpp` | DevIL | stub `rts/lib/wasm-stubs/devil/IL/il.h` (every load/save fails) when DevIL isn't found |
| `LuaVFSDownload` | pr-downloader not linked | `rts/lib/wasm-stubs/prdownloader/prd_stub.cpp`: search finds 0 results → download fails with code 2 |
| link | `--shared-memory is disallowed by json_value.cpp.o / plutovg-surface.c.o` | `-pthread` in `CMAKE_C_FLAGS` and in `tools/CMakeLists.txt` (which resets flags) |
| exceptions | Emscripten aborts on `throw` by default; the engine uses exceptions | `-fwasm-exceptions` everywhere (Node 24 supports it) |
| link | `undefined symbol: emscripten_longjmp` (freetype port, plutovg) | `-sSUPPORT_LONGJMP=wasm` everywhere. **Freetype via `-sUSE_FREETYPE=1`** (`rts/lib/CMakeLists.txt`) so emcc picks the `wasmsjlj` variant; FindFreetype's fixed `libfreetype.a` is the JS-sjlj one. |
| link | `initial memory too small` | headless link options (below) |

**Link options (phase 1, Node):** `-sENVIRONMENT=node,worker -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=256MB -sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=8MB -sDEFAULT_PTHREAD_STACK_SIZE=4MB -sPTHREAD_POOL_SIZE=8 -sEXIT_RUNTIME=1 -sASSERTIONS=1`, in `rts/builds/headless/CMakeLists.txt`.

**Native regression check:** the `wasm-port` branch also builds natively with gcc-13 (`~/native-build-wasmport.sh`, build dir `~/build-native-wasmport`): no errors, and `spring-headless --sync-version` runs.

**Not an issue after all:** `CpuID.cpp` already no-ops on non-x86; `backtrace.c` is Windows-only; the mem pools fall back to the dynamic pools ARM64 already uses.

**Open items / risks for M3–M4**
- **Engine version string.** WASM reports `2026.07.04-2-g271425e wasm-port`, native reports `2026.07.04`. Replay playback is *not* blocked: `DemoReader.cpp:47` accepts any replay on non-release builds. But BAR Lua can read `Engine.version*`; if any synced gadget branches on it, an exact `2026.07.04` will be needed (version override in `rts/build/cmake/UtilVersion.cmake`).
- **Environment variables.** Under Node, Emscripten doesn't import `process.env` by default, so `SPRING_DATADIR` etc. need a `--pre-js` that copies them into `ENV`.
- **DevIL** is still a stub. Fine for `--version`; needs checking for anything the sim reads as an image before M4.
- `-frounding-math` produces a harmless "unsupported rounding mode" warning on wasm (WASM is always round-to-nearest).
- The browser main thread can't use `Atomics.wait`, so Emscripten busy-waits there. Irrelevant under Node; matters in phase 2.

### 2026-11-14: M3 done, unit tests pass under Node

**Result:** `ninja tests` + `ctest` in `~/build-wasm`: **28/28 pass** under Node 24 (ctest runs `test_*.js` through `CMAKE_CROSSCOMPILING_EMULATOR` = emsdk node). The same branch built natively (`~/build-native-wasmport`, gcc-13) passes **29/29** (it also has UDPListener). Logs: `~/ctest-wasm.log`, `~/ctest-native.log`.

**What it took:**
| Area | Problem | Fix |
|---|---|---|
| link options | tests need the same Node flags as the engine | `RECOIL_WASM_NODE_LINK_OPTIONS` in the top-level `CMakeLists.txt`, used by `engine-headless` and `add_spring_test` |
| env vars | Emscripten doesn't import `process.env` | `rts/lib/wasm-stubs/node-env-pre.js` (`--pre-js`, copies `process.env` into `ENV` in `preRun`). Verified by UnitSync, which only finds base content via `SPRING_DATADIR` |
| `Threading.cpp` | `std::ranges::find_if` without `<algorithm>` (libc++) | include it |
| unitsync | Linux `CpuTopology`/`ThreadSupport` added on top of the Emscripten ones; `SHARED` lib → PIC side module | Emscripten branch adds only `Linux/Hardware.cpp`; `STATIC` on WASM |
| `test_ThreadPool` | `-latomic` for Clang | not on Emscripten |
| `test_Mutex` | raw `SYS_futex` syscalls | `emscripten_futex_wait/wake` |
| `test_UDPListener` | Emscripten sockets are WebSocket-backed (needs `ws` npm module) | skipped on WASM; local games/replays never open the UDP listener |
| `testCreg` | ran `spring-headless.js` directly (no emulator) | WASM: `COMMAND engine-headless` (target name → node) |
| `testUnitSync` | `base/springcontent.sdz` not found (**native too**) | `SPRING_DATADIR=${CMAKE_BINARY_DIR}` test env, all platforms |
| `testClampRad` | direct `float→short` cast of ~65535.99 is UB; wasm gives a different result than x86 | test now goes through `int`, exactly like the engine's `RadAngleToCobShort` (`CobInstance.cpp`, which upstream already fixed after an arm64 desync) |
| `testCreg` | `CSolidObject::paletteIndex` and `objectUsable` not registered with creg (**fails natively at the tag too**; on 64-bit `objectUsable` hides in alignment padding) | `CR_MEMBER` both (savegame-only; no effect on sim or sync checksums) |

**Caveats**
- The `testBitwiseEnum_fail{1,2,3}` compile-fail tests pass vacuously on every platform: `spring_test_compile_fail` is given a source *list*, so the compile command is malformed (`-o` with multiple files) and fails before testing anything. They also use the host `c++`, not `em++`. Upstream bug; left alone.
- **M4 sync risk worth remembering:** any synced `float→short`/`float→intN` cast of an out-of-range value is UB and differs between x86 and wasm. The ClampRad case shows the pattern; a desync in M4 should check for this first.
- `.github/workflows/synctest.yml` runs BAR's `/luarules synctest` and compares sync hashes across platforms. That could be a cheaper sync oracle than a full replay for M4.

**Next (M4):** replay playback under Node with BAR content mounted via NODERAWFS (`SPRING_DATADIR` now works), comparing sync checksums against native.

### 2026-11-14: M4 done, a native replay plays to the end under Node with no desync

**Result:** a 15-minute BARb vs BARb replay (All That Glitters v2.2, game `test-31943-6cd6caa`, 27,000 frames), recorded by the installed **Windows** `recoil_2026.07.04` spring-headless.exe, plays back under Node 24 with `~/build-wasm/spring-headless.js`. **All 450 echoed sync checksums match (0 mismatched)**, the replay reaches end of demo, and the process exits 0. A native Linux playback of the same branch gives the same 450/450. Engine commit `4410497` on `wasm-port`. Harness, replay and logs: `C:\Beyond All Reason Web\m4-harness\` (see its README).

**The oracle.** With `SYNCCHECK` on, the server echoes every player's sync response into the demo every 60 frames (`GameServer.cpp`, `syncResponseEchoInterval`). On playback the client compares each one with its own checksum for that frame and logs `[DESYNC WARNING]` on a mismatch (`NetCommands.cpp`). Because silence proves nothing, the branch now counts the checks: `[DemoSync] frame N: … matched, … mismatched` every minute, and a `summary` line at game exit.

**Why a new replay.** Every replay in `data/demos` was recorded with engine 2025.01–2025.04 and game versions that are no longer installed (only `test-31943` is in the rapid pool). The new one was recorded headlessly: `script.txt` with two BARb AIs and a spectator host, plus an unsynced widget in a separate write dir that sets speed 20x and `quitforce`s at frame 27000. The demo is written only on clean shutdown, and the header's game time stays 0 because the game never reached GameOver.

| | native (gcc-13, Linux) | WASM (Node 24) |
|---|---|---|
| load to "Beginning demo playback" | 1:35 | 3:43 (5–7 min on earlier runs) |
| 27,000 sim frames at max speed | ~99 s | ~151 s (~1.5x native) |
| peak RSS | 3.8 GB | 3.0 GB |
| checksums | 450/450 | 450/450 |

**What it took (in order hit):**
| Area | Problem | Fix |
|---|---|---|
| main loop | Hang after `InitLocalClient` at 100% CPU. `LoadDemoFile` runs on a `std::async` "pregame" thread. Emscripten proxies every pthread's stdio and NODERAWFS file calls to the main thread, which only services that queue while blocked in a wait, and `SpringApp::Run` busy-loops. (A bigger pthread pool did not help.) | `emscripten_main_thread_process_queued_calls()` once per main-loop iteration |
| networking | Demo playback opens the UDP listener (`onlyLocal` is false); Emscripten can't resolve `localhost` → fatal `network_error` | `CGameSetup::Init`: `onlyLocal = true` on Emscripten |
| images | `Unable to load default cursor`: the always-fail DevIL stub broke a mandatory load | `wasm-stubs/devil/IL/il.h` now decodes via the `stb_image.h` vendored with Tracy (PNG/JPG/BMP/TGA/GIF/PSD, 8/16-bit, format and type conversion, origin flip). Saving still fails (screenshots only). DDS is never decoded in headless. |
| Lua VFS | BAR `barwidgets.lua:1506` "table index is nil" for user widgets: `VFS.CalculateHash` returned nil because the prd stub's `CalcHash` returned null | Real `CalcHash` (base64 MD5) in the stub, using pr-downloader's own `pr-md5` + `prd::base64` |
| threads | ~16 threads by game start, over the pool of 8 | `RECOIL_WASM_PTHREAD_POOL_SIZE` default 32. Extra workers spawned on demand did start under Node, but in browsers they need the main thread to yield. |

**Caveats / open items for phase 2**
- One replay, one map, AI vs AI, 15 minutes. Real multiplayer replays (more players, longer games, raptors/scavengers, other maps) would widen coverage. They need replays recorded on 2026.07.04 with an installed game version: play a few online games with the current client, then rerun `play.sh wasm` on them.
- On a fatal error during loading (seen with the old DevIL stub), the shutdown path ends in `RuntimeError: null function or function signature mismatch` after the error is logged. This is cosmetic for M4, but there is an indirect-call signature mismatch somewhere in `SpringApp::Kill` / `KillLua` that needs tracking down.
- WASM load time (3.5–7 min vs 1.5 native) is dominated by archive scanning/hashing over `/mnt/c` (9p) plus single-threaded proxied file I/O. Startup in the browser will need a pre-built archive cache and content in OPFS.
- All file I/O from worker threads is proxied through the main thread, which is fine under Node but must not block a browser main thread. Phase 2 should run the engine's main loop in a worker (`-sPROXY_TO_PTHREAD`).
- `Spring.GetReplayLength()` reads the header game time, which is 0 for `quitforce`d recordings. The playback widget instead detects end of demo when that call starts returning nil (the server drops its demo reader).

## Repositories
- Engine: public fork https://github.com/SgtMetz/RecoilEngine, branch `wasm-port` (6 commits ahead of tag `2026.07.04`).
- streflop: public fork https://github.com/SgtMetz/streflop, branch `wasm-port`. `.gitmodules` on the engine branch points here (`branch = wasm-port`).
- Local clone `~/RecoilEngine`: `origin` = upstream (fetch only, never push), `fork` = SgtMetz. Push with `~/push-fork.sh` (streflop first, so the submodule commit exists before the engine commit that references it).
- Later, when M3/M4 produce harness code (Node replay runner, browser front end), put it in a separate, clearly unofficial repo rather than in the engine fork.

## Upstream note
Recoil's `AI_POLICY.md` forbids AI-written PRs unless they reference an accepted issue, are disclosed, and are human-tested on the target platform. Keep this work as a fork. Upstreaming would need a maintainer-accepted issue first.
