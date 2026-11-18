import { bindings, defineConfig, exports } from "cf/config";

import * as entrypoint from "./src/index.js" with { type: "cf-worker" };

// Multiplayer relay for the browser port: one Durable Object per game room.
export default defineConfig({
	worker: {
		name: "bar-web-relay",
		compatibilityDate: "2026-11-01",
		entrypoint,
		exports: {
			Room: exports.durableObject({ storage: "sqlite" }),
		},
		env: {
			ROOMS: bindings.durableObject({
				worker: "bar-web-relay",
				exportName: "Room",
			}),
		},
	},
});
