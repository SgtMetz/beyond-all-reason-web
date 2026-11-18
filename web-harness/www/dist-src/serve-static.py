#!/usr/bin/env python3
"""A plain static file server for the dist/ site: no COOP/COEP headers on purpose (coi-sw.js
adds them in the browser), correct MIME types for .wasm/.js, and Range requests (the content loader fetches the game bundle in parallel byte ranges).
usage: serve-static.py [--port 8090] [dir]"""
import argparse, functools, http.server, os, re

class H(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".js": "text/javascript", ".json": "application/json",
                      ".bin": "application/octet-stream", ".lua": "text/plain"}

    def do_GET(self):
        # byte ranges: the content loader fetches the game bundle in parallel parts
        path = self.translate_path(self.path)
        m = re.match(r"bytes=(\d+)-(\d*)$", self.headers.get("Range") or "")
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

p = argparse.ArgumentParser()
p.add_argument("--port", type=int, default=8090)
p.add_argument("dir", nargs="?", default=os.path.dirname(os.path.abspath(__file__)))
a = p.parse_args()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), functools.partial(H, directory=a.dir))
print(f"serving {a.dir} on http://localhost:{a.port}/ (no isolation headers)")
srv.serve_forever()
