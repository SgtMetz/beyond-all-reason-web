#!/usr/bin/env bash
# usage: play.sh native|wasm <demo.sdfz>
set -u
MODE=$1; DEMO=$(readlink -f "$2")
BAR=/mnt/c/Users/evmet/AppData/Local/Programs/Beyond-All-Reason/data
W=$HOME/m4/play-$MODE
rm -rf "$W"; mkdir -p "$W/LuaUI/Widgets"; cp "$HOME/m4/m4_play.lua" "$W/LuaUI/Widgets/"
if [ "$MODE" = native ]; then
	BASE=$HOME/build-native-wasmport; CMD=("$BASE/spring-headless")
else
	export EMSDK_QUIET=1; source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1
	BASE=$HOME/build-wasm; CMD=(node "$BASE/spring-headless.js")
fi
export SPRING_WRITEDIR="$W" SPRING_DATADIR="$W:$BASE:$BAR"
cd "$W"
start=$(date +%s)
/usr/bin/time -v "${CMD[@]}" --write-dir "$W" "$DEMO" > "$W/stdout.log" 2>&1
rc=$?
echo "mode=$MODE rc=$rc wall=$(( $(date +%s) - start ))s"
grep -E "\[M4\]|\[DemoSync\]|DESYNC|Maximum resident" "$W/stdout.log" "$W/infolog.txt" 2>/dev/null | tail -15
