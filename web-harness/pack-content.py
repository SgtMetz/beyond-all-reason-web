#!/usr/bin/env python3
"""Pack the content one BAR replay needs into bundles for the browser harness.

Run in WSL. Three steps (see README.md):

  stage   copy the game (rapid .sdp + its pool files), the map, the engine base
          archives and the replay out of a BAR install into STAGE, keeping mtimes
  (then)  build-cache.sh plays the replay natively against STAGE, which writes the
          archive scan/hash cache (and checks 450/450 on the way)
  bundle  rewrite the cache's paths to the browser layout and write OUT/manifest.json
          plus one .bin per bundle (the files concatenated in manifest order)

Browser layout (OPFS root, mounted by the engine at /recoil):
  base/ maps/ packages/ pool/ demos/   read-only content
  write/                               write dir: widget, pre-built cache, springsettings.cfg
  mtimes.tsv                           original mtimes, restored by the engine at start
"""
import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import sys


def sdp_entries(sdp_path):
    """(archive path, pool file path relative to pool/) for every file of a rapid .sdp."""
    data = gzip.open(sdp_path).read()
    i, out = 0, []
    while i < len(data):
        n = data[i]
        name = data[i + 1:i + 1 + n].decode("utf-8", "replace").lower()
        i += 1 + n
        md5 = data[i:i + 16].hex()
        i += 16 + 4 + 4  # md5, crc32, size
        out.append((name, f"{md5[:2]}/{md5[2:]}.gz"))
    return out


def sdp_pool_files(sdp_path):
    """Pool file paths (relative to pool/) referenced by a rapid .sdp."""
    return [rel for _, rel in sdp_entries(sdp_path)]


# Game files a 1v1 skirmish doesn't need to start: they go to the "extra" bundle, which the
# page fetches in the background once the game runs (opfs-loader.js "deferred"). Music
# (536 MB) then starts playing once it has arrived; raptor/scavenger assets belong to other
# game modes; lava textures to lava maps. About 765 MB of the 2 GB game. Not models or
# sounds: the engine loads every unit def's model at start (a missing raptor model aborts
# the load), raptors included.
DEFERRED_PREFIXES = (
    "music/",
    "unitpics/scavengers/", "unitpics/raptors/",
    "luaui/images/raptor_scum/", "luaui/images/lava/",
    "singleplayer/",
)


def copy_keep_mtime(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    st = os.stat(src)
    if os.path.exists(dst):
        dt = os.stat(dst)
        if dt.st_size == st.st_size and int(dt.st_mtime) == int(st.st_mtime):
            return st.st_size
    shutil.copyfile(src, dst)
    os.utime(dst, (st.st_atime, st.st_mtime))
    return st.st_size


def cmd_stage(a):
    data = os.path.join(a.stage, "data")
    total = 0
    sdp = os.path.join(a.bar, "packages", a.sdp)
    total += copy_keep_mtime(sdp, os.path.join(data, "packages", a.sdp))
    pool = sdp_pool_files(sdp)
    for k, rel in enumerate(pool):
        total += copy_keep_mtime(os.path.join(a.bar, "pool", rel), os.path.join(data, "pool", rel))
        if k % 2000 == 0:
            print(f"  pool {k}/{len(pool)}", flush=True)
    total += copy_keep_mtime(os.path.join(a.bar, "maps", a.map), os.path.join(data, "maps", a.map))
    for root, _, files in os.walk(os.path.join(a.base_build, "base")):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, a.base_build)
            total += copy_keep_mtime(src, os.path.join(a.stage, "engine", rel))
    total += copy_keep_mtime(a.demo, os.path.join(data, "demos", os.path.basename(a.demo)))
    print(f"staged {len(pool)} pool files, {total / 1e6:.0f} MB in {a.stage}")


def list_files(root, sub):
    out = []
    for r, _, files in os.walk(os.path.join(root, sub)):
        for f in sorted(files):
            out.append(os.path.relpath(os.path.join(r, f), root).replace(os.sep, "/"))
    return sorted(out)


def write_bundle(out_dir, name, entries):
    """entries: list of (dest path under /recoil, source path or bytes, mtime)."""
    meta, h = [], hashlib.sha1()
    path = os.path.join(out_dir, name + ".bin")
    with open(path, "wb") as o:
        for dest, src, mtime in entries:
            blob = src if isinstance(src, bytes) else None
            size = len(blob) if blob is not None else os.path.getsize(src)
            meta.append([dest, size, int(mtime)])
            h.update(f"{dest}\0{size}\0{int(mtime)}\n".encode())
            if blob is not None:
                o.write(blob)
                h.update(blob)
            else:
                with open(src, "rb") as i:
                    shutil.copyfileobj(i, o, 1 << 20)
    total = sum(m[1] for m in meta)
    print(f"  {name}.bin: {len(meta)} files, {total / 1e6:.1f} MB")
    return {"name": name, "file": name + ".bin", "size": total, "id": h.hexdigest(), "files": meta}


