#!/usr/bin/env python3
"""Tiny static server for the browser harness, with the headers SharedArrayBuffer
(pthreads) needs: Cross-Origin-Opener-Policy: same-origin and
Cross-Origin-Embedder-Policy: require-corp (plus CORP for good measure).

URL layout:
  /            the harness page (www/ next to this script)
  /engine/     the engine build dir (spring-headless-web.js/.wasm)
  /content/    pack-content.py's output (manifest.json, *.bin)
  POST /log/<name>.txt   saves the page's log (engine output + harness summary) to --log-dir

usage: serve.py --engine ~/build-wasm --content ~/web-content/out [--port 8080]
"""
import argparse
import http.server
import os
import posixpath
import re
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    roots = {}
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".json": "application/json",
        ".bin": "application/octet-stream",
    }

    def translate_path(self, path):
        path = posixpath.normpath(urllib.parse.unquote(path.split("?", 1)[0].split("#", 1)[0]))
        for prefix, root in self.roots.items():
            if path == prefix.rstrip("/") or path.startswith(prefix):
                rel = path[len(prefix):] if path.startswith(prefix) else ""
                parts = [p for p in rel.split("/") if p not in ("", ".", "..")]
                return os.path.join(root, *parts)
        return os.path.join(self.roots["/"], "__missing__")

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    log_dir = None

    def do_GET(self):
        # byte ranges: the content loader fetches the game bundle in parallel parts
        rng = self.headers.get("Range")
        path = self.translate_path(self.path)
        m = re.match(r"bytes=(\d+)-(\d*)$", rng or "")
        if m and os.path.isfile(path):
            size = os.path.getsize(path)
            start = int(m.group(1))
            end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            if start > end:
                self.send_error(416)
                return
            self.send_response(206)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    data = f.read(min(1 << 20, left))
                    if not data:
                        break
                    try:
                        self.wfile.write(data)
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    left -= len(data)
            return
        super().do_GET()

    def do_POST(self):
        # the page posts its full log here when the engine exits: POST /log/<name>.txt
        name = os.path.basename(urllib.parse.unquote(self.path.split("?", 1)[0]))
        if not self.path.startswith("/log/") or not name.endswith((".txt", ".png")) or not self.log_dir:
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        os.makedirs(self.log_dir, exist_ok=True)
        with open(os.path.join(self.log_dir, name), "wb") as f:
            f.write(self.rfile.read(length))
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *args):
        if not self.path.startswith("/content/") or "manifest" in self.path:
            super().log_message(fmt, *args)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--engine", required=True, help="dir with spring-headless-web.js/.wasm")
    p.add_argument("--content", required=True, help="pack-content.py bundle output dir")
    p.add_argument("--log-dir", default=os.path.join(HERE, "logs"), help="where POST /log/<name>.txt is saved")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8080)
    a = p.parse_args()
    Handler.roots = {
        "/engine/": os.path.abspath(os.path.expanduser(a.engine)),
        "/content/": os.path.abspath(os.path.expanduser(a.content)),
        "/": os.path.join(HERE, "www"),
    }
    Handler.log_dir = os.path.abspath(os.path.expanduser(a.log_dir))
    srv = http.server.ThreadingHTTPServer((a.host, a.port), Handler)
    print(f"serving http://localhost:{a.port}/ (engine {Handler.roots['/engine/']}, content {Handler.roots['/content/']})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
