# M4 replay harness (unofficial, not part of the engine fork)

Files used to prove M4: a native BAR replay plays back under Node (WASM) with no desync.

| File | What it is |
|---|---|
| `m4-atg-barb-15min.sdfz` | The test replay: BARb (Armada) vs BARb (Cortex), All That Glitters v2.2, game `test-31943-6cd6caa`, 27,000 frames (15 min). Recorded 2026-11-14 by the installed Windows `recoil_2026.07.04` spring-headless.exe. Contains 450 echoed sync checksums (every 60 frames). |
| `script.txt`, `m4_driver.lua`, `record.ps1` | How it was recorded. `record.ps1` runs from a write dir that holds `script.txt` and `LuaUI/Widgets/m4_driver.lua` (the widget sets speed 20x and `quitforce`s at frame 27000, so the demo gets written). |
| `play.sh`, `m4_play.lua` | Playback, run in WSL from `~/m4`: `~/m4/play.sh native\|wasm <demo>`. Uses a fresh write dir `~/m4/play-<mode>` with the widget in `LuaUI/Widgets`, and reads BAR content straight from the Windows install (`/mnt/c/.../Beyond-All-Reason/data`). The widget runs at max speed. When the server's demo reader closes, it plays 60 more frames and then quits; the server reads ahead, so without the drain the client could stop a few frames short of 27,000. |
| `infolog-native.txt`, `infolog-wasm.txt` | Logs of the passing runs. Look for `[DemoSync]`. |

Pass criterion: `[DemoSync] summary: 450 demo checksums matched, 0 mismatched` and no `[DESYNC WARNING]`.
