#!/usr/bin/env bash
# Package the browser build as a static site in web-harness/dist/.
# usage: build-dist.sh [engine-build-dir=~/build-wasm] [content-dir=~/web-content/out]
# Rebuild the engine first (~/wasm-build.sh engine-web) and the content bundles
# (pack-content.py, see README.md) when they changed. Content is copied (the 2 GB game
# bundle takes a minute); files that are already current are skipped.
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${1:-$HOME/build-wasm}"; CONTENT="${2:-$HOME/web-content/out}"
OUT="$H/dist"
mkdir -p "$OUT/engine" "$OUT/content"
cp "$H/www/dist-src/index.html" "$H/www/dist-src/coi-sw.js" "$H/www/dist-src/_headers" "$H/www/dist-src/serve-static.py" "$OUT/"
cp "$H/www/render.js" "$H/www/opfs-loader.js" "$H/www/test_live.lua" "$OUT/"
cp "$ENGINE/spring-web.js" "$ENGINE/spring-web.wasm" "$OUT/engine/"
for f in "$CONTENT"/*; do
	b="$(basename "$f")"
	if [ ! -f "$OUT/content/$b" ] || [ "$f" -nt "$OUT/content/$b" ] || [ "$(stat -c %s "$f")" != "$(stat -c %s "$OUT/content/$b")" ]; then
		cp "$f" "$OUT/content/$b"
	fi
done
cat > "$OUT/build-info.json" <<JSON
{"built": "$(date -u +%FT%TZ)", "engine": "$(git -C "$HOME/RecoilEngine" describe --always --dirty 2>/dev/null || echo unknown)",
 "engineWasmBytes": $(stat -c %s "$OUT/engine/spring-web.wasm")}
JSON
du -sh "$OUT"
echo "dist ready: python3 $OUT/serve-static.py --port 8090  ->  http://localhost:8090/"
