#!/usr/bin/env bash
# Toolchain for the BAR -> WebAssembly port (phase 1), run inside WSL2 Ubuntu.
# Installs: build essentials, CMake, Ninja, Node, Python, and the Emscripten SDK (~/emsdk).
set -euo pipefail

sudo apt-get update
sudo apt-get install -y build-essential git cmake ninja-build python3 pkg-config ccache \
	gcc-13 g++-13 clang \
	zlib1g-dev libcurl4-openssl-dev libdevil-dev libunwind-dev libminizip-dev \
	libgl-dev libsdl2-dev

# Emscripten SDK (official repo), pinned to latest release
if [ ! -d "$HOME/emsdk" ]; then
	git clone https://github.com/emscripten-core/emsdk.git "$HOME/emsdk"
fi
cd "$HOME/emsdk"
git pull --ff-only
./emsdk install latest
./emsdk activate latest
grep -q 'emsdk_env.sh' "$HOME/.bashrc" || echo 'source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1' >> "$HOME/.bashrc"

# shellcheck disable=SC1091
source "$HOME/emsdk/emsdk_env.sh" >/dev/null
echo "---- versions ----"
cmake --version | head -1
ninja --version
gcc-13 --version | head -1
emcc --version | head -1
node --version
