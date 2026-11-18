# Beyond All Reason on the web

An unofficial port of the [Recoil engine](https://github.com/beyond-all-reason/RecoilEngine) running [Beyond All Reason](https://www.beyondallreason.info/) in the browser: the engine compiled to WebAssembly with Emscripten, rendering through WebGL2 on an OffscreenCanvas, with game content streamed into OPFS.

**Engine changes:** [SgtMetz/RecoilEngine, branch `wasm-port`](https://github.com/SgtMetz/RecoilEngine/tree/wasm-port). This repo holds everything around it: the browser harness, test tooling and the engineering log.

## Status
- **Headless sim in the browser (B1):** a 15-minute BAR replay plays to the end in a Chromium tab with all 450/450 sync checksums matching the native build.
- **Renderer (B2), in progress:** sky, textured terrain, features, units, build stages, BAR's LuaUI, reflections and post-processing render through a desktop-GL → WebGL2 shim. Desktop GLSL is cross-compiled with glslang → SPIR-V → SPIRV-Cross to ESSL 3.00.
- **Audio, live play, static delivery build (B3–B5):** built and partly tested.

The full write-up, with what broke and how it was fixed, is in [BAR-web-phase1-scoping.md](BAR-web-phase1-scoping.md) and [BAR-web-phase2.md](BAR-web-phase2.md).

## Contents
| Path | What it is |
|---|---|
| [`web-harness/`](web-harness/) | Browser pages (headless and renderer), OPFS content loader, content packer, dev server and static-site build. See its [README](web-harness/README.md). |
| [`m4-harness/`](m4-harness/) | Native vs. WASM replay comparison used for the Node milestone. |
| [`bar-web-setup-toolchain.sh`](bar-web-setup-toolchain.sh) | WSL toolchain setup (Emscripten, build deps). |
| `BAR-web-*.md`, `handoff-*.md`, `prompts/` | Engineering log, scoping and hand-off notes. |

## Not included
No game files. BAR content, maps and the test replay come from your own BAR install; `web-harness/pack-content.py` stages and bundles them locally.

Beyond All Reason and Recoil are the work of their respective teams; this project is not affiliated with them.
