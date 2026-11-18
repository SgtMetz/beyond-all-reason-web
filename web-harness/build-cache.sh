#!/usr/bin/env bash
# Pre-build the archive scan/hash cache for the browser, natively, by playing the
# replay against the staged content only (no other archives in the data dirs).
# Doubles as a check that the staged subset is complete: expect 450/450 checksums.
# usage: build-cache.sh <stage dir> <native build dir> <widget.lua>
set -u
STAGE=$(readlink -f "$1"); NATIVE=$(readlink -f "$2"); WIDGET=$(readlink -f "$3")
W=$STAGE/cache-write
rm -rf "$W"; mkdir -p "$W/LuaUI/Widgets"; cp "$WIDGET" "$W/LuaUI/Widgets/"
DEMO=$(ls "$STAGE"/data/demos/*.sdfz | head -1)
export SPRING_WRITEDIR="$W" SPRING_DATADIR="$W:$STAGE/data"
cd "$W"
start=$(date +%s)
/usr/bin/time -v "$NATIVE/spring-headless" --write-dir "$W" "$DEMO" > "$W/stdout.log" 2>&1
rc=$?
echo "native cache run rc=$rc wall=$(( $(date +%s) - start ))s"
grep -E "\[M4\]|\[DemoSync\] summary|DESYNC|Scanning:|Maximum resident" "$W/stdout.log" | tail -12
ls -la "$W"/cache/ArchiveCache*.lua
