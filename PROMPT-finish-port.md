# Prompt: finish the Beyond All Reason browser port

Paste everything below the line into a new Claude Code session opened in `C:\Beyond All Reason Web`.

---

Finish porting Beyond All Reason (Recoil engine, WASM/Emscripten) to the browser. Work autonomously through the milestones below in order. Each must be verified before you start the next. Don't stop to ask unless a step needs my credentials, a purchase, a public deploy, or a download from outside the sources already used (emsdk, glslang, SPIRV-Cross, BAR content). In those cases, finish everything else first and ask once at the end.

## Read first (don't re-derive)
- `BAR-web-phase1-scoping.md` and `BAR-web-phase2.md`. These are the full history: build quirks, harness, what each fix was and why. Read the "Milestones" section and the latest 2026-11-16 entries closely.
- Your memory files (they include the push rule).
- Engine: `~/RecoilEngine` (WSL Ubuntu-24.04), branch `wasm-port`, HEAD `7c4182b`. The WebGL2 shim is in `rts/Rendering/GL/WebGL/`. Harness: `web-harness/` (server on `localhost:8080`, `render.html`, OPFS write dir, `?testwidget=`, `?capture=`, `?glcheck=1`, `?trace=1`, `?dumpshaders=`).
- Scripts in `scratchpad/`: `validate.ps1`, `ssbo5-runs.ps1` (the four-replay check), `restart-validate.ps1`, `cdp-eval.ps1`, `dump-shaders.ps1`, `repro-fresh.ps1` (isolated WebGL link test, fresh Chrome per shader).

## Hard rules
- **Oracle:** every engine change must keep `m4-atg-barb-15min.sdfz` at 450/450 checksums. Check it in the browser (all four `ssbo5-runs.ps1` replays, with 0 context losses and no growth in GL error lines beyond the current 60), under Node (`~/m4/play.sh wasm ~/m4/m4-atg-barb-15min.sdfz`), natively (`~/m4/play.sh native …`), and with `ctest` 28/28 in `~/build-wasm`. Rebuild engine-web, engine-headless and engine-headless-web and the native build whenever shared files change.
- **Builds:** `~/wasm-build.sh <target>` and `~/native-build-wasmport.sh`. New source files need `cmake .` in `~/build-wasm` with emsdk sourced. `wsl.exe` expands `$VAR`, so put multi-step shell in script files under `scratchpad/`. In PowerShell, don't name a helper function `R` (it's an alias).
- **GPU safety:** a shader that crashes ANGLE loses the WebGL context, and Chrome then blocks WebGL for the origin until it restarts (`restart-validate.ps1`). Test risky shaders with `repro-fresh.ps1` first. Read `chrome_debug.log` (`--enable-logging`) for the GPU process exit code.
- **Git:** commit in `~/RecoilEngine` as the identity from `git log -1`, set through GIT_AUTHOR_/GIT_COMMITTER_ env vars. Messages disclose Claude Code assistance and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Push only with `bash ~/push-fork.sh` (the SgtMetz fork). Never push to origin/upstream and never open upstream PRs. Commit and push after each milestone.
- Don't modify BAR game content. Engine-side workarounds only, documented with their trigger.
- Keep credentials and personal details out of code, commits and docs.
- After each milestone, append a dated section to `BAR-web-phase2.md` in the existing style: what changed and why, a validation table with log/capture file names, remaining limitations, and what was shipped. Update the Milestones list too. Be explicit about what a capture or test verifies and what is only inferred.

## Milestones

**B2 — finish the renderer.** Close out what's left, or document why it can't be done in WebGL2:
1. CUS GL4 and the 13 "Missing capabilities" widgets (distortion, deferred rendering, defense/attack range, DrawUnitShape, ground AO plates, map blockout…). Find what each capability check needs. Then emulate it: indirect/multi-draw → loops of base draws; `ARB_draw_elements_base_vertex` → offset rebasing; writable SSBOs or compute → transform feedback or render-to-texture where feasible. For each, either make it pass or report it truthfully as unsupported.
2. BuildSquare GL4 `uboParamDefs` nil: find which engine query or capability returns nil under the shim.
3. Radar preview sheet: look for an engine-side, semantics-preserving rewrite that avoids FXC's stack overflow (the bisect is in the notes: complementary uniform tests across inlined calls). If one works on `repro-fresh.ps1`, drop the refusal for that shader.
4. Verify the GL4 widgets visually: health bars on damaged units, airjets, grass and range circles. Use a testwidget that moves the camera to the right place and frame, plus pixel checks where possible.
5. Run BAR's medium and high graphics presets and fix what breaks (shadows, DOF, clouds, water).
6. Measure frame time with the pane visible and note any gross hotspots.

**B3 — audio.** Emscripten OpenAL plus an Ogg/Vorbis port (see phase 1 scoping, row 8). Build the sound path for engine-web only and keep headless at `no-sound`. Verify that unit and UI sounds and music play in the tab: log OpenAL source starts and capture the WebAudio graph/output levels in headless Chrome. Mind the browser autoplay gesture requirement.

**B4 — live play.** A local skirmish, player vs BAR's AI, started from the page (map and AI chosen by URL params or a minimal page form). Mouse and keyboard input, camera control, selection, build menus and orders must work, with pointer lock where the engine needs it. Verify with a scripted CDP input session: start a game, select the commander, build something and check that the unit appears, and issue a move order. Also run a 10-minute AI-vs-AI skirmish with no crash and keep the page responsive. Check that BAR's chobby/lobby isn't required; document the minimal start path.

**B5 — browser delivery.** A self-contained deployable build: a static site with streamed or cached content (BAR archives, maps, base content, fonts including `cont/fonts`), cache headers, the COOP/COEP needed for threads/SharedArrayBuffer, a loading screen with progress, and a clean first-run in a fresh profile. Package it under `web-harness/dist/` with a script that rebuilds it. Test it locally from a plain static server in a fresh Chrome profile. **Don't deploy it anywhere public.** At the end, ask me whether to and where (Cloudflare: use the `cf` CLI unless a Wrangler config exists).

**B6 — multiplayer (stretch).** Assess what network play needs: the engine's UDP protocol, which would need WebSocket/WebRTC transport plus a relay to reach a native autohost/spring server. Implement it only if it fits; otherwise write the design and the gap list in the notes.

## Definition of done
B2–B5 are done and verified as above, or each unfinished item has a documented reason it can't be done in a browser. All oracle checks pass on the final commit, it's pushed to the fork, the notes and Milestones are current, and the final summary lists exactly what works, what was verified (and how), and what remains.
