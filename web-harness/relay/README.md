# Multiplayer relay (Cloudflare Worker)

Browsers can't send UDP, so browser players reach each other through this relay. Each game is a **room**: a Durable Object (`Room` in `src/index.js`) that holds one WebSocket per player and forwards the engine's datagrams between them.

- `wss://<relay>/room/<CODE>?name=<player>&role=host|player|spectator|bridge` joins room `CODE` (3–16 letters/digits, uppercased). The room assigns each peer a virtual IPv4 address `10.77.0.<id>` and sends `{"type":"welcome",…}`, then `{"type":"peers",…}` to everyone whenever someone joins or leaves. It refuses a second host, a duplicate name, and more than 32 peers.
- Text frames are lobby messages (JSON). The room adds `from`/`fromName` and sends them to everyone else, or to `to` alone.
- Binary frames are datagrams: `u32 ip, u16 port, u16 port` (big-endian), then the payload. A peer sends `dst ip, dst port, src port`; the room delivers it to the peer at `dst ip` as `src ip, src port, dst port`. The limit is 16 KiB a frame.
- The room uses the WebSocket hibernation API, so an idle room costs nothing. Nothing is stored.

The engine side is `rts/System/Net/WebNet.cpp` in the engine fork (active with `RECOIL_WEB_NET=1`). The page side is `www/webnet.js` and `www/webnet-worker.js`. The lobby and game-script logic is the multiplayer section of `www/render.js`.

## Run locally
```
npm install
npx cf dev                     # http://localhost:5173
node test-relay.mjs ws://localhost:5173
```
Then open the dev page as host and as a player, using two origins so the two engines don't share browser storage:
`http://localhost:8080/render.html?mp=host&room=TEST&name=Alice&relay=ws://localhost:5173` and
`http://127.0.0.1:8080/render.html?mp=join&room=TEST&name=Bob&relay=ws://localhost:5173`. The host starts with `harness.mpStart()`, or adds `&mpstart=2` to start automatically once two players are in.

## Deploy
Uses the `cf` CLI (`cloudflare.config.ts`, no Wrangler file):
```
npx cf auth login
npx cf deploy                  # prints https://bar-web-relay.<account>.workers.dev
```
Then build the delivery site with it: `BAR_RELAY=wss://bar-web-relay.<account>.workers.dev bash ../build-dist.sh`.

## Native engines (cross-play)
`../webnet-bridge.py` joins a room as one more peer and carries datagrams to and from native engines over real UDP. It can connect to a native host that browser players join, or let native clients join a browser host. Native and browser engines must be built from the same engine commit (the server checks the version string). See the script's `--help`.
