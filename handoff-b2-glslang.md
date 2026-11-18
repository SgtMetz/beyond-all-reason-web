You are continuing BAR→Web phase 2, milestone B2: the Recoil engine renderer in the browser (WASM + WebGL2). The previous session wired glslang + SPIRV-Cross into the shader translator. That works, but it breaks demo sync, and you are picking up the investigation of that desync.

## Hard rules (unchanged)
- Push only to the fork. When a milestone is finished, run `~/push-fork.sh` in WSL (streflop first, then the engine; `fork` remotes = SgtMetz). Never push to `origin` (upstream) and never open upstream PRs (Recoil's AI_POLICY.md).
- Don't regress the Node/headless paths. The checksum runs are the oracle.
- No credentials or personal details in code, commits or docs.
- Be honest in the log about what a captured frame verifies versus what is only inferred from the log.
- Commits end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The repo has no stored git identity, so commit with `GIT_AUTHOR_NAME/EMAIL` and `GIT_COMMITTER_NAME/EMAIL` set to the same identity as the earlier commits (`git log -1 --format='%an <%ae>'`).

## Environment
- Run WSL commands as: `MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -- bash -c '...'`. Shell variables and `$(...)` often get mangled on the way through, so put anything non-trivial in a script file (write it with the Write tool to the session scratchpad, then `bash /mnt/c/...`).
- Edit engine files at `\\wsl.localhost\Ubuntu-24.04\home\evmet\RecoilEngine\...`.
- Build with `~/wasm-build.sh engine-web` (about 1 minute incremental). New source files or CMake changes need `cmake .` in `~/build-wasm` first, with the emsdk env sourced.
- Harness: `C:\Beyond All Reason Web\web-harness` (not a git repo). Preview server "web-harness" on :8080.
- Browser procedure:
  1. Open `/render.html?autostart=0`.
  2. **Wait for "content ready"** before navigating anywhere else. Navigating while the loader worker was still writing once wiped all OPFS content, and the engine then died on a missing font.
  3. Navigate to the real run.
- The engine log is in OPFS at `write/infolog.txt`. Grab frames with `await harness.grab(name)`, which saves to `web-harness/logs/<name>`.
- `serve.py` only accepts POST `/log/*.txt|.png`.
- `javascript_tool` times out at 45 s, so keep wait loops at 42 s or less and repeat them. The game reaches frame 0 about 2:05 after starting.

## State
- `~/RecoilEngine` is on branch `wasm-port`. HEAD is 09df5b2, already pushed to the fork.
- **Uncommitted engine changes:**
  - `rts/builds/web/CMakeLists.txt`:
    - Optional `find_package(glslang / spirv_cross_core / spirv_cross_glsl CONFIG NO_CMAKE_FIND_ROOT_PATH)`; when found, it sets `RECOIL_WEB_GLSLANG` and links the libraries (installed in `~/wasm-deps`).
    - `--emit-symbol-map` was just added to the engine-web link options (writes `spring-web.js.symbols`).
  - `rts/Rendering/GL/WebGL/WebGLShaderTranslate.{h,cpp}`:
    - `TranslateShader(..., bool forGlslang)` emits desktop `#version >=330 core` with no precision lines. It raises the version to 420 for `binding` or line continuations.
    - In glslang mode it runs `PreprocessGlsl` first, so the text rewrites only see the active `#if` branches. That fixed InfoLOS.
    - New `StripComments`.
    - `FlattenInterfaceBlocks` was rewritten to keep newlines and preprocessor lines and to drop comments. This also fixes the text path.
    - Declares `CrossCompiled`, `CrossCompile`, `CrossCompileAvailable`, `GetCrossCompileStats`, `PreprocessGlsl`.
  - **New** `rts/Rendering/GL/WebGL/WebGLSpirv.cpp`. glslang compiles with OpenGL SPIR-V rules and automapped locations/bindings. It records explicit sampler/UBO bindings and explicit vertex-input locations through reflection before `mapIO`. SPIRV-Cross then emits ES 300 with the non-explicit Location/Binding decorations removed. There is a stub when glslang isn't available.
  - `rts/Rendering/GL/WebGL/WebGLState.cpp`:
    - `SetTranslatedSource` tries the cross-compile first and falls back to the text translation. It logs the first 12 failures.
    - With `RECOIL_WEB_TRACE`, every failure's glslang input goes to `<cwd>/xc-fail-N.glsl`.
    - Diagnostics: `RECOIL_WEB_GLSLANG=0` (text only), `=2` (compile, then discard the result), and `RECOIL_WEB_GLSLANG_LIMIT=N` (use glslang output for the first N shaders only; it logs where the limit was reached).
    - Explicit sampler/UBO bindings are applied after link with `glUniform1i` / `glUniformBlockBinding`.
  - `WebGLCompat.cpp` logs the cross-compile ok/fallback counts in `LogStubStats`.
  - The `SyncChecker.cpp` diagnostic edit was **not** applied.
  - The last build (cmake reconfigure plus build) was interrupted mid-run. Check that no ninja or emcc process is still running, then rebuild.
- **Harness, uncommitted by nature:** `www/render.js` gained `?glslang=N` (→ `RECOIL_WEB_GLSLANG`) and `?glslanglimit=N` (→ `RECOIL_WEB_GLSLANG_LIMIT`). The README doesn't mention either yet.
- Native translator test: `scratchpad/xltest.cpp` + `xltest.sh` compile `WebGLShaderTranslate.cpp` with g++. They now need a `PreprocessGlsl` stub to link.

## Results so far
These numbers come from the log, not from captured frames.

**Shader compilation**
- Lua shaders that fail to compile: text only, 37; glslang, 16. All 16 remaining are SSBO users (`std430`, or the engine's `layout(std140, binding=1) readonly buffer UniformsBuffer`/`MatrixBuffer`/`TransformBuffer` include). WebGL2 has no SSBOs.
- Of about 190 shaders, 175–179 cross-compile and 15 fall back, all of them SSBO shaders.

**Rendering**
- The terrain is still flat grey in both modes (frames `logs/frame-glsl-base.png` and `logs/frame-glsl-1.png`), so it isn't a shader-compile problem.
- GL4 widgets also need LuaVAO. `LuaVAOs::GetVAO` refuses to run because `GL_ARB_draw_elements_base_vertex` and `GL_ARB_multi_draw_indirect` are reported as 0.

**DESYNC (the blocker)**
- With glslang, `[DemoSync] frame 0` mismatches and every later checksum mismatches too.
- With `?glslang=0`: in sync through frame 777. With `?glslang=2`: in sync.
- Bisect on `glslanglimit`: 15, 58, 79 and 90 match; 91 and 100 mismatch; unlimited mismatches; unlimited with `UseLuaMemPools=1` also mismatches.
- Shaders 90 and 91 are the `Raptor Scum GL4` gadget's (`luarules/gadgets/gfx_raptor_scum_gl4.lua`). Its synced half is the same in both modes. Only its unsynced half (it draws, calls `Spring.GetGroundHeight`/`GetGameFrame` and `math.random`) runs when the shader compiles.
- Ruled out:
  - Lua messages: `GameServer` drops `NETMSG_LUAMSG` when `demoReader` is set.
  - BAR's `RemoveGadget`: it is local and sends nothing to synced.
  - Lua memory pools.
  - libc `rand()`: unsynced Lua `math.random` uses it, but no sim code does.
- A helper reads files from the game package: `python3 scratchpad/sdpcat.py ~/web-content/stage/data 44fd01f1d430f1c94f27b75b242738df.sdp '<path regex>' '[grep regex]'`.

## Next steps
1. **Find the unsynced write that feeds the SYNCCHECK checksum.** `CSyncChecker::Sync` (`rts/System/Sync/SyncChecker.cpp`) is fed by `SyncedPrimitive` writes, whose `assert(InSyncedCode())` is compiled out.
   - Add a TEMPORARY diagnostic under `__EMSCRIPTEN__`: when `!InSyncedCode()`, log `emscripten_get_callstack(EM_LOG_C_STACK, ...)` to stderr for the first ~6 hits.
   - Rebuild, run `?glslanglimit=91`, and map the `wasm-function[N]` frames through `~/build-wasm/spring-web.js.symbols`.
   - There may be legitimate out-of-synced writes during loading; focus on hits from scum's unsynced paths (`GetGroundHeight`, the heightmap texture, `DrawWorldPreUnit`).
   - Fix the root cause in the engine if it is an engine bug. Otherwise document it, for example if it is a checksum false positive or a BAR gadget issue. Remove the diagnostic before committing.
2. **Decide the default.** Until sync holds with glslang on, either make cross-compilation opt-in (`RECOIL_WEB_GLSLANG=1`, plus a harness param) so the render build stays in sync by default, or ask the user.
3. **Regression checks:**
   - Builds: `engine-headless`, `engine-headless-web`, `engine-web` (the glslang changes only touch engine-web).
   - `ctest` in `~/build-wasm`: 28/28.
   - `bash ~/m4/play.sh wasm ~/m4/m4-atg-barb-15min.sdfz`: 450/450.
   - Headless browser page `/`: 450/450.
   - `bash ~/native-build-wasmport.sh` must build.
   - Also run a render-page sync check (frame 0 and a few minutes in).
4. **Docs:**
   - `C:\Beyond All Reason Web\BAR-web-phase2.md`: add a B2-continued entry covering glslang/SPIRV-Cross (versions 16.6.0 / vulkan-sdk-1.4.363.0), the numbers above, the desync bisect and root cause, SSBO/LuaVAO as next work, and the OPFS navigation hazard.
   - `web-harness/README.md`: add `?glslang`, `?glslanglimit`, the `xc-fail-*.glsl` dumps under `?trace=1`, and the "wait for content ready before navigating" note.
5. **Ship:** make focused commits on `wasm-port`:
   - (a) the `FlattenInterfaceBlocks` fix plus `StripComments`;
   - (b) glslang/SPIRV-Cross cross-compilation plus CMake;
   - (c) any sync fix.

   Then run `~/push-fork.sh`.