def cmd_bundle(a):
    stage = os.path.abspath(a.stage)
    data = os.path.join(stage, "data")
    engine = os.path.join(stage, "engine")
    os.makedirs(a.out, exist_ok=True)

    def entries(root, rels):
        return [(rel, os.path.join(root, rel), os.stat(os.path.join(root, rel)).st_mtime) for rel in rels]

    groups = {
        "base": entries(engine, list_files(engine, "base")),
        "map": entries(data, list_files(data, "maps")),
        "game": entries(data, list_files(data, "packages") + list_files(data, "pool")),
        "demo": entries(data, list_files(data, "demos")),
    }

    # move the pool files only deferred paths use into "extra" (a pool file shared with a
    # needed path stays in "game")
    need, defer = set(), set()
    for sdp in list_files(data, "packages"):
        if sdp.endswith(".sdp"):
            for name, rel in sdp_entries(os.path.join(data, sdp)):
                (defer if name.startswith(DEFERRED_PREFIXES) else need).add("pool/" + rel)
    defer -= need
    groups["extra"] = [e for e in groups["game"] if e[0] in defer]
    groups["game"] = [e for e in groups["game"] if e[0] not in defer]

    # the renderer build needs the engine's default fonts (cont/fonts in the engine source);
    # they are looked up as fonts/<name> in the data dirs
    if a.fonts:
        fonts = os.path.abspath(a.fonts)
        groups["base"] += [("fonts/" + f, os.path.join(fonts, f), os.stat(os.path.join(fonts, f)).st_mtime)
                           for f in sorted(os.listdir(fonts)) if f.lower().endswith((".otf", ".ttf"))]

    # pre-built archive cache from build-cache.sh: point its paths at /recoil
    caches = sorted(f for f in os.listdir(os.path.join(a.cache_write, "cache")) if re.match(r"ArchiveCache\d+\.lua$", f))
    if not caches:
        sys.exit("no ArchiveCache*.lua in " + a.cache_write + "/cache (run build-cache.sh first)")
    cache_name = caches[-1]
    text = open(os.path.join(a.cache_write, "cache", cache_name), encoding="utf-8").read()
    text = text.replace(f'"{data}/', '"/recoil/').replace(f'"{os.path.abspath(a.base_build)}/', '"/recoil/')
    leftover = sorted(set(re.findall(r'path = "([^"]*)"', text)) - {p for p in re.findall(r'path = "(/recoil/[^"]*)"', text)})
    if leftover:
        print("  note: cache entries outside the bundle (ignored by the engine):", leftover)

    mtimes = []
    for g in groups.values():
        # the archive scanner validates its cache by the mtimes of archives (.sdp, .sd7, .sdz, the
        # demo), not of the rapid pool's files; restoring those 18,000 costs ~14 s of startup
        mtimes += [f"{int(m)}\t{dest}\n" for dest, _, m in g if not dest.startswith("pool/")]

    widget = open(a.widget, "rb").read()
    now = int(os.stat(a.widget).st_mtime)
    # The Node/native runs read the BAR install's springsettings.cfg, which sets these
    # two. Without them the engine keeps every archive file it reads in memory
    # (VFSCacheArchiveFiles defaults to 1), which takes the 2 GB game to ~4 GiB of wasm heap.
    settings = (
        "VFSCacheArchiveFiles = 0\n"
        "UseLuaMemPools = 0\n"
    )
    groups["run"] = [
        ("write/springsettings.cfg", settings.encode(), now),
        ("write/cache/" + cache_name, text.encode("utf-8"), now),
        ("write/LuaUI/Widgets/" + os.path.basename(a.widget), widget, now),
        ("mtimes.tsv", "".join(mtimes).encode(), now),
    ]

    manifest = {
        "format": 1,
        "demo": "/recoil/" + groups["demo"][0][0],
        "bundles": [write_bundle(a.out, n, groups[n]) for n in ("base", "map", "game", "demo", "run", "extra")],
    }
    manifest["bundles"][-1]["deferred"] = True
    with open(os.path.join(a.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, separators=(",", ":"))
    print(f"wrote {a.out}/manifest.json ({sum(b['size'] for b in manifest['bundles']) / 1e6:.0f} MB in total)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stage")
    s.add_argument("--bar", required=True, help="BAR data dir (holds packages/, pool/, maps/)")
    s.add_argument("--sdp", required=True, help="rapid package of the game, e.g. 44fd...df.sdp")
    s.add_argument("--map", required=True, help="map archive file name under maps/")
    s.add_argument("--demo", required=True, help="the replay (.sdfz)")
    s.add_argument("--base-build", required=True, help="engine build dir whose base/ is shipped (the native one used by build-cache.sh)")
    s.add_argument("--stage", required=True)
    b = sub.add_parser("bundle")
    b.add_argument("--stage", required=True)
    b.add_argument("--base-build", required=True)
    b.add_argument("--cache-write", required=True, help="write dir of the build-cache.sh run")
    b.add_argument("--widget", required=True, help="playback widget (m4_play.lua)")
    b.add_argument("--fonts", help="engine cont/fonts dir; its .otf/.ttf files are shipped as fonts/ (renderer build)")
    b.add_argument("--out", required=True)
    a = p.parse_args()
    {"stage": cmd_stage, "bundle": cmd_bundle}[a.cmd](a)


if __name__ == "__main__":
    main()
