#!/usr/bin/env python3
"""Bridge between the browser multiplayer relay and native Recoil engines (real UDP).

Browsers can't send UDP, so browser players reach each other through the relay
(web-harness/relay). This program joins a relay room as one more peer and carries the
engine's datagrams between that room and native engines on this machine or LAN.
The native engine must be built from the same engine commit as the browser build
(the game server refuses other versions, and other builds would desync).

Native host, browser players join it:
    webnet-bridge.py --relay wss://RELAY --room CODE --native-host 127.0.0.1:8452
  Start the native host first, with a script whose [playerN] names match the browser
  players' names. Browser players open the page with ?mp=join&room=CODE&name=NAME; the
  bridge tells each of them to connect, and their traffic reaches the native host from
  one local UDP port per browser player.

Browser host, native players join it:
    webnet-bridge.py --relay wss://RELAY --room CODE --listen 8452 --players Alice,Bob
  The bridge announces the names, so the browser host puts them in its script. Native
  players then start a client script pointing at this machine:
    [game] { hostip=<this machine>; hostport=8452; myplayername=Alice; ishost=0; }

Only the Python standard library is used.
"""
import argparse, base64, json, os, select, socket, ssl, struct, sys, threading, time
from urllib.parse import urlparse, quote


class WebSocketClient:
    """Minimal RFC 6455 client: unfragmented text/binary frames, ping/pong, close."""

    def __init__(self, url):
        u = urlparse(url)
        port = u.port or (443 if u.scheme == "wss" else 80)
        raw = socket.create_connection((u.hostname, port), timeout=15)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=u.hostname) if u.scheme == "wss" else raw
        key = base64.b64encode(os.urandom(16)).decode()
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("relay closed the connection during the handshake")
            resp += chunk
        head, self.buf = resp.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in status + " ":
            raise ConnectionError(f"relay refused the connection: {status}")
        self.sock.settimeout(None)
        self.lock = threading.Lock()

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("relay connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        """Returns (opcode, payload); opcode 1 text, 2 binary."""
        while True:
            b0, b1 = self._read(2)
            op, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
            if op == 9:
                self._send(10, data)
            elif op == 8:
                raise ConnectionError("relay closed the connection")
            elif op in (1, 2):
                return op, data

    def _send(self, op, data):
        n = len(data)
        head = bytes([0x80 | op])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
        with self.lock:
            self.sock.sendall(head + mask + masked)

    def send_text(self, obj):
        self._send(1, json.dumps(obj).encode())

    def send_binary(self, data):
        self._send(2, data)


def ip_str(n):
    return socket.inet_ntoa(struct.pack(">I", n))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--relay", required=True, help="relay URL, e.g. wss://bar-web-relay.example.workers.dev")
    ap.add_argument("--room", required=True)
    ap.add_argument("--name", default="Bridge")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--native-host", metavar="IP:PORT", help="a native engine hosts the game here")
    mode.add_argument("--listen", type=int, metavar="PORT", help="accept native clients on this UDP port")
    ap.add_argument("--players", default="", help="with --listen: native player names, comma-separated")
    ap.add_argument("--host-port", type=int, default=8452, help="with --listen: the browser host's game port")
    a = ap.parse_args()

    url = f"{a.relay.rstrip('/').replace('http', 'ws', 1)}/room/{quote(a.room)}?name={quote(a.name)}&role=bridge"
    ws = WebSocketClient(url)
    op, data = ws.recv()
    welcome = json.loads(data)
    my_ip = welcome["ipNum"]
    print(f"[bridge] in room {a.room} as {welcome['ip']}", flush=True)

    state = {"peers": [], "started": set()}
    udp_lock = threading.Lock()

    if a.native_host:
        host_ip, host_port = a.native_host.rsplit(":", 1)
        native = (host_ip, int(host_port))
        per_peer = {}  # (room ip, room port) -> local UDP socket towards the native host

        def from_room(src_ip, src_port, dst_port, payload):
            key = (src_ip, src_port)
            with udp_lock:
                s = per_peer.get(key)
                if s is None:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    s.bind(("0.0.0.0", 0))
                    s.setblocking(False)
                    per_peer[key] = s
                    print(f"[bridge] {ip_str(src_ip)}:{src_port} -> native host via local port {s.getsockname()[1]}", flush=True)
            s.sendto(payload, native)

        def on_peers(peers):
            for p in peers:
                if p["role"] in ("player", "spectator", "host") and p["id"] not in state["started"]:
                    state["started"].add(p["id"])
                    ws.send_text({"type": "start", "to": p["id"], "hostIP": welcome["ip"], "hostPort": native[1]})
                    print(f"[bridge] told {p['name']} to join the native host", flush=True)

        def udp_loop():
            while True:
                with udp_lock:
                    items = list(per_peer.items())
                if not items:
                    time.sleep(0.01)
                    continue
                r, _, _ = select.select([s for _, s in items], [], [], 0.01)
                for (src_ip, src_port), s in items:
                    if s in r:
                        try:
                            while True:
                                payload, _ = s.recvfrom(65536)
                                ws.send_binary(struct.pack(">IHH", src_ip, src_port, native[1]) + payload)
                        except (BlockingIOError, InterruptedError):
                            pass
    else:
        names = [n for n in a.players.split(",") if n]
        listen = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        listen.bind(("0.0.0.0", a.listen))
        print(f"[bridge] native clients: connect to this machine, UDP port {a.listen}", flush=True)
        by_endpoint, by_vport = {}, {}
        next_vport = [50000]

        def browser_host():
            for p in state["peers"]:
                if p["role"] == "host":
                    return struct.unpack(">I", socket.inet_aton(p["ip"]))[0]
            return None

        def from_room(src_ip, src_port, dst_port, payload):
            ep = by_vport.get(dst_port)
            if ep:
                listen.sendto(payload, ep)

        def on_peers(peers):
            ws.send_text({"type": "native-players", "names": names})

        def udp_loop():
            while True:
                payload, ep = listen.recvfrom(65536)
                vport = by_endpoint.get(ep)
                if vport is None:
                    vport = by_endpoint[ep] = next_vport[0]
                    by_vport[vport] = ep
                    next_vport[0] += 1
                    print(f"[bridge] native client {ep[0]}:{ep[1]} is {welcome['ip']}:{vport} in the room", flush=True)
                host = browser_host()
                if host is not None:
                    ws.send_binary(struct.pack(">IHH", host, a.host_port, vport) + payload)

        ws.send_text({"type": "native-players", "names": names})

    threading.Thread(target=udp_loop, daemon=True).start()
    try:
        while True:
            op, data = ws.recv()
            if op == 2:
                if len(data) >= 8:
                    src_ip, src_port, dst_port = struct.unpack(">IHH", data[:8])
                    from_room(src_ip, src_port, dst_port, data[8:])
            else:
                msg = json.loads(data)
                if msg.get("type") == "peers":
                    state["peers"] = msg["peers"]
                    print("[bridge] room: " + ", ".join(f"{p['name']} ({p['role']}, {p['ip']})" for p in msg["peers"]), flush=True)
                    on_peers(msg["peers"])
    except (ConnectionError, KeyboardInterrupt) as e:
        print(f"[bridge] stopped: {e}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
